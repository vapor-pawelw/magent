import Cocoa

struct PromptTOCEntry: Sendable {
    let lineIndex: Int
    let displayText: String
}

private struct PromptPaneCandidate {
    let lineIndex: Int
    let promptText: String
    let normalizedPromptText: String
}

extension ThreadDetailViewController {

    func setupPromptTOCOverlay() {
        let tocView = PromptTableOfContentsView()
        tocView.translatesAutoresizingMaskIntoConstraints = false
        tocView.isHidden = true
        tocView.onSelectEntry = { [weak self] entryIndex in
            self?.handlePromptTOCSelection(entryIndex: entryIndex)
        }
        tocView.onDragGesture = { [weak self] gesture in
            self?.handlePromptTOCDrag(gesture)
        }
        tocView.onResizeGesture = { [weak self] gesture in
            self?.handlePromptTOCResize(gesture)
        }

        terminalContainer.addSubview(tocView)
        let top = tocView.topAnchor.constraint(equalTo: terminalContainer.topAnchor, constant: 12)
        let trailing = tocView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -12)
        let width = tocView.widthAnchor.constraint(equalToConstant: Self.promptTOCMinimumWidth)
        let height = tocView.heightAnchor.constraint(equalToConstant: Self.promptTOCMinimumHeight)
        promptTOCTopConstraint = top
        promptTOCTrailingConstraint = trailing
        promptTOCWidthConstraint = width
        promptTOCHeightConstraint = height

        NSLayoutConstraint.activate([
            top,
            trailing,
            width,
            height,
        ])

