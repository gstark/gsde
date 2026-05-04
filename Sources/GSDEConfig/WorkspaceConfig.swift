import CoreGraphics
import Foundation

public struct WorkspaceConfig: Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let panes: [PaneDefinition]
    public let layouts: [LayoutDefinition]
    public let validatedLayouts: [ValidatedMosaicLayout]
    public let startupLayout: String

    public init(
        version: Int,
        panes: [PaneDefinition],
        layouts: [LayoutDefinition],
        validatedLayouts: [ValidatedMosaicLayout],
        startupLayout: String
    ) {
        self.version = version
        self.panes = panes
        self.layouts = layouts
        self.validatedLayouts = validatedLayouts
        self.startupLayout = startupLayout
    }

    public static let builtIn = WorkspaceConfig(
        version: currentVersion,
        panes: [
            PaneDefinition(id: "terminal.main", kind: .terminal, url: nil, profile: nil),
            PaneDefinition(id: "browser.main", kind: .browser, url: URL(string: "https://example.com")!, profile: nil),
            PaneDefinition(id: "terminal.secondary", kind: .terminal, url: nil, profile: nil)
        ],
        layouts: [
            LayoutDefinition(id: "default", areas: ["terminal.main browser.main terminal.secondary"]),
            LayoutDefinition(id: "flipped", areas: ["terminal.secondary browser.main terminal.main"])
        ],
        validatedLayouts: [
            ValidatedMosaicLayout(
                id: "default",
                rowCount: 1,
                columnCount: 3,
                matrix: [["terminal.main", "browser.main", "terminal.secondary"]],
                slots: [
                    MosaicPaneSlot(paneID: "terminal.main", row: 0, column: 0, rowSpan: 1, columnSpan: 1),
                    MosaicPaneSlot(paneID: "browser.main", row: 0, column: 1, rowSpan: 1, columnSpan: 1),
                    MosaicPaneSlot(paneID: "terminal.secondary", row: 0, column: 2, rowSpan: 1, columnSpan: 1)
                ]
            ),
            ValidatedMosaicLayout(
                id: "flipped",
                rowCount: 1,
                columnCount: 3,
                matrix: [["terminal.secondary", "browser.main", "terminal.main"]],
                slots: [
                    MosaicPaneSlot(paneID: "terminal.secondary", row: 0, column: 0, rowSpan: 1, columnSpan: 1),
                    MosaicPaneSlot(paneID: "browser.main", row: 0, column: 1, rowSpan: 1, columnSpan: 1),
                    MosaicPaneSlot(paneID: "terminal.main", row: 0, column: 2, rowSpan: 1, columnSpan: 1)
                ]
            )
        ],
        startupLayout: "default"
    )

    public var startupMosaicLayout: ValidatedMosaicLayout? {
        validatedLayouts.first(where: { $0.id == startupLayout })
    }

    public var startupPaneDefinitions: [PaneDefinition] {
        guard let layout = startupMosaicLayout else { return [] }
        return layout.slots.map { slot in
            panes.first(where: { $0.id == slot.paneID })!
        }
    }
}

public struct PaneDefinition: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case terminal
        case browser
    }

    public let id: String
    public let kind: Kind
    public let url: URL?
    public let profile: String?
    public let command: String?
    public let procfile: String?
    public let process: String?
    public let startupCommand: String?

    public init(
        id: String,
        kind: Kind,
        url: URL?,
        profile: String? = nil,
        command: String? = nil,
        procfile: String? = nil,
        process: String? = nil,
        startupCommand: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.profile = profile
        self.command = command
        self.procfile = procfile
        self.process = process
        self.startupCommand = startupCommand ?? command
    }
}

public struct LayoutDefinition: Equatable, Sendable {
    public let id: String
    public let areas: [String]

    public init(id: String, areas: [String]) {
        self.id = id
        self.areas = areas
    }
}

public struct MosaicPaneSlot: Equatable, Sendable {
    public let paneID: String
    public let row: Int
    public let column: Int
    public let rowSpan: Int
    public let columnSpan: Int

