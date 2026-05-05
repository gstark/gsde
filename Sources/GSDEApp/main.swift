import AppKit
import Darwin
import ChromiumStub
import GhosttyShim
import GSDEConfig

final class GhosttyHostView: NSView, @preconcurrency NSTextInputClient {
    static weak var activePane: GhosttyHostView?

    private var host: OpaquePointer?
    private var statusLabel: NSTextField?
    private var displayLink: Timer?
    private var activePaneObserver: NSObjectProtocol?
    var drawsActiveAppearance = true
    private var markedText = ""
    private let startupCommand: String?
    private var handledTextInput = false
    private var keyTextAccumulator: [String]?
    private var didRunStartupCommand = false

    init(frame frameRect: NSRect = .zero, startupCommand: String? = nil) {
        self.startupCommand = startupCommand
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.startupCommand = nil
        super.init(coder: coder)
        commonInit()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.firstResponder == nil {
            window?.makeFirstResponder(self)
        }
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
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        if shouldUseTextInput(for: event) {
            let hadMarkedText = !markedText.isEmpty
            keyTextAccumulator = []
            handledTextInput = false
            interpretKeyEvents([event])
            let committedText = keyTextAccumulator ?? []
            keyTextAccumulator = nil

            if !committedText.isEmpty {
                let composing = !markedText.isEmpty || hadMarkedText
                for text in committedText {
                    _ = sendKey(event, action: action, text: text, composing: composing)
                }
                return
            }

            if handledTextInput || !markedText.isEmpty || hadMarkedText { return }
        }

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
        gsde_ghostty_host_mouse_pos(
            host,
            Double(point.x),
            Double(bounds.height - point.y),
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
        VSCodePaneView.activePane = nil
        updateWindowTitleIfActive()
        NotificationCenter.default.post(name: .gsdeActivePaneDidChange, object: self)
    }

    private func updateWindowTitleIfActive() {
        guard Self.activePane === self else { return }
        let title = host.map { String(cString: gsde_ghostty_host_title($0)) } ?? "Terminal"
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.title = cleanTitle.isEmpty ? WorkspaceDisplayTitle.title : "\(WorkspaceDisplayTitle.title) — \(cleanTitle)"
    }

    private func setActiveAppearance(_ active: Bool) {
        guard drawsActiveAppearance else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
            return
        }
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
            runStartupCommandIfNeeded()
        } else {
            statusLabel?.stringValue = String(cString: gsde_ghostty_status())
        }
    }

    @objc private func tickGhostty() {
        guard let host else { return }
        gsde_ghostty_host_tick(host)
        gsde_ghostty_host_draw(host)
        updateWindowTitleIfActive()
        runStartupCommandIfNeeded()
    }

    private func runStartupCommandIfNeeded() {
        guard !didRunStartupCommand,
              let host,
              let startupCommand,
              !startupCommand.isEmpty
        else { return }
        didRunStartupCommand = true
        let commandLine = startupCommand + "\n"
        commandLine.withCString { pointer in
            gsde_ghostty_host_text(host, pointer, UInt(commandLine.utf8.count))
        }
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
        let hadMarkedText = !markedText.isEmpty
        markedText = ""
        handledTextInput = true
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            text.withCString { pointer in
                gsde_ghostty_host_text(host, pointer, UInt(text.utf8.count))
            }
        }
        if hadMarkedText {
            gsde_ghostty_host_preedit(host, "", 0)
        }
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
final class PaneBoxView: NSView {
    let contentView: NSView
    let configuredBorder: PaneBoxEdges
    let padding: PaneBoxEdges
    private var displayBorder: PaneBoxEdges
    private var activePaneObserver: NSObjectProtocol?
    private var active = false

    init(contentView: NSView, border: PaneBoxEdges, padding: PaneBoxEdges) {
        self.contentView = contentView
        self.configuredBorder = border
        self.displayBorder = border
        self.padding = padding
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(contentView)
        installActivePaneObserver()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("PaneBoxView requires a content view")
    }

    override var acceptsFirstResponder: Bool { false }

    func setDisplayBorder(_ border: PaneBoxEdges) {
        guard displayBorder != border else { return }
        displayBorder = border
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let top = CGFloat(configuredBorder.top + padding.top)
        let right = CGFloat(configuredBorder.right + padding.right)
        let bottom = CGFloat(configuredBorder.bottom + padding.bottom)
        let left = CGFloat(configuredBorder.left + padding.left)
        contentView.frame = NSRect(
            x: bounds.minX + left,
            y: bounds.minY + bottom,
            width: max(1, bounds.width - left - right),
            height: max(1, bounds.height - top - bottom)
        )
    }

