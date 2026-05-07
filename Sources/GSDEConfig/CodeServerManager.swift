import Darwin
import Foundation

public enum CodeServerOutputStream: String, Sendable {
    case stdout
    case stderr
}

public struct CodeServerProcessDiagnostics: Equatable, Sendable {
    public let stdout: String
    public let stderr: String

    public init(stdout: String = "", stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }

    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum CodeServerManagerError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    case paneAlreadyRunning(String)
    case randomPortUnavailable(Int32)
    case processLaunchFailed(String)
    case processExitedBeforeReady(paneID: String, exitCode: Int32, diagnostics: CodeServerProcessDiagnostics)
    case readinessTimedOut(paneID: String, url: URL, diagnostics: CodeServerProcessDiagnostics)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .paneAlreadyRunning(let paneID):
            return "code-server is already running for pane \(paneID)"
        case .randomPortUnavailable(let errnoCode):
            return "Unable to reserve a random localhost port: \(String(cString: strerror(errnoCode)))"
        case .processLaunchFailed(let message):
            return "Unable to launch code-server: \(message)"
        case .processExitedBeforeReady(let paneID, let exitCode, let diagnostics):
            let output = diagnostics.combinedOutput.isEmpty ? "no output" : diagnostics.combinedOutput
            return "code-server for pane \(paneID) exited before becoming ready with status \(exitCode): \(output)"
        case .readinessTimedOut(let paneID, let url, let diagnostics):
            let output = diagnostics.combinedOutput.isEmpty ? "no output" : diagnostics.combinedOutput
            return "code-server for pane \(paneID) did not become ready at \(url.absoluteString): \(output)"
        }
    }
}

public struct CodeServerStartRequest: Sendable {
    public let paneID: String
    public let configSource: WorkspaceConfigSource
    public let executableURL: URL?
    public let readinessTimeout: TimeInterval
    public let profileMode: VSCodePaneProfileMode

    public init(
        paneID: String,
        configSource: WorkspaceConfigSource,
        executableURL: URL? = nil,
        readinessTimeout: TimeInterval = 20,
        profileMode: VSCodePaneProfileMode = .native
    ) {
        self.paneID = paneID
        self.configSource = configSource
        self.executableURL = executableURL
        self.readinessTimeout = readinessTimeout
        self.profileMode = profileMode
    }
}

public struct ManagedCodeServerSession: Equatable, Sendable {
    public let paneID: String
    public let serverURL: URL
    public let launchConfiguration: CodeServerLaunchConfiguration
    public let diagnostics: CodeServerProcessDiagnostics
}

public enum CodeServerProcessStatus: Equatable, Sendable {
    case running(diagnostics: CodeServerProcessDiagnostics)
    case exited(exitCode: Int32, diagnostics: CodeServerProcessDiagnostics)
}

public protocol CodeServerProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func terminate()
    func waitUntilExit()
}

public typealias CodeServerOutputHandler = @Sendable (CodeServerOutputStream, String) -> Void
public typealias CodeServerTerminationHandler = @Sendable (Int32) -> Void

public protocol CodeServerProcessLaunching: Sendable {
    func launch(
        configuration: CodeServerLaunchConfiguration,
        outputHandler: @escaping CodeServerOutputHandler,
        terminationHandler: @escaping CodeServerTerminationHandler
    ) throws -> any CodeServerProcessHandle
}

public protocol CodeServerReadinessChecking: Sendable {
    func waitUntilReady(
        url: URL,
        process: any CodeServerProcessHandle,
        timeout: TimeInterval,
        diagnostics: @escaping @Sendable () -> CodeServerProcessDiagnostics
    ) async throws
}

public struct HTTPCodeServerReadinessChecker: CodeServerReadinessChecking {
    private let pollInterval: TimeInterval
    private let requestTimeout: TimeInterval

    public init(pollInterval: TimeInterval = 0.1, requestTimeout: TimeInterval = 1.0) {
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
    }

