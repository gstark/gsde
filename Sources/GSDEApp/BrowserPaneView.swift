import AppKit
import ChromiumStub
import WebKit

struct BrowserProfileConfig {
    let name: String
    let storageDirectory: URL?
    let persistent: Bool

    static let `default` = BrowserProfileConfig(
        name: "default",
        storageDirectory: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("GSDE/Chromium/Profiles/default", isDirectory: true),
        persistent: true
    )
}

final class BrowserPaneView: NSView, WKNavigationDelegate {
    private let profile: BrowserProfileConfig
    private let toolbar = NSStackView()
    private let backButton = NSButton(title: "‹", target: nil, action: nil)
    private let forwardButton = NSButton(title: "›", target: nil, action: nil)
    private let reloadButton = NSButton(title: "↻", target: nil, action: nil)
    private let stopButton = NSButton(title: "×", target: nil, action: nil)
    private let devToolsButton = NSButton(title: "DevTools", target: nil, action: nil)
    private let backendStatusLabel = NSTextField(labelWithString: "")
    private let urlField = NSTextField(string: "")
    private let findField = NSTextField(string: "")
    private let findPreviousButton = NSButton(title: "↑", target: nil, action: nil)
    private let findNextButton = NSButton(title: "↓", target: nil, action: nil)
    private let findCloseButton = NSButton(title: "×", target: nil, action: nil)
    private let browserContainer = NSView()
    private let webView: WKWebView
    private var cefBrowser: OpaquePointer?
    private weak var cefNativeView: NSView?
    private var cefStatusTimer: Timer?
    private var keyCommandMonitor: Any?
    private var webKitPageZoom: CGFloat = 1.0
    private var hasStartedWebKitFallbackLoad = false
    private var pendingInitialURL: URL

    init(
        frame frameRect: NSRect = .zero,
        profile: BrowserProfileConfig = .default,
        initialURL: URL = URL(string: "https://www.google.com")!
    ) {
        self.profile = profile
        self.pendingInitialURL = initialURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.persistent ? .default() : .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)

