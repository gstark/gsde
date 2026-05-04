import AppKit
import ChromiumStub
import GhosttyShim
import GSDEConfig

final class GhosttyHostView: NSView, @preconcurrency NSTextInputClient {
    static weak var activePane: GhosttyHostView?

    private var host: OpaquePointer?
    private var statusLabel: NSTextField?
    private var displayLink: Timer?
    private var activePaneObserver: NSObjectProtocol?
    private var markedText = ""
    private var handledTextInput = false

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
            if let activePaneObserver {
                NotificationCenter.default.removeObserver(activePaneObserver)
                self.activePaneObserver = nil
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
        markActivePane()
        gsde_ghostty_host_focus(host, true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        gsde_ghostty_host_focus(host, false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        markActivePane()
        window?.makeFirstResponder(self)
        gsde_ghostty_host_focus(host, true)
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        markActivePane()
        window?.makeFirstResponder(self)
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        markActivePane()
        window?.makeFirstResponder(self)
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: ghosttyButton(for: event))
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: ghosttyButton(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let host else { return }
        gsde_ghostty_host_mouse_scroll(host, event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags.ghosttyScrollMods)
    }

    override func keyDown(with event: NSEvent) {
        if shouldUseTextInput(for: event) {
            handledTextInput = false
            interpretKeyEvents([event])
            if handledTextInput { return }
        }

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

    private func shouldUseTextInput(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .control]).isEmpty,
              let characters = event.characters,
              !characters.isEmpty
        else { return false }

        return characters.unicodeScalars.contains { scalar in
            scalar.value >= 0x20 && !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF)
        }
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let host else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = backingScaleFactor
        gsde_ghostty_host_mouse_pos(
            host,
            Double(point.x) * scale,
            Double(bounds.height - point.y) * scale,
            event.modifierFlags.ghosttyMods
        )
    }

