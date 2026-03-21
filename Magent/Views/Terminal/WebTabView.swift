import Cocoa
import MagentCore
import WebKit

/// Lightweight in-app browser view with back/forward/refresh navigation.
/// Used for Jira tickets and similar web content displayed inside a tab.
final class WebTabView: NSView, WKNavigationDelegate {

    let webView: WKWebView
    private let toolbar: NSStackView
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let refreshButton: NSButton
    private let addressField: NSTextField
    let tabIdentifier: String
    let initialURL: URL

    /// Fires when the page title changes (for updating the tab item label).
    var onTitleChange: ((String?) -> Void)?

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
        toolbar.spacing = 4
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true

        for btn in [backButton, forwardButton, refreshButton] {
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.setContentHuggingPriority(.required, for: .horizontal)
        }

        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        refreshButton.target = self
        refreshButton.action = #selector(reload)

        addressField.delegate = self

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(refreshButton)
        toolbar.addArrangedSubview(addressField)

        addSubview(toolbar)
        addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 28),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        webView.navigationDelegate = self
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

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: - WKNavigationDelegate

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
        let input = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // If the input already has a recognized scheme, use it as-is
        if let url = URL(string: input), let scheme = url.scheme, !scheme.isEmpty {
            // URL(string:) parses "localhost:3000" as scheme="localhost" host=nil —
            // detect that case: a real scheme won't have digits-only as the path-like part
            let looksLikeBareHostPort = url.host == nil && url.port == nil && scheme.allSatisfy(\.isLetter)
                && input.hasPrefix("\(scheme):") && !input.hasPrefix("\(scheme)://")
                && input.dropFirst(scheme.count + 1).allSatisfy({ $0.isNumber || $0 == "/" })

            if !looksLikeBareHostPort {
                webView.load(URLRequest(url: url))
                return
            }
        }

        // No scheme — prepend http:// for localhost/127.0.0.1, https:// otherwise
        let prefix = (input.hasPrefix("localhost") || input.hasPrefix("127.0.0.1") || input.hasPrefix("[::1]"))
            ? "http://" : "https://"
        guard let url = URL(string: prefix + input) else { return }
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
