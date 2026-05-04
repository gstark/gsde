import Darwin
import Foundation

public enum VSCodePaneLaunchError: Error, Equatable, CustomStringConvertible {
    case missingConfigFile
    case emptyPaneID
    case invalidPort(UInt16)
    case emptyPassword
    case invalidBindHost(String)

    public var description: String {
        switch self {
        case .missingConfigFile:
            return "VS Code pane state requires GSDE_PROJECT_DIR or a resolved workspace config file"
        case .emptyPaneID:
            return "VS Code pane ID must not be empty"
        case .invalidPort(let port):
            return "code-server port must be non-zero; received \(port)"
        case .emptyPassword:
            return "code-server password must not be empty"
        case .invalidBindHost(let host):
            return "code-server bind host must be a non-empty host name or IP address; received \(host.debugDescription)"
        }
    }
}

public struct VSCodePaneStateDirectories: Equatable, Sendable {
    public let paneID: String
    public let workspaceFolder: URL
    public let gsdeConfigDirectory: URL
    public let paneStateDirectory: URL
    public let codeServerUserDataDirectory: URL
    public let codeServerExtensionsDirectory: URL
    public let cefCacheDirectory: URL

    public init(
        paneID: String,
        workspaceFolder: URL,
        gsdeConfigDirectory: URL,
        paneStateDirectory: URL,
        codeServerUserDataDirectory: URL,
        codeServerExtensionsDirectory: URL,
        cefCacheDirectory: URL
    ) {
        self.paneID = paneID
        self.workspaceFolder = workspaceFolder
        self.gsdeConfigDirectory = gsdeConfigDirectory
        self.paneStateDirectory = paneStateDirectory
        self.codeServerUserDataDirectory = codeServerUserDataDirectory
        self.codeServerExtensionsDirectory = codeServerExtensionsDirectory
        self.cefCacheDirectory = cefCacheDirectory
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: codeServerUserDataDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codeServerExtensionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cefCacheDirectory, withIntermediateDirectories: true)
    }
}

public struct VSCodePaneStateResolver: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func directories(paneID: String, configSource: WorkspaceConfigSource) throws -> VSCodePaneStateDirectories {
        let trimmedPaneID = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPaneID.isEmpty else { throw VSCodePaneLaunchError.emptyPaneID }

        let workspaceFolder: URL
        let gsdeConfigDirectory: URL
        if let projectDirectory = Self.nonEmptyEnvironmentURL(named: "GSDE_PROJECT_DIR", in: environment) {
            workspaceFolder = projectDirectory.standardizedFileURL
            gsdeConfigDirectory = workspaceFolder
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("gsde", isDirectory: true)
        } else if let configURL = configSource.url {
            workspaceFolder = configURL.deletingLastPathComponent().standardizedFileURL
            gsdeConfigDirectory = workspaceFolder
        } else {
            throw VSCodePaneLaunchError.missingConfigFile
        }

        let paneStateDirectory = gsdeConfigDirectory
            .appendingPathComponent("panes", isDirectory: true)
            .appendingPathComponent(Self.pathComponent(forPaneID: trimmedPaneID), isDirectory: true)
        return VSCodePaneStateDirectories(
            paneID: trimmedPaneID,
            workspaceFolder: workspaceFolder,
            gsdeConfigDirectory: gsdeConfigDirectory.standardizedFileURL,
            paneStateDirectory: paneStateDirectory.standardizedFileURL,
            codeServerUserDataDirectory: paneStateDirectory
                .appendingPathComponent("code-server", isDirectory: true)
                .appendingPathComponent("user-data", isDirectory: true)
                .standardizedFileURL,
            codeServerExtensionsDirectory: paneStateDirectory
                .appendingPathComponent("code-server", isDirectory: true)
                .appendingPathComponent("extensions", isDirectory: true)
                .standardizedFileURL,
            cefCacheDirectory: paneStateDirectory
                .appendingPathComponent("cef-cache", isDirectory: true)
                .standardizedFileURL
        )
    }

    private static func nonEmptyEnvironmentURL(named name: String, in environment: [String: String]) -> URL? {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func pathComponent(forPaneID paneID: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var encoded = ""
        for scalar in paneID.unicodeScalars {
            if allowedScalars.contains(scalar), scalar.value < 128 {
                encoded.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    encoded += String(format: "%%%02X", byte)
                }
            }
        }
        return encoded == "." || encoded == ".." ? encoded.replacingOccurrences(of: ".", with: "%2E") : encoded
    }
}

public struct CodeServerLaunchConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let serverURL: URL
    public let stateDirectories: VSCodePaneStateDirectories
}

public struct CodeServerLaunchBuilder: Sendable {
    public let bindHost: String
    public let stateResolver: VSCodePaneStateResolver

    public init(bindHost: String = "127.0.0.1", stateResolver: VSCodePaneStateResolver = VSCodePaneStateResolver()) {
        self.bindHost = bindHost
        self.stateResolver = stateResolver
    }

    public func configuration(
        executableURL: URL,
        paneID: String,
        configSource: WorkspaceConfigSource,
        port: UInt16,
        password: String
    ) throws -> CodeServerLaunchConfiguration {
        guard port != 0 else { throw VSCodePaneLaunchError.invalidPort(port) }
        guard !password.isEmpty else { throw VSCodePaneLaunchError.emptyPassword }

        let stateDirectories = try stateResolver.directories(paneID: paneID, configSource: configSource)
        let normalizedBindHost = try Self.normalizedHost(bindHost)
        let bindAddress = Self.bindAddress(host: normalizedBindHost, port: port)
        let arguments = [
            "--bind-addr", bindAddress,
            "--auth", "password",
            "--user-data-dir", stateDirectories.codeServerUserDataDirectory.path,
            "--extensions-dir", stateDirectories.codeServerExtensionsDirectory.path,
            "--disable-telemetry",
            "--disable-update-check",
            stateDirectories.workspaceFolder.path
        ]
        let serverURL = try Self.serverURL(host: normalizedBindHost, port: port)
        return CodeServerLaunchConfiguration(
            executableURL: executableURL,
            arguments: arguments,
            environment: ["PASSWORD": password],
            serverURL: serverURL,
            stateDirectories: stateDirectories
        )
    }

    private static func normalizedHost(_ host: String) throws -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              normalizedHost.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !normalizedHost.contains("/"),
              !normalizedHost.contains("[") && !normalizedHost.contains("]"),
              Self.isValidHostShape(normalizedHost) else {
            throw VSCodePaneLaunchError.invalidBindHost(host)
        }
        return normalizedHost
    }

    private static func isValidHostShape(_ host: String) -> Bool {
        let colonCount = host.reduce(0) { count, character in
            character == ":" ? count + 1 : count
        }
        guard colonCount > 0 else { return true }
        guard colonCount != 1 else { return false }

        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func bindAddress(host: String, port: UInt16) -> String {
        let addressHost = host.contains(":") ? "[\(host)]" : host
        return "\(addressHost):\(port)"
    }

    private static func serverURL(host: String, port: UInt16) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = Int(port)
        components.path = "/"
        guard let url = components.url else {
            throw VSCodePaneLaunchError.invalidBindHost(host)
        }
        return url
    }
}
