import CoreGraphics
import Foundation
import Testing
@testable import GSDEConfig

@Suite("Workspace config loading")
struct WorkspaceConfigTests {
    @Test("loads valid TOML from GSDE_CONFIG into typed structures")
    func loadsExplicitConfig() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("config.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[panes]]
        id = "docs"
        kind = "browser"
        url = "https://developer.apple.com"

        [[layouts]]
        id = "work"
        areas = ["term docs"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.source == .environment(configURL))
        #expect(result.config.version == 1)
        #expect(result.config.startupLayout == "work")
        #expect(result.config.startupPaneDefinitions.map(\.id) == ["term", "docs"])
        #expect(result.config.startupPaneDefinitions.last?.url?.absoluteString == "https://developer.apple.com")
        #expect(result.config.startupPaneDefinitions.last?.profile == nil)
        #expect(result.config.startupMosaicLayout?.matrix == [["term", "docs"]])
        #expect(result.config.startupMosaicLayout?.slots.map(\.paneID) == ["term", "docs"])
    }

    @Test("built-in config validates default and flipped layouts")
    func builtInConfigSupportsDefaultToFlippedSwitching() {
        #expect(WorkspaceConfig.builtIn.startupLayout == "default")
        #expect(WorkspaceConfig.builtIn.validatedLayouts.map(\.id) == ["default", "flipped"])
        #expect(WorkspaceConfig.builtIn.validatedLayouts.first { $0.id == "default" }?.slots.map(\.paneID) == [
            "terminal.main",
            "browser.main",
            "terminal.secondary"
        ])
        #expect(WorkspaceConfig.builtIn.validatedLayouts.first { $0.id == "flipped" }?.slots.map(\.paneID) == [
            "terminal.secondary",
            "browser.main",
            "terminal.main"
        ])
    }

    @Test("discovers project config from GSDE_PROJECT_DIR before home config")
    func discoversProjectConfig() throws {
        let home = try temporaryDirectory()
        let project = try temporaryDirectory()

        let homeConfigDirectory = home.appendingPathComponent(".config/gsde", isDirectory: true)
        try FileManager.default.createDirectory(at: homeConfigDirectory, withIntermediateDirectories: true)
        try minimalConfig(startupLayout: "home").write(
            to: homeConfigDirectory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let projectConfigDirectory = project.appendingPathComponent(".config/gsde", isDirectory: true)
        try FileManager.default.createDirectory(at: projectConfigDirectory, withIntermediateDirectories: true)
        let projectConfigURL = projectConfigDirectory.appendingPathComponent("config.toml")
        try minimalConfig(startupLayout: "project").write(to: projectConfigURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(
            environment: ["GSDE_PROJECT_DIR": project.path],
            homeDirectory: home
        ).load()

        #expect(result.source == .projectDefault(projectConfigURL))
        #expect(result.config.startupLayout == "project")
    }

    @Test("discovers default config under home .config path")
    func discoversHomeConfig() throws {
        let home = try temporaryDirectory()
        let configDirectory = home.appendingPathComponent(".config/gsde", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        try minimalConfig(startupLayout: "solo").write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: [:], homeDirectory: home).load()

        #expect(result.source == .userDefault(configURL))
        #expect(result.config.startupPaneDefinitions.map(\.kind) == [.terminal])
    }

    @Test("invalid file returns built-in config with structured diagnostic")
    func invalidFileFallsBackWithDiagnostic() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("bad.toml")
        try "startup_layout = \"missing\"".write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.source == .builtIn)
        #expect(result.config == .builtIn)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].severity == .error)
        #expect(result.diagnostics[0].source == .environment(configURL))
    }

    @Test("browser panes must declare URLs")
    func browserPaneWithoutURLIsInvalid() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("bad-browser.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "docs"
        kind = "browser"

        [[layouts]]
        id = "work"
        areas = ["docs"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.source == .builtIn)
        #expect(result.diagnostics.first?.message.contains("missing required field url") == true)
    }

    @Test("browser panes can declare stable Chromium profiles")
    func browserPaneProfileLoads() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("profile.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "docs"
        kind = "browser"
        profile = "shared.docs"
        url = "https://example.com/docs"

        [[layouts]]
        id = "work"
        areas = ["docs"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupPaneDefinitions.first?.profile == "shared.docs")
    }

    @Test("terminal panes reject browser profiles")
    func terminalPaneProfileIsInvalid() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("terminal-profile.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"
        profile = "not-valid"

        [[layouts]]
        id = "work"
        areas = ["term"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.source == .builtIn)
        #expect(result.diagnostics.first?.message.contains("terminal panes cannot define profile") == true)
    }

    @Test("valid TOML literal strings and trailing array comma load")
    func validTomlLiteralStringsAndTrailingArrayCommaLoad() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("literal.toml")
        try """
        version = 1
        startup_layout = 'work'

        [[panes]]
        id = 'docs'
        kind = 'browser'
        url = 'https://example.com/docs#section'

        [[layouts]]
        id = 'work'
        areas = ['docs',]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupPaneDefinitions.map(\.id) == ["docs"])
        #expect(result.config.startupPaneDefinitions.first?.url?.absoluteString == "https://example.com/docs#section")
    }

    @Test("mosaic layout frames assign equal grid areas")
    func mosaicLayoutFramesAssignEqualGridAreas() throws {
        let layout = ValidatedMosaicLayout(
            id: "work",
            rowCount: 2,
            columnCount: 2,
            matrix: [["one", "two"], ["three", "three"]],
            slots: [
                MosaicPaneSlot(paneID: "one", row: 0, column: 0, rowSpan: 1, columnSpan: 1),
                MosaicPaneSlot(paneID: "two", row: 0, column: 1, rowSpan: 1, columnSpan: 1),
                MosaicPaneSlot(paneID: "three", row: 1, column: 0, rowSpan: 1, columnSpan: 2)
            ]
        )

        let frames = MosaicLayoutFrames.frames(for: layout, in: CGRect(x: 0, y: 0, width: 400, height: 200))

        #expect(frames == [
            MosaicPaneFrame(paneID: "one", frame: CGRect(x: 0, y: 100, width: 200, height: 100)),
            MosaicPaneFrame(paneID: "two", frame: CGRect(x: 200, y: 100, width: 200, height: 100)),
            MosaicPaneFrame(paneID: "three", frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        ])
    }

    @Test("valid single-pane mosaic layout loads")
    func validSinglePaneMosaicLayoutLoads() throws {
        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "single-pane.toml", contents: """
        version = 1
        startup_layout = "solo"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "solo"
        areas = ["term"]
        """).path]).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupMosaicLayout?.rowCount == 1)
        #expect(result.config.startupMosaicLayout?.columnCount == 1)
        #expect(result.config.startupMosaicLayout?.slots == [MosaicPaneSlot(paneID: "term", row: 0, column: 0, rowSpan: 1, columnSpan: 1)])
    }

    @Test("valid side-by-side mosaic layout loads")
    func validSideBySideMosaicLayoutLoads() throws {
        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "side-by-side.toml", contents: """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[panes]]
        id = "docs"
        kind = "browser"
        url = "https://example.com"

        [[layouts]]
        id = "work"
        areas = ["term docs"]
        """).path]).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupMosaicLayout?.matrix == [["term", "docs"]])
        #expect(result.config.startupMosaicLayout?.slots.map(\.paneID) == ["term", "docs"])
    }

    @Test("rectangular repeated area tokens produce mosaic slot spans")
    func rectangularRepeatedAreaTokensProduceMosaicSlotSpans() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("spanned-layout.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "docs"
        kind = "browser"
        url = "https://example.com"

        [[layouts]]
        id = "work"
        areas = ["docs docs"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupMosaicLayout?.columnCount == 2)
        #expect(result.config.startupMosaicLayout?.slots == [MosaicPaneSlot(paneID: "docs", row: 0, column: 0, rowSpan: 1, columnSpan: 2)])
    }

    @Test("documented sample configs load")
    func documentedSampleConfigsLoad() throws {
        let samplesDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/sample-configs", isDirectory: true)
        let sampleNames = [
            "terminal-12-33.toml",
            "browser-terminal-dev.toml",
            "multiple-named-layouts.toml",
            "configured-smoke.toml"
        ]

        for sampleName in sampleNames {
            let sampleURL = samplesDirectory.appendingPathComponent(sampleName)
            let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": sampleURL.path]).load()

            #expect(result.source == .environment(sampleURL), "\(sampleName) should be loaded from GSDE_CONFIG")
            #expect(result.diagnostics.isEmpty, "\(sampleName) diagnostics: \(result.diagnostics)")
            #expect(result.config.startupMosaicLayout != nil, "\(sampleName) should declare its startup layout")
        }
    }

    @Test("valid multiline TOML arrays load")
    func validMultilineArrayLoads() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("multiline-array.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[panes]]
        id = "docs"
        kind = "browser"
        url = "https://example.com/docs#section"

        [[layouts]]
        id = "work"
        areas = [
            "term docs", # comments may trail multiline array items
        ]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupPaneDefinitions.map(\.id) == ["term", "docs"])
    }

    @Test("unknown keys are invalid instead of silently ignored")
    func unknownKeysAreInvalid() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("unknown-key.toml")
        try """
        version = 1
        startup_layout = "work"
        startup_layuot = "typo"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["term"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.source == .builtIn)
        #expect(result.diagnostics.first?.message.contains("unsupported key startup_layuot") == true)
    }

    @Test("layout areas reject unknown pane references")
    func layoutAreasRejectUnknownPaneReferences() throws {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent("unknown-pane.toml")
        try """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["term missing"]
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": configURL.path], homeDirectory: directory).load()

        #expect(result.source == .builtIn)
        #expect(result.diagnostics.first?.message.contains("references unknown pane missing") == true)
    }

    @Test("12/33 sample layout validates as asymmetric rows over an equal grid")
    func twelveThirtyThreeSampleLayoutValidatesAsEqualGrid() throws {
        let sampleURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/sample-configs/terminal-12-33.toml")
        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": sampleURL.path]).load()

        #expect(result.diagnostics.isEmpty)
        #expect(result.config.startupMosaicLayout?.rowCount == 2)
        #expect(result.config.startupMosaicLayout?.columnCount == 2)
        #expect(result.config.startupMosaicLayout?.slots == [
            MosaicPaneSlot(paneID: "1", row: 0, column: 0, rowSpan: 1, columnSpan: 1),
            MosaicPaneSlot(paneID: "2", row: 0, column: 1, rowSpan: 1, columnSpan: 1),
            MosaicPaneSlot(paneID: "3", row: 1, column: 0, rowSpan: 1, columnSpan: 2)
        ])
    }

    @Test("startup layout must reference a declared layout")
    func startupLayoutMustReferenceDeclaredLayout() throws {
        let result = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "bad-startup.toml", contents: """
        version = 1
        startup_layout = "missing"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["term"]
        """).path]).load()

        #expect(result.source == .builtIn)
        #expect(result.diagnostics.first?.message.contains("startup_layout references unknown layout missing") == true)
    }

    @Test("layout areas reject uneven rows and empty areas")
    func layoutAreasRejectUnevenRowsAndEmptyAreas() throws {
        let uneven = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "uneven.toml", contents: """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["term term", "term"]
        """).path]).load()
        #expect(uneven.diagnostics.first?.message.contains("row 1 has 1 columns; expected 2") == true)

        let empty = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "empty.toml", contents: """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = []
        """).path]).load()
        #expect(empty.diagnostics.first?.message.contains("areas must contain at least one non-empty row") == true)

        let emptyRow = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "empty-row.toml", contents: """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["term", "   "]
        """).path]).load()
        #expect(emptyRow.diagnostics.first?.message.contains("areas row 1 is empty") == true)
    }

    @Test("layout areas reject disjoint and L-shaped pane regions")
    func layoutAreasRejectNonRectangularPaneRegions() throws {
        let disjoint = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "disjoint.toml", contents: """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "a"
        kind = "terminal"

        [[panes]]
        id = "b"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["a b a"]
        """).path]).load()
        #expect(disjoint.diagnostics.first?.message.contains("pane a areas are not a single rectangle") == true)

        let lShaped = WorkspaceConfigLoader(environment: ["GSDE_CONFIG": try writeConfig(named: "l-shaped.toml", contents: """
        version = 1
        startup_layout = "work"

        [[panes]]
        id = "a"
        kind = "terminal"

        [[panes]]
        id = "b"
        kind = "terminal"

        [[layouts]]
        id = "work"
        areas = ["a a", "a b"]
        """).path]).load()
        #expect(lShaped.diagnostics.first?.message.contains("pane a areas are not a single rectangle") == true)
    }

    @Test("built-in config is used when no file exists")
    func fallsBackToBuiltInWhenNoFileExists() throws {
        let directory = try temporaryDirectory()

        let result = WorkspaceConfigLoader(environment: [:], homeDirectory: directory).load()

        #expect(result.source == .builtIn)
        #expect(result.config == .builtIn)
        #expect(result.diagnostics.isEmpty)
    }

    private func minimalConfig(startupLayout: String) -> String {
        """
        version = 1
        startup_layout = "\(startupLayout)"

        [[panes]]
        id = "term"
        kind = "terminal"

        [[layouts]]
        id = "\(startupLayout)"
        areas = ["term"]
        """
    }

    private func writeConfig(named filename: String, contents: String) throws -> URL {
        let directory = try temporaryDirectory()
        let configURL = directory.appendingPathComponent(filename)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