    private func sendMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) {
        guard let host else { return }
        _ = gsde_ghostty_host_mouse_button(host, state, button, event.modifierFlags.ghosttyMods)
    }

    private func ghosttyButton(for event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
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
        layer?.borderWidth = 0
        layer?.cornerRadius = 6

        installActivePaneObserver()
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

    private func installActivePaneObserver() {
        activePaneObserver = NotificationCenter.default.addObserver(
            forName: .gsdeActivePaneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activeObjectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self else { return }
                self.setActiveAppearance(activeObjectID == ObjectIdentifier(self))
            }
        }
    }

    var hasSelectionForCopy: Bool {
        guard let host else { return false }
        return gsde_ghostty_host_has_selection(host)
    }

    func copySelectionToPasteboard() {
        guard let host, let selection = gsde_ghostty_host_read_selection(host) else { return }
        defer { gsde_ghostty_free_string(selection) }
        let text = String(cString: selection)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteTextFromPasteboard() {
        guard let host,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty
        else { return }
        text.withCString { pointer in
            gsde_ghostty_host_text(host, pointer, UInt(text.utf8.count))
        }
    }

    private func markActivePane() {
        Self.activePane = self
        BrowserPaneView.activePane = nil
        updateWindowTitleIfActive()
        NotificationCenter.default.post(name: .gsdeActivePaneDidChange, object: self)
    }

    private func updateWindowTitleIfActive() {
        guard Self.activePane === self else { return }
        let title = host.map { String(cString: gsde_ghostty_host_title($0)) } ?? "Terminal"
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.title = cleanTitle.isEmpty ? "GSDE — Terminal" : "GSDE — \(cleanTitle)"
    }

    private func setActiveAppearance(_ active: Bool) {
        layer?.borderWidth = active ? 2 : 0
        layer?.borderColor = active ? NSColor.controlAccentColor.cgColor : nil
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
        updateWindowTitleIfActive()
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

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = plainText(from: string)
        guard !text.isEmpty else { return }
        markedText = ""
        handledTextInput = true
        text.withCString { pointer in
            gsde_ghostty_host_text(host, pointer, UInt(text.utf8.count))
        }
        gsde_ghostty_host_preedit(host, "", 0)
    }

    override func doCommand(by selector: Selector) {
        handledTextInput = false
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = plainText(from: string)
        handledTextInput = true
        markedText.withCString { pointer in
            gsde_ghostty_host_preedit(host, pointer, UInt(markedText.utf8.count))
        }
    }

    func unmarkText() {
        markedText = ""
        gsde_ghostty_host_preedit(host, "", 0)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: markedText.utf16.count, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        gsde_ghostty_host_ime_point(host, &x, &y, &width, &height)

        let scale = backingScaleFactor
        let localRect = NSRect(
            x: x / scale,
            y: bounds.height - (y / scale),
            width: width / scale,
            height: max(1, height / scale)
        )
        let windowRect = convert(localRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    private func plainText(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }
}

@MainActor
final class ConfiguredPaneRegistry {
    private let definitionsByID: [String: PaneDefinition]
    private let appSupportDirectory: URL
    private var viewsByPaneID: [String: NSView] = [:]

    init(
        config: WorkspaceConfig,
        appSupportDirectory: URL = ConfiguredPaneRegistry.applicationSupportDirectory()
    ) {
        self.definitionsByID = Dictionary(uniqueKeysWithValues: config.panes.map { ($0.id, $0) })
        self.appSupportDirectory = appSupportDirectory
    }

    private static func applicationSupportDirectory() -> URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("Could not resolve the user Application Support directory for configured pane profiles")
        }
        return url
    }

    func view(for paneID: String) -> NSView {
        if let existingView = viewsByPaneID[paneID] { return existingView }
        guard let definition = definitionsByID[paneID] else {
            preconditionFailure("Layout references unknown configured pane ID \(paneID)")
        }
        let view = makeView(for: definition)
        viewsByPaneID[paneID] = view
        return view
    }

    func views(for layout: ValidatedMosaicLayout) -> [NSView] {
        layout.slots.map { view(for: $0.paneID) }
    }

    func allViews() -> [NSView] {
        definitionsByID.keys.sorted().map { view(for: $0) }
    }

    private static func profileDirectoryName(for profileName: String) -> String {
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "._-")
        guard let directoryName = profileName.addingPercentEncoding(withAllowedCharacters: allowedCharacters),
              !directoryName.isEmpty
        else {
            preconditionFailure("Could not derive a safe configured browser profile directory name")
        }
        if directoryName == "." || directoryName == ".." {
            return directoryName.replacingOccurrences(of: ".", with: "%2E")
        }
        return directoryName
    }

    private func makeView(for definition: PaneDefinition) -> NSView {
        switch definition.kind {
        case .terminal:
            return GhosttyHostView()
        case .browser:
            guard let url = definition.url else {
                preconditionFailure("Validated browser pane \(definition.id) is missing its URL")
            }
            let profileName = definition.profile ?? definition.id
            let profile = BrowserProfileConfig(
                name: profileName,
                storageDirectory: appSupportDirectory
                    .appendingPathComponent("GSDE", isDirectory: true)
                    .appendingPathComponent("Chromium", isDirectory: true)
                    .appendingPathComponent("Profiles", isDirectory: true)
                    .appendingPathComponent(Self.profileDirectoryName(for: profileName), isDirectory: true),
                persistent: true
            )
            return BrowserPaneView(profile: profile, stateIdentifier: definition.id, initialURL: url)
        }
    }
}

final class MosaicWorkspaceView: NSView {
    private let config: WorkspaceConfig
    private let paneRegistry: ConfiguredPaneRegistry
    private var activeLayoutID: String

    init(
        frame frameRect: NSRect,
        config: WorkspaceConfig,
        paneRegistry: ConfiguredPaneRegistry,
        activeLayoutID: String
    ) {
        self.config = config
        self.paneRegistry = paneRegistry
        self.activeLayoutID = activeLayoutID
        super.init(frame: frameRect)
        commonInit()
        applyActiveLayout()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("MosaicWorkspaceView requires a validated workspace config and pane registry")
    }

    func applyLayout(id layoutID: String) {
        guard config.validatedLayouts.contains(where: { $0.id == layoutID }) else {
            preconditionFailure("Layout references unknown configured layout ID \(layoutID)")
        }
        activeLayoutID = layoutID
        applyActiveLayout()
    }

    override func layout() {
        super.layout()
        applyActiveLayout()
    }