    public init(paneID: String, row: Int, column: Int, rowSpan: Int, columnSpan: Int) {
        self.paneID = paneID
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }
}

public struct ValidatedMosaicLayout: Equatable, Sendable {
    public let id: String
    public let rowCount: Int
    public let columnCount: Int
    public let matrix: [[String]]
    public let slots: [MosaicPaneSlot]

    public init(id: String, rowCount: Int, columnCount: Int, matrix: [[String]], slots: [MosaicPaneSlot]) {
        self.id = id
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.matrix = matrix
        self.slots = slots
    }
}

public struct MosaicPaneFrame: Equatable, Sendable {
    public let paneID: String
    public let frame: CGRect

    public init(paneID: String, frame: CGRect) {
        self.paneID = paneID
        self.frame = frame
    }
}

public enum MosaicLayoutFrames {
    public static func frames(for layout: ValidatedMosaicLayout, in bounds: CGRect) -> [MosaicPaneFrame] {
        precondition(layout.rowCount > 0 && layout.columnCount > 0, "Validated mosaic layouts must have positive dimensions")
        return layout.slots.map { slot in
            let minX = edge(index: slot.column, count: layout.columnCount, extent: bounds.width)
            let maxX = edge(index: slot.column + slot.columnSpan, count: layout.columnCount, extent: bounds.width)
            let maxY = bounds.height - edge(index: slot.row, count: layout.rowCount, extent: bounds.height)
            let minY = bounds.height - edge(index: slot.row + slot.rowSpan, count: layout.rowCount, extent: bounds.height)
            return MosaicPaneFrame(
                paneID: slot.paneID,
                frame: CGRect(
                    x: bounds.minX + minX,
                    y: bounds.minY + minY,
                    width: maxX - minX,
                    height: maxY - minY
                )
            )
        }
    }

    private static func edge(index: Int, count: Int, extent: CGFloat) -> CGFloat {
        floor(extent * CGFloat(index) / CGFloat(count))
    }
}

public enum WorkspaceConfigSource: Equatable, Sendable {
    case environment(URL)
    case projectDefault(URL)
    case userDefault(URL)
    case builtIn

    public var url: URL? {
        switch self {
        case .environment(let url), .projectDefault(let url), .userDefault(let url): return url
        case .builtIn: return nil
        }
    }
}

public struct WorkspaceConfigDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public let severity: Severity
    public let message: String
    public let source: WorkspaceConfigSource?

    public init(severity: Severity, message: String, source: WorkspaceConfigSource? = nil) {
        self.severity = severity
        self.message = message
        self.source = source
    }

    public var description: String {
        let location = source?.url.map { " (\($0.path))" } ?? ""
        return "[\(severity.rawValue)]\(location) \(message)"
    }
}

public struct WorkspaceConfigLoadResult: Equatable, Sendable {
    public let config: WorkspaceConfig
    public let source: WorkspaceConfigSource
    public let diagnostics: [WorkspaceConfigDiagnostic]

    public init(config: WorkspaceConfig, source: WorkspaceConfigSource, diagnostics: [WorkspaceConfigDiagnostic]) {
        self.config = config
        self.source = source
        self.diagnostics = diagnostics
    }
}

public final class WorkspaceConfigLoader {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileManager: FileManager

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    public func load() -> WorkspaceConfigLoadResult {
        if let explicitPath = environment["GSDE_CONFIG"], !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            return loadFile(at: url, source: .environment(url))
        }