    private func installActivePaneObserver() {
        activePaneObserver = NotificationCenter.default.addObserver(
            forName: .gsdeActivePaneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activeView = notification.object as? NSView
            Task { @MainActor in
                guard let self else { return }
                let isActive = activeView === self.contentView || activeView?.isDescendant(of: self.contentView) == true
                if self.active != isActive {
                    self.active = isActive
                    self.needsDisplay = true
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        drawBorderLine(edge: .minY, thickness: CGFloat(displayBorder.top))
        drawBorderLine(edge: .maxX, thickness: CGFloat(displayBorder.right))
        drawBorderLine(edge: .maxY, thickness: CGFloat(displayBorder.bottom))
        drawBorderLine(edge: .minX, thickness: CGFloat(displayBorder.left))

        if active {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }

    private enum BorderEdge { case minX, maxX, minY, maxY }

    private func drawBorderLine(edge: BorderEdge, thickness: CGFloat) {
        guard thickness > 0 else { return }
        let rect: NSRect
        switch edge {
        case .minX:
            rect = NSRect(x: bounds.minX, y: bounds.minY, width: thickness, height: bounds.height)
        case .maxX:
            rect = NSRect(x: bounds.maxX - thickness, y: bounds.minY, width: thickness, height: bounds.height)
        case .minY:
            rect = NSRect(x: bounds.minX, y: bounds.maxY - thickness, width: bounds.width, height: thickness)
        case .maxY:
            rect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: thickness)
        }
        rect.fill()
    }
}

@MainActor
final class VSCodePaneView: NSView {
    static weak var activePane: VSCodePaneView?

    private let paneID: String
    private let configSource: WorkspaceConfigSource
    private let codeServerManager: CodeServerManager
    private let profileMode: VSCodePaneProfileMode
    private let browserContainer = NSView()
    private let overlayContainer = NSView()
    private var cefBrowser: OpaquePointer?
    private weak var cefNativeView: NSView?
    private var cefStatusTimer: Timer?
    private var keyCommandMonitor: Any?
    private var mouseFocusMonitor: Any?
    private var activePaneObserver: NSObjectProtocol?
    private var startTask: Task<Void, Never>?
    private var startTaskID: UUID?
    private var statusTask: Task<Void, Never>?
    private var hideOverlayTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopGeneration = 0
    private var hasStartedSession = false
    private var currentServerURL: URL?
    private var currentCEFCacheDirectory: URL?
    private static let cefErrorAborted = -3
    var drawsActiveAppearance = true

    init(paneID: String, configSource: WorkspaceConfigSource, codeServerManager: CodeServerManager, profileMode: VSCodePaneProfileMode = .native) {
        self.paneID = paneID
        self.configSource = configSource
        self.codeServerManager = codeServerManager
        self.profileMode = profileMode
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        preconditionFailure("VSCodePaneView requires a pane ID and code-server manager")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDownViewLifetimeResources()
            stopGeneration += 1
            stopTask = Task { await codeServerManager.stop(paneID: paneID) }
            return
        }
        installActivePaneObserverIfNeeded()
        installKeyCommandMonitorIfNeeded()
        installMouseFocusMonitorIfNeeded()
        if Self.activePane == nil, BrowserPaneView.activePane == nil, GhosttyHostView.activePane == nil {
            markActivePane()
        }
        if hasStartedSession, cefBrowser == nil {
            _ = attachBrowserToStartedSessionOrFail()
        } else {
            startCodeServerIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        resizeCEFBrowser()
    }

    override func becomeFirstResponder() -> Bool {
        markActivePane()
        focusCEFBrowser()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let cefBrowser {
            gsde_chromium_browser_focus(cefBrowser, 0)
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        focusBrowserContent()
        super.mouseDown(with: event)
    }

    func focusBrowserContent() {
        markActivePane()
        focusCEFBrowser()
        guard let window else { return }
        if let cefNativeView, window.firstResponder !== cefNativeView {
            if !window.makeFirstResponder(cefNativeView), window.firstResponder !== self {
                _ = window.makeFirstResponder(self)
            }
        } else if cefNativeView == nil, window.firstResponder !== self {
            _ = window.makeFirstResponder(self)
        }
    }

    private func focusCEFBrowser() {
        if let cefBrowser {
            gsde_chromium_browser_focus(cefBrowser, 1)
        }
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        browserContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.wantsLayer = true
        overlayContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        addSubview(browserContainer)
        addSubview(overlayContainer)
        NSLayoutConstraint.activate([
            browserContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            browserContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            browserContainer.topAnchor.constraint(equalTo: topAnchor),
            browserContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayContainer.topAnchor.constraint(equalTo: topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        installActivePaneObserverIfNeeded()
        showOverlay(title: "Starting VS Code…", detail: "Launching code-server for pane \(paneID)", retryAction: nil)
        startCodeServerIfNeeded()
    }

    private func tearDownViewLifetimeResources() {
        startTask?.cancel()
        statusTask?.cancel()
        hideOverlayTask?.cancel()
        cefStatusTimer?.invalidate()
        cefStatusTimer = nil
        startTask = nil
        startTaskID = nil
        statusTask = nil
        hideOverlayTask = nil
        hasStartedSession = false
        currentServerURL = nil
        currentCEFCacheDirectory = nil
        if Self.activePane === self {
            Self.activePane = nil
        }
        if let keyCommandMonitor {
            NSEvent.removeMonitor(keyCommandMonitor)
            self.keyCommandMonitor = nil
        }
        if let mouseFocusMonitor {
            NSEvent.removeMonitor(mouseFocusMonitor)
            self.mouseFocusMonitor = nil
        }
        if let activePaneObserver {
            NotificationCenter.default.removeObserver(activePaneObserver)
            self.activePaneObserver = nil
        }
        if let cefBrowser {
            gsde_chromium_browser_destroy(cefBrowser)
            self.cefBrowser = nil
            cefNativeView = nil
        }
    }

    private func installKeyCommandMonitorIfNeeded() {
        guard keyCommandMonitor == nil else { return }
        keyCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.window === event.window,
                  Self.activePane === self,
                  self.handleVSCodeKeyCommand(event)
            else { return event }
            return nil
        }
    }

    private func handleVSCodeKeyCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command],
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        switch characters {
        case "+", "=":
            zoomIn()
        case "-":
            zoomOut()
        case "0":
            zoomReset()
        case "v":
            pasteClipboard()
        default:
            return false
        }
        return true
    }

    private func installMouseFocusMonitorIfNeeded() {
        guard mouseFocusMonitor == nil else { return }
        mouseFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self,
                  self.window === event.window,
                  self.isEventInsidePane(event)
            else { return event }
            self.focusBrowserContent()
            return event
        }
    }

    private func installActivePaneObserverIfNeeded() {
        guard activePaneObserver == nil else { return }
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

    private func isEventInsidePane(_ event: NSEvent) -> Bool {
        let screenPoint = NSPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        let localPoint = convert(screenPoint, from: nil)
        return bounds.contains(localPoint)
    }

    private func markActivePane() {
        Self.activePane = self
        BrowserPaneView.activePane = nil
        GhosttyHostView.activePane = nil
        updateWindowTitleForActivePane()
        NotificationCenter.default.post(name: .gsdeActivePaneDidChange, object: self)
    }

    private func setActiveAppearance(_ active: Bool) {
        guard drawsActiveAppearance else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
            return
        }
        layer?.borderWidth = active ? 2 : 0
        layer?.borderColor = active ? NSColor.controlAccentColor.cgColor : nil
    }

    private func startCodeServerIfNeeded() {
        guard startTask == nil, !hasStartedSession else { return }
        showOverlay(title: "Starting VS Code…", detail: "Launching code-server for pane \(paneID)", retryAction: nil)
        let pendingStopTask = stopTask
        let pendingStopGeneration = stopGeneration
        let taskID = UUID()
        startTaskID = taskID
        startTask = Task { [weak self, paneID, configSource, codeServerManager, profileMode] in
            do {
                await pendingStopTask?.value
                try Task.checkCancellation()
                let shouldStart = await MainActor.run { [weak self] in
                    guard let self, startTaskID == taskID, stopGeneration == pendingStopGeneration else { return false }
                    stopTask = nil
                    return true
                }
                guard shouldStart else { return }

                let session = try await codeServerManager.start(CodeServerStartRequest(paneID: paneID, configSource: configSource, profileMode: profileMode))
                try Task.checkCancellation()
                let shouldStopSession = await MainActor.run { [weak self] in
                    guard let self, startTaskID == taskID else { return true }
                    currentServerURL = session.serverURL
                    currentCEFCacheDirectory = session.launchConfiguration.stateDirectories.cefCacheDirectory
                    hasStartedSession = true
                    startTask = nil
                    startTaskID = nil
                    guard window != nil else { return true }
                    return attachBrowserToStartedSessionOrFail()
                }
                if shouldStopSession {
                    await codeServerManager.stop(paneID: paneID)
                }
            } catch is CancellationError {
                let shouldStop = await MainActor.run { [weak self] in
                    guard let self else { return true }
                    let taskIsCurrent = startTaskID == taskID
                    if taskIsCurrent {
                        startTask = nil
                        startTaskID = nil
                    }
                    return taskIsCurrent || window == nil
                }
                if shouldStop {
                    await codeServerManager.stop(paneID: paneID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, startTaskID == taskID else { return }
                    showFailure(title: "VS Code pane failed", detail: error.localizedDescription)
                    startTask = nil
                    startTaskID = nil
                }
            }
        }
    }

    private func attachBrowserToStartedSessionOrFail() -> Bool {
        guard let serverURL = currentServerURL, let cacheDirectory = currentCEFCacheDirectory else {
            showFailure(title: "VS Code pane failed", detail: "code-server session is marked ready without a server URL or CEF cache directory")
            return true
        }
        do {
            try createCEFBrowser(serverURL: serverURL, cacheDirectory: cacheDirectory)
            beginMonitoringSession()
            return false
        } catch {
            showFailure(title: "VS Code browser failed", detail: error.localizedDescription)
            return true
        }
    }

    private func createCEFBrowser(serverURL: URL, cacheDirectory: URL) throws {
        guard cefBrowser == nil else { return }
        guard gsde_chromium_cef_available() != 0 else {
            throw VSCodePaneError.cefUnavailable(String(cString: gsde_chromium_backend_status()))
        }
        browserContainer.layoutSubtreeIfNeeded()
        let width = Int32(max(1, browserContainer.bounds.width))
        let height = Int32(max(1, browserContainer.bounds.height))
        let cachePath = CEFPath.canonicalPath(for: cacheDirectory)
        let browser = serverURL.absoluteString.withCString { initialURLPointer in
            cachePath.withCString { cachePathPointer in
                gsde_chromium_browser_create(
                    Unmanaged.passUnretained(browserContainer).toOpaque(),
                    width,
                    height,
                    initialURLPointer,
                    cachePathPointer
                )
            }
        }
        guard let browser else {
            throw VSCodePaneError.cefCreateFailed(String(cString: gsde_chromium_last_error()))
        }
        cefBrowser = browser
        attachCEFBrowserViewIfAvailable(browser)
        startCEFStatusPolling()
    }

    private func attachCEFBrowserViewIfAvailable(_ browser: OpaquePointer) {
        guard let rawView = gsde_chromium_browser_view(browser) else { return }
        let nativeView = Unmanaged<NSView>.fromOpaque(rawView).takeUnretainedValue()
        if nativeView.superview !== browserContainer {
            nativeView.removeFromSuperview()
            browserContainer.addSubview(nativeView)
        }
        nativeView.frame = browserContainer.bounds
        nativeView.autoresizingMask = [.width, .height]
        cefNativeView = nativeView
    }

    private func startCEFStatusPolling() {
        cefStatusTimer?.invalidate()
        cefStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCEFState()
            }
        }
        refreshCEFState()
    }

    private func refreshCEFState() {
        guard let cefBrowser else { return }
        attachCEFBrowserViewIfAvailable(cefBrowser)
        let currentTitle = String(cString: gsde_chromium_browser_title(cefBrowser))
        if Self.activePane === self, !currentTitle.isEmpty {
            updateWindowTitleForActivePane(title: currentTitle)
        }
        let httpStatus = gsde_chromium_browser_http_status(cefBrowser)
        if httpStatus >= 200 && httpStatus < 400 {
            scheduleInitialOverlayHide()
        } else if httpStatus < 0, httpStatus != Self.cefErrorAborted {
            showFailure(title: "VS Code page failed", detail: "CEF reported load error \(httpStatus) for \(currentServerURL?.absoluteString ?? "the VS Code URL")")
        }
    }

    private func scheduleInitialOverlayHide() {
        guard hideOverlayTask == nil, !overlayContainer.isHidden else { return }
        hideOverlayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.hideOverlay()
                self.hideOverlayTask = nil
            }
        }
    }