    func visiblePaneFrames() -> [MosaicPaneFrame] {
        guard let layout = config.validatedLayouts.first(where: { $0.id == activeLayoutID }) else {
            preconditionFailure("Layout references unknown configured layout ID \(activeLayoutID)")
        }
        return layout.slots.map { slot in
            let paneView = paneRegistry.view(for: slot.paneID)
            return MosaicPaneFrame(paneID: slot.paneID, frame: paneView.frame)
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true
        paneRegistry.allViews().forEach { paneView in
            paneView.autoresizingMask = []
            paneView.isHidden = true
            addSubview(paneView)
        }
    }

    private func applyActiveLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let layout = config.validatedLayouts.first(where: { $0.id == activeLayoutID }) else {
            preconditionFailure("Layout references unknown configured layout ID \(activeLayoutID)")
        }

        for paneView in paneRegistry.allViews() {
            paneView.isHidden = true
        }

        for assignment in MosaicLayoutFrames.frames(for: layout, in: bounds) {
            let paneView = paneRegistry.view(for: assignment.paneID)
            if paneView.superview !== self {
                addSubview(paneView)
            }
            paneView.frame = assignment.frame
            paneView.isHidden = false
        }
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

    private struct WorkspaceLayout: Codable {
        let version: Int
        let panes: [PaneDescriptor]
    }

    private static let paneLayoutVersion = 1
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
        let hasLegacyPaneEnvironment = ProcessInfo.processInfo.environment["GSDE_BROWSER_PANES"] != nil
            || ProcessInfo.processInfo.environment["GSDE_BROWSER_URLS"] != nil
        guard hasLegacyPaneEnvironment else {
            if let savedPanes = makeSavedPanes() {
                return savedPanes
            }
            return makeConfiguredPanes(from: .builtIn)
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

    private static func makeConfiguredPanes(from config: WorkspaceConfig) -> [NSView] {
        guard let startupLayout = config.startupMosaicLayout else { return [GhosttyHostView()] }
        let registry = ConfiguredPaneRegistry(config: config)
        let configuredPanes = registry.views(for: startupLayout)
        return configuredPanes.isEmpty ? [GhosttyHostView()] : configuredPanes
    }

    private static func makeSavedPanes() -> [NSView]? {
        guard let data = UserDefaults.standard.data(forKey: paneLayoutDefaultsKey),
              let descriptors = decodeSavedPaneDescriptors(from: data),
              !descriptors.isEmpty
        else { return nil }

        cleanupAbandonedDynamicBrowserProfiles(retaining: Set(descriptors.compactMap(\.stateIdentifier)))

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

    private static func decodeSavedPaneDescriptors(from data: Data) -> [PaneDescriptor]? {
        let decoder = JSONDecoder()
        if let layout = try? decoder.decode(WorkspaceLayout.self, from: data),
           layout.version == paneLayoutVersion {
            return layout.panes
        }

        // Backward compatibility with the original persisted format, which was
        // just an array of pane descriptors without an envelope/version.
        return try? decoder.decode([PaneDescriptor].self, from: data)
    }

    private static func cleanupAbandonedDynamicBrowserProfiles(retaining retainedIdentifiers: Set<String>) {
        guard let profilesDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("GSDE/Chromium/Profiles", isDirectory: true),
              let profileURLs = try? FileManager.default.contentsOfDirectory(
                at: profilesDirectory,
                includingPropertiesForKeys: nil
              )
        else { return }

        for profileURL in profileURLs {
            let identifier = profileURL.lastPathComponent
            guard identifier.hasPrefix("browser.dynamic."), !retainedIdentifiers.contains(identifier) else { continue }
            try? FileManager.default.removeItem(at: profileURL)
            UserDefaults.standard.removeObject(forKey: "GSDE.BrowserPane.\(identifier).url")
        }
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
        addBrowserPane(initialURL: URL(string: "https://example.com")!, after: activeArrangedPane)
    }

    func duplicateActiveBrowserPane() {
        guard let browserPane = BrowserPaneView.activePane else { return }
        addBrowserPane(initialURL: browserPane.currentURLForWorkspaceDuplication, after: activeArrangedPane)
    }

    private func addBrowserPane(initialURL: URL, after existingPane: NSView?) {
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
            BrowserPaneView(profile: profile, stateIdentifier: stateIdentifier, initialURL: initialURL),
            after: existingPane
        )
        persistPaneLayout()
        distributePanesEvenly()
    }

    var canCloseActivePane: Bool {
        arrangedSubviews.count > 1 && activeArrangedPane != nil
    }

    var canCloseOtherPanes: Bool {
        arrangedSubviews.count > 1 && activeArrangedPane != nil
    }

    func focusNextPane() {
        focusPane(offset: 1)
    }

    func focusPreviousPane() {
        focusPane(offset: -1)
    }

    func moveActivePaneLeft() {
        moveActivePane(offset: -1)
    }

    func moveActivePaneRight() {
        moveActivePane(offset: 1)
    }

    func closeActivePane() {
        guard canCloseActivePane, let pane = activeArrangedPane else { return }
        removePane(pane)
        BrowserPaneView.activePane = nil
        GhosttyHostView.activePane = nil
        persistPaneLayout()
        distributePanesEvenly()
    }

    func closeOtherPanes() {
        guard canCloseOtherPanes, let activePane = activeArrangedPane else { return }
        arrangedSubviews
            .filter { $0 !== activePane }
            .forEach(removePane)
        persistPaneLayout()
        distributePanesEvenly()
        if let browserPane = activePane as? BrowserPaneView {
            window?.makeFirstResponder(browserPane)
        } else if let terminalPane = activePane as? GhosttyHostView {
            window?.makeFirstResponder(terminalPane)
        }
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

    private func removePane(_ pane: NSView) {
        removeArrangedSubview(pane)
        pane.removeFromSuperview()
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
        let layout = WorkspaceLayout(version: Self.paneLayoutVersion, panes: descriptors)
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: Self.paneLayoutDefaultsKey)
    }

    private func distributePanesEvenly() {
        guard bounds.width > 0, arrangedSubviews.count > 1 else { return }
        autosaveName = splitAutosaveName
        for index in 1..<arrangedSubviews.count {
            setPosition(bounds.width * CGFloat(index) / CGFloat(arrangedSubviews.count), ofDividerAt: index - 1)
        }
    }

    private func moveActivePane(offset: Int) {
        guard arrangedSubviews.count > 1,
              let pane = activeArrangedPane,
              let currentIndex = arrangedSubviews.firstIndex(of: pane)
        else { return }
        let targetIndex = currentIndex + offset
        guard arrangedSubviews.indices.contains(targetIndex) else { return }
        removeArrangedSubview(pane)
        insertArrangedSubview(pane, at: targetIndex)
        setHoldingPriority(.defaultLow, forSubviewAt: targetIndex)
        persistPaneLayout()
        distributePanesEvenly()
        focusPane(at: targetIndex)
    }

    private func focusPane(offset: Int) {
        guard !arrangedSubviews.isEmpty else { return }
        let currentIndex = activeArrangedPane.flatMap { arrangedSubviews.firstIndex(of: $0) } ?? 0
        let nextIndex = (currentIndex + offset + arrangedSubviews.count) % arrangedSubviews.count
        focusPane(at: nextIndex)
    }

    private func focusPane(at index: Int) {
        guard arrangedSubviews.indices.contains(index) else { return }
        let pane = arrangedSubviews[index]
        if let browserPane = pane as? BrowserPaneView {
            window?.makeFirstResponder(browserPane)
        } else if let terminalPane = pane as? GhosttyHostView {
            window?.makeFirstResponder(terminalPane)
        } else if let focusable = pane.subviews.first(where: { $0.acceptsFirstResponder }) {
            window?.makeFirstResponder(focusable)
        } else {
            window?.makeFirstResponder(pane)
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

final class BorderlessMainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var chromiumMessageLoopTimer: Timer?
    private var didPrepareChromiumShutdown = false
    private let frameAutosaveName = "GSDE.MainWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        installMainMenu()
        initializeChromiumIfAvailable()

        let frame = Self.frameCoveringAllDisplays()
        let contentView = Self.makeWorkspaceView(frame: NSRect(origin: .zero, size: frame.size))

        let window = BorderlessMainWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "GSDE"
        window.hasShadow = false
        window.level = .mainMenu
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(frame, display: true)
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

    static func makeWorkspaceView(frame: NSRect) -> NSView {
        let hasLegacyPaneEnvironment = ProcessInfo.processInfo.environment["GSDE_BROWSER_PANES"] != nil
            || ProcessInfo.processInfo.environment["GSDE_BROWSER_URLS"] != nil
        guard !hasLegacyPaneEnvironment else {
            logConfig("GSDE_BROWSER_PANES/GSDE_BROWSER_URLS set; skipping TOML workspace config and using ThreePane workspace")
            return ThreePaneWorkspaceView(frame: frame)
        }

        let loadedConfig = WorkspaceConfigLoader().load()
        for diagnostic in loadedConfig.diagnostics {
            logConfig("\(diagnostic)")
        }

        let hasConfigErrors = loadedConfig.diagnostics.contains { $0.severity == .error }
        guard !hasConfigErrors else {
            logConfig("workspace config failed validation or parsing; falling back to ThreePane workspace")
            return ThreePaneWorkspaceView(frame: frame)
        }
        guard loadedConfig.source != .builtIn else {
            logConfig("no TOML workspace config found; using ThreePane workspace")
            return ThreePaneWorkspaceView(frame: frame)
        }
        guard let startupLayout = loadedConfig.config.startupMosaicLayout else {
            preconditionFailure("Validated workspace config is missing startup layout \(loadedConfig.config.startupLayout)")
        }

        if let configURL = loadedConfig.source.url {
            logConfig("loaded TOML workspace config from \(configURL.path); using Mosaic workspace layout \(startupLayout.id)")
        }
        let registry = ConfiguredPaneRegistry(config: loadedConfig.config)
        return MosaicWorkspaceView(
            frame: frame,
            config: loadedConfig.config,
            paneRegistry: registry,
            activeLayoutID: startupLayout.id
        )
    }

    private static func logConfig(_ message: String) {
        FileHandle.standardError.write(Data("GSDE config: \(message)\n".utf8))
    }

    private static func frameCoveringAllDisplays() -> NSRect {
        let screens = NSScreen.screens
        guard let firstScreen = screens.first else { return .zero }

        let displayBounds = screens
            .map(\.frame)
            .reduce(NSRect.null) { accumulated, screenFrame in
                accumulated.union(screenFrame)
            }

        return NSRect(
            x: firstScreen.frame.minX,
            y: firstScreen.frame.maxY - displayBounds.height,
            width: displayBounds.width,
            height: displayBounds.height
        )
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
        addMenuItem("Duplicate Active Browser Pane", #selector(duplicateActiveBrowserPane(_:)), "d", modifiers: [.command, .shift], to: workspaceMenu)
        addMenuItem("Close Active Pane", #selector(closeActivePane(_:)), "w", to: workspaceMenu)
        addMenuItem("Close Other Panes", #selector(closeOtherPanes(_:)), "w", modifiers: [.command, .option], to: workspaceMenu)
        workspaceMenu.addItem(.separator())
        addMenuItem("Focus Next Pane", #selector(focusNextPane(_:)), "}", to: workspaceMenu)
        addMenuItem("Focus Previous Pane", #selector(focusPreviousPane(_:)), "{", to: workspaceMenu)
        addMenuItem("Move Pane Left", #selector(moveActivePaneLeft(_:)), "{", modifiers: [.command, .shift], to: workspaceMenu)
        addMenuItem("Move Pane Right", #selector(moveActivePaneRight(_:)), "}", modifiers: [.command, .shift], to: workspaceMenu)
        workspaceMenu.addItem(.separator())
        addMenuItem("Reset Window and Pane Layout", #selector(resetWindowAndPaneLayout(_:)), "", modifiers: [], to: workspaceMenu)

        let terminalMenuItem = NSMenuItem()
        terminalMenuItem.title = "Terminal"
        mainMenu.addItem(terminalMenuItem)
        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenuItem.submenu = terminalMenu
        addMenuItem("Copy", #selector(terminalCopy(_:)), "c", to: terminalMenu)
        addMenuItem("Paste", #selector(terminalPaste(_:)), "v", to: terminalMenu)

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

    @objc private func duplicateActiveBrowserPane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.duplicateActiveBrowserPane()
    }

    @objc private func closeActivePane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.closeActivePane()
    }

    @objc private func closeOtherPanes(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.closeOtherPanes()
    }

    @objc private func focusNextPane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.focusNextPane()
    }

    @objc private func focusPreviousPane(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.focusPreviousPane()
    }

    @objc private func moveActivePaneLeft(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.moveActivePaneLeft()
    }

    @objc private func moveActivePaneRight(_ sender: Any?) {
        (window?.contentView as? ThreePaneWorkspaceView)?.moveActivePaneRight()
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeActivePane(_:)):
            return (window?.contentView as? ThreePaneWorkspaceView)?.canCloseActivePane ?? false
        case #selector(terminalCopy(_:)):
            return activeTerminalPane?.hasSelectionForCopy ?? false
        case #selector(terminalPaste(_:)):
            return activeTerminalPane != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(closeOtherPanes(_:)):
            return (window?.contentView as? ThreePaneWorkspaceView)?.canCloseOtherPanes ?? false
        case #selector(duplicateActiveBrowserPane(_:)):
            return activeBrowserPane != nil
        case #selector(browserFocusLocation(_:)),
             #selector(browserOpenFind(_:)),
             #selector(browserFindNext(_:)),
             #selector(browserFindPrevious(_:)),
             #selector(browserGoBack(_:)),
             #selector(browserGoForward(_:)),
             #selector(browserReload(_:)),
             #selector(browserReloadIgnoringCache(_:)),
             #selector(browserStopLoading(_:)),
             #selector(browserCut(_:)),
             #selector(browserCopy(_:)),
             #selector(browserPaste(_:)),
             #selector(browserSelectAll(_:)),
             #selector(browserCopyPageURL(_:)),
             #selector(browserOpenPageInDefaultBrowser(_:)),
             #selector(browserViewSource(_:)),
             #selector(browserZoomIn(_:)),
             #selector(browserZoomOut(_:)),
             #selector(browserZoomReset(_:)),
             #selector(browserPrint(_:)),
             #selector(browserShowDeveloperTools(_:)):
            return activeBrowserPane != nil
        default:
            return true
        }
    }

    private var activeBrowserPane: BrowserPaneView? {
        BrowserPaneView.activePane
    }

    private var activeTerminalPane: GhosttyHostView? {
        GhosttyHostView.activePane
    }

    @objc private func terminalCopy(_ sender: Any?) { activeTerminalPane?.copySelectionToPasteboard() }
    @objc private func terminalPaste(_ sender: Any?) { activeTerminalPane?.pasteTextFromPasteboard() }

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

if ProcessInfo.processInfo.environment["GSDE_VERIFY_WORKSPACE_STARTUP"] != nil {
    let workspaceView = AppDelegate.makeWorkspaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    print(String(describing: type(of: workspaceView)))
} else if let rawSize = ProcessInfo.processInfo.environment["GSDE_VERIFY_MOSAIC_LAYOUT"] {
    let parts = rawSize.split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2 else {
        fatalError("GSDE_VERIFY_MOSAIC_LAYOUT must be WIDTHxHEIGHT")
    }
    let loadedConfig = WorkspaceConfigLoader().load()
    guard loadedConfig.diagnostics.isEmpty else {
        fatalError("GSDE config diagnostics blocked mosaic verification: \(loadedConfig.diagnostics)")
    }
    guard let startupLayout = loadedConfig.config.startupMosaicLayout else {
        fatalError("GSDE config has no startup layout to verify")
    }
    let frame = NSRect(x: 0, y: 0, width: parts[0], height: parts[1])
    let paneRegistry = ConfiguredPaneRegistry(config: loadedConfig.config)
    let workspaceView = MosaicWorkspaceView(
        frame: frame,
        config: loadedConfig.config,
        paneRegistry: paneRegistry,
        activeLayoutID: startupLayout.id
    )
    workspaceView.layoutSubtreeIfNeeded()

    if let targetLayoutID = ProcessInfo.processInfo.environment["GSDE_VERIFY_MOSAIC_LAYOUT_SWITCH"] {
        let originalViewIDs = Dictionary(uniqueKeysWithValues: loadedConfig.config.panes.map { pane in
            (pane.id, ObjectIdentifier(paneRegistry.view(for: pane.id)))
        })
        workspaceView.applyLayout(id: targetLayoutID)
        workspaceView.layoutSubtreeIfNeeded()
        print("layout \(targetLayoutID)")
        for pane in loadedConfig.config.panes {
            let reusedView = originalViewIDs[pane.id] == ObjectIdentifier(paneRegistry.view(for: pane.id))
            print("reused \(pane.id) \(reusedView)")
        }
    }

    for assignment in workspaceView.visiblePaneFrames() {
        let frame = assignment.frame
        print("\(assignment.paneID) \(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))")
    }
    for pane in loadedConfig.config.panes where paneRegistry.view(for: pane.id).isHidden {
        print("hidden \(pane.id)")
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