        if let projectPath = environment["GSDE_PROJECT_DIR"], !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let projectURL = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath, isDirectory: true)
            let projectDefaultURL = projectURL
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("gsde", isDirectory: true)
                .appendingPathComponent("config.toml")
            if fileManager.fileExists(atPath: projectDefaultURL.path) {
                return loadFile(at: projectDefaultURL, source: .projectDefault(projectDefaultURL))
            }
        }

        let defaultURL = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("gsde", isDirectory: true)
            .appendingPathComponent("config.toml")
        if fileManager.fileExists(atPath: defaultURL.path) {
            return loadFile(at: defaultURL, source: .userDefault(defaultURL))
        }

        return WorkspaceConfigLoadResult(config: .builtIn, source: .builtIn, diagnostics: [])
    }

    private func loadFile(at url: URL, source: WorkspaceConfigSource) -> WorkspaceConfigLoadResult {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let config = try WorkspaceConfigTOMLParser(text: text).parse()
            let resolvedConfig = try resolveTerminalStartupCommands(in: config, sourceURL: url)
            return WorkspaceConfigLoadResult(config: resolvedConfig, source: source, diagnostics: [])
        } catch {
            let diagnostic = WorkspaceConfigDiagnostic(
                severity: .error,
                message: "Could not load workspace config: \(error)",
                source: source
            )
            return WorkspaceConfigLoadResult(config: .builtIn, source: .builtIn, diagnostics: [diagnostic])
        }
    }

    private func resolveTerminalStartupCommands(in config: WorkspaceConfig, sourceURL: URL) throws -> WorkspaceConfig {
        let projectRoot = environment["GSDE_PROJECT_DIR"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? sourceURL.deletingLastPathComponent()

        let panes = try config.panes.map { pane -> PaneDefinition in
            guard pane.kind == .terminal else { return pane }

            let command: String?
            if let procfile = pane.procfile, let process = pane.process {
                let procfileURL = URL(fileURLWithPath: procfile, relativeTo: projectRoot).standardizedFileURL
                guard fileManager.fileExists(atPath: procfileURL.path) else {
                    throw WorkspaceConfigParseError.missingProcfile(path: procfile)
                }
                command = try Self.command(named: process, inProcfileAt: procfileURL)
            } else {
                command = pane.command
            }

            guard let command else { return pane }
            return PaneDefinition(
                id: pane.id,
                kind: pane.kind,
                url: pane.url,
                profile: pane.profile,
                command: pane.command,
                procfile: pane.procfile,
                process: pane.process,
                startupCommand: "cd \(Self.shellQuote(projectRoot.path)) && \(command)"
            )
        }

        return WorkspaceConfig(
            version: config.version,
            panes: panes,
            layouts: config.layouts,
            validatedLayouts: config.validatedLayouts,
            startupLayout: config.startupLayout
        )
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func command(named process: String, inProcfileAt url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let command = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == process, !command.isEmpty {
                return String(command)
            }
        }
        throw WorkspaceConfigParseError.missingProcfileProcess(procfile: url.lastPathComponent, process: process)
    }
}

enum WorkspaceConfigParseError: Error, Equatable, CustomStringConvertible {
    case invalidLine(line: Int, text: String)
    case unsupportedHeader(line: Int, header: String)
    case duplicateKey(line: Int, key: String)
    case unsupportedKey(line: Int, key: String, table: String)
    case missingRequiredField(table: String, field: String)
    case invalidValue(field: String, value: String)
    case unsupportedVersion(Int)
    case emptyLayoutAreas(layout: String)
    case emptyLayoutAreaRow(layout: String, row: Int)
    case unevenLayoutAreaRow(layout: String, row: Int, expectedColumns: Int, actualColumns: Int)
    case unknownStartupLayout(String)
    case unknownPaneInLayout(layout: String, pane: String)
    case nonRectangularPaneArea(layout: String, pane: String, rows: ClosedRange<Int>, columns: ClosedRange<Int>)
    case duplicateIdentifier(table: String, id: String)
    case missingProcfile(path: String)
    case missingProcfileProcess(procfile: String, process: String)