        commonInit()
        if Self.cefRequested {
            urlField.stringValue = initialURL.absoluteString
        } else {
            load(initialURL)
        }
    }

    required init?(coder: NSCoder) {
        self.profile = .default
        self.pendingInitialURL = URL(string: "https://www.google.com")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(coder: coder)
        commonInit()
    }

    override var acceptsFirstResponder: Bool { true }

    private static var cefRequested: Bool {
        ProcessInfo.processInfo.environment["GSDE_ENABLE_CEF"] == "1"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cefStatusTimer?.invalidate()
            cefStatusTimer = nil
            if let keyCommandMonitor {
                NSEvent.removeMonitor(keyCommandMonitor)
                self.keyCommandMonitor = nil
            }
            if let cefBrowser {
                gsde_chromium_browser_destroy(cefBrowser)
                self.cefBrowser = nil
            }
            return
        }

        installKeyCommandMonitorIfNeeded()
        createCEFBrowserIfPossible()
        if window?.firstResponder == nil {
            window?.makeFirstResponder(cefBrowser == nil ? webView : browserContainer)
        }
    }

    override func layout() {
        super.layout()
        resizeCEFBrowser()
    }

    override func becomeFirstResponder() -> Bool {
        if let cefBrowser {
            gsde_chromium_browser_focus(cefBrowser, 1)
            return true
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let cefBrowser {
            gsde_chromium_browser_focus(cefBrowser, 0)
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let cefBrowser {
            gsde_chromium_browser_focus(cefBrowser, 1)
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleBrowserKeyCommand(event) { return }
        super.keyDown(with: event)
    }

    private func installKeyCommandMonitorIfNeeded() {
        guard keyCommandMonitor == nil else { return }
        keyCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.window === event.window,
                  self.isFirstResponderInsidePane,
                  self.handleBrowserKeyCommand(event)
            else { return event }
            return nil
        }
    }

    private var isFirstResponderInsidePane: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self || responder === urlField { return true }
        guard let responderView = responder as? NSView else { return false }
        if responderView.isDescendant(of: self) { return true }
        if let cefNativeView, responderView.isDescendant(of: cefNativeView) { return true }
        return false
    }

    private func handleBrowserKeyCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }

        switch (flags, characters) {
        case ([.command], "l"):
            focusURLField()
        case ([.command], "f"):
            openFind()
        case ([.command], "g"):
            findNext()
        case ([.command, .shift], "g"):
            findPrevious()
        case ([.command], "r"):
            performReload(ignoringCache: false)
        case ([.command, .shift], "r"):
            performReload(ignoringCache: true)
        case ([.command], "."):
            stopLoading()
        case ([.command], "["):
            goBack()
        case ([.command], "]"):
            goForward()
        case ([.command], "+"), ([.command], "="):
            zoomIn()
        case ([.command], "-"):
            zoomOut()
        case ([.command], "0"):
            zoomReset()
        case ([.command], "p"):
            printPage()
        case ([.command, .option], "i"):
            showDeveloperTools()
        case ([], "\u{1b}"):
            if !findField.isHidden {
                closeFind()
            } else {
                return false
            }
        default:
            return false
        }
        return true
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        configureToolbar()
        configureWebView()
        configureProfileStorageDirectory()

        addSubview(toolbar)
        addSubview(browserContainer)
        browserContainer.addSubview(webView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        browserContainer.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.heightAnchor.constraint(equalToConstant: 30),

            browserContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            browserContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            browserContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            browserContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            webView.leadingAnchor.constraint(equalTo: browserContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: browserContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: browserContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: browserContainer.bottomAnchor)
        ])
    }

    private func configureToolbar() {
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.distribution = .fill

        [backButton, forwardButton, reloadButton, stopButton, devToolsButton, findPreviousButton, findNextButton, findCloseButton].forEach { button in
            button.bezelStyle = .rounded
            button.controlSize = .small
        }

        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        stopButton.target = self
        stopButton.action = #selector(stopLoading)
        devToolsButton.target = self
        devToolsButton.action = #selector(showDeveloperTools)
        findPreviousButton.target = self
        findPreviousButton.action = #selector(findPrevious)
        findNextButton.target = self
        findNextButton.action = #selector(findNext)
        findCloseButton.target = self
        findCloseButton.action = #selector(closeFind)

        backendStatusLabel.stringValue = String(cString: gsde_chromium_backend_status())
        backendStatusLabel.textColor = .secondaryLabelColor
        backendStatusLabel.font = .systemFont(ofSize: 11)
        backendStatusLabel.lineBreakMode = .byTruncatingTail

        urlField.placeholderString = "Enter URL"
        urlField.target = self
        urlField.action = #selector(navigateFromURLField)
        urlField.lineBreakMode = .byTruncatingMiddle

        findField.placeholderString = "Find"
        findField.target = self
        findField.action = #selector(findNext)
        findField.isHidden = true
        findPreviousButton.isHidden = true
        findNextButton.isHidden = true
        findCloseButton.isHidden = true

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(reloadButton)
        toolbar.addArrangedSubview(stopButton)
        toolbar.addArrangedSubview(urlField)
        toolbar.addArrangedSubview(devToolsButton)
        toolbar.addArrangedSubview(findField)
        toolbar.addArrangedSubview(findPreviousButton)
        toolbar.addArrangedSubview(findNextButton)
        toolbar.addArrangedSubview(findCloseButton)
        toolbar.addArrangedSubview(backendStatusLabel)

        backendStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        backendStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        findField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        updateNavigationButtons()
    }

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        // Enables Safari/WebKit inspector for this view on supported macOS versions.
        // CEF will replace this with Chromium DevTools when we swap the backend.
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.setValue(true, forKey: "inspectable")
        }
    }

    private func configureProfileStorageDirectory() {
        guard profile.persistent, let storageDirectory = profile.storageDirectory else { return }
        try? FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }

    func load(_ url: URL) {
        pendingInitialURL = url
        urlField.stringValue = url.absoluteString
        if let cefBrowser {
            url.absoluteString.withCString { gsde_chromium_browser_load_url(cefBrowser, $0) }
        } else {
            hasStartedWebKitFallbackLoad = true
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func navigateFromURLField() {
        guard let url = normalizedURL(from: urlField.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(self)
    }

    @objc private func focusURLField() {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    @objc private func openFind() {
        setFindVisible(true)
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    @objc private func closeFind() {
        setFindVisible(false)
        if let cefBrowser {
            gsde_chromium_browser_stop_finding(cefBrowser, 1)
        } else {
            webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        }
        window?.makeFirstResponder(self)
    }

    @objc private func findNext() {
        performFind(forward: true, findNext: true)
    }

    @objc private func findPrevious() {
        performFind(forward: false, findNext: true)
    }

    private func setFindVisible(_ visible: Bool) {
        [findField, findPreviousButton, findNextButton, findCloseButton].forEach { $0.isHidden = !visible }
    }

    private func performFind(forward: Bool, findNext: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else { return }
        if let cefBrowser {
            query.withCString { gsde_chromium_browser_find(cefBrowser, $0, forward ? 1 : 0, 0, findNext ? 1 : 0) }
        } else {
            findInWebView(query: query, forward: forward)
        }
    }

    private func zoomIn() {
        if let cefBrowser {
            gsde_chromium_browser_zoom_in(cefBrowser)
        } else {
            setWebKitPageZoom(webKitPageZoom + 0.1)
        }
    }

    private func zoomOut() {
        if let cefBrowser {
            gsde_chromium_browser_zoom_out(cefBrowser)
        } else {
            setWebKitPageZoom(webKitPageZoom - 0.1)
        }
    }

    private func zoomReset() {
        if let cefBrowser {
            gsde_chromium_browser_zoom_reset(cefBrowser)
        } else {
            setWebKitPageZoom(1.0)
        }
    }

    private func printPage() {
        if let cefBrowser {
            gsde_chromium_browser_print(cefBrowser)
        } else {
            webView.printView(nil)
        }
    }

    private func setWebKitPageZoom(_ zoom: CGFloat) {
        webKitPageZoom = min(max(zoom, 0.5), 3.0)
        webView.pageZoom = webKitPageZoom
    }

    private func findInWebView(query: String, forward: Bool) {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = "window.find('\(escaped)', false, \(!forward), true, false, false, false)"
        webView.evaluateJavaScript(script)
    }

    @objc private func goBack() {
        if let cefBrowser {
            gsde_chromium_browser_go_back(cefBrowser)
            updateNavigationButtons()
        } else if webView.canGoBack {
            webView.goBack()
        }
    }

    @objc private func goForward() {
        if let cefBrowser {
            gsde_chromium_browser_go_forward(cefBrowser)
            updateNavigationButtons()
        } else if webView.canGoForward {
            webView.goForward()
        }
    }

    @objc private func reload() {
        performReload(ignoringCache: false)
    }

    @objc private func stopLoading() {
        if let cefBrowser {
            gsde_chromium_browser_stop(cefBrowser)
        } else {
            webView.stopLoading()
        }
        updateNavigationButtons()
    }

    private func performReload(ignoringCache: Bool) {
        if let cefBrowser {
            if ignoringCache {
                gsde_chromium_browser_reload_ignore_cache(cefBrowser)
            } else {
                gsde_chromium_browser_reload(cefBrowser)
            }
            updateNavigationButtons()
        } else if ignoringCache {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    @objc private func showDeveloperTools() {
        if let cefBrowser {
            gsde_chromium_browser_show_devtools(cefBrowser)
        } else if webView.responds(to: Selector(("_showInspector"))) {
            webView.perform(Selector(("_showInspector")))
        } else {
            NSSound.beep()
        }
    }

    private func createCEFBrowserIfPossible() {
        guard cefBrowser == nil else { return }
        guard gsde_chromium_cef_available() != 0 else {
            startWebKitFallbackLoadIfNeeded()
            return
        }
        browserContainer.layoutSubtreeIfNeeded()
        let width = Int32(max(1, browserContainer.bounds.width))
        let height = Int32(max(1, browserContainer.bounds.height))
        let browser = "about:blank".withCString { initialURLPointer in
            "".withCString { cachePathPointer in
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
            backendStatusLabel.stringValue = String(cString: gsde_chromium_last_error())
            startWebKitFallbackLoadIfNeeded()
            return
        }
        cefBrowser = browser
        attachCEFBrowserViewIfAvailable(browser)
        webView.isHidden = true
        backendStatusLabel.stringValue = String(cString: gsde_chromium_backend_status())
        startCEFStatusPolling()
        let initialURL = pendingInitialURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak browserContainer] in
            guard let self, self.cefBrowser == browser, browserContainer != nil else { return }
            initialURL.absoluteString.withCString { gsde_chromium_browser_load_url(browser, $0) }
        }
    }

    private func startWebKitFallbackLoadIfNeeded() {
        guard !hasStartedWebKitFallbackLoad else { return }
        hasStartedWebKitFallbackLoad = true
        webView.isHidden = false
        webView.load(URLRequest(url: pendingInitialURL))
    }

    private func attachCEFBrowserViewIfAvailable(_ browser: OpaquePointer) {
        guard let rawView = gsde_chromium_browser_view(browser) else { return }
        let nativeView = Unmanaged<NSView>.fromOpaque(rawView).takeUnretainedValue()
        if nativeView.superview !== browserContainer {
            nativeView.removeFromSuperview()
            browserContainer.addSubview(nativeView, positioned: .above, relativeTo: webView)
        }
        nativeView.frame = browserContainer.bounds
        nativeView.autoresizingMask = [.width, .height]
        cefNativeView = nativeView
        updateNavigationButtons()
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
        let currentURL = String(cString: gsde_chromium_browser_current_url(cefBrowser))
        if !currentURL.isEmpty, urlField.currentEditor() == nil {
            urlField.stringValue = currentURL
        }

        let loading = gsde_chromium_browser_is_loading(cefBrowser) != 0
        let httpStatus = gsde_chromium_browser_http_status(cefBrowser)
        if loading {
            backendStatusLabel.stringValue = "CEF loading…"
        } else if httpStatus > 0 {
            backendStatusLabel.stringValue = "CEF HTTP \(httpStatus)"
        } else if httpStatus < 0 {
            backendStatusLabel.stringValue = "CEF error \(httpStatus)"
        } else {
            backendStatusLabel.stringValue = String(cString: gsde_chromium_backend_status())
        }
        updateNavigationButtons()
    }

    private func resizeCEFBrowser() {
        guard let cefBrowser else { return }
        let width = Int32(max(1, browserContainer.bounds.width))
        let height = Int32(max(1, browserContainer.bounds.height))
        cefNativeView?.frame = browserContainer.bounds
        gsde_chromium_browser_resize(cefBrowser, width, height)
    }

    private func normalizedURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value), url.scheme != nil {
            return url
        }

        if value.contains(".") || value.hasPrefix("localhost") {
            return URL(string: "https://\(value)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url {
            urlField.stringValue = url.absoluteString
        }
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            urlField.stringValue = url.absoluteString
        }
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavigationButtons()
    }

    private func updateNavigationButtons() {
        if let cefBrowser {
            backButton.isEnabled = gsde_chromium_browser_can_go_back(cefBrowser) != 0
            forwardButton.isEnabled = gsde_chromium_browser_can_go_forward(cefBrowser) != 0
            stopButton.isEnabled = gsde_chromium_browser_is_loading(cefBrowser) != 0
        } else {
            backButton.isEnabled = webView.canGoBack
            forwardButton.isEnabled = webView.canGoForward
            stopButton.isEnabled = webView.isLoading
        }
    }
}
