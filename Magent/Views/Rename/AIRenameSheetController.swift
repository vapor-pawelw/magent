import Cocoa
import MagentCore

struct AIRenameSheetResult {
    let prompt: String
    let renameIcon: Bool
    let renameDescription: Bool
    let renameBranch: Bool
}

struct AIRenameSheetConfig {
    let thread: MagentThread
    /// Recent prompts (deduplicated, newest-first) to show in the prompt picker.
    let recentPrompts: [String]
    /// Pre-filled prompt text (e.g. from TOC right-click). Empty string = show placeholder.
    let prefillPrompt: String

    init(thread: MagentThread, recentPrompts: [String], prefillPrompt: String = "") {
        self.thread = thread
        self.recentPrompts = recentPrompts
        self.prefillPrompt = prefillPrompt
    }
}

final class AIRenameSheetController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static var activeControllers: [ObjectIdentifier: AIRenameSheetController] = [:]
    private static let sheetContentWidth: CGFloat = 480

    private let config: AIRenameSheetConfig
    private let promptTextView = NSTextView()
    private var promptScrollView: NSScrollView!
    private let promptPicker = NSPopUpButton()
    private let iconCheckbox = NSButton(checkboxWithTitle: "Icon", target: nil, action: nil)
    private let descriptionCheckbox = NSButton(checkboxWithTitle: "Description", target: nil, action: nil)
    private let branchCheckbox = NSButton(checkboxWithTitle: "Branch name", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private var completion: ((AIRenameSheetResult?) -> Void)?
    private var didFinish = false

    private static let placeholderText = "Describe the task for AI rename..."
    private var isShowingPlaceholder = false
    /// Guard against re-entrant text change notifications while clearing placeholder.
    private var isClearingPlaceholder = false

    init(config: AIRenameSheetConfig) {
        self.config = config

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.sheetContentWidth, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Rename"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupUI()
        loadCheckboxState()
        applyPrefill()
        resizeWindowToFitContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Present / Dismiss

    func present(for parentWindow: NSWindow, completion: @escaping (AIRenameSheetResult?) -> Void) {
        self.completion = completion
        guard let window else {
            completion(nil)
            return
        }

        let identifier = ObjectIdentifier(self)
        Self.activeControllers[identifier] = self
        parentWindow.beginSheet(window) { _ in
            Self.activeControllers.removeValue(forKey: identifier)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.promptTextView)
            // Select all text if pre-filled so user can easily replace
            if !self.isShowingPlaceholder, !self.promptTextView.string.isEmpty {
                self.promptTextView.selectAll(nil)
            }
        }
    }

    private func finish(with result: AIRenameSheetResult?) {
        guard !didFinish else { return }
        didFinish = true

        if let parentWindow = window?.sheetParent, let window {
            parentWindow.endSheet(window)
        } else {
            close()
        }

        completion?(result)
        completion = nil
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        // 1. Title label
        let titleLabel = NSTextField(labelWithString: "AI Rename")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(titleLabel)

        // 2. Thread context chip
        let threadName = config.thread.taskDescription ?? config.thread.name
        let contextLabel = NSTextField(labelWithString: "Thread: \(threadName)")
        contextLabel.font = .systemFont(ofSize: 11)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(contextLabel)
        stack.setCustomSpacing(8, after: contextLabel)

        // 3. Prompt picker (recent prompts)
        if !config.recentPrompts.isEmpty {
            let pickerLabel = NSTextField(labelWithString: "Recent prompts")
            pickerLabel.font = .systemFont(ofSize: 12, weight: .medium)
            stack.addArrangedSubview(pickerLabel)
            stack.setCustomSpacing(4, after: pickerLabel)

            setupPromptPicker()
            stack.addArrangedSubview(promptPicker)
            stack.setCustomSpacing(10, after: promptPicker)
        }

        // 4. Prompt text view
        let promptLabel = NSTextField(labelWithString: "Prompt")
        promptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(promptLabel)
        stack.setCustomSpacing(4, after: promptLabel)

        setupPromptTextView()
        stack.addArrangedSubview(promptScrollView)

        // 5. Checkboxes row
        let checkboxRow = NSStackView()
        checkboxRow.orientation = .horizontal
        checkboxRow.spacing = 16
        checkboxRow.translatesAutoresizingMaskIntoConstraints = false

        let whatToChangeLabel = NSTextField(labelWithString: "Change:")
        whatToChangeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        checkboxRow.addArrangedSubview(whatToChangeLabel)

        for checkbox in [iconCheckbox, descriptionCheckbox, branchCheckbox] {
            checkbox.font = .systemFont(ofSize: 12)
            checkbox.contentTintColor = .controlAccentColor
            checkbox.target = self
            checkbox.action = #selector(checkboxChanged)
            checkboxRow.addArrangedSubview(checkbox)
        }
        stack.addArrangedSubview(checkboxRow)

        // 6. Button row
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        buttonRow.addArrangedSubview(cancelButton)

        renameButton.target = self
        renameButton.action = #selector(renameTapped)
        renameButton.keyEquivalent = "\r"
        renameButton.bezelStyle = .rounded
        renameButton.controlSize = .large
        (renameButton.cell as? NSButtonCell)?.backgroundColor = .controlAccentColor
        buttonRow.addArrangedSubview(renameButton)

        stack.addArrangedSubview(buttonRow)

        // Constraints
        let contentWidth = Self.sheetContentWidth - 40 // 20pt padding on each side

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        // Width constraints for full-width subviews
        for subview in stack.arrangedSubviews {
            subview.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
    }

    private func setupPromptPicker() {
        promptPicker.translatesAutoresizingMaskIntoConstraints = false
        promptPicker.removeAllItems()
        promptPicker.addItem(withTitle: "Select a prompt...")
        promptPicker.lastItem?.isEnabled = false

        for prompt in config.recentPrompts {
            let truncated = prompt.count > 80 ? String(prompt.prefix(77)) + "…" : prompt
            // Collapse newlines for menu display
            let singleLine = truncated.replacingOccurrences(of: "\n", with: " ")
            promptPicker.addItem(withTitle: singleLine)
            promptPicker.lastItem?.representedObject = prompt
        }

        promptPicker.target = self
        promptPicker.action = #selector(promptPickerChanged)
    }

    private func setupPromptTextView() {
        let promptFont = NSFont.systemFont(ofSize: 13)

        promptTextView.isRichText = false
        promptTextView.font = promptFont
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.isAutomaticTextReplacementEnabled = false
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.allowsUndo = true
        promptTextView.textContainerInset = NSSize(width: 8, height: 8)
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        promptTextView.delegate = self

        let scrollView = NonCapturingScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = promptTextView
        promptScrollView = scrollView

        let lineHeight = promptFont.ascender + abs(promptFont.descender) + promptFont.leading
        let promptHeight = max((lineHeight * 5) + 20, 100)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: promptHeight).isActive = true
    }

    // MARK: - Placeholder

    private func showPlaceholder() {
        guard !isClearingPlaceholder else { return }
        isShowingPlaceholder = true
        promptTextView.string = Self.placeholderText
        promptTextView.textColor = .placeholderTextColor
        // Place caret at the beginning so it doesn't appear after placeholder text
        promptTextView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func clearPlaceholder() {
        guard isShowingPlaceholder, !isClearingPlaceholder else { return }
        isClearingPlaceholder = true
        isShowingPlaceholder = false
        promptTextView.string = ""
        promptTextView.textColor = .textColor
        isClearingPlaceholder = false
    }

    // MARK: - Prefill & State

    private func applyPrefill() {
        if config.prefillPrompt.isEmpty {
            showPlaceholder()
        } else {
            promptTextView.string = config.prefillPrompt
            promptTextView.textColor = .textColor
            isShowingPlaceholder = false
            // Try to select the matching picker item
            selectPickerItem(matching: config.prefillPrompt)
        }
    }

    private func selectPickerItem(matching prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in 0..<promptPicker.numberOfItems {
            if let obj = promptPicker.item(at: i)?.representedObject as? String,
               obj.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                promptPicker.selectItem(at: i)
                return
            }
        }
        // No match — keep placeholder selected
        promptPicker.selectItem(at: 0)
    }

    private func loadCheckboxState() {
        let settings = PersistenceService.shared.loadSettings()
        iconCheckbox.state = settings.aiRenameIcon ? .on : .off
        descriptionCheckbox.state = settings.aiRenameDescription ? .on : .off
        branchCheckbox.state = settings.aiRenameBranch ? .on : .off
    }

    private func saveCheckboxState() {
        var settings = PersistenceService.shared.loadSettings()
        settings.aiRenameIcon = iconCheckbox.state == .on
        settings.aiRenameDescription = descriptionCheckbox.state == .on
        settings.aiRenameBranch = branchCheckbox.state == .on
        try? PersistenceService.shared.saveSettings(settings)
    }

    // MARK: - Actions

    @objc private func promptPickerChanged() {
        guard let selectedItem = promptPicker.selectedItem,
              let prompt = selectedItem.representedObject as? String else { return }
        clearPlaceholder()
        promptTextView.string = prompt
        promptTextView.textColor = .textColor
        window?.makeFirstResponder(promptTextView)
        promptTextView.selectAll(nil)
    }

    @objc private func checkboxChanged() {
        saveCheckboxState()
    }

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    @objc private func renameTapped() {
        let prompt: String
        if isShowingPlaceholder {
            prompt = ""
        } else {
            prompt = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !prompt.isEmpty else {
            NSSound.beep()
            return
        }

        // At least one checkbox must be checked
        guard iconCheckbox.state == .on || descriptionCheckbox.state == .on || branchCheckbox.state == .on else {
            NSSound.beep()
            return
        }

        let result = AIRenameSheetResult(
            prompt: prompt,
            renameIcon: iconCheckbox.state == .on,
            renameDescription: descriptionCheckbox.state == .on,
            renameBranch: branchCheckbox.state == .on
        )
        finish(with: result)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                // Shift+Return inserts a newline — but clear placeholder first
                if isShowingPlaceholder { clearPlaceholder() }
                return false
            }
            renameTapped()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            window?.selectNextKeyView(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            window?.selectPreviousKeyView(nil)
            return true
        }
        // Swallow delete/backspace while placeholder is shown
        if isShowingPlaceholder,
           commandSelector == #selector(NSResponder.deleteBackward(_:))
            || commandSelector == #selector(NSResponder.deleteForward(_:)) {
            return true
        }
        return false
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isShowingPlaceholder, let replacement = replacementString, !replacement.isEmpty {
            // User is typing real content — clear placeholder first, then let the
            // character land in the now-empty text view.
            clearPlaceholder()
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isClearingPlaceholder else { return }
        if !isShowingPlaceholder, promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showPlaceholder()
        }
    }

    // MARK: - Layout

    private func resizeWindowToFitContent() {
        guard let window, let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        let h = max(fitting.height, 200)
        window.setContentSize(NSSize(width: fitting.width > 0 ? fitting.width : Self.sheetContentWidth, height: h))
    }
}