    var description: String {
        switch self {
        case .invalidLine(let line, let text): return "line \(line) is not a key/value pair: \(text)"
        case .unsupportedHeader(let line, let header): return "line \(line) uses unsupported TOML table \(header)"
        case .duplicateKey(let line, let key): return "line \(line) repeats key \(key) in the same table"
        case .unsupportedKey(let line, let key, let table): return "line \(line) uses unsupported key \(key) in \(table)"
        case .missingRequiredField(let table, let field): return "\(table) is missing required field \(field)"
        case .invalidValue(let field, let value): return "\(field) has invalid value \(value)"
        case .unsupportedVersion(let version): return "unsupported config version \(version)"
        case .emptyLayoutAreas(let layout): return "layout \(layout) areas must contain at least one non-empty row"
        case .emptyLayoutAreaRow(let layout, let row): return "layout \(layout) areas row \(row) is empty"
        case .unevenLayoutAreaRow(let layout, let row, let expectedColumns, let actualColumns): return "layout \(layout) areas row \(row) has \(actualColumns) columns; expected \(expectedColumns)"
        case .unknownStartupLayout(let layout): return "startup_layout references unknown layout \(layout)"
        case .unknownPaneInLayout(let layout, let pane): return "layout \(layout) references unknown pane \(pane)"
        case .nonRectangularPaneArea(let layout, let pane, let rows, let columns): return "layout \(layout) pane \(pane) areas are not a single rectangle; bounding box rows \(rows.lowerBound)-\(rows.upperBound), columns \(columns.lowerBound)-\(columns.upperBound) is not fully occupied"
        case .duplicateIdentifier(let table, let id): return "\(table) id \(id) is duplicated"
        case .missingProcfile(let path): return "procfile \(path) does not exist"
        case .missingProcfileProcess(let procfile, let process): return "procfile \(procfile) does not define process \(process)"
        }
    }
}

struct WorkspaceConfigTOMLParser {
    private enum Table {
        case root
        case pane(Int)
        case layout(Int)
    }

    private let text: String

    init(text: String) {
        self.text = text
    }

    func parse() throws -> WorkspaceConfig {
        var root: [String: String] = [:]
        var paneTables: [[String: String]] = []
        var layoutTables: [[String: String]] = []
        var table = Table.root

        for (lineNumber, logicalLine) in try logicalLines() {
            let line = logicalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let header = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                switch header {
                case "panes":
                    paneTables.append([:])
                    table = .pane(paneTables.count - 1)
                case "layouts":
                    layoutTables.append([:])
                    table = .layout(layoutTables.count - 1)
                default:
                    throw WorkspaceConfigParseError.unsupportedHeader(line: lineNumber, header: line)
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                throw WorkspaceConfigParseError.invalidLine(line: lineNumber, text: line)
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                throw WorkspaceConfigParseError.invalidLine(line: lineNumber, text: line)
            }

            switch table {
            case .root:
                try insert(key: String(key), value: String(value), into: &root, line: lineNumber, table: "root", allowedKeys: ["version", "startup_layout"])
            case .pane(let index):
                try insert(key: String(key), value: String(value), into: &paneTables[index], line: lineNumber, table: "panes[\(index)]", allowedKeys: ["id", "kind", "url", "profile", "command", "procfile", "process"])
            case .layout(let index):
                try insert(key: String(key), value: String(value), into: &layoutTables[index], line: lineNumber, table: "layouts[\(index)]", allowedKeys: ["id", "areas"])
            }
        }

        let version = try requiredInt(root["version"], table: "root", field: "version")
        guard version == WorkspaceConfig.currentVersion else { throw WorkspaceConfigParseError.unsupportedVersion(version) }

        let panes = try paneTables.enumerated().map { index, fields in
            try parsePane(fields, index: index)
        }
        let layouts = try layoutTables.enumerated().map { index, fields in
            try parseLayout(fields, index: index)
        }
        let startupLayout = try requiredString(root["startup_layout"], table: "root", field: "startup_layout")

        let validatedLayouts = try validate(panes: panes, layouts: layouts, startupLayout: startupLayout)
        return WorkspaceConfig(version: version, panes: panes, layouts: layouts, validatedLayouts: validatedLayouts, startupLayout: startupLayout)
    }

