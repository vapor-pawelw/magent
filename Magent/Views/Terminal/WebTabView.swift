import Cocoa
import MagentCore
import WebKit

/// Normalizes a user-entered URL string into a proper URL.
/// Handles bare host:port (e.g. "localhost:3000"), loopback addresses,
/// and scheme-less hostnames. Returns nil for empty or unparseable input.
enum WebURLNormalizer {
    private static let inAppWebTabSchemes: Set<String> = ["http", "https"]
    private static let inAppNavigationSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file", "javascript"]

    private static let bareHostPortRegex: NSRegularExpression = {
        // Treat host:port (with optional path/query/fragment) as a web URL, not a custom scheme.
        try! NSRegularExpression(
            pattern: #"^(localhost|127\.0\.0\.1|\[::1\]|[A-Za-z0-9.-]+):\d+(?:[/?#].*)?$"#,
            options: [.caseInsensitive]
        )
    }()

    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("://"),
           let normalizedBareHostPort = normalizedBareHostPortURL(from: trimmed) {
            return normalizedBareHostPort
        }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        // No scheme — prepend http:// for localhost/loopback, https:// otherwise
        let lower = trimmed.lowercased()
        let prefix = (lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]"))
            ? "http://" : "https://"
        return URL(string: prefix + trimmed)
    }

    private static func normalizedBareHostPortURL(from input: String) -> URL? {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        guard bareHostPortRegex.firstMatch(in: input, options: [], range: range) != nil else {
            return nil
        }

        let lower = input.lowercased()
        let isLocal =
            lower.hasPrefix("localhost:") ||
            lower.hasPrefix("127.0.0.1:") ||
            lower.hasPrefix("[::1]:")
        let prefix = isLocal ? "http://" : "https://"
        return URL(string: prefix + input)
    }

    static func shortHost(from url: URL) -> String? {
        guard let host = url.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func supportsInAppWebTab(_ url: URL) -> Bool {
        // `about:blank` is an intentional "empty" tab state used when the user creates
        // a new web tab/thread without entering a URL. It renders cleanly in WKWebView
        // but is not openable by `NSWorkspace.open`, so it must be treated as in-app.
        if isBlankTab(url) { return true }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return inAppWebTabSchemes.contains(scheme)
    }

    static func isBlankTab(_ url: URL) -> Bool {
        url.absoluteString == "about:blank"
    }

    static func supportsInAppNavigation(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return inAppNavigationSchemes.contains(scheme)
    }
}

/// Lightweight in-app browser view with back/forward/refresh navigation.
/// Used for Jira tickets and similar web content displayed inside a tab.
final class WebTabView: NSView, WKNavigationDelegate, WKUIDelegate {
    private static let aboutBlankURL = URL(string: "about:blank")!

    let webView: WKWebView
    private let toolbar: NSStackView
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let refreshButton: NSButton
    private let openInBrowserButton: NSButton
    private let addressField: NSTextField
    private let findBar: NSStackView
    private let findField: NSSearchField
    private let findPreviousButton: NSButton
    private let findNextButton: NSButton
    private let findDoneButton: NSButton
    private let findStatusLabel: NSTextField
    let tabIdentifier: String
    let initialURL: URL

    /// Fires when the page title changes (for updating the tab item label).
    var onTitleChange: ((String?) -> Void)?
    /// Fires when the committed URL changes (for persisting the current location).
    var onURLChange: ((URL) -> Void)?
    /// Fires when the current page requests opening a URL in a separate tab.
    var onOpenInNewTab: ((URL) -> Void)?

