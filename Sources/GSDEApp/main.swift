import AppKit
import ChromiumStub
import GhosttyShim

final class GhosttyHostView: NSView {
    static weak var activePane: GhosttyHostView?

    private var host: OpaquePointer?
    private var statusLabel: NSTextField?
    private var displayLink: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        createHostIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            displayLink?.invalidate()
            displayLink = nil
            if let host {
                gsde_ghostty_host_destroy(host)
                self.host = nil
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        resizeHost()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeHost()
    }

    override func becomeFirstResponder() -> Bool {
        Self.activePane = self
        gsde_ghostty_host_focus(host, true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        gsde_ghostty_host_focus(host, false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        Self.activePane = self
        window?.makeFirstResponder(self)
        gsde_ghostty_host_focus(host, true)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        _ = sendKey(event, action: action, text: event.ghosttyCharacters)
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        let changedModifier: UInt32
        switch event.keyCode {
        case 0x39: changedModifier = UInt32(GHOSTTY_MODS_CAPS.rawValue)
        case 0x38, 0x3C: changedModifier = UInt32(GHOSTTY_MODS_SHIFT.rawValue)
        case 0x3B, 0x3E: changedModifier = UInt32(GHOSTTY_MODS_CTRL.rawValue)
        case 0x3A, 0x3D: changedModifier = UInt32(GHOSTTY_MODS_ALT.rawValue)
        case 0x37, 0x36: changedModifier = UInt32(GHOSTTY_MODS_SUPER.rawValue)
        default: return
        }

        let mods = event.modifierFlags.ghosttyMods
        var action = GHOSTTY_ACTION_RELEASE

        if UInt32(mods.rawValue) & changedModifier != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = sendKey(event, action: action)
    }

    private func sendKey(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let host else { return false }

        var keyEvent = event.ghosttyKeyEvent(action)
        keyEvent.composing = composing

        if let text,
           !text.isEmpty,
           let firstByte = text.utf8.first,
           firstByte >= 0x20 {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return gsde_ghostty_host_key(host, keyEvent)
            }
        }

        return gsde_ghostty_host_key(host, keyEvent)
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let label = NSTextField(labelWithString: "Starting libghostty…")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        statusLabel = label

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
    }

    private func createHostIfNeeded() {
        guard host == nil, window != nil else { return }

        let scale = backingScaleFactor
        let size = pixelSize(scale: scale)
        host = gsde_ghostty_host_create(
            Unmanaged.passUnretained(self).toOpaque(),
            scale,
            size.width,
            size.height
        )

        if let host, gsde_ghostty_host_is_loaded(host) {
            statusLabel?.isHidden = true
            displayLink = Timer.scheduledTimer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(tickGhostty),
                userInfo: nil,
                repeats: true
            )
        } else {
            statusLabel?.stringValue = String(cString: gsde_ghostty_status())
        }
    }

    @objc private func tickGhostty() {
        guard let host else { return }
        gsde_ghostty_host_tick(host)
        gsde_ghostty_host_draw(host)
    }

    private func resizeHost() {
        guard let host else { return }
        let scale = backingScaleFactor
        let size = pixelSize(scale: scale)
        gsde_ghostty_host_resize(host, scale, size.width, size.height)
    }

    private var backingScaleFactor: Double {
        if let window { return Double(window.backingScaleFactor) }
        if let screen = NSScreen.main { return Double(screen.backingScaleFactor) }
        return 2.0
    }

    private func pixelSize(scale: Double) -> (width: UInt32, height: UInt32) {
        (
            UInt32(max(1, bounds.width * scale)),
            UInt32(max(1, bounds.height * scale))
        )
    }
}

final class ThreePaneWorkspaceView: NSSplitView {
    private enum PaneKind: String, Codable {
        case terminal
        case browser
    }

    private struct PaneDescriptor: Codable {
        let kind: PaneKind
        let stateIdentifier: String?
    }

    private static let paneLayoutDefaultsKey = "GSDE.WorkspacePaneLayout"

    private var didSetInitialDividerPositions = false
    private var splitAutosaveName: NSSplitView.AutosaveName {
        NSSplitView.AutosaveName("GSDE.WorkspaceSplit.\(arrangedSubviews.count)")
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit(initialPanes: Self.makePanes())
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit(initialPanes: Self.makePanes())
    }