    private func parsePane(_ fields: [String: String], index: Int) throws -> PaneDefinition {
        let table = "panes[\(index)]"
        let id = try requiredString(fields["id"], table: table, field: "id")
        let rawKind = try requiredString(fields["kind"], table: table, field: "kind")
        guard let kind = PaneDefinition.Kind(rawValue: rawKind) else {
            throw WorkspaceConfigParseError.invalidValue(field: "\(table).kind", value: rawKind)
        }
        let urlString = try parseString(fields["url"], field: "\(table).url")
        let profile = try parseString(fields["profile"], field: "\(table).profile")
        let command = try parseString(fields["command"], field: "\(table).command")
        let procfile = try parseString(fields["procfile"], field: "\(table).procfile")
        let process = try parseString(fields["process"], field: "\(table).process")
        if let profile, profile.isEmpty {
            throw WorkspaceConfigParseError.invalidValue(field: "\(table).profile", value: profile)
        }
        if let command, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkspaceConfigParseError.invalidValue(field: "\(table).command", value: command)
        }
        if let procfile, procfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkspaceConfigParseError.invalidValue(field: "\(table).procfile", value: procfile)
        }
        if let process, process.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorkspaceConfigParseError.invalidValue(field: "\(table).process", value: process)
        }
        let url = try urlString.map { rawURL in
            guard let url = URL(string: rawURL), url.scheme != nil else {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).url", value: rawURL)
            }
            return url
        }
        switch kind {
        case .terminal:
            if url != nil {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).url", value: "terminal panes cannot define url")
            }
            if profile != nil {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).profile", value: "terminal panes cannot define profile")
            }
            if command != nil && (procfile != nil || process != nil) {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).command", value: "command cannot be combined with procfile/process")
            }
            if (procfile == nil) != (process == nil) {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).procfile", value: "procfile and process must be provided together")
            }
        case .browser:
            if url == nil {
                throw WorkspaceConfigParseError.missingRequiredField(table: table, field: "url")
            }
            if command != nil {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).command", value: "browser panes cannot define command")
            }
            if procfile != nil {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).procfile", value: "browser panes cannot define procfile")
            }
            if process != nil {
                throw WorkspaceConfigParseError.invalidValue(field: "\(table).process", value: "browser panes cannot define process")
            }
        }
        return PaneDefinition(id: id, kind: kind, url: url, profile: profile, command: command, procfile: procfile, process: process)
    }

    private func parseLayout(_ fields: [String: String], index: Int) throws -> LayoutDefinition {
        let table = "layouts[\(index)]"
        let id = try requiredString(fields["id"], table: table, field: "id")
        let areas = try parseStringArray(fields["areas"], field: "\(table).areas")
        guard let areas else { throw WorkspaceConfigParseError.missingRequiredField(table: table, field: "areas") }
        return LayoutDefinition(id: id, areas: areas)
    }

    private func validate(panes: [PaneDefinition], layouts: [LayoutDefinition], startupLayout: String) throws -> [ValidatedMosaicLayout] {
        guard Set(panes.map(\.id)).count == panes.count else {
            let duplicates = duplicateIDs(panes.map(\.id))
            throw WorkspaceConfigParseError.duplicateIdentifier(table: "panes", id: duplicates.first ?? "<unknown>")
        }
        guard Set(layouts.map(\.id)).count == layouts.count else {
            let duplicates = duplicateIDs(layouts.map(\.id))
            throw WorkspaceConfigParseError.duplicateIdentifier(table: "layouts", id: duplicates.first ?? "<unknown>")
        }
        guard layouts.contains(where: { $0.id == startupLayout }) else {
            throw WorkspaceConfigParseError.unknownStartupLayout(startupLayout)
        }
        let paneIDs = Set(panes.map(\.id))
        return try layouts.map { layout in
            try validateMosaicLayout(layout, paneIDs: paneIDs)
        }
    }

    private func validateMosaicLayout(_ layout: LayoutDefinition, paneIDs: Set<String>) throws -> ValidatedMosaicLayout {
        guard !layout.areas.isEmpty else { throw WorkspaceConfigParseError.emptyLayoutAreas(layout: layout.id) }

        var matrix: [[String]] = []
        var expectedColumnCount: Int?
        for (rowIndex, areaRow) in layout.areas.enumerated() {
            let tokens = areaRow.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else { throw WorkspaceConfigParseError.emptyLayoutAreaRow(layout: layout.id, row: rowIndex) }
            if let expectedColumnCount, tokens.count != expectedColumnCount {
                throw WorkspaceConfigParseError.unevenLayoutAreaRow(
                    layout: layout.id,
                    row: rowIndex,
                    expectedColumns: expectedColumnCount,
                    actualColumns: tokens.count
                )
            }
            expectedColumnCount = tokens.count
            for pane in tokens where !paneIDs.contains(pane) {
                throw WorkspaceConfigParseError.unknownPaneInLayout(layout: layout.id, pane: pane)
            }
            matrix.append(tokens)
        }

        let slots = try rectangularSlots(for: layout.id, matrix: matrix)
        return ValidatedMosaicLayout(
            id: layout.id,
            rowCount: matrix.count,
            columnCount: expectedColumnCount!,
            matrix: matrix,
            slots: slots.sorted { lhs, rhs in
                if lhs.row != rhs.row { return lhs.row < rhs.row }
                if lhs.column != rhs.column { return lhs.column < rhs.column }
                return lhs.paneID < rhs.paneID
            }
        )
    }

    private func rectangularSlots(for layoutID: String, matrix: [[String]]) throws -> [MosaicPaneSlot] {
        struct Bounds {
            var minRow: Int
            var maxRow: Int
            var minColumn: Int
            var maxColumn: Int
            var cellCount: Int
        }

        var boundsByPane: [String: Bounds] = [:]
        for (rowIndex, row) in matrix.enumerated() {
            for (columnIndex, paneID) in row.enumerated() {
                if var bounds = boundsByPane[paneID] {
                    bounds.minRow = min(bounds.minRow, rowIndex)
                    bounds.maxRow = max(bounds.maxRow, rowIndex)
                    bounds.minColumn = min(bounds.minColumn, columnIndex)
                    bounds.maxColumn = max(bounds.maxColumn, columnIndex)
                    bounds.cellCount += 1
                    boundsByPane[paneID] = bounds
                } else {
                    boundsByPane[paneID] = Bounds(
                        minRow: rowIndex,
                        maxRow: rowIndex,
                        minColumn: columnIndex,
                        maxColumn: columnIndex,
                        cellCount: 1
                    )
                }
            }
        }

        return try boundsByPane.map { paneID, bounds in
            let rowSpan = bounds.maxRow - bounds.minRow + 1
            let columnSpan = bounds.maxColumn - bounds.minColumn + 1
            guard rowSpan * columnSpan == bounds.cellCount else {
                throw WorkspaceConfigParseError.nonRectangularPaneArea(
                    layout: layoutID,
                    pane: paneID,
                    rows: bounds.minRow...bounds.maxRow,
                    columns: bounds.minColumn...bounds.maxColumn
                )
            }
            for row in bounds.minRow...bounds.maxRow {
                for column in bounds.minColumn...bounds.maxColumn where matrix[row][column] != paneID {
                    throw WorkspaceConfigParseError.nonRectangularPaneArea(
                        layout: layoutID,
                        pane: paneID,
                        rows: bounds.minRow...bounds.maxRow,
                        columns: bounds.minColumn...bounds.maxColumn
                    )
                }
            }
            return MosaicPaneSlot(paneID: paneID, row: bounds.minRow, column: bounds.minColumn, rowSpan: rowSpan, columnSpan: columnSpan)
        }
    }

    private func insert(key: String, value: String, into table: inout [String: String], line: Int, table tableName: String, allowedKeys: Set<String>) throws {
        guard allowedKeys.contains(key) else { throw WorkspaceConfigParseError.unsupportedKey(line: line, key: key, table: tableName) }
        guard table[key] == nil else { throw WorkspaceConfigParseError.duplicateKey(line: line, key: key) }
        table[key] = value
    }

    private func requiredString(_ value: String?, table: String, field: String) throws -> String {
        guard let parsed = try parseString(value, field: "\(table).\(field)") else {
            throw WorkspaceConfigParseError.missingRequiredField(table: table, field: field)
        }
        guard !parsed.isEmpty else { throw WorkspaceConfigParseError.invalidValue(field: "\(table).\(field)", value: parsed) }
        return parsed
    }

    private func requiredInt(_ value: String?, table: String, field: String) throws -> Int {
        guard let parsed = try parseInt(value, field: field) else {
            throw WorkspaceConfigParseError.missingRequiredField(table: table, field: field)
        }
        return parsed
    }

    private func parseInt(_ value: String?, field: String) throws -> Int? {
        guard let value else { return nil }
        guard let intValue = Int(value) else { throw WorkspaceConfigParseError.invalidValue(field: field, value: value) }
        return intValue
    }

    private func parseString(_ value: String?, field: String) throws -> String? {
        guard let value else { return nil }
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        guard value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 else {
            throw WorkspaceConfigParseError.invalidValue(field: field, value: value)
        }
        let inner = value.dropFirst().dropLast()
        var result = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                guard let escaped = iterator.next() else { throw WorkspaceConfigParseError.invalidValue(field: field, value: value) }
                switch escaped {
                case "\\", "\"": result.append(escaped)
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: throw WorkspaceConfigParseError.invalidValue(field: field, value: value)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    private func parseStringArray(_ value: String?, field: String) throws -> [String]? {
        guard let value else { return nil }
        guard value.hasPrefix("[") && value.hasSuffix("]") else {
            throw WorkspaceConfigParseError.invalidValue(field: field, value: value)
        }
        let body = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }
        return try splitArray(body).map { item in
            guard let string = try parseString(item.trimmingCharacters(in: .whitespacesAndNewlines), field: field) else {
                throw WorkspaceConfigParseError.invalidValue(field: field, value: String(item))
            }
            return string
        }
    }

    private func logicalLines() throws -> [(Int, String)] {
        var lines: [(Int, String)] = []
        var pendingArrayLine: Int?
        var pendingArrayText = ""

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = stripComment(from: String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let startLine = pendingArrayLine {
                pendingArrayText += " " + line
                if try isBalancedArrayValue(pendingArrayText) {
                    lines.append((startLine, pendingArrayText))
                    pendingArrayLine = nil
                    pendingArrayText = ""
                }
                continue
            }

            if let equals = line.firstIndex(of: "=") {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("[") {
                    let isCompleteArray = try isBalancedArrayValue(String(value))
                    if !isCompleteArray {
                        pendingArrayLine = lineNumber
                        pendingArrayText = line
                        continue
                    }
                }
            }

            lines.append((lineNumber, line))
        }

        if let startLine = pendingArrayLine {
            throw WorkspaceConfigParseError.invalidLine(line: startLine, text: pendingArrayText)
        }
        return lines
    }

    private func isBalancedArrayValue(_ value: String) throws -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
                continue
            }
            guard quote == nil else { continue }
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth < 0 { throw WorkspaceConfigParseError.invalidValue(field: "array", value: value) }
            }
        }
        if quote != nil || escaped { throw WorkspaceConfigParseError.invalidValue(field: "array", value: value) }
        return depth == 0
    }

    private func splitArray(_ body: String) throws -> [String] {
        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
                current.append(character)
                continue
            }
            if character == ",", quote == nil {
                values.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        guard quote == nil, !escaped else { throw WorkspaceConfigParseError.invalidValue(field: "array", value: String(body)) }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(current)
        }
        return values
    }

    private func stripComment(from line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
                result.append(character)
                continue
            }
            if character == "#", quote == nil { break }
            result.append(character)
        }
        return result
    }

    private func duplicateIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var duplicates: [String] = []
        for id in ids {
            if !seen.insert(id).inserted { duplicates.append(id) }
        }
        return duplicates
    }
}