    private func pasteClipboard() {
        if let cefBrowser {
            gsde_chromium_browser_paste(cefBrowser)
        }
    }

    private func zoomIn() {
        if let cefBrowser {
            gsde_chromium_browser_zoom_in(cefBrowser)
        }
    }

    private func zoomOut() {
        if let cefBrowser {
            gsde_chromium_browser_zoom_out(cefBrowser)
        }
    }

    private func zoomReset() {
        if let cefBrowser {
            gsde_chromium_browser_zoom_reset(cefBrowser)
        }
    }

    private func resizeCEFBrowser() {
        guard let cefBrowser else { return }
        let width = Int32(max(1, browserContainer.bounds.width))
        let height = Int32(max(1, browserContainer.bounds.height))
        cefNativeView?.frame = browserContainer.bounds
        gsde_chromium_browser_resize(cefBrowser, width, height)
    }

    private func beginMonitoringSession() {
        statusTask?.cancel()
        statusTask = Task { [weak self, paneID, codeServerManager] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }

                guard case .exited(let exitCode, let diagnostics) = await codeServerManager.status(forPaneID: paneID) else {
                    continue
                }
                await MainActor.run { [weak self] in
                    guard let self, window != nil else { return }
                    statusTask = nil
                    showFailure(
                        title: "VS Code pane crashed",
                        detail: Self.crashDetail(exitCode: exitCode, diagnostics: diagnostics)
                    )
                }
                return
            }
        }
    }

    private static func crashDetail(exitCode: Int32, diagnostics: CodeServerProcessDiagnostics) -> String {
        let output = diagnostics.combinedOutput.isEmpty ? "no output" : diagnostics.combinedOutput
        return "code-server exited with status \(exitCode): \(output)"
    }

    private func showFailure(title: String, detail: String) {
        statusTask?.cancel()
        statusTask = nil
        cefStatusTimer?.invalidate()
        cefStatusTimer = nil
        if let cefBrowser {
            gsde_chromium_browser_destroy(cefBrowser)
            self.cefBrowser = nil
            cefNativeView = nil
        }
        hasStartedSession = false
        currentServerURL = nil
        currentCEFCacheDirectory = nil
        stopGeneration += 1
        stopTask = Task { await codeServerManager.stop(paneID: paneID) }
        showOverlay(title: title, detail: detail, retryAction: #selector(retryButtonPressed(_:)))
    }

    @objc private func retryButtonPressed(_ sender: NSButton) {
        startCodeServerIfNeeded()
    }

    private func showOverlay(title: String, detail: String, retryAction: Selector?) {
        overlayContainer.subviews.forEach { $0.removeFromSuperview() }
        overlayContainer.isHidden = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        var arrangedViews: [NSView] = [titleLabel, detailLabel]
        if let retryAction {
            let retryButton = NSButton(title: "Retry", target: self, action: retryAction)
            retryButton.bezelStyle = .rounded
            arrangedViews.append(retryButton)
        } else {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            arrangedViews.append(progress)
        }

        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlayContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlayContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlayContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: overlayContainer.widthAnchor, multiplier: 0.82)
        ])
    }

    private func hideOverlay() {
        overlayContainer.isHidden = true
        overlayContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func updateWindowTitleForActivePane(title: String? = nil) {
        guard Self.activePane === self else { return }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanTitle.isEmpty {
            window?.title = "\(WorkspaceDisplayTitle.title) — \(cleanTitle)"
        } else {
            window?.title = "\(WorkspaceDisplayTitle.title) — VS Code"
        }
    }

    private enum VSCodePaneError: LocalizedError {
        case cefUnavailable(String)
        case cefCreateFailed(String)

        var errorDescription: String? {
            switch self {
            case .cefUnavailable(let detail): "CEF is unavailable: \(detail)"
            case .cefCreateFailed(let detail): "CEF browser creation failed: \(detail)"
            }
        }
    }
}