    private static func makePanes() -> [NSView] {
        if ProcessInfo.processInfo.environment["GSDE_BROWSER_PANES"] == nil,
           ProcessInfo.processInfo.environment["GSDE_BROWSER_URLS"] == nil,
           let savedPanes = makeSavedPanes() {
            return savedPanes
        }

        let requestedBrowserPanes = ProcessInfo.processInfo.environment["GSDE_BROWSER_PANES"]
            .flatMap(Int.init) ?? 1
        let browserPaneCount = min(max(requestedBrowserPanes, 1), 4)
        let defaultURLs = [
            "https://example.com",
            "https://www.wikipedia.org",
            "https://developer.apple.com",
            "https://chromium.org"
        ]
        let configuredURLs = ProcessInfo.processInfo.environment["GSDE_BROWSER_URLS"]?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        var panes: [NSView] = [GhosttyHostView()]
        for index in 0..<browserPaneCount {
            let stateIdentifier = "browser.\(index)"
            let savedURL = UserDefaults.standard.string(forKey: "GSDE.BrowserPane.\(stateIdentifier).url")
            let rawURL = index < configuredURLs.count ? configuredURLs[index] : (savedURL ?? defaultURLs[index])
            let url = URL(string: rawURL) ?? URL(string: defaultURLs[index]) ?? URL(string: "https://example.com")!
            let profile = BrowserProfileConfig(
                name: stateIdentifier,
                storageDirectory: FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first?.appendingPathComponent("GSDE/Chromium/Profiles/\(stateIdentifier)", isDirectory: true),
                persistent: true
            )
            panes.append(BrowserPaneView(profile: profile, stateIdentifier: stateIdentifier, initialURL: url))
        }
        panes.append(GhosttyHostView())
        return panes
    }

    private static func makeSavedPanes() -> [NSView]? {
        guard let data = UserDefaults.standard.data(forKey: paneLayoutDefaultsKey),
              let descriptors = try? JSONDecoder().decode([PaneDescriptor].self, from: data),
              !descriptors.isEmpty
        else { return nil }

        let panes = descriptors.compactMap { descriptor -> NSView? in
            switch descriptor.kind {
            case .terminal:
                return GhosttyHostView()
            case .browser:
                guard let stateIdentifier = descriptor.stateIdentifier else { return nil }
                let savedURL = UserDefaults.standard.string(forKey: "GSDE.BrowserPane.\(stateIdentifier).url")
                let url = savedURL.flatMap(URL.init(string:)) ?? URL(string: "https://example.com")!
                let profile = BrowserProfileConfig(
                    name: stateIdentifier,
                    storageDirectory: FileManager.default.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask
                    ).first?.appendingPathComponent("GSDE/Chromium/Profiles/\(stateIdentifier)", isDirectory: true),
                    persistent: true
                )
                return BrowserPaneView(profile: profile, stateIdentifier: stateIdentifier, initialURL: url)
            }
        }

