import Foundation
import Testing
@testable import GSDEConfig

@Suite("Code-server manager")
struct CodeServerManagerTests {
    @Test("starts one managed process per pane with random localhost port and generated password")
    func startsManagedProcessWithLaunchParameters() async throws {
        let project = try temporaryDirectory()
        let configURL = project.appendingPathComponent(".config/gsde/config.toml")
        let launcher = RecordingCodeServerLauncher()
        let readiness = ImmediateReadinessChecker()
        let executableURL = URL(fileURLWithPath: "/tmp/fake-code-server")
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: readiness
        )

        let session = try await manager.start(CodeServerStartRequest(
            paneID: "editor",
            configSource: .projectDefault(configURL),
            executableURL: executableURL,
            readinessTimeout: 1
        ))

        let launched = try #require(launcher.launchedConfigurations.first)
        #expect(session.paneID == "editor")
        #expect(session.serverURL.host == "127.0.0.1")
        #expect(session.serverURL.port != nil)
        #expect(session.serverURL.port != 0)
        #expect(session.password.count >= 24)
        #expect(launched.executableURL == executableURL)
        #expect(launched.serverURL == session.serverURL)
        #expect(launched.environment == ["PASSWORD": session.password])
        #expect(launched.arguments.prefix(2) == ["--bind-addr", "127.0.0.1:\(session.serverURL.port!)"])
        #expect(FileManager.default.fileExists(atPath: launched.stateDirectories.codeServerUserDataDirectory.path))
        #expect(FileManager.default.fileExists(atPath: launched.stateDirectories.codeServerExtensionsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: launched.stateDirectories.cefCacheDirectory.path))
        #expect(readiness.readyURLs == [session.serverURL])
    }

    @Test("rejects duplicate starts until the pane is stopped")
    func rejectsDuplicateStartsUntilStopped() async throws {
        let project = try temporaryDirectory()
        let configURL = project.appendingPathComponent(".config/gsde/config.toml")
        let launcher = RecordingCodeServerLauncher()
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: ImmediateReadinessChecker()
        )
        let request = CodeServerStartRequest(
            paneID: "editor",
            configSource: .projectDefault(configURL),
            executableURL: URL(fileURLWithPath: "/tmp/fake-code-server"),
            readinessTimeout: 1
        )

        _ = try await manager.start(request)
        await #expect(throws: CodeServerManagerError.paneAlreadyRunning("editor")) {
            try await manager.start(request)
        }

        await manager.stop(paneID: "editor")
        _ = try await manager.start(request)
        #expect(launcher.handles.count == 2)
        #expect(launcher.handles[0].terminateCallCount == 1)
        #expect(launcher.handles[0].waitUntilExitCallCount == 1)
    }

    @Test("captures output and surfaces readiness timeout diagnostics")
    func capturesOutputAndSurfacesReadinessTimeoutDiagnostics() async throws {
        let project = try temporaryDirectory()
        let launcher = RecordingCodeServerLauncher()
        launcher.stdoutOnLaunch = "booting\n"
        launcher.stderrOnLaunch = "warning\n"
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: FailingReadinessChecker(error: .readinessTimedOut(
                paneID: "wrong",
                url: URL(string: "http://127.0.0.1:1/")!,
                diagnostics: CodeServerProcessDiagnostics()
            ))
        )

        await #expect(throws: CodeServerManagerError.readinessTimedOut(
            paneID: "editor",
            url: URL(string: "http://127.0.0.1:1/")!,
            diagnostics: CodeServerProcessDiagnostics(stdout: "booting\n", stderr: "warning\n")
        )) {
            try await manager.start(CodeServerStartRequest(
                paneID: "editor",
                configSource: .projectDefault(project.appendingPathComponent(".config/gsde/config.toml")),
                executableURL: URL(fileURLWithPath: "/tmp/fake-code-server"),
                readinessTimeout: 0.01
            ))
        }
        #expect(launcher.handles.first?.terminateCallCount == 1)
        #expect(launcher.handles.first?.waitUntilExitCallCount == 1)
        #expect(await manager.status(forPaneID: "editor") == nil)
    }

    @Test("fails startup if the process exits after readiness but before the session is returned")
    func failsStartupWhenProcessExitsBeforeSessionReturn() async throws {
        let project = try temporaryDirectory()
        let launcher = RecordingCodeServerLauncher()
        launcher.stdoutOnLaunch = "served once\n"
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: TerminatingReadinessChecker()
        )

        await #expect(throws: CodeServerManagerError.processExitedBeforeReady(
            paneID: "editor",
            exitCode: 15,
            diagnostics: CodeServerProcessDiagnostics(stdout: "served once\n", stderr: "")
        )) {
            try await manager.start(CodeServerStartRequest(
                paneID: "editor",
                configSource: .projectDefault(project.appendingPathComponent(".config/gsde/config.toml")),
                executableURL: URL(fileURLWithPath: "/tmp/fake-code-server"),
                readinessTimeout: 1
            ))
        }
        #expect(await manager.status(forPaneID: "editor") == nil)
    }

    @Test("terminates running processes when the manager is released")
    func terminatesRunningProcessesWhenReleased() async throws {
        let project = try temporaryDirectory()
        let launcher = RecordingCodeServerLauncher()
        var manager: CodeServerManager? = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: ImmediateReadinessChecker()
        )

        _ = try await manager?.start(CodeServerStartRequest(
            paneID: "editor",
            configSource: .projectDefault(project.appendingPathComponent(".config/gsde/config.toml")),
            executableURL: URL(fileURLWithPath: "/tmp/fake-code-server"),
            readinessTimeout: 1
        ))
        manager = nil

        #expect(launcher.handles.first?.terminateCallCount == 1)
        #expect(launcher.handles.first?.waitUntilExitCallCount == 1)
    }

    @Test("launches a real subprocess, detects HTTP readiness, captures output, and stops it")
    func launchesRealSubprocessAndStopsIt() async throws {
        let project = try temporaryDirectory()
        let executableURL = project.appendingPathComponent("fake-code-server")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        bind=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --bind-addr) bind="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        host="${bind%:*}"
        port="${bind##*:}"
        echo "fake code-server password length ${#PASSWORD}"
        HOST="$host" PORT="$port" exec python3 -u - <<'PY'
        import http.server
        import os
        import socketserver
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
            def log_message(self, format, *args):
                pass
        with socketserver.TCPServer((os.environ["HOST"], int(os.environ["PORT"])), Handler) as httpd:
            httpd.serve_forever()
        PY
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: DefaultCodeServerProcessLauncher(),
            readinessChecker: HTTPCodeServerReadinessChecker(pollInterval: 0.05, requestTimeout: 0.2)
        )

        let session = try await manager.start(CodeServerStartRequest(
            paneID: "editor",
            configSource: .projectDefault(project.appendingPathComponent(".config/gsde/config.toml")),
            executableURL: executableURL,
            readinessTimeout: 5
        ))
        let (data, response) = try await URLSession.shared.data(from: session.serverURL)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(await manager.diagnostics(forPaneID: "editor")?.stdout.contains("fake code-server password length") == true)
        await manager.stop(paneID: "editor")
        #expect(await manager.status(forPaneID: "editor") == nil)
    }

    @Test("HTTP readiness checking propagates cancellation instead of timing out")
    func httpReadinessCheckingPropagatesCancellation() async throws {
        let checker = HTTPCodeServerReadinessChecker(pollInterval: 1, requestTimeout: 0.1)
        let process = AlwaysRunningProcessHandle()
        let task = Task {
            try await checker.waitUntilReady(
                url: URL(string: "http://127.0.0.1:9/")!,
                process: process,
                timeout: 30,
                diagnostics: { CodeServerProcessDiagnostics() }
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("records post-readiness crashes for callers to surface")
    func recordsPostReadinessCrashes() async throws {
        let project = try temporaryDirectory()
        let launcher = RecordingCodeServerLauncher()
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: ImmediateReadinessChecker()
        )

        _ = try await manager.start(CodeServerStartRequest(
            paneID: "editor",
            configSource: .projectDefault(project.appendingPathComponent(".config/gsde/config.toml")),
            executableURL: URL(fileURLWithPath: "/tmp/fake-code-server"),
            readinessTimeout: 1
        ))
        launcher.handles[0].emit(stream: .stderr, text: "fatal crash\n")
        launcher.handles[0].exit(status: 42)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(await manager.status(forPaneID: "editor") == .exited(
            exitCode: 42,
            diagnostics: CodeServerProcessDiagnostics(stdout: "", stderr: "fatal crash\n")
        ))
    }

    @Test("stale exits from stopped processes do not clear a restarted pane")
    func staleExitsFromStoppedProcessesDoNotClearRestartedPane() async throws {
        let project = try temporaryDirectory()
        let launcher = RecordingCodeServerLauncher()
        launcher.exitsOnTerminate = false
        let manager = CodeServerManager(
            launchBuilder: CodeServerLaunchBuilder(stateResolver: VSCodePaneStateResolver(environment: ["GSDE_PROJECT_DIR": project.path])),
            processLauncher: launcher,
            readinessChecker: ImmediateReadinessChecker()
        )
        let request = CodeServerStartRequest(
            paneID: "editor",
            configSource: .projectDefault(project.appendingPathComponent(".config/gsde/config.toml")),
            executableURL: URL(fileURLWithPath: "/tmp/fake-code-server"),
            readinessTimeout: 1
        )

        _ = try await manager.start(request)
        await manager.stop(paneID: "editor")
        _ = try await manager.start(request)
        launcher.handles[1].emit(stream: .stdout, text: "new process\n")
        launcher.handles[0].exit(status: 15)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(await manager.status(forPaneID: "editor") == .running(
            diagnostics: CodeServerProcessDiagnostics(stdout: "new process\n", stderr: "")
        ))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingCodeServerLauncher: CodeServerProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _launchedConfigurations: [CodeServerLaunchConfiguration] = []
    private var _handles: [RecordingProcessHandle] = []
    var stdoutOnLaunch = ""
    var stderrOnLaunch = ""
    var exitsOnTerminate = true

    var launchedConfigurations: [CodeServerLaunchConfiguration] {
        lock.withLock { _launchedConfigurations }
    }

    var handles: [RecordingProcessHandle] {
        lock.withLock { _handles }
    }

    func launch(
        configuration: CodeServerLaunchConfiguration,
        outputHandler: @escaping CodeServerOutputHandler,
        terminationHandler: @escaping CodeServerTerminationHandler
    ) throws -> any CodeServerProcessHandle {
        let handle = RecordingProcessHandle(
            terminationHandler: terminationHandler,
            outputHandler: outputHandler,
            exitsOnTerminate: exitsOnTerminate
        )
        lock.withLock {
            _launchedConfigurations.append(configuration)
            _handles.append(handle)
        }
        if !stdoutOnLaunch.isEmpty { outputHandler(.stdout, stdoutOnLaunch) }
        if !stderrOnLaunch.isEmpty { outputHandler(.stderr, stderrOnLaunch) }
        return handle
    }
}

private final class AlwaysRunningProcessHandle: CodeServerProcessHandle, @unchecked Sendable {
    var isRunning: Bool { true }
    var terminationStatus: Int32 { 0 }
    func terminate() {}
    func waitUntilExit() {}
}

private final class RecordingProcessHandle: CodeServerProcessHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var status: Int32 = 0
    private let terminationHandler: CodeServerTerminationHandler
    private let outputHandler: CodeServerOutputHandler
    private let exitsOnTerminate: Bool
    private(set) var terminateCallCount = 0
    private(set) var waitUntilExitCallCount = 0

    init(
        terminationHandler: @escaping CodeServerTerminationHandler,
        outputHandler: @escaping CodeServerOutputHandler,
        exitsOnTerminate: Bool = true
    ) {
        self.terminationHandler = terminationHandler
        self.outputHandler = outputHandler
        self.exitsOnTerminate = exitsOnTerminate
    }

    var isRunning: Bool { lock.withLock { running } }
    var terminationStatus: Int32 { lock.withLock { status } }

    func emit(stream: CodeServerOutputStream, text: String) {
        outputHandler(stream, text)
    }

    func exit(status: Int32) {
        let shouldNotify = lock.withLock { () -> Bool in
            guard running else { return false }
            running = false
            self.status = status
            return true
        }
        if shouldNotify { terminationHandler(status) }
    }

    func terminate() {
        lock.withLock { terminateCallCount += 1 }
        if exitsOnTerminate { exit(status: 15) }
    }

    func waitUntilExit() {
        lock.withLock { waitUntilExitCallCount += 1 }
    }
}

private final class ImmediateReadinessChecker: CodeServerReadinessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _readyURLs: [URL] = []

    var readyURLs: [URL] { lock.withLock { _readyURLs } }

    func waitUntilReady(
        url: URL,
        process: any CodeServerProcessHandle,
        timeout: TimeInterval,
        diagnostics: @escaping @Sendable () -> CodeServerProcessDiagnostics
    ) async throws {
        lock.withLock { _readyURLs.append(url) }
    }
}

private struct TerminatingReadinessChecker: CodeServerReadinessChecking {
    func waitUntilReady(
        url: URL,
        process: any CodeServerProcessHandle,
        timeout: TimeInterval,
        diagnostics: @escaping @Sendable () -> CodeServerProcessDiagnostics
    ) async throws {
        process.terminate()
    }
}

private struct FailingReadinessChecker: CodeServerReadinessChecking {
    let error: CodeServerManagerError

    func waitUntilReady(
        url: URL,
        process: any CodeServerProcessHandle,
        timeout: TimeInterval,
        diagnostics: @escaping @Sendable () -> CodeServerProcessDiagnostics
    ) async throws {
        switch error {
        case .readinessTimedOut:
            throw CodeServerManagerError.readinessTimedOut(paneID: "wrong", url: URL(string: "http://127.0.0.1:1/")!, diagnostics: diagnostics())
        case .processExitedBeforeReady:
            throw CodeServerManagerError.processExitedBeforeReady(paneID: "wrong", exitCode: process.terminationStatus, diagnostics: diagnostics())
        default:
            throw error
        }
    }
}
