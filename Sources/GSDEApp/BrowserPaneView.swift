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
    private let devToolsButton = NSButton(title: "DevTools", target: nil, action: nil)
    private let backendStatusLabel = NSTextField(labelWithString: "")
    private let urlField = NSTextField(string: "")
    private let browserContainer = NSView()
    private let webView: WKWebView
    private var cefBrowser: OpaquePointer?
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
        load(initialURL)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let cefBrowser {
                gsde_chromium_browser_destroy(cefBrowser)
                self.cefBrowser = nil
            }
            return
        }

        createCEFBrowserIfPossible()
        if window?.firstResponder == nil {
            window?.makeFirstResponder(cefBrowser == nil ? webView : browserContainer)
        }
    }

    override func layout() {
        super.layout()
        resizeCEFBrowser()
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

        [backButton, forwardButton, reloadButton, devToolsButton].forEach { button in
            button.bezelStyle = .rounded
            button.controlSize = .small
        }

        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        devToolsButton.target = self
        devToolsButton.action = #selector(showDeveloperTools)

        backendStatusLabel.stringValue = String(cString: gsde_chromium_backend_status())
        backendStatusLabel.textColor = .secondaryLabelColor
        backendStatusLabel.font = .systemFont(ofSize: 11)
        backendStatusLabel.lineBreakMode = .byTruncatingTail

        urlField.placeholderString = "Enter URL"
        urlField.target = self
        urlField.action = #selector(navigateFromURLField)
        urlField.lineBreakMode = .byTruncatingMiddle

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(reloadButton)
        toolbar.addArrangedSubview(urlField)
        toolbar.addArrangedSubview(devToolsButton)
        toolbar.addArrangedSubview(backendStatusLabel)

        backendStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        backendStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func navigateFromURLField() {
        guard let url = normalizedURL(from: urlField.stringValue) else { return }
        load(url)
    }

    @objc private func goBack() {
        if let cefBrowser {
            gsde_chromium_browser_go_back(cefBrowser)
        } else if webView.canGoBack {
            webView.goBack()
        }
    }

    @objc private func goForward() {
        if let cefBrowser {
            gsde_chromium_browser_go_forward(cefBrowser)
        } else if webView.canGoForward {
            webView.goForward()
        }
    }

    @objc private func reload() {
        if let cefBrowser {
            gsde_chromium_browser_reload(cefBrowser)
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
        guard cefBrowser == nil, gsde_chromium_cef_available() != 0 else { return }
        browserContainer.layoutSubtreeIfNeeded()
        let width = Int32(max(1, browserContainer.bounds.width))
        let height = Int32(max(1, browserContainer.bounds.height))
        let browser = pendingInitialURL.absoluteString.withCString { initialURLPointer in
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
            return
        }
        cefBrowser = browser
        webView.isHidden = true
        backendStatusLabel.stringValue = String(cString: gsde_chromium_backend_status())
    }

    private func resizeCEFBrowser() {
        guard let cefBrowser else { return }
        let width = Int32(max(1, browserContainer.bounds.width))
        let height = Int32(max(1, browserContainer.bounds.height))
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
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }
}