        return panes.isEmpty ? nil : panes
    }

    private func commonInit(initialPanes: [NSView]) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        isVertical = true
        dividerStyle = .thin
        autoresizesSubviews = true
        autosaveName = splitAutosaveName

        initialPanes.forEach { addPane($0, after: nil) }
    }

    override func layout() {
        super.layout()
        guard !didSetInitialDividerPositions, bounds.width > 0, arrangedSubviews.count > 1 else { return }
        didSetInitialDividerPositions = true
        guard !hasSavedDividerPositions else { return }
        distributePanesEvenly()
    }

    func addTerminalPane() {
        addPane(GhosttyHostView(), after: activeArrangedPane)
        persistPaneLayout()
        distributePanesEvenly()
    }

    func addBrowserPane() {
        let stateIdentifier = nextDynamicBrowserIdentifier()
        let profile = BrowserProfileConfig(
            name: stateIdentifier,
            storageDirectory: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("GSDE/Chromium/Profiles/\(stateIdentifier)", isDirectory: true),
            persistent: true
        )
        addPane(
            BrowserPaneView(profile: profile, stateIdentifier: stateIdentifier, initialURL: URL(string: "https://example.com")!),
            after: activeArrangedPane
        )
        persistPaneLayout()
        distributePanesEvenly()
    }

    func closeActivePane() {
        guard arrangedSubviews.count > 1, let pane = activeArrangedPane else { return }
        removeArrangedSubview(pane)
        pane.removeFromSuperview()
        persistPaneLayout()
        distributePanesEvenly()
    }

    func resetDividerPositions() {
        guard bounds.width > 0, arrangedSubviews.count > 1 else { return }
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(splitAutosaveName)")
        distributePanesEvenly()
    }

    private func addPane(_ pane: NSView, after existingPane: NSView?) {
        if let existingPane, let existingIndex = arrangedSubviews.firstIndex(of: existingPane) {
            insertArrangedSubview(pane, at: existingIndex + 1)
            setHoldingPriority(.defaultLow, forSubviewAt: existingIndex + 1)
        } else {
            addArrangedSubview(pane)
            setHoldingPriority(.defaultLow, forSubviewAt: arrangedSubviews.count - 1)
        }
        autosaveName = splitAutosaveName
    }

    private func persistPaneLayout() {
        let descriptors = arrangedSubviews.compactMap { pane -> PaneDescriptor? in
            if pane is GhosttyHostView {
                return PaneDescriptor(kind: .terminal, stateIdentifier: nil)
            }
            if let browserPane = pane as? BrowserPaneView {
                return PaneDescriptor(kind: .browser, stateIdentifier: browserPane.stateIdentifierForPersistence)
            }
            if pane.subviews.contains(where: { $0 is GhosttyHostView }) {
                return PaneDescriptor(kind: .terminal, stateIdentifier: nil)
            }
            if let browserPane = pane.subviews.compactMap({ $0 as? BrowserPaneView }).first {
                return PaneDescriptor(kind: .browser, stateIdentifier: browserPane.stateIdentifierForPersistence)
            }
            return nil
        }
        guard let data = try? JSONEncoder().encode(descriptors) else { return }
        UserDefaults.standard.set(data, forKey: Self.paneLayoutDefaultsKey)
    }

    private func distributePanesEvenly() {
        guard bounds.width > 0, arrangedSubviews.count > 1 else { return }
        autosaveName = splitAutosaveName
        for index in 1..<arrangedSubviews.count {
            setPosition(bounds.width * CGFloat(index) / CGFloat(arrangedSubviews.count), ofDividerAt: index - 1)
        }
    }

    private var activeArrangedPane: NSView? {
        if let browserPane = BrowserPaneView.activePane,
           arrangedSubviews.contains(where: { browserPane.isDescendant(of: $0) }) {
            return arrangedSubviews.first { browserPane.isDescendant(of: $0) }
        }
        if let terminalPane = GhosttyHostView.activePane,
           arrangedSubviews.contains(where: { terminalPane.isDescendant(of: $0) }) {
            return arrangedSubviews.first { terminalPane.isDescendant(of: $0) }
        }
        guard let responder = window?.firstResponder as? NSView else { return arrangedSubviews.last }
        return arrangedSubviews.first { responder === $0 || responder.isDescendant(of: $0) } ?? arrangedSubviews.last
    }

    private func nextDynamicBrowserIdentifier() -> String {
        let key = "GSDE.BrowserPane.nextDynamicIndex"
        let index = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(index + 1, forKey: key)
        return "browser.dynamic.\(index)"
    }

    private var hasSavedDividerPositions: Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(splitAutosaveName)") != nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var chromiumMessageLoopTimer: Timer?
    private var didPrepareChromiumShutdown = false
    private let frameAutosaveName = "GSDE.MainWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        initializeChromiumIfAvailable()

        let frame = Self.frameCoveringAllDisplays()
        let contentView = ThreePaneWorkspaceView(frame: NSRect(origin: .zero, size: frame.size))

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GSDE"
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrameAutosaveName(frameAutosaveName)
        if !window.setFrameUsingName(frameAutosaveName) {
            window.setFrame(frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareChromiumShutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        prepareChromiumShutdown()
        gsde_chromium_shutdown()
    }

    private func prepareChromiumShutdown() {
        guard !didPrepareChromiumShutdown else { return }
        didPrepareChromiumShutdown = true
        window?.contentView = nil
        chromiumMessageLoopTimer?.invalidate()
        chromiumMessageLoopTimer = nil
        for _ in 0..<200 {
            gsde_chromium_do_message_loop_work()
            if gsde_chromium_live_browser_count() == 0 { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func initializeChromiumIfAvailable() {
        // Keep CEF opt-in while the native Chromium bridge is still under active
        // integration. The browser pane remains usable via WebKit fallback.
        guard ProcessInfo.processInfo.environment["GSDE_ENABLE_CEF"] == "1" else { return }
        guard gsde_chromium_cef_available() != 0 else { return }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let rootCachePath = appSupport.appendingPathComponent("GSDE/Chromium", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootCachePath, withIntermediateDirectories: true)

        let initialized = rootCachePath.path.withCString { rootCache in
            rootCachePath.path.withCString { profileCache in
                "".withCString { helper in
                    gsde_chromium_initialize(rootCache, profileCache, helper)
                }
            }
        }

        guard initialized != 0 else { return }

        chromiumMessageLoopTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { _ in
            gsde_chromium_do_message_loop_work()
        }
    }

    private static func frameCoveringAllDisplays() -> NSRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(NSRect.null) { accumulated, screenFrame in
                accumulated.union(screenFrame)
            }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Reset Window and Pane Layout",
            action: #selector(resetWindowAndPaneLayout(_:)),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit GSDE",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let workspaceMenuItem = NSMenuItem()
        workspaceMenuItem.title = "Workspace"
        mainMenu.addItem(workspaceMenuItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        workspaceMenuItem.submenu = workspaceMenu
        addMenuItem("New Browser Pane", #selector(newBrowserPane(_:)), "n", to: workspaceMenu)
        addMenuItem("New Terminal Pane", #selector(newTerminalPane(_:)), "n", modifiers: [.command, .shift], to: workspaceMenu)
        addMenuItem("Close Active Pane", #selector(closeActivePane(_:)), "w", to: workspaceMenu)
        workspaceMenu.addItem(.separator())
        addMenuItem("Reset Window and Pane Layout", #selector(resetWindowAndPaneLayout(_:)), "", modifiers: [], to: workspaceMenu)

        let browserMenuItem = NSMenuItem()
        browserMenuItem.title = "Browser"
        mainMenu.addItem(browserMenuItem)
        let browserMenu = NSMenu(title: "Browser")
        browserMenuItem.submenu = browserMenu

        addMenuItem("Focus Location", #selector(browserFocusLocation(_:)), "l", to: browserMenu)
        addMenuItem("Find", #selector(browserOpenFind(_:)), "f", to: browserMenu)
        addMenuItem("Find Next", #selector(browserFindNext(_:)), "g", to: browserMenu)
        addMenuItem("Find Previous", #selector(browserFindPrevious(_:)), "G", to: browserMenu)
        browserMenu.addItem(.separator())
        addMenuItem("Back", #selector(browserGoBack(_:)), "[", to: browserMenu)
        addMenuItem("Forward", #selector(browserGoForward(_:)), "]", to: browserMenu)
        addMenuItem("Reload", #selector(browserReload(_:)), "r", to: browserMenu)
        addMenuItem("Reload Ignoring Cache", #selector(browserReloadIgnoringCache(_:)), "R", to: browserMenu)
        addMenuItem("Stop Loading", #selector(browserStopLoading(_:)), ".", to: browserMenu)
        browserMenu.addItem(.separator())
        addMenuItem("Cut", #selector(browserCut(_:)), "x", to: browserMenu)
        addMenuItem("Copy", #selector(browserCopy(_:)), "c", to: browserMenu)
        addMenuItem("Paste", #selector(browserPaste(_:)), "v", to: browserMenu)
        addMenuItem("Select All", #selector(browserSelectAll(_:)), "a", to: browserMenu)
        browserMenu.addItem(.separator())
        addMenuItem("Copy Page URL", #selector(browserCopyPageURL(_:)), "", modifiers: [], to: browserMenu)
        addMenuItem("Open Page in Default Browser", #selector(browserOpenPageInDefaultBrowser(_:)), "", modifiers: [], to: browserMenu)
        addMenuItem("View Source", #selector(browserViewSource(_:)), "u", modifiers: [.command, .option], to: browserMenu)
        browserMenu.addItem(.separator())
        addMenuItem("Zoom In", #selector(browserZoomIn(_:)), "+", to: browserMenu)
        addMenuItem("Zoom Out", #selector(browserZoomOut(_:)), "-", to: browserMenu)
        addMenuItem("Actual Size", #selector(browserZoomReset(_:)), "0", to: browserMenu)
        browserMenu.addItem(.separator())
        addMenuItem("Print", #selector(browserPrint(_:)), "p", to: browserMenu)
        addMenuItem("Developer Tools", #selector(browserShowDeveloperTools(_:)), "i", modifiers: [.command, .option], to: browserMenu)

        NSApp.mainMenu = mainMenu
    }

    private func addMenuItem(
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }

    @objc private func newBrowserPane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.addBrowserPane()
    }

    @objc private func newTerminalPane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.addTerminalPane()
    }

    @objc private func closeActivePane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.closeActivePane()
    }

    @objc private func resetWindowAndPaneLayout(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(frameAutosaveName)")
        for paneCount in 3...6 {
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames GSDE.WorkspaceSplit.\(paneCount)")
        }
        for browserIndex in 0..<4 {
            UserDefaults.standard.removeObject(forKey: "GSDE.BrowserPane.browser.\(browserIndex).url")
        }
        UserDefaults.standard.removeObject(forKey: "GSDE.WorkspacePaneLayout")
        UserDefaults.standard.removeObject(forKey: "GSDE.BrowserPane.nextDynamicIndex")
        let frame = Self.frameCoveringAllDisplays()
        window?.setFrame(frame, display: true, animate: true)
        (window?.contentView as? ThreePaneWorkspaceView)?.resetDividerPositions()
    }

    private var activeBrowserPane: BrowserPaneView? {
        BrowserPaneView.activePane
    }

    @objc private func browserFocusLocation(_ sender: Any?) { activeBrowserPane?.browserFocusLocation() }
    @objc private func browserOpenFind(_ sender: Any?) { activeBrowserPane?.browserOpenFind() }
    @objc private func browserFindNext(_ sender: Any?) { activeBrowserPane?.browserFindNext() }
    @objc private func browserFindPrevious(_ sender: Any?) { activeBrowserPane?.browserFindPrevious() }
    @objc private func browserGoBack(_ sender: Any?) { activeBrowserPane?.browserGoBack() }
    @objc private func browserGoForward(_ sender: Any?) { activeBrowserPane?.browserGoForward() }
    @objc private func browserReload(_ sender: Any?) { activeBrowserPane?.browserReload() }
    @objc private func browserReloadIgnoringCache(_ sender: Any?) { activeBrowserPane?.browserReloadIgnoringCache() }
    @objc private func browserStopLoading(_ sender: Any?) { activeBrowserPane?.browserStopLoading() }
    @objc private func browserCut(_ sender: Any?) { activeBrowserPane?.browserCut() }
    @objc private func browserCopy(_ sender: Any?) { activeBrowserPane?.browserCopy() }
    @objc private func browserPaste(_ sender: Any?) { activeBrowserPane?.browserPaste() }
    @objc private func browserSelectAll(_ sender: Any?) { activeBrowserPane?.browserSelectAll() }
    @objc private func browserCopyPageURL(_ sender: Any?) { activeBrowserPane?.browserCopyPageURL() }
    @objc private func browserOpenPageInDefaultBrowser(_ sender: Any?) { activeBrowserPane?.browserOpenPageInDefaultBrowser() }
    @objc private func browserViewSource(_ sender: Any?) { activeBrowserPane?.browserViewSource() }
    @objc private func browserZoomIn(_ sender: Any?) { activeBrowserPane?.browserZoomIn() }
    @objc private func browserZoomOut(_ sender: Any?) { activeBrowserPane?.browserZoomOut() }
    @objc private func browserZoomReset(_ sender: Any?) { activeBrowserPane?.browserZoomReset() }
    @objc private func browserPrint(_ sender: Any?) { activeBrowserPane?.browserPrint() }
    @objc private func browserShowDeveloperTools(_ sender: Any?) { activeBrowserPane?.browserShowDeveloperTools() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