@MainActor
final class ConfiguredPaneRegistry {
    private let definitionsByID: [String: PaneDefinition]
    private let configSource: WorkspaceConfigSource
    private var codeServerManagersByPaneID: [String: CodeServerManager] = [:]
    private var viewsByPaneID: [String: NSView] = [:]

    init(config: WorkspaceConfig, configSource: WorkspaceConfigSource) {
        self.definitionsByID = Dictionary(uniqueKeysWithValues: config.panes.map { ($0.id, $0) })
        self.configSource = configSource
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

    private func makeView(for definition: PaneDefinition) -> NSView {
        let contentView: NSView
        switch definition.kind {
        case .terminal:
            contentView = GhosttyHostView(startupCommand: definition.startupCommand)
        case .browser:
            guard let url = definition.url else {
                preconditionFailure("Validated browser pane \(definition.id) is missing its URL")
            }
            let profile = BrowserProfileConfig(
                name: "default",
                storageDirectory: nil,
                persistent: false
            )
            contentView = BrowserPaneView(profile: profile, stateIdentifier: definition.id, initialURL: url)
        case .vscode:
            contentView = VSCodePaneView(
                paneID: definition.id,
                configSource: configSource,
                codeServerManager: codeServerManager(forPaneID: definition.id),
                profileMode: definition.profile == "local" ? .local : .native
            )
        }

        guard !definition.border.isZero || !definition.padding.isZero else { return contentView }
        if let terminalView = contentView as? GhosttyHostView {
            terminalView.drawsActiveAppearance = false
        } else if let browserView = contentView as? BrowserPaneView {
            browserView.drawsActiveAppearance = false
        } else if let vscodeView = contentView as? VSCodePaneView {
            vscodeView.drawsActiveAppearance = false
        }
        return PaneBoxView(contentView: contentView, border: definition.border, padding: definition.padding)
    }

    private func codeServerManager(forPaneID paneID: String) -> CodeServerManager {
        if let existingManager = codeServerManagersByPaneID[paneID] { return existingManager }
        let manager = CodeServerManager()
        codeServerManagersByPaneID[paneID] = manager
        return manager
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

    var canSwitchLayouts: Bool { config.validatedLayouts.count > 1 }
    var layoutIDs: [String] { config.validatedLayouts.map(\.id) }
    var currentLayoutID: String { activeLayoutID }
    var layoutFlashEnabled: Bool { config.layoutFlashEnabled }
    var layoutFlashDuration: TimeInterval { config.layoutFlashDuration }

    func applyLayout(id layoutID: String) {
        guard config.validatedLayouts.contains(where: { $0.id == layoutID }) else {
            preconditionFailure("Layout references unknown configured layout ID \(layoutID)")
        }
        activeLayoutID = layoutID
        applyActiveLayout()
    }

    @discardableResult
    func switchLayout(offset: Int) -> String? {
        guard canSwitchLayouts,
              let currentIndex = layoutIDs.firstIndex(of: activeLayoutID)
        else { return nil }
        let nextIndex = (currentIndex + offset + layoutIDs.count) % layoutIDs.count
        let layoutID = layoutIDs[nextIndex]
        applyLayout(id: layoutID)
        return layoutID
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

    func focusInitialPane() {
        guard let layout = config.validatedLayouts.first(where: { $0.id == activeLayoutID }),
              let firstVisiblePaneID = layout.slots.first?.paneID
        else { return }
        focus(paneRegistry.view(for: firstVisiblePaneID))
    }

    func layoutSwitcherAnchorFrameInScreen() -> NSRect {
        if let activePane = activeVisiblePane,
           let window = activePane.window {
            return window.convertToScreen(activePane.convert(activePane.bounds, to: nil))
        }
        return window?.frame ?? NSScreen.main?.frame ?? bounds
    }

    private var activeVisiblePane: NSView? {
        if let browserPane = BrowserPaneView.activePane,
           !browserPane.isHidden,
           browserPane.window != nil {
            return browserPane
        }
        if let terminalPane = GhosttyHostView.activePane,
           !terminalPane.isHidden,
           terminalPane.window != nil {
            return terminalPane
        }
        if let vscodePane = VSCodePaneView.activePane,
           !vscodePane.isHidden,
           vscodePane.window != nil {
            return vscodePane
        }
        return nil
    }

    private func focus(_ pane: NSView) {
        if let browserPane = pane as? BrowserPaneView {
            window?.makeFirstResponder(browserPane)
        } else if let terminalPane = pane as? GhosttyHostView {
            window?.makeFirstResponder(terminalPane)
        } else if let vscodePane = pane as? VSCodePaneView {
            vscodePane.focusBrowserContent()
        } else if let focusable = pane.subviews.first(where: { $0.acceptsFirstResponder }) {
            window?.makeFirstResponder(focusable)
        } else {
            window?.makeFirstResponder(pane)
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

        let assignments = MosaicLayoutFrames.frames(for: layout, in: bounds)
        let visiblePaneIDs = Set(assignments.map(\.paneID))

        for paneID in config.panes.map(\.id) where !visiblePaneIDs.contains(paneID) {
            let paneView = paneRegistry.view(for: paneID)
            if !paneView.isHidden {
                paneView.isHidden = true
            }
        }

        let framesByPaneID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.paneID, $0.frame) })
        applyCollapsedBorders(for: framesByPaneID)

        for assignment in assignments {
            let paneView = paneRegistry.view(for: assignment.paneID)
            if paneView.superview !== self {
                addSubview(paneView)
            }
            if !Self.framesMatch(paneView.frame, assignment.frame) {
                paneView.frame = assignment.frame
            }
            if paneView.isHidden {
                paneView.isHidden = false
            }
        }
    }

    private func applyCollapsedBorders(for framesByPaneID: [String: NSRect]) {
        for (paneID, frame) in framesByPaneID {
            guard let paneBox = paneRegistry.view(for: paneID) as? PaneBoxView else { continue }
            let border = paneBox.configuredBorder
            let displayBorder = PaneBoxEdges(
                top: collapsedBorderWidth(
                    paneID: paneID,
                    frame: frame,
                    edge: .top,
                    ownWidth: border.top,
                    framesByPaneID: framesByPaneID
                ),
                right: collapsedBorderWidth(
                    paneID: paneID,
                    frame: frame,
                    edge: .right,
                    ownWidth: border.right,
                    framesByPaneID: framesByPaneID
                ),
                bottom: collapsedBorderWidth(
                    paneID: paneID,
                    frame: frame,
                    edge: .bottom,
                    ownWidth: border.bottom,
                    framesByPaneID: framesByPaneID
                ),
                left: collapsedBorderWidth(
                    paneID: paneID,
                    frame: frame,
                    edge: .left,
                    ownWidth: border.left,
                    framesByPaneID: framesByPaneID
                )
            )
            paneBox.setDisplayBorder(displayBorder)
        }
    }

    private enum PaneEdge { case top, right, bottom, left }

    private func collapsedBorderWidth(
        paneID: String,
        frame: NSRect,
        edge: PaneEdge,
        ownWidth: Double,
        framesByPaneID: [String: NSRect]
    ) -> Double {
        var adjacentWidth: Double?
        for (otherPaneID, otherFrame) in framesByPaneID where otherPaneID != paneID {
            guard areAdjacent(frame, otherFrame, edge: edge) else { continue }
            let otherBorder = (paneRegistry.view(for: otherPaneID) as? PaneBoxView)?.configuredBorder ?? .zero
            let otherWidth: Double
            switch edge {
            case .top: otherWidth = otherBorder.bottom
            case .right: otherWidth = otherBorder.left
            case .bottom: otherWidth = otherBorder.top
            case .left: otherWidth = otherBorder.right
            }
            adjacentWidth = max(adjacentWidth ?? 0, otherWidth)
        }
        guard let adjacentWidth else { return ownWidth }
        return max(ownWidth, adjacentWidth) / 2
    }

    private static let paneFrameTolerance = 0.5

    private func areAdjacent(_ frame: NSRect, _ otherFrame: NSRect, edge: PaneEdge) -> Bool {
        switch edge {
        case .top:
            return abs(frame.maxY - otherFrame.minY) < Self.paneFrameTolerance
                && rangesOverlap(frame.minX...frame.maxX, otherFrame.minX...otherFrame.maxX)
        case .right:
            return abs(frame.maxX - otherFrame.minX) < Self.paneFrameTolerance
                && rangesOverlap(frame.minY...frame.maxY, otherFrame.minY...otherFrame.maxY)
        case .bottom:
            return abs(frame.minY - otherFrame.maxY) < Self.paneFrameTolerance
                && rangesOverlap(frame.minX...frame.maxX, otherFrame.minX...otherFrame.maxX)
        case .left:
            return abs(frame.minX - otherFrame.maxX) < Self.paneFrameTolerance
                && rangesOverlap(frame.minY...frame.maxY, otherFrame.minY...otherFrame.maxY)
        }
    }

    private func rangesOverlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> Bool {
        min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound) > Self.paneFrameTolerance
    }