    public func waitUntilReady(
        url: URL,
        process: any CodeServerProcessHandle,
        timeout: TimeInterval,
        diagnostics: @escaping @Sendable () -> CodeServerProcessDiagnostics
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if !process.isRunning {
                throw CodeServerManagerError.processExitedBeforeReady(
                    paneID: "<unknown>",
                    exitCode: process.terminationStatus,
                    diagnostics: diagnostics()
                )
            }
            if try await responds(at: url) { return }
            let delay = UInt64(max(pollInterval, 0.01) * 1_000_000_000)
            try await Task.sleep(nanoseconds: delay)
        }
        throw CodeServerManagerError.readinessTimedOut(paneID: "<unknown>", url: url, diagnostics: diagnostics())
    }

    private func responds(at url: URL) async throws -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse) != nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return false
        }
    }
}

public struct DefaultCodeServerProcessLauncher: CodeServerProcessLaunching {
    public init() {}

    public func launch(
        configuration: CodeServerLaunchConfiguration,
        outputHandler: @escaping CodeServerOutputHandler,
        terminationHandler: @escaping CodeServerTerminationHandler
    ) throws -> any CodeServerProcessHandle {
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        process.currentDirectoryURL = configuration.stateDirectories.workspaceFolder
        VSCodePaneDebugLog.write(
            "launching code-server process: executable=\(configuration.executableURL.path), currentDirectory=\(configuration.stateDirectories.workspaceFolder.path), environment=\(configuration.environment), serverURL=\(configuration.serverURL.absoluteString), arguments=\(configuration.arguments), userData=\(configuration.stateDirectories.codeServerUserDataDirectory.path), extensions=\(configuration.stateDirectories.codeServerExtensionsDirectory.path), cefCache=\(configuration.stateDirectories.cefCacheDirectory.path)"
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let handle = FoundationProcessHandle(process: process)
        stdout.fileHandleForReading.readabilityHandler = { fileHandle in
            emitAvailableText(from: fileHandle, stream: .stdout, outputHandler: outputHandler)
        }
        stderr.fileHandleForReading.readabilityHandler = { fileHandle in
            emitAvailableText(from: fileHandle, stream: .stderr, outputHandler: outputHandler)
        }
        process.terminationHandler = { process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            emitRemainingText(from: stdout.fileHandleForReading, stream: .stdout, outputHandler: outputHandler)
            emitRemainingText(from: stderr.fileHandleForReading, stream: .stderr, outputHandler: outputHandler)
            VSCodePaneDebugLog.write("code-server process terminated: executable=\(configuration.executableURL.path), pid=\(process.processIdentifier), status=\(process.terminationStatus)")
            terminationHandler(process.terminationStatus)
        }

        do {
            try process.run()
            VSCodePaneDebugLog.write("code-server process started: executable=\(configuration.executableURL.path), pid=\(process.processIdentifier), serverURL=\(configuration.serverURL.absoluteString)")
        } catch {
            VSCodePaneDebugLog.write("code-server process launch failed: executable=\(configuration.executableURL.path), error=\(error.localizedDescription)")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw CodeServerManagerError.processLaunchFailed(error.localizedDescription)
        }
        return handle
    }
}

private final class FoundationProcessHandle: CodeServerProcessHandle, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }
}

private func emitAvailableText(
    from fileHandle: FileHandle,
    stream: CodeServerOutputStream,
    outputHandler: CodeServerOutputHandler
) {
    let data = fileHandle.availableData
    guard !data.isEmpty else { return }
    outputHandler(stream, String(decoding: data, as: UTF8.self))
}

private func emitRemainingText(
    from fileHandle: FileHandle,
    stream: CodeServerOutputStream,
    outputHandler: CodeServerOutputHandler
) {
    let data = fileHandle.readDataToEndOfFile()
    guard !data.isEmpty else { return }
    outputHandler(stream, String(decoding: data, as: UTF8.self))
}

