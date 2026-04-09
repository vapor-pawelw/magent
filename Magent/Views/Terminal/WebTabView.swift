import Cocoa
import MagentCore
import WebKit

/// Normalizes a user-entered URL string into a proper URL.
/// Handles bare host:port (e.g. "localhost:3000"), loopback addresses,
/// and scheme-less hostnames. Returns nil for empty or unparseable input.
enum WebURLNormalizer {
    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            // URL(string:) parses "localhost:3000" as scheme="localhost" host=nil —
            // detect that case: a real scheme won't have digits-only as the path-like part
            let looksLikeBareHostPort = url.host == nil && url.port == nil && scheme.allSatisfy(\.isLetter)
                && trimmed.hasPrefix("\(scheme):") && !trimmed.hasPrefix("\(scheme)://")
                && trimmed.dropFirst(scheme.count + 1).allSatisfy({ $0.isNumber || $0 == "/" })

            if !looksLikeBareHostPort {
                return url
            }
        }

        // No scheme — prepend http:// for localhost/loopback, https:// otherwise
        let prefix = (trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") || trimmed.hasPrefix("[::1]"))
            ? "http://" : "https://"
        return URL(string: prefix + trimmed)
    }

    static func shortHost(from url: URL) -> String? {
        guard let host = url.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Lightweight in-app browser view with back/forward/refresh navigation.
/// Used for Jira tickets and similar web content displayed inside a tab.
final class WebTabView: NSView, WKNavigationDelegate, WKUIDelegate {

    let webView: WKWebView
    private let toolbar: NSStackView
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let refreshButton: NSButton
    private let openInBrowserButton: NSButton
    private let addressField: NSTextField
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
        addressField.stringValue = url.absoluteString

        toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true

        for btn in [backButton, forwardButton, refreshButton, openInBrowserButton] {
            btn.bezelStyle = .texturedSquare
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

        addressField.delegate = self

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(addressField)
        toolbar.addArrangedSubview(refreshButton)
        toolbar.addArrangedSubview(openInBrowserButton)

        addSubview(toolbar)
        addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            backButton.widthAnchor.constraint(equalToConstant: 28),
            backButton.heightAnchor.constraint(equalTo: backButton.widthAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 28),
            forwardButton.heightAnchor.constraint(equalTo: forwardButton.widthAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 28),
            refreshButton.heightAnchor.constraint(equalTo: refreshButton.widthAnchor),
            openInBrowserButton.widthAnchor.constraint(equalToConstant: 28),
            openInBrowserButton.heightAnchor.constraint(equalTo: openInBrowserButton.widthAnchor),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        webView.load(URLRequest(url: url))
        updateNavButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Key Equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let bindings = PersistenceService.shared.loadSettings().keyBindings
        let modifiers = KeyModifiers.from(event.modifierFlags.intersection(.deviceIndependentFlagsMask))

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
        NSWorkspace.shared.open(url)
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func shouldOpenInNewTab(_ navigationAction: WKNavigationAction) -> Bool {
        guard navigationAction.navigationType == .linkActivated else { return false }
        return navigationAction.buttonNumber == 2 || navigationAction.modifierFlags.contains(.command)
    }

    private func openInNewTabIfPossible(_ navigationAction: WKNavigationAction) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        onOpenInNewTab?(url)
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
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
            onTitleChange?(webView.title)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            updateNavButtons()
            updateAddressField()
            if let url = webView.url, url.absoluteString != "about:blank" {
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
        addressField.stringValue = webView.url?.absoluteString ?? ""
    }

    private func navigateToAddressFieldValue() {
        guard let url = WebURLNormalizer.normalize(addressField.stringValue) else { return }
        webView.load(URLRequest(url: url))
    }
}

// MARK: - NSTextFieldDelegate

extension WebTabView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            navigateToAddressFieldValue()
            // Resign first responder so the URL field updates on navigation
            window?.makeFirstResponder(webView)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape: revert to current URL and resign
            addressField.stringValue = webView.url?.absoluteString ?? ""
            window?.makeFirstResponder(webView)
            return true
        }
        return false
    }
}