    init(url: URL, identifier: String) {
        self.tabIdentifier = identifier
        self.initialURL = url

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: nil, action: nil)
        forwardButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!, target: nil, action: nil)
        refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!, target: nil, action: nil)
        openInBrowserButton = NSButton(image: NSImage(systemSymbolName: "safari", accessibilityDescription: "Open in Browser")!, target: nil, action: nil)

        addressField = NSTextField()
        addressField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addressField.textColor = .labelColor
        addressField.placeholderString = "Enter URL…"
        addressField.lineBreakMode = .byTruncatingTail
        addressField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.cell?.wraps = false
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.stringValue = WebURLNormalizer.isBlankTab(url) ? "" : url.absoluteString

        findField = NSSearchField()
        findField.placeholderString = "Find in page"
        findField.controlSize = .small
        findField.translatesAutoresizingMaskIntoConstraints = false

        findPreviousButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: nil, action: nil)
        findNextButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: nil, action: nil)
        findDoneButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Done")!, target: nil, action: nil)
        findStatusLabel = NSTextField(labelWithString: "")
        findStatusLabel.font = .systemFont(ofSize: 11)
        findStatusLabel.textColor = .secondaryLabelColor
        findStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        findBar = NSStackView()
        findBar.orientation = .horizontal
        findBar.spacing = 6
        findBar.alignment = .centerY
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 8
        findBar.layer?.borderWidth = 1
        findBar.isHidden = true

        toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true

        for btn in [backButton, forwardButton, refreshButton, openInBrowserButton] {
            btn.bezelStyle = .rounded
            btn.isBordered = true
            btn.controlSize = .small
            btn.imageScaling = .scaleProportionallyDown
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.setContentHuggingPriority(.required, for: .horizontal)
        }
        for btn in [findPreviousButton, findNextButton, findDoneButton] {
            btn.bezelStyle = .rounded
            btn.isBordered = true
            btn.controlSize = .small
            btn.imageScaling = .scaleProportionallyDown
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.setContentHuggingPriority(.required, for: .horizontal)
        }

        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        refreshButton.target = self
        refreshButton.action = #selector(reload)
        openInBrowserButton.target = self
        openInBrowserButton.action = #selector(openInExternalBrowser)
        openInBrowserButton.toolTip = "Open in Browser"
        findPreviousButton.target = self
        findPreviousButton.action = #selector(findPrevious)
        findNextButton.target = self
        findNextButton.action = #selector(findNext)
        findDoneButton.target = self
        findDoneButton.action = #selector(hideFindBar)

        addressField.delegate = self
        findField.delegate = self

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(addressField)
        toolbar.addArrangedSubview(refreshButton)
        toolbar.addArrangedSubview(openInBrowserButton)

        findBar.addArrangedSubview(findField)
        findBar.addArrangedSubview(findPreviousButton)
        findBar.addArrangedSubview(findNextButton)
        findBar.addArrangedSubview(findStatusLabel)
        findBar.addArrangedSubview(findDoneButton)

        addSubview(toolbar)
        addSubview(findBar)
        addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 30),

            backButton.widthAnchor.constraint(equalToConstant: 28),
            backButton.heightAnchor.constraint(equalTo: backButton.widthAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 28),
            forwardButton.heightAnchor.constraint(equalTo: forwardButton.widthAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 28),
            refreshButton.heightAnchor.constraint(equalTo: refreshButton.widthAnchor),
            openInBrowserButton.widthAnchor.constraint(equalToConstant: 28),
            openInBrowserButton.heightAnchor.constraint(equalTo: openInBrowserButton.widthAnchor),

            findBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            findPreviousButton.widthAnchor.constraint(equalToConstant: 24),
            findPreviousButton.heightAnchor.constraint(equalToConstant: 24),
            findNextButton.widthAnchor.constraint(equalToConstant: 24),
            findNextButton.heightAnchor.constraint(equalToConstant: 24),
            findDoneButton.widthAnchor.constraint(equalToConstant: 24),
            findDoneButton.heightAnchor.constraint(equalToConstant: 24),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        applyVisualStyling()
        applyAppearanceMode()
        if WebURLNormalizer.supportsInAppWebTab(url) {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: Self.aboutBlankURL))
        }
        updateNavButtons()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsDidChange(_:)),
            name: .magentSettingsDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisualStyling()
    }

    // MARK: - Key Equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let bindings = PersistenceService.shared.loadSettings().keyBindings
        let modifiers = KeyModifiers.from(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let commandModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.charactersIgnoringModifiers == "f", commandModifiers == [.command] {
            showFindBar()
            return true
        }
        if event.charactersIgnoringModifiers == "g", commandModifiers == [.command] {
            performFind(forward: true)
            return true
        }
        if event.charactersIgnoringModifiers == "g", commandModifiers == [.command, .shift] {
            performFind(forward: false)
            return true
        }
        if event.keyCode == 53, !findBar.isHidden {
            hideFindBar()
            return true
        }

        let hardRefreshBinding = bindings.binding(for: .hardRefreshWebTab)
        if event.keyCode == hardRefreshBinding.keyCode && modifiers == hardRefreshBinding.modifiers {
            hardRefresh()
            return true
        }

        let refreshBinding = bindings.binding(for: .refreshWebTab)
        if event.keyCode == refreshBinding.keyCode && modifiers == refreshBinding.modifiers {
            webView.reload()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Navigation Actions

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc func reload() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func hardRefresh() {
        webView.reloadFromOrigin()
    }

    @objc private func openInExternalBrowser() {
        guard let url = webView.url ?? URL(string: addressField.stringValue) else { return }
        // `about:blank` isn't a resource the system can hand off to a browser; skip it
        // so an empty web tab can't trigger a "there's no app to open about:blank" alert.
        if WebURLNormalizer.isBlankTab(url) { return }
        NSWorkspace.shared.open(url)
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func shouldOpenInNewTab(_ navigationAction: WKNavigationAction) -> Bool {
        guard navigationAction.navigationType == .linkActivated else { return false }
        return navigationAction.buttonNumber == 1
            || navigationAction.buttonNumber == 2
            || navigationAction.modifierFlags.contains(.command)
    }

    private func openInNewTabIfPossible(_ navigationAction: WKNavigationAction) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        if WebURLNormalizer.supportsInAppWebTab(url) {
            onOpenInNewTab?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           !WebURLNormalizer.supportsInAppNavigation(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true,
           shouldOpenInNewTab(navigationAction),
           openInNewTabIfPossible(navigationAction) {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            _ = openInNewTabIfPossible(navigationAction)
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            updateNavButtons()
            updateAddressField()
            applyAppearanceModeToCurrentPage()
            onTitleChange?(webView.title)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            updateNavButtons()
            updateAddressField()
            applyAppearanceModeToCurrentPage()
            if let url = webView.url,
               WebURLNormalizer.supportsInAppWebTab(url),
               url.absoluteString != "about:blank" {
                onURLChange?(url)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            updateNavButtons()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated {
            updateNavButtons()
            updateAddressField()
        }
    }

    private func updateAddressField() {
        // Only update when the field is not being edited
        guard window?.firstResponder != addressField.currentEditor() else { return }
        let raw = webView.url?.absoluteString ?? ""
        addressField.stringValue = (raw == "about:blank") ? "" : raw
    }

    private func navigateToAddressFieldValue() {
        guard let url = WebURLNormalizer.normalize(addressField.stringValue) else { return }
        if WebURLNormalizer.supportsInAppNavigation(url) {
            webView.load(URLRequest(url: url))
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func applyVisualStyling() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
            findBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
            findBar.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func applyAppearanceMode() {
        let settings = PersistenceService.shared.loadSettings()
        switch settings.appAppearanceMode {
        case .system:
            webView.appearance = nil
        case .light:
            webView.appearance = NSAppearance(named: .aqua)
        case .dark:
            webView.appearance = NSAppearance(named: .darkAqua)
        }
        applyAppearanceModeToCurrentPage()
    }

    @objc private func handleSettingsDidChange(_ notification: Notification) {
        applyAppearanceMode()
    }

    private func applyAppearanceModeToCurrentPage() {
        let mode = PersistenceService.shared.loadSettings().appAppearanceMode.rawValue
        guard let modeLiteral = javaScriptStringLiteral(mode) else { return }
        let script = """
        (() => {
          const mode = \(modeLiteral);
          window.__MAGENT_APPEARANCE = mode;
          document.documentElement.setAttribute("data-magent-appearance", mode);
          const root = document.documentElement;
          if (mode === "dark") {
            root.style.colorScheme = "dark";
          } else if (mode === "light") {
            root.style.colorScheme = "light";
          } else {
            root.style.colorScheme = "light dark";
          }
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func javaScriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else { return nil }
        return String(json.dropFirst().dropLast())
    }

    @objc private func showFindBar() {
        findBar.isHidden = false
        findStatusLabel.stringValue = ""
        window?.makeFirstResponder(findField)
        if !findField.stringValue.isEmpty {
            performFind(forward: true)
        }
    }

    @objc private func hideFindBar() {
        findBar.isHidden = true
        findStatusLabel.stringValue = ""
        window?.makeFirstResponder(webView)
    }

    @objc private func findNext() {
        performFind(forward: true)
    }

    @objc private func findPrevious() {
        performFind(forward: false)
    }

    private func performFind(forward: Bool) {
        let query = findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let queryLiteral = javaScriptStringLiteral(query) else {
            findStatusLabel.stringValue = ""
            return
        }

        let backwards = forward ? "false" : "true"
        let script = "window.find(\(queryLiteral), false, \(backwards), true, false, true, false);"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let found = (result as? Bool) ?? false
            self.findStatusLabel.stringValue = found ? "" : "No matches"
        }
    }
}

// MARK: - Text Delegates

extension WebTabView: NSTextFieldDelegate, NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === findField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let goForward = NSApp.currentEvent?.modifierFlags.contains(.shift) != true
                performFind(forward: goForward)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                hideFindBar()
                return true
            }
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            navigateToAddressFieldValue()
            // Resign first responder so the URL field updates on navigation
            window?.makeFirstResponder(webView)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape: revert to current URL and resign
            let raw = webView.url?.absoluteString ?? ""
            addressField.stringValue = (raw == "about:blank") ? "" : raw
            window?.makeFirstResponder(webView)
            return true
        }
        return false
    }
}