    private static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
    }
}

@MainActor
enum WorkspaceDisplayTitle {
    private static let fallback = "GSDE"
    private static var configuredTitle: String?

    static var title: String {
        configuredTitle ?? fallback
    }

    static func configure(_ title: String?) {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredTitle = cleanTitle?.isEmpty == false ? cleanTitle : nil
        NSApp.dockTile.badgeLabel = configuredTitle
    }
}

enum WorkspaceStateScope {
    private static let prefix = ProcessInfo.processInfo.environment["GSDE_STATE_SCOPE"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    static func key(_ value: String) -> String {
        guard let prefix, !prefix.isEmpty else { return value }
        return "\(prefix).\(value)"
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
        NSSplitView.AutosaveName(WorkspaceStateScope.key("GSDE.WorkspaceSplit.\(arrangedSubviews.count)"))
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
            let savedURL = UserDefaults.standard.string(forKey: WorkspaceStateScope.key("GSDE.BrowserPane.\(stateIdentifier).url"))
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
        let registry = ConfiguredPaneRegistry(config: config, configSource: .builtIn)
        let configuredPanes = registry.views(for: startupLayout)
        return configuredPanes.isEmpty ? [GhosttyHostView()] : configuredPanes
    }

    private static func makeSavedPanes() -> [NSView]? {
        guard let data = UserDefaults.standard.data(forKey: WorkspaceStateScope.key(paneLayoutDefaultsKey)),
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
                let savedURL = UserDefaults.standard.string(forKey: WorkspaceStateScope.key("GSDE.BrowserPane.\(stateIdentifier).url"))
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
            UserDefaults.standard.removeObject(forKey: WorkspaceStateScope.key("GSDE.BrowserPane.\(identifier).url"))
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

    func focusInitialPane() {
        if let activePane = activeArrangedPane,
           let activeIndex = arrangedSubviews.firstIndex(of: activePane) {
            focusPane(at: activeIndex)
        } else {
            focusPane(at: 0)
        }
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
        VSCodePaneView.activePane = nil
        persistPaneLayout()
        distributePanesEvenly()
    }

    func closeOtherPanes() {
        guard canCloseOtherPanes, let activePane = activeArrangedPane else { return }
        for pane in arrangedSubviews where pane !== activePane {
            removePane(pane)
        }
        persistPaneLayout()
        distributePanesEvenly()
        if let browserPane = activePane as? BrowserPaneView {
            window?.makeFirstResponder(browserPane)
        } else if let terminalPane = activePane as? GhosttyHostView {
            window?.makeFirstResponder(terminalPane)
        } else if let vscodePane = activePane as? VSCodePaneView {
            vscodePane.focusBrowserContent()
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
        UserDefaults.standard.set(data, forKey: WorkspaceStateScope.key(Self.paneLayoutDefaultsKey))
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
        } else if let vscodePane = pane as? VSCodePaneView {
            vscodePane.focusBrowserContent()
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
        if let vscodePane = VSCodePaneView.activePane,
           arrangedSubviews.contains(where: { vscodePane.isDescendant(of: $0) }) {
            return arrangedSubviews.first { vscodePane.isDescendant(of: $0) }
        }
        guard let responder = window?.firstResponder as? NSView else { return arrangedSubviews.last }
        return arrangedSubviews.first { responder === $0 || responder.isDescendant(of: $0) } ?? arrangedSubviews.last
    }

    private func nextDynamicBrowserIdentifier() -> String {
        let key = WorkspaceStateScope.key("GSDE.BrowserPane.nextDynamicIndex")
        let index = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(index + 1, forKey: key)
        return "browser.dynamic.\(index)"
    }

    private var hasSavedDividerPositions: Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(splitAutosaveName)") != nil
    }
}

final class ShutdownStatusView: NSView {
    private let message = "GSDE is shutting down…"
    private let detail = "Closing VS Code, browser, and terminal panes"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let unionFrame = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let center = NSPoint(
                x: screen.frame.midX - unionFrame.minX,
                y: screen.frame.midY - unionFrame.minY
            )
            drawStatus(centeredAt: center)
        }
    }

