import AppKit
import ChromiumStub
import GhosttyShim

final class GhosttyHostView: NSView {
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
        gsde_ghostty_host_focus(host, true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        gsde_ghostty_host_focus(host, false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
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

final class ThreePaneWorkspaceView: NSView {
    private let panes: [NSView] = [
        GhosttyHostView(),
        BrowserPaneView(initialURL: URL(string: "https://www.google.com")!),
        GhosttyHostView()
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        panes.forEach { pane in
            pane.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pane)
        }

        NSLayoutConstraint.activate([
            panes[0].leadingAnchor.constraint(equalTo: leadingAnchor),
            panes[0].topAnchor.constraint(equalTo: topAnchor),
            panes[0].bottomAnchor.constraint(equalTo: bottomAnchor),

            panes[1].leadingAnchor.constraint(equalTo: panes[0].trailingAnchor),
            panes[1].topAnchor.constraint(equalTo: topAnchor),
            panes[1].bottomAnchor.constraint(equalTo: bottomAnchor),
            panes[1].widthAnchor.constraint(equalTo: panes[0].widthAnchor),

            panes[2].leadingAnchor.constraint(equalTo: panes[1].trailingAnchor),
            panes[2].trailingAnchor.constraint(equalTo: trailingAnchor),
            panes[2].topAnchor.constraint(equalTo: topAnchor),
            panes[2].bottomAnchor.constraint(equalTo: bottomAnchor),
            panes[2].widthAnchor.constraint(equalTo: panes[0].widthAnchor)
        ])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var chromiumMessageLoopTimer: Timer?

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
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        chromiumMessageLoopTimer?.invalidate()
        chromiumMessageLoopTimer = nil
        gsde_chromium_shutdown()
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

        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/GSDE Chromium Helper.app/Contents/MacOS/GSDE Chromium Helper")
            .path

        let initialized = rootCachePath.path.withCString { rootCache in
            rootCachePath.path.withCString { profileCache in
                helperPath.withCString { helper in
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
            withTitle: "Quit GSDE",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