        promptTOCView = tocView
    }

    func schedulePromptTOCRefresh(after delay: TimeInterval = 0) {
        promptTOCRefreshTask?.cancel()
        promptTOCRefreshTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await refreshPromptTOC()
        }
    }

    @MainActor
    func refreshPromptTOC() async {
        guard currentTabIndex < thread.tmuxSessionNames.count else {
            promptTOCSessionName = nil
            promptTOCEntries = []
            promptTOCCanShowForCurrentTab = false
            updatePromptTOCToggleButtonState(canShow: false)
            promptTOCView?.isHidden = true
            return
        }

        let sessionName = thread.tmuxSessionNames[currentTabIndex]
        guard thread.agentTmuxSessions.contains(sessionName) else {
            promptTOCSessionName = nil
            promptTOCEntries = []
            promptTOCCanShowForCurrentTab = false
            updatePromptTOCToggleButtonState(canShow: false)
            promptTOCView?.isHidden = true
            return
        }

        let agentType = thread.sessionAgentTypes[sessionName]
            ?? thread.selectedAgentType
            ?? threadManager.effectiveAgentType(for: thread.projectId)
        let previousSessionName = promptTOCSessionName
        promptTOCCanShowForCurrentTab = true
        updatePromptTOCToggleButtonState(canShow: true)
        promptTOCView?.isHidden = isPromptTOCManuallyHidden
        promptTOCView?.setLoading(agentType: agentType)

        let paneContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) ?? ""
        guard !Task.isCancelled else { return }
        guard currentTabIndex < thread.tmuxSessionNames.count, thread.tmuxSessionNames[currentTabIndex] == sessionName else { return }

        let latestThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let submittedPrompts = threadManager.submittedPromptHistory(threadId: thread.id, sessionName: sessionName)
        let isWaitingForInput = latestThread.waitingForInputSessions.contains(sessionName)
        let entries = parsePromptEntries(
            from: paneContent,
            agentType: agentType,
            submittedPrompts: submittedPrompts,
            isWaitingForInput: isWaitingForInput
        )
        promptTOCSessionName = sessionName
        promptTOCEntries = entries
        promptTOCView?.setEntries(entries, agentType: agentType)
        promptTOCView?.isHidden = isPromptTOCManuallyHidden
        if previousSessionName != sessionName {
            restorePromptTOCSize(for: sessionName)
            restorePromptTOCPosition(for: sessionName)
        }
        clampPromptTOCPositionIfNeeded()
    }

    private func parsePromptEntries(
        from paneContent: String,
        agentType: AgentType?,
        submittedPrompts: [String],
        isWaitingForInput: Bool
    ) -> [PromptTOCEntry] {
        let (candidates, lineCount) = parsePromptCandidates(from: paneContent, agentType: agentType)
        if candidates.isEmpty { return [] }

        let normalizedSubmitted = submittedPrompts
            .map(normalizedPromptText(_:))
            .filter { !$0.isEmpty }
        if !normalizedSubmitted.isEmpty {
            return entriesFromSubmittedPrompts(
                candidates: candidates,
                normalizedSubmittedPrompts: normalizedSubmitted
            )
        }

        // Legacy fallback when prompt history has not been captured yet.
        var fallback = candidates
        if isWaitingForInput {
            fallback = removingTrailingComposerCandidates(from: fallback, lineCount: lineCount)
        }
        return entriesFromCandidates(fallback)
    }

    private func parsePromptCandidates(from paneContent: String, agentType: AgentType?) -> ([PromptPaneCandidate], Int) {
        let codexPromptMarker = "\u{203A}" // ›
        let claudePromptMarker = "\u{276F}" // ❯

        let markers: [String] = switch agentType {
        case .codex: [codexPromptMarker]
        case .claude: [claudePromptMarker]
        default: [codexPromptMarker, claudePromptMarker]
        }

        var candidates: [PromptPaneCandidate] = []
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        for (lineIndex, rawLine) in lines.enumerated() {
            let leftTrimmed = String(rawLine.drop { $0 == " " || $0 == "\t" })
            guard let marker = markers.first(where: { leftTrimmed.hasPrefix($0) }) else { continue }
            let promptText = String(leftTrimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard !promptText.isEmpty else { continue }

            // Skip interactive selector rows (for example: "❯ 1. Continue").
            if promptText.range(of: #"^\d+\."#, options: .regularExpression) != nil { continue }
            let lowerPrompt = promptText.lowercased()
            if lowerPrompt == "yes" || lowerPrompt == "no" { continue }
            // Exclude generic suggestion templates (for example: "Implement (feature)")
            // that can appear in the composer area but were not actually submitted.
            if isPlaceholderSuggestionPrompt(promptText) { continue }

            candidates.append(
                PromptPaneCandidate(
                    lineIndex: lineIndex,
                    promptText: promptText,
                    normalizedPromptText: normalizedPromptText(promptText)
                )
            )
        }

        return (candidates, lines.count)
    }

    private func entriesFromSubmittedPrompts(
        candidates: [PromptPaneCandidate],
        normalizedSubmittedPrompts: [String]
    ) -> [PromptTOCEntry] {
        var matched: [PromptTOCEntry] = []
        var searchStart = 0

        for submitted in normalizedSubmittedPrompts {
            guard !submitted.isEmpty else { continue }
            while searchStart < candidates.count {
                let candidate = candidates[searchStart]
                if promptsMatch(submittedPrompt: submitted, candidatePrompt: candidate.normalizedPromptText) {
                    matched.append(
                        PromptTOCEntry(
                            lineIndex: candidate.lineIndex,
                            displayText: candidate.promptText
                        )
                    )
                    searchStart += 1
                    break
                }
                searchStart += 1
            }
        }

        if matched.count > 250 {
            matched = Array(matched.suffix(250))
        }
        return matched
    }

    private func entriesFromCandidates(_ candidates: [PromptPaneCandidate]) -> [PromptTOCEntry] {
        var entries = candidates.map { candidate in
            PromptTOCEntry(
                lineIndex: candidate.lineIndex,
                displayText: candidate.promptText
            )
        }
        if entries.count > 250 {
            entries = Array(entries.suffix(250))
        }
        return entries
    }

    private func promptsMatch(submittedPrompt: String, candidatePrompt: String) -> Bool {
        if submittedPrompt.caseInsensitiveCompare(candidatePrompt) == .orderedSame {
            return true
        }
        return submittedPrompt.hasPrefix(candidatePrompt) || candidatePrompt.hasPrefix(submittedPrompt)
    }

    private func normalizedPromptText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removingTrailingComposerCandidates(from candidates: [PromptPaneCandidate], lineCount: Int) -> [PromptPaneCandidate] {
        guard !candidates.isEmpty else { return candidates }

        var cutoff = min(lineCount, candidates.last!.lineIndex)
        var previousLineIndex = candidates.last!.lineIndex
        for candidate in candidates.dropLast().reversed() {
            // Treat tightly clustered prompt-marker rows near the bottom as the active
            // composer/suggestion area and exclude them from fallback TOC parsing.
            if previousLineIndex - candidate.lineIndex <= 2 {
                cutoff = candidate.lineIndex
                previousLineIndex = candidate.lineIndex
                continue
            }
            break
        }
        return candidates.filter { $0.lineIndex < cutoff }
    }

    private func isPlaceholderSuggestionPrompt(_ promptText: String) -> Bool {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let openParen = trimmed.lastIndex(of: "(") else { return false }

        let prefix = trimmed[..<openParen].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return false }

        let placeholderStart = trimmed.index(after: openParen)
        let placeholderEnd = trimmed.index(before: trimmed.endIndex)
        guard placeholderStart < placeholderEnd else { return false }

        let placeholder = trimmed[placeholderStart..<placeholderEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !placeholder.isEmpty else { return false }
        guard placeholder.range(of: #"^[a-z][a-z0-9 _/\-]{1,24}$"#, options: .regularExpression) != nil else { return false }

        let prefixWordCount = prefix.split(whereSeparator: \.isWhitespace).count
        guard (1...4).contains(prefixWordCount) else { return false }

        switch placeholder {
        case "feature", "bug", "fix", "refactor", "improvement", "task", "issue",
             "test", "tests", "doc", "docs", "documentation", "ui", "ux", "api":
            return true
        default:
            return false
        }
    }

    private func handlePromptTOCSelection(entryIndex: Int) {
        guard entryIndex >= 0, entryIndex < promptTOCEntries.count else { return }
        guard currentTabIndex < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[currentTabIndex]
        guard promptTOCSessionName == sessionName else { return }

        let entry = promptTOCEntries[entryIndex]
        Task {
            do {
                try await TmuxService.shared.scrollHistoryLineToTop(sessionName: sessionName, lineIndex: entry.lineIndex)
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Could not jump to prompt in \(thread.displayName(for: sessionName, at: currentTabIndex)).",
                        style: .error
                    )
                }
            }
        }
    }

    private func handlePromptTOCDrag(_ gesture: NSPanGestureRecognizer) {
        guard let tocView = promptTOCView else { return }
        guard !isPromptTOCManuallyHidden else { return }

        switch gesture.state {
        case .began:
            promptTOCDragStartOrigin = tocView.frame.origin
        case .changed:
            let translation = gesture.translation(in: terminalContainer)
            var newOrigin = NSPoint(
                x: promptTOCDragStartOrigin.x + translation.x,
                y: promptTOCDragStartOrigin.y + translation.y
            )

            let maxX = max(0, terminalContainer.bounds.width - tocView.frame.width)
            let maxY = max(0, terminalContainer.bounds.height - tocView.frame.height)
            newOrigin.x = min(max(0, newOrigin.x), maxX)
            newOrigin.y = min(max(0, newOrigin.y), maxY)

            let top = terminalContainer.bounds.height - (newOrigin.y + tocView.frame.height)
            let trailing = newOrigin.x + tocView.frame.width - terminalContainer.bounds.width
            promptTOCTopConstraint?.constant = top
            promptTOCTrailingConstraint?.constant = trailing
            terminalContainer.layoutSubtreeIfNeeded()
        case .ended, .cancelled:
            clampPromptTOCPositionIfNeeded()
            if let sessionName = promptTOCSessionName {
                savePromptTOCPosition(for: sessionName)
            }
        default:
            break
        }
    }

    private func handlePromptTOCResize(_ gesture: NSPanGestureRecognizer) {
        guard promptTOCView != nil else { return }
        guard !isPromptTOCManuallyHidden else { return }
        guard let width = promptTOCWidthConstraint, let height = promptTOCHeightConstraint else { return }

        switch gesture.state {
        case .began:
            promptTOCResizeStartSize = NSSize(width: width.constant, height: height.constant)
        case .changed:
            let translation = gesture.translation(in: terminalContainer)
            let minimumWidth = Self.promptTOCMinimumWidth
            let minimumHeight = Self.promptTOCMinimumHeight
            let maxWidth = max(minimumWidth, terminalContainer.bounds.width - 8)
            let maxHeight = max(minimumHeight, terminalContainer.bounds.height - 8)

            let proposedWidth = promptTOCResizeStartSize.width + translation.x
            let proposedHeight = promptTOCResizeStartSize.height - translation.y
            width.constant = min(max(minimumWidth, proposedWidth), maxWidth)
            height.constant = min(max(minimumHeight, proposedHeight), maxHeight)

            terminalContainer.layoutSubtreeIfNeeded()
            clampPromptTOCPositionIfNeeded()
        case .ended, .cancelled:
            clampPromptTOCPositionIfNeeded()
            if let sessionName = promptTOCSessionName {
                savePromptTOCSize(for: sessionName)
                savePromptTOCPosition(for: sessionName)
            }
        default:
            break
        }
    }

    func clampPromptTOCPositionIfNeeded() {
        guard let tocView = promptTOCView, !tocView.isHidden else { return }
        guard let top = promptTOCTopConstraint, let trailing = promptTOCTrailingConstraint else { return }
        guard tocView.frame.width > 0, tocView.frame.height > 0 else { return }

        var origin = NSPoint(
            x: terminalContainer.bounds.width - tocView.frame.width + trailing.constant,
            y: terminalContainer.bounds.height - tocView.frame.height - top.constant
        )
        let maxX = max(0, terminalContainer.bounds.width - tocView.frame.width)
        let maxY = max(0, terminalContainer.bounds.height - tocView.frame.height)
        origin.x = min(max(0, origin.x), maxX)
        origin.y = min(max(0, origin.y), maxY)

        top.constant = terminalContainer.bounds.height - (origin.y + tocView.frame.height)
        trailing.constant = origin.x + tocView.frame.width - terminalContainer.bounds.width
    }

    func updatePromptTOCToggleButtonState(canShow: Bool) {
        togglePromptTOCButton.isEnabled = canShow
        let isShown = canShow && !isPromptTOCManuallyHidden
        let symbolName = isShown ? "list.bullet.rectangle.fill" : "list.bullet.rectangle"
        togglePromptTOCButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Table of Contents")
        togglePromptTOCButton.toolTip = isShown ? "Hide Table of Contents" : "Show Table of Contents"
    }

    func togglePromptTOCVisibility() {
        guard promptTOCCanShowForCurrentTab else { return }
        isPromptTOCManuallyHidden.toggle()
        promptTOCView?.isHidden = isPromptTOCManuallyHidden
        updatePromptTOCToggleButtonState(canShow: true)

        if !isPromptTOCManuallyHidden {
            if let sessionName = promptTOCSessionName {
                restorePromptTOCPosition(for: sessionName)
            }
            clampPromptTOCPositionIfNeeded()
        }
    }

    private func savePromptTOCPosition(for sessionName: String) {
        guard let tocView = promptTOCView else { return }
        let availableWidth = max(1, terminalContainer.bounds.width - tocView.frame.width)
        let availableHeight = max(1, terminalContainer.bounds.height - tocView.frame.height)

        let x = terminalContainer.bounds.width - tocView.frame.width + (promptTOCTrailingConstraint?.constant ?? 0)
        let y = terminalContainer.bounds.height - tocView.frame.height - (promptTOCTopConstraint?.constant ?? 0)
        let normalizedX = min(max(0, x / availableWidth), 1)
        let normalizedY = min(max(0, y / availableHeight), 1)

        UserDefaults.standard.set(
            [normalizedX, normalizedY],
            forKey: promptTOCPositionDefaultsKey(for: sessionName)
        )
    }

    private func savePromptTOCSize(for sessionName: String) {
        guard let width = promptTOCWidthConstraint, let height = promptTOCHeightConstraint else { return }
        let storedWidth = max(Self.promptTOCMinimumWidth, width.constant)
        let storedHeight = max(Self.promptTOCMinimumHeight, height.constant)
        UserDefaults.standard.set(
            [storedWidth, storedHeight],
            forKey: promptTOCSizeDefaultsKey(for: sessionName)
        )
    }

    private func restorePromptTOCPosition(for sessionName: String) {
        guard let values = UserDefaults.standard.array(forKey: promptTOCPositionDefaultsKey(for: sessionName)) as? [Double],
              values.count == 2,
              let tocView = promptTOCView,
              let top = promptTOCTopConstraint,
              let trailing = promptTOCTrailingConstraint else {
            // Reset to the default top-right position when no saved value exists.
            promptTOCTopConstraint?.constant = 12
            promptTOCTrailingConstraint?.constant = -12
            return
        }

        let normalizedX = min(max(0, values[0]), 1)
        let normalizedY = min(max(0, values[1]), 1)
        let availableWidth = max(0, terminalContainer.bounds.width - tocView.frame.width)
        let availableHeight = max(0, terminalContainer.bounds.height - tocView.frame.height)
        let originX = availableWidth * normalizedX
        let originY = availableHeight * normalizedY

        top.constant = terminalContainer.bounds.height - (originY + tocView.frame.height)
        trailing.constant = originX + tocView.frame.width - terminalContainer.bounds.width
    }

    private func restorePromptTOCSize(for sessionName: String) {
        guard let width = promptTOCWidthConstraint, let height = promptTOCHeightConstraint else { return }
        guard let values = UserDefaults.standard.array(forKey: promptTOCSizeDefaultsKey(for: sessionName)) as? [Double],
              values.count == 2 else {
            width.constant = Self.promptTOCMinimumWidth
            height.constant = Self.promptTOCMinimumHeight
            return
        }

        let minimumWidth = Self.promptTOCMinimumWidth
        let minimumHeight = Self.promptTOCMinimumHeight
        let maxWidth = max(minimumWidth, terminalContainer.bounds.width - 8)
        let maxHeight = max(minimumHeight, terminalContainer.bounds.height - 8)
        width.constant = min(max(minimumWidth, values[0]), maxWidth)
        height.constant = min(max(minimumHeight, values[1]), maxHeight)
    }

    private func promptTOCPositionDefaultsKey(for sessionName: String) -> String {
        let raw = "\(thread.id.uuidString)-\(sessionName)"
        return "\(Self.promptTOCPositionDefaultsPrefix).\(sanitizedDefaultsKeySegment(raw))"
    }

    private func promptTOCSizeDefaultsKey(for sessionName: String) -> String {
        let raw = "\(thread.id.uuidString)-\(sessionName)"
        return "\(Self.promptTOCSizeDefaultsPrefix).\(sanitizedDefaultsKeySegment(raw))"
    }

    private func sanitizedDefaultsKeySegment(_ text: String) -> String {
        text.map { char in
            char.isLetter || char.isNumber ? char : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}

final class PromptTableOfContentsView: NSView {
    var onSelectEntry: ((Int) -> Void)?
    var onDragGesture: ((NSPanGestureRecognizer) -> Void)?
    var onResizeGesture: ((NSPanGestureRecognizer) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Table of Contents")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No prompts yet")
    private let spinner = NSProgressIndicator()
    private let resizeHandle = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLoading(agentType: AgentType?) {
        subtitleLabel.stringValue = subtitle(forCount: nil, agentType: agentType)
        spinner.isHidden = false
        spinner.startAnimation(nil)
        emptyLabel.isHidden = true
        clearRows()
    }

    func setEntries(_ entries: [PromptTOCEntry], agentType: AgentType?) {
        subtitleLabel.stringValue = subtitle(forCount: entries.count, agentType: agentType)
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        clearRows()

        guard !entries.isEmpty else {
            emptyLabel.stringValue = "No prompts yet"
            emptyLabel.isHidden = false
            return
        }

        emptyLabel.isHidden = true
        for (index, entry) in entries.enumerated() {
            let row = NSView()
            row.tag = index
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            row.layer?.cornerRadius = 4
            if index.isMultiple(of: 2) {
                row.layer?.backgroundColor = NSColor.clear.cgColor
            } else {
                row.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.08).cgColor
            }

            let label = NSTextField(wrappingLabelWithString: "\(index + 1). \(entry.displayText)")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor(resource: .textPrimary)
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byTruncatingTail

            row.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
                label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            ])

            let tap = NSClickGestureRecognizer(target: self, action: #selector(handleEntryRowTap(_:)))
            row.addGestureRecognizer(tap)

            rowsStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor),
            ])
        }
    }

    private func setupUI() {
        wantsLayer = true
        // Keep TOC above terminal surfaces that are added later.
        layer?.zPosition = 10
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(resource: .surface).withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let headerIcon = NSImageView()
        headerIcon.image = NSImage(systemSymbolName: "list.bullet.rectangle.portrait", accessibilityDescription: nil)
        headerIcon.contentTintColor = NSColor(resource: .textSecondary)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        headerIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(resource: .textPrimary)

        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = NSColor(resource: .textSecondary)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.spacing = 1
        textStack.alignment = .leading

        let headerStack = NSStackView(views: [headerIcon, textStack, NSView(), spinner])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        headerStack.addGestureRecognizer(pan)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let rowsContainer = NSView()
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        rowsContainer.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: rowsContainer.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: rowsContainer.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsContainer.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: rowsContainer.bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: rowsContainer.widthAnchor),
        ])

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = rowsContainer
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
        emptyLabel.textColor = NSColor(resource: .textSecondary)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        resizeHandle.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize Table of Contents")
        resizeHandle.contentTintColor = NSColor(resource: .textSecondary).withAlphaComponent(0.8)
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.toolTip = "Drag to resize"
        let resizePan = NSPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizeHandle.addGestureRecognizer(resizePan)

        addSubview(headerStack)
        addSubview(scrollView)
        addSubview(emptyLabel)
        addSubview(resizeHandle)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            resizeHandle.widthAnchor.constraint(equalToConstant: 12),
            resizeHandle.heightAnchor.constraint(equalToConstant: 12),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func clearRows() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func subtitle(forCount count: Int?, agentType: AgentType?) -> String {
        let agentLabel = switch agentType {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .custom: "Custom"
        case nil: "Session"
        }
        guard let count else { return "\(agentLabel) · Loading..." }
        let noun = count == 1 ? "prompt" : "prompts"
        return "\(agentLabel) · \(count) \(noun)"
    }

    @objc private func handleEntryRowTap(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view else { return }
        onSelectEntry?(row.tag)
    }

    @objc private func handleDrag(_ gesture: NSPanGestureRecognizer) {
        onDragGesture?(gesture)
    }

    @objc private func handleResize(_ gesture: NSPanGestureRecognizer) {
        onResizeGesture?(gesture)
    }
}