    private func drawStatus(centeredAt center: NSPoint) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: NSColor(white: 0.92, alpha: 1)
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(white: 0.62, alpha: 1)
        ]
        let title = NSAttributedString(string: message, attributes: titleAttributes)
        let subtitle = NSAttributedString(string: detail, attributes: detailAttributes)
        let titleSize = title.size()
        let subtitleSize = subtitle.size()
        title.draw(at: NSPoint(x: center.x - titleSize.width / 2, y: center.y + 6))
        subtitle.draw(at: NSPoint(x: center.x - subtitleSize.width / 2, y: center.y - subtitleSize.height - 8))
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
    private var layoutSwitcherKeyMonitor: Any?
    private var layoutSwitcherPanel: LayoutSwitcherPanel?
    private var layoutFlashPanels: [LayoutFlashPanel] = []
    private weak var responderBeforeLayoutSwitcher: NSResponder?
    private var didPrepareChromiumShutdown = false
    private var frameAutosaveName: String { WorkspaceStateScope.key("GSDE.MainWindow") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        installMainMenu()
        installLayoutSwitcherShortcutMonitor()

        let loadedConfig = WorkspaceConfigLoader().load()
        WorkspaceDisplayTitle.configure(loadedConfig.config.title)
        initializeChromiumIfAvailable(rootCachePath: Self.chromiumRootDirectory(for: loadedConfig.source))

        let frame = Self.frameCoveringAllDisplays()
        let contentView = Self.makeWorkspaceView(frame: NSRect(origin: .zero, size: frame.size), loadedConfig: loadedConfig)

        let window = BorderlessMainWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = WorkspaceDisplayTitle.title
        window.hasShadow = false
        window.level = .normal
        window.contentView = contentView
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in
            Self.focusInitialPane(in: window?.contentView)
        }
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
        if let window {
            let shutdownView = ShutdownStatusView(frame: NSRect(origin: .zero, size: window.frame.size))
            window.contentView = shutdownView
            window.displayIfNeeded()
        }
        gsde_chromium_close_all_browsers()
        chromiumMessageLoopTimer?.invalidate()
        chromiumMessageLoopTimer = nil
        for _ in 0..<500 {
            gsde_chromium_do_message_loop_work()
            if gsde_chromium_live_browser_count() == 0 { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        for _ in 0..<100 {
            gsde_chromium_do_message_loop_work()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func focusInitialPane(in contentView: NSView?) {
        if let workspace = contentView as? ThreePaneWorkspaceView {
            workspace.focusInitialPane()
        } else if let workspace = contentView as? MosaicWorkspaceView {
            workspace.focusInitialPane()
        } else if let focusable = contentView?.subviews.first(where: { $0.acceptsFirstResponder }) {
            contentView?.window?.makeFirstResponder(focusable)
        }
    }

    private func installLayoutSwitcherShortcutMonitor() {
        guard layoutSwitcherKeyMonitor == nil else { return }
        layoutSwitcherKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isLayoutSwitcherShortcut(event) {
                self.showLayoutSwitcher(nil)
                return nil
            }
            if self.isLayoutStepShortcut(event, keyCode: 123) {
                self.switchToPreviousLayout(nil)
                return nil
            }
            if self.isLayoutStepShortcut(event, keyCode: 124) {
                self.switchToNextLayout(nil)
                return nil
            }
            return event
        }
    }

    private func isLayoutSwitcherShortcut(_ event: NSEvent) -> Bool {
        isLayoutShortcut(event, keyCode: 37)
    }

    private func isLayoutStepShortcut(_ event: NSEvent, keyCode: UInt16) -> Bool {
        isLayoutShortcut(event, keyCode: keyCode)
    }

    private func isLayoutShortcut(_ event: NSEvent, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.command, .option, .control, .shift] && event.keyCode == keyCode
    }



    private func initializeChromiumIfAvailable(rootCachePath: URL) {
        guard gsde_chromium_cef_available() != 0 else { return }

        try? FileManager.default.createDirectory(at: rootCachePath, withIntermediateDirectories: true)
        let rootCache = CEFPath.canonicalPath(for: rootCachePath)
        // Leave CefSettings.cache_path empty so every persistent browser must provide an explicit
        // CefRequestContext cache path. This prevents accidentally sharing the global profile.
        let initialized = rootCache.withCString { rootCache in
            "".withCString { profileCache in
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
        makeWorkspaceView(frame: frame, loadedConfig: WorkspaceConfigLoader().load())
    }

    private static func makeWorkspaceView(frame: NSRect, loadedConfig: WorkspaceConfigLoadResult) -> NSView {
        let hasLegacyPaneEnvironment = ProcessInfo.processInfo.environment["GSDE_BROWSER_PANES"] != nil
            || ProcessInfo.processInfo.environment["GSDE_BROWSER_URLS"] != nil
        guard !hasLegacyPaneEnvironment else {
            logConfig("GSDE_BROWSER_PANES/GSDE_BROWSER_URLS set; skipping TOML workspace config and using ThreePane workspace")
            return ThreePaneWorkspaceView(frame: frame)
        }

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
        let registry = ConfiguredPaneRegistry(config: loadedConfig.config, configSource: loadedConfig.source)
        return MosaicWorkspaceView(
            frame: frame,
            config: loadedConfig.config,
            paneRegistry: registry,
            activeLayoutID: startupLayout.id
        )
    }

    private static func chromiumRootDirectory(for source: WorkspaceConfigSource) -> URL {
        // CEF 120+ requires every persistent CefRequestContext cache path to sit under
        // CefSettings.root_cache_path. Keep the root at the shared chromium directory so
        // VS Code pane caches and any other Chromium profiles can coexist below it.
        if let projectDirectory = nonEmptyEnvironmentDirectory(named: "GSDE_PROJECT_DIR") {
            return projectDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("gsde", isDirectory: true)
                .appendingPathComponent("chromium", isDirectory: true)
                .standardizedFileURL
        }

        if let configURL = source.url {
            return configURL
                .deletingLastPathComponent()
                .appendingPathComponent("chromium", isDirectory: true)
                .standardizedFileURL
        }

        guard let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("GSDE", isDirectory: true)
                .appendingPathComponent("Chromium", isDirectory: true)
                .standardizedFileURL
        }
        return appSupportDirectory
            .appendingPathComponent("GSDE", isDirectory: true)
            .appendingPathComponent("Chromium", isDirectory: true)
            .standardizedFileURL
    }

    private static func nonEmptyEnvironmentDirectory(named name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
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
        addMenuItem("Switch Layout…", #selector(showLayoutSwitcher(_:)), "l", modifiers: [.command, .option, .control, .shift], to: workspaceMenu)
        addMenuItem("Previous Layout", #selector(switchToPreviousLayout(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: [.command, .option, .control, .shift], to: workspaceMenu)
        addMenuItem("Next Layout", #selector(switchToNextLayout(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .option, .control, .shift], to: workspaceMenu)
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

    @objc private func switchToPreviousLayout(_ sender: Any?) {
        guard let workspace = window?.contentView as? MosaicWorkspaceView,
              workspace.canSwitchLayouts
        else {
            NSSound.beep()
            return
        }
        if let layoutID = workspace.switchLayout(offset: -1) {
            showLayoutFlash(layoutID: layoutID, workspace: workspace)
        }
    }

    @objc private func switchToNextLayout(_ sender: Any?) {
        guard let workspace = window?.contentView as? MosaicWorkspaceView,
              workspace.canSwitchLayouts
        else {
            NSSound.beep()
            return
        }
        if let layoutID = workspace.switchLayout(offset: 1) {
            showLayoutFlash(layoutID: layoutID, workspace: workspace)
        }
    }

    private func showLayoutFlash(layoutID: String, workspace: MosaicWorkspaceView) {
        guard workspace.layoutFlashEnabled, workspace.layoutFlashDuration > 0 else { return }
        layoutFlashPanels.forEach { $0.close() }
        layoutFlashPanels = NSScreen.screens.map { screen in
            let panel = LayoutFlashPanel(layoutID: layoutID, screen: screen)
            panel.orderFront(nil)
            return panel
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            layoutFlashPanels.forEach { $0.animator().alphaValue = 1 }
        }

        let displayDuration = workspace.layoutFlashDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) { [weak self] in
            guard let self else { return }
            let panels = self.layoutFlashPanels
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panels.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: {
                DispatchQueue.main.async { [weak self] in
                    panels.forEach { $0.close() }
                    self?.layoutFlashPanels.removeAll { panel in panels.contains(where: { $0 === panel }) }
                }
            }
        }
    }

    @objc private func showLayoutSwitcher(_ sender: Any?) {
        if layoutSwitcherPanel != nil {
            dismissLayoutSwitcher(restoreFocus: true)
            return
        }

        guard let workspace = window?.contentView as? MosaicWorkspaceView,
              workspace.canSwitchLayouts
        else {
            NSSound.beep()
            return
        }

        responderBeforeLayoutSwitcher = window?.firstResponder

        let panel = LayoutSwitcherPanel(
            layoutIDs: workspace.layoutIDs,
            activeLayoutID: workspace.currentLayoutID,
            anchorFrameInScreen: workspace.layoutSwitcherAnchorFrameInScreen(),
            onSelect: { [weak self, weak workspace] layoutID in
                workspace?.applyLayout(id: layoutID)
                self?.dismissLayoutSwitcher(restoreFocus: true)
            },
            onCancel: { [weak self] in
                self?.dismissLayoutSwitcher(restoreFocus: true)
            }
        )
        layoutSwitcherPanel = panel
        window?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismissLayoutSwitcher(restoreFocus: Bool) {
        guard let panel = layoutSwitcherPanel else { return }
        window?.removeChildWindow(panel)
        panel.close()
        layoutSwitcherPanel = nil

        guard restoreFocus, let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let responder = responderBeforeLayoutSwitcher,
           window.makeFirstResponder(responder) {
            return
        }
        if let workspace = window.contentView as? MosaicWorkspaceView {
            workspace.focusInitialPane()
        }
    }

    @objc private func resetWindowAndPaneLayout(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(frameAutosaveName)")
        for paneCount in 3...6 {
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(WorkspaceStateScope.key("GSDE.WorkspaceSplit.\(paneCount)"))")
        }
        for browserIndex in 0..<4 {
            UserDefaults.standard.removeObject(forKey: WorkspaceStateScope.key("GSDE.BrowserPane.browser.\(browserIndex).url"))
        }
        UserDefaults.standard.removeObject(forKey: WorkspaceStateScope.key("GSDE.WorkspacePaneLayout"))
        UserDefaults.standard.removeObject(forKey: WorkspaceStateScope.key("GSDE.BrowserPane.nextDynamicIndex"))
        let frame = Self.frameCoveringAllDisplays()
        window?.setFrame(frame, display: true, animate: true)
        (window?.contentView as? ThreePaneWorkspaceView)?.resetDividerPositions()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if activeVSCodePane != nil,
           Self.shouldDisableMenuActionForVSCodePassthrough(menuItem.action) {
            return false
        }

        switch menuItem.action {
        case #selector(showLayoutSwitcher(_:)),
             #selector(switchToPreviousLayout(_:)),
             #selector(switchToNextLayout(_:)):
            return (window?.contentView as? MosaicWorkspaceView)?.canSwitchLayouts ?? false
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

    static func verifyVSCodeShortcutPassthroughPolicyForCommandLine() {
        let appOwnedSelectors: [Selector] = [
            #selector(browserOpenFind(_:)),
            #selector(browserFocusLocation(_:)),
            #selector(browserPrint(_:)),
            #selector(closeActivePane(_:)),
            #selector(newBrowserPane(_:)),
            #selector(terminalCopy(_:))
        ]
        let globalSelectors: [Selector] = [
            #selector(showLayoutSwitcher(_:)),
            #selector(switchToPreviousLayout(_:)),
            #selector(switchToNextLayout(_:)),
            #selector(NSApplication.terminate(_:))
        ]
        precondition(appOwnedSelectors.allSatisfy(shouldDisableMenuActionForVSCodePassthrough(_:)))
        precondition(globalSelectors.allSatisfy { !shouldDisableMenuActionForVSCodePassthrough($0) })
    }

    private static func shouldDisableMenuActionForVSCodePassthrough(_ action: Selector?) -> Bool {
        switch action {
        case #selector(newBrowserPane(_:)),
             #selector(newTerminalPane(_:)),
             #selector(duplicateActiveBrowserPane(_:)),
             #selector(closeActivePane(_:)),
             #selector(closeOtherPanes(_:)),
             #selector(focusNextPane(_:)),
             #selector(focusPreviousPane(_:)),
             #selector(moveActivePaneLeft(_:)),
             #selector(moveActivePaneRight(_:)),
             #selector(terminalCopy(_:)),
             #selector(terminalPaste(_:)),
             #selector(browserFocusLocation(_:)),
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
            return true
        default:
            return false
        }
    }

    private var activeBrowserPane: BrowserPaneView? {
        BrowserPaneView.activePane
    }

    private var activeTerminalPane: GhosttyHostView? {
        GhosttyHostView.activePane
    }

    private var activeVSCodePane: VSCodePaneView? {
        VSCodePaneView.activePane
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

if ProcessInfo.processInfo.environment["GSDE_VALIDATE_CONFIG"] != nil {
    let result = WorkspaceConfigLoader().load()
    for diagnostic in result.diagnostics {
        FileHandle.standardError.write(Data("\(diagnostic)\n".utf8))
    }
    if result.diagnostics.contains(where: { $0.severity == .error }) {
        exit(1)
    }

    let sourceDescription = result.source.url?.path ?? "built-in default"
    print("GSDE config valid: \(sourceDescription)")
    print("panes: \(result.config.panes.count)")
    print("layouts: \(result.config.validatedLayouts.map(\.id).joined(separator: ", "))")
    print("startup_layout: \(result.config.startupLayout)")
    exit(0)
} else if ProcessInfo.processInfo.environment["GSDE_VERIFY_VSCODE_SHORTCUT_POLICY"] != nil {
    AppDelegate.verifyVSCodeShortcutPassthroughPolicyForCommandLine()
    print("VS Code shortcut passthrough policy valid")
    exit(0)
} else if ProcessInfo.processInfo.environment["GSDE_VERIFY_WORKSPACE_STARTUP"] != nil {
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
    let paneRegistry = ConfiguredPaneRegistry(config: loadedConfig.config, configSource: loadedConfig.source)
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