public actor CodeServerManager {
    private struct RunningProcess: Sendable {
        let launchID: UUID
        let handle: any CodeServerProcessHandle
        let launchConfiguration: CodeServerLaunchConfiguration
        let port: UInt16
        let outputBuffer: CodeServerOutputBuffer
    }

    private let launchBuilder: CodeServerLaunchBuilder
    private let bundleResolver: CodeServerBundleResolver
    private let processLauncher: any CodeServerProcessLaunching
    private let readinessChecker: any CodeServerReadinessChecking
    private var runningByPaneID: [String: RunningProcess] = [:]
    private var exitedByPaneID: [String: CodeServerProcessStatus] = [:]

    public init(
        launchBuilder: CodeServerLaunchBuilder = CodeServerLaunchBuilder(),
        bundleResolver: CodeServerBundleResolver = CodeServerBundleResolver(),
        processLauncher: any CodeServerProcessLaunching = DefaultCodeServerProcessLauncher(),
        readinessChecker: any CodeServerReadinessChecking = HTTPCodeServerReadinessChecker()
    ) {
        self.launchBuilder = launchBuilder
        self.bundleResolver = bundleResolver
        self.processLauncher = processLauncher
        self.readinessChecker = readinessChecker
    }

    deinit {
        for running in runningByPaneID.values {
            Self.terminateAndWait(running.handle)
            Self.releaseReservedLocalhostPort(running.port)
        }
    }

    public func start(_ request: CodeServerStartRequest) async throws -> ManagedCodeServerSession {
        VSCodePaneDebugLog.write("code-server manager start requested: paneID=\(request.paneID), configSource=\(request.configSource.url?.path ?? "built-in"), explicitExecutable=\(request.executableURL?.path ?? "<bundled>"), profile=\(request.profileMode.rawValue), readinessTimeout=\(request.readinessTimeout)")
        if runningByPaneID[request.paneID] != nil {
            throw CodeServerManagerError.paneAlreadyRunning(request.paneID)
        }
        exitedByPaneID[request.paneID] = nil

        let port = try Self.reserveUnusedLocalhostPort()
        VSCodePaneDebugLog.write("reserved code-server localhost port: paneID=\(request.paneID), port=\(port)")
        return try await start(request, usingReservedPort: port)
    }

    private func start(_ request: CodeServerStartRequest, usingReservedPort port: UInt16) async throws -> ManagedCodeServerSession {
        var portReservationTransferredToRunningProcess = false
        defer {
            if !portReservationTransferredToRunningProcess {
                Self.releaseReservedLocalhostPort(port)
            }
        }

        let executableURL = try request.executableURL ?? bundleResolver.executableURL()
        let configuration = try launchBuilder.configuration(
            executableURL: executableURL,
            paneID: request.paneID,
            configSource: request.configSource,
            port: port,
            profileMode: request.profileMode
        )
        try configuration.stateDirectories.createDirectories()

        let outputBuffer = CodeServerOutputBuffer()
        let launchID = UUID()
        let handle = try processLauncher.launch(
            configuration: configuration,
            outputHandler: { stream, text in outputBuffer.append(text, to: stream) },
            terminationHandler: { [weak self] exitCode in
                Task { await self?.recordExit(paneID: request.paneID, launchID: launchID, exitCode: exitCode) }
            }
        )
        runningByPaneID[request.paneID] = RunningProcess(
            launchID: launchID,
            handle: handle,
            launchConfiguration: configuration,
            port: port,
            outputBuffer: outputBuffer
        )
        portReservationTransferredToRunningProcess = true

        do {
            VSCodePaneDebugLog.write("waiting for code-server readiness: paneID=\(request.paneID), url=\(configuration.serverURL.absoluteString), timeout=\(request.readinessTimeout)")
            try await readinessChecker.waitUntilReady(
                url: configuration.serverURL,
                process: handle,
                timeout: request.readinessTimeout,
                diagnostics: { outputBuffer.diagnostics }
            )
            VSCodePaneDebugLog.write("code-server readiness succeeded: paneID=\(request.paneID), url=\(configuration.serverURL.absoluteString)")
            try Task.checkCancellation()
        } catch let error as CodeServerManagerError {
            stopRunningProcessIfPresent(paneID: request.paneID)
            exitedByPaneID[request.paneID] = nil
            throw Self.rewritePaneID(in: error, paneID: request.paneID)
        } catch {
            stopRunningProcessIfPresent(paneID: request.paneID)
            exitedByPaneID[request.paneID] = nil
            throw error
        }

        if !handle.isRunning {
            stopRunningProcessIfPresent(paneID: request.paneID)
            exitedByPaneID[request.paneID] = nil
            throw CodeServerManagerError.processExitedBeforeReady(
                paneID: request.paneID,
                exitCode: handle.terminationStatus,
                diagnostics: outputBuffer.diagnostics
            )
        }

        VSCodePaneDebugLog.write("code-server session ready: paneID=\(request.paneID), url=\(configuration.serverURL.absoluteString), workspaceFolder=\(configuration.stateDirectories.workspaceFolder.path)")
        return ManagedCodeServerSession(
            paneID: request.paneID,
            serverURL: configuration.serverURL,
            launchConfiguration: configuration,
            diagnostics: outputBuffer.diagnostics
        )
    }

    public func diagnostics(forPaneID paneID: String) -> CodeServerProcessDiagnostics? {
        switch status(forPaneID: paneID) {
        case .running(let diagnostics), .exited(_, let diagnostics): diagnostics
        case nil: nil
        }
    }

    public func status(forPaneID paneID: String) -> CodeServerProcessStatus? {
        if let running = runningByPaneID[paneID] {
            return .running(diagnostics: running.outputBuffer.diagnostics)
        }
        return exitedByPaneID[paneID]
    }

    public func stop(paneID: String) {
        exitedByPaneID[paneID] = nil
        stopRunningProcessIfPresent(paneID: paneID)
    }

    public func stopAll() {
        let runningProcesses = Array(runningByPaneID.values)
        runningByPaneID.removeAll()
        exitedByPaneID.removeAll()
        for running in runningProcesses {
            Self.terminateAndWait(running.handle)
            Self.releaseReservedLocalhostPort(running.port)
        }
    }

    private func recordExit(paneID: String, launchID: UUID, exitCode: Int32) {
        guard let running = runningByPaneID[paneID], running.launchID == launchID else { return }
        runningByPaneID[paneID] = nil
        Self.releaseReservedLocalhostPort(running.port)
        exitedByPaneID[paneID] = .exited(exitCode: exitCode, diagnostics: running.outputBuffer.diagnostics)
    }

    private func stopRunningProcessIfPresent(paneID: String) {
        guard let running = runningByPaneID.removeValue(forKey: paneID) else { return }
        Self.terminateAndWait(running.handle)
        Self.releaseReservedLocalhostPort(running.port)
    }

    private static func terminateAndWait(_ handle: any CodeServerProcessHandle) {
        handle.terminate()
        handle.waitUntilExit()
    }

    private static func rewritePaneID(in error: CodeServerManagerError, paneID: String) -> CodeServerManagerError {
        switch error {
        case .processExitedBeforeReady(_, let exitCode, let diagnostics):
            return .processExitedBeforeReady(paneID: paneID, exitCode: exitCode, diagnostics: diagnostics)
        case .readinessTimedOut(_, let url, let diagnostics):
            return .readinessTimedOut(paneID: paneID, url: url, diagnostics: diagnostics)
        default:
            return error
        }
    }

    private static let portReservations = LocalhostPortReservations()

    private static func reserveUnusedLocalhostPort(maxAttempts: Int = 32) throws -> UInt16 {
        var lastError: CodeServerManagerError?
        for _ in 0..<maxAttempts {
            do {
                let port = try randomLocalhostPort()
                if portReservations.reserve(port) { return port }
            } catch let error as CodeServerManagerError {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw CodeServerManagerError.randomPortUnavailable(EADDRINUSE)
    }

    private static func releaseReservedLocalhostPort(_ port: UInt16) {
        portReservations.release(port)
    }

    private static func randomLocalhostPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CodeServerManagerError.randomPortUnavailable(errno) }
        defer { close(descriptor) }

        var value: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw CodeServerManagerError.randomPortUnavailable(errno)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw CodeServerManagerError.randomPortUnavailable(errno) }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else { throw CodeServerManagerError.randomPortUnavailable(errno) }
        return UInt16(bigEndian: boundAddress.sin_port)
    }
}

private final class LocalhostPortReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var reservedPorts: Set<UInt16> = []

    func reserve(_ port: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reservedPorts.contains(port) else { return false }
        reservedPorts.insert(port)
        return true
    }

    func release(_ port: UInt16) {
        lock.lock()
        reservedPorts.remove(port)
        lock.unlock()
    }
}

private final class CodeServerOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""

    var diagnostics: CodeServerProcessDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return CodeServerProcessDiagnostics(stdout: stdout, stderr: stderr)
    }

    func append(_ text: String, to stream: CodeServerOutputStream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: stdout += text
        case .stderr: stderr += text
        }
    }
}
