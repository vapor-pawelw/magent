import Cocoa

struct PromptTOCEntry: Sendable {
    let lineIndex: Int
    let displayText: String
}

private struct PromptPaneCandidate {
    let startLineIndex: Int
    let endLineIndex: Int
    let promptText: String
}

private struct PromptPaneLine {
    let rawText: String
    let plainText: String
    let styledCharacters: [PromptPaneStyledCharacter]
}

private struct PromptPaneStyledCharacter {
    let character: Character
    let style: PromptANSIStyle
}

private struct PromptANSIStyle: Equatable {
    var isDim = false
    var foreground: PromptANSIForeground = .default

    var looksPlaceholderLike: Bool {
        isDim || foreground.isGrayLike
    }
}

private enum PromptANSIForeground: Equatable {
    case `default`
    case indexed(Int)
    case rgb(Int, Int, Int)

    var isGrayLike: Bool {
        switch self {
        case .default:
            return false
        case .indexed(let value):
            return value == 7 || value == 8 || (240...250).contains(value)
        case .rgb(let red, let green, let blue):
            let minChannel = min(red, min(green, blue))
            let maxChannel = max(red, max(green, blue))
            return maxChannel - minChannel <= 18
        }
    }
}

extension ThreadDetailViewController {

    func setupPromptTOCOverlay() {
        let tocView = PromptTableOfContentsView()
        tocView.translatesAutoresizingMaskIntoConstraints = false
        tocView.isHidden = true
        tocView.onSelectEntry = { [weak self] entryIndex in
            self?.handlePromptTOCSelection(entryIndex: entryIndex)
        }
        tocView.onCloseRequested = { [weak self] in
            self?.togglePromptTOCVisibility()
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
        bringPromptTOCOverlayToFront()
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

        let paneContent = await TmuxService.shared.captureFullPane(
            sessionName: sessionName,
            includeAttributes: true
        ) ?? ""
        guard !Task.isCancelled else { return }
        guard currentTabIndex < thread.tmuxSessionNames.count, thread.tmuxSessionNames[currentTabIndex] == sessionName else { return }

        let entries = parsePromptEntries(
            from: paneContent,
            agentType: agentType
        )
        threadManager.replaceSubmittedPromptHistory(
            threadId: thread.id,
            sessionName: sessionName,
            prompts: entries.map(\.displayText)
        )
        promptTOCSessionName = sessionName
        promptTOCEntries = entries
        promptTOCView?.setEntries(entries, agentType: agentType)
        promptTOCView?.isHidden = isPromptTOCManuallyHidden
        if previousSessionName != sessionName {
            restorePromptTOCSize(for: sessionName)
            restorePromptTOCPosition(for: sessionName)
        }
        bringPromptTOCOverlayToFront()
        clampPromptTOCPositionIfNeeded()
    }

    private func parsePromptEntries(
        from paneContent: String,
        agentType: AgentType?
    ) -> [PromptTOCEntry] {
        let (candidates, lines) = parsePromptCandidates(from: paneContent, agentType: agentType)
        if candidates.isEmpty { return [] }

        let candidateOccupiedLineIndexes = Set(
            candidates.flatMap { Array($0.startLineIndex...$0.endLineIndex) }
        )
        let cutoff = activeBottomClusterStartIndex(
            in: lines,
            candidateOccupiedLineIndexes: candidateOccupiedLineIndexes
        )
        let confirmedCandidates = candidates.filter {
            $0.endLineIndex < cutoff &&
            hasConfirmedOutput(
                after: $0,
                in: lines,
                candidateOccupiedLineIndexes: candidateOccupiedLineIndexes,
                cutoff: cutoff
            )
        }
        return entriesFromCandidates(confirmedCandidates)
    }

    private func parsePromptCandidates(from paneContent: String, agentType: AgentType?) -> ([PromptPaneCandidate], [PromptPaneLine]) {
        let codexPromptMarker = "\u{203A}" // ›
        let claudePromptMarker = "\u{276F}" // ❯

        let markers: [String] = switch agentType {
        case .codex: [codexPromptMarker]
        case .claude: [claudePromptMarker]
        default: [codexPromptMarker, claudePromptMarker]
        }

        var candidates: [PromptPaneCandidate] = []
        let lines = promptPaneLines(from: paneContent)

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let leftTrimmedCharacters = line.styledCharacters.drop(while: { $0.character.isWhitespace })
            let leftTrimmedText = String(leftTrimmedCharacters.map(\.character))
            guard let marker = markers.first(where: { leftTrimmedText.hasPrefix($0) }) else {
                lineIndex += 1
                continue
            }

            let promptCharacters = promptCharacters(after: marker, in: Array(leftTrimmedCharacters))
            let firstPromptLine = String(promptCharacters.map(\.character))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstPromptLine.isEmpty else {
                lineIndex += 1
                continue
            }

            let promptTextStyleLooksPlaceholderLike = promptTextLooksLikePlaceholder(promptCharacters)
            var promptLines = [firstPromptLine]
            var endLineIndex = lineIndex
            var continuationIndex = lineIndex + 1

            while continuationIndex < lines.count,
                  let continuation = promptContinuationText(from: lines[continuationIndex], markers: markers) {
                promptLines.append(continuation)
                endLineIndex = continuationIndex
                continuationIndex += 1
            }

            let promptText = promptLines.joined(separator: " ")
            guard !promptText.isEmpty else {
                lineIndex = continuationIndex
                continue
            }

            // Skip interactive selector rows (for example: "❯ 1. Continue").
            if promptText.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                lineIndex = continuationIndex
                continue
            }
            let lowerPrompt = promptText.lowercased()
            if lowerPrompt == "yes" || lowerPrompt == "no" {
                lineIndex = continuationIndex
                continue
            }
            // Exclude generic suggestion templates (for example: "Implement {feature}")
            // that can appear in the composer area but were not actually submitted.
            if promptTextStyleLooksPlaceholderLike || isPlaceholderSuggestionPrompt(promptText) {
                lineIndex = continuationIndex
                continue
            }

            candidates.append(
                PromptPaneCandidate(
                    startLineIndex: lineIndex,
                    endLineIndex: endLineIndex,
                    promptText: promptText
                )
            )
            lineIndex = continuationIndex
            continue
        }

        return (candidates, lines)
    }

    private func entriesFromCandidates(_ candidates: [PromptPaneCandidate]) -> [PromptTOCEntry] {
        var entries = candidates.map { candidate in
            PromptTOCEntry(
                lineIndex: candidate.startLineIndex,
                displayText: candidate.promptText
            )
        }
        if entries.count > 250 {
            entries = Array(entries.suffix(250))
        }
        return entries
    }

    private func activeBottomClusterStartIndex(
        in lines: [PromptPaneLine],
        candidateOccupiedLineIndexes: Set<Int>
    ) -> Int {
        guard !lines.isEmpty else { return 0 }

        var cutoff = lines.count
        var sawBottomClusterContent = false

        for lineIndex in stride(from: lines.count - 1, through: 0, by: -1) {
            let trimmed = lines[lineIndex].plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if sawBottomClusterContent {
                    cutoff = lineIndex
                }
                continue
            }

            let isCandidateLine = candidateOccupiedLineIndexes.contains(lineIndex)
            let isBottomAuxiliary = isBottomPinnedAuxiliaryLine(trimmed)

            if isCandidateLine || isBottomAuxiliary {
                sawBottomClusterContent = true
                cutoff = lineIndex
                continue
            }

            break
        }
        return cutoff
    }

    private func hasConfirmedOutput(
        after candidate: PromptPaneCandidate,
        in lines: [PromptPaneLine],
        candidateOccupiedLineIndexes: Set<Int>,
        cutoff: Int
    ) -> Bool {
        guard candidate.endLineIndex + 1 < cutoff else { return false }

        for lineIndex in (candidate.endLineIndex + 1)..<cutoff {
            let trimmed = lines[lineIndex].plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isBottomPinnedAuxiliaryLine(trimmed) {
                continue
            }
            if candidateOccupiedLineIndexes.contains(lineIndex) {
                return false
            }
            return true
        }

        return false
    }

    private func isPlaceholderSuggestionPrompt(_ promptText: String) -> Bool {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = extractTemplatePlaceholder(from: trimmed)?.lowercased() ?? ""
        guard !placeholder.isEmpty else { return false }
        guard placeholder.range(of: #"^[a-z][a-z0-9 _/\-]{1,24}$"#, options: .regularExpression) != nil else { return false }

        guard let prefix = templatePlaceholderPrefix(from: trimmed), !prefix.isEmpty else { return false }
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

    private func isBottomPinnedAuxiliaryLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        if lower.contains("tab to cycle")
            || lower.contains("enter to submit")
            || lower.contains("shift+tab")
            || lower.contains("ctrl+c to stop")
            || lower.contains("esc to interrupt") {
            return true
        }

        let isModelStatusLine = trimmed.range(
            of: #"^(gpt|o[1-9]|claude|codex)[a-z0-9 .\-]*\s+·\s+.*\bleft\b.*(?:~/|/Users/|/[A-Za-z0-9._-]+/)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if isModelStatusLine {
            return true
        }

        return false
    }

    private func promptPaneLines(from paneContent: String) -> [PromptPaneLine] {
        paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .map(parsePromptPaneLine)
    }

    private func parsePromptPaneLine(_ rawLine: String) -> PromptPaneLine {
        var styledCharacters: [PromptPaneStyledCharacter] = []
        var currentStyle = PromptANSIStyle()
        var index = rawLine.startIndex

        while index < rawLine.endIndex {
            let character = rawLine[index]
            if character == "\u{001B}" {
                let nextIndex = rawLine.index(after: index)
                guard nextIndex < rawLine.endIndex else { break }
                let nextCharacter = rawLine[nextIndex]

                if nextCharacter == "[" {
                    var sequenceEnd = rawLine.index(after: nextIndex)
                    while sequenceEnd < rawLine.endIndex {
                        let scalar = rawLine[sequenceEnd].unicodeScalars.first?.value ?? 0
                        if (0x40...0x7E).contains(scalar) { break }
                        sequenceEnd = rawLine.index(after: sequenceEnd)
                    }
                    guard sequenceEnd < rawLine.endIndex else { break }
                    if rawLine[sequenceEnd] == "m" {
                        let paramsText = String(rawLine[rawLine.index(after: nextIndex)..<sequenceEnd])
                        applySGRParameters(
                            paramsText
                                .split(separator: ";", omittingEmptySubsequences: false)
                                .compactMap { $0.isEmpty ? 0 : Int($0) },
                            to: &currentStyle
                        )
                    }
                    index = rawLine.index(after: sequenceEnd)
                    continue
                }

                if nextCharacter == "]" {
                    var sequenceEnd = rawLine.index(after: nextIndex)
                    while sequenceEnd < rawLine.endIndex {
                        let current = rawLine[sequenceEnd]
                        if current == "\u{0007}" {
                            sequenceEnd = rawLine.index(after: sequenceEnd)
                            break
                        }
                        if current == "\u{001B}" {
                            let terminatorIndex = rawLine.index(after: sequenceEnd)
                            if terminatorIndex < rawLine.endIndex, rawLine[terminatorIndex] == "\\" {
                                sequenceEnd = rawLine.index(after: terminatorIndex)
                                break
                            }
                        }
                        sequenceEnd = rawLine.index(after: sequenceEnd)
                    }
                    index = sequenceEnd
                    continue
                }

                index = rawLine.index(after: nextIndex)
                continue
            }

            let scalar = character.unicodeScalars.first?.value ?? 0
            if (0x80...0x9F).contains(scalar) || scalar == 0x0E || scalar == 0x0F {
                index = rawLine.index(after: index)
                continue
            }

            styledCharacters.append(
                PromptPaneStyledCharacter(
                    character: character,
                    style: currentStyle
                )
            )
            index = rawLine.index(after: index)
        }

        return PromptPaneLine(
            rawText: rawLine,
            plainText: String(styledCharacters.map(\.character)),
            styledCharacters: styledCharacters
        )
    }

    private func applySGRParameters(_ params: [Int], to style: inout PromptANSIStyle) {
        let normalizedParams = params.isEmpty ? [0] : params
        var index = 0

        while index < normalizedParams.count {
            let value = normalizedParams[index]
            switch value {
            case 0:
                style = PromptANSIStyle()
            case 2:
                style.isDim = true
            case 22:
                style.isDim = false
            case 30...37:
                style.foreground = .indexed(value - 30)
            case 38:
                if index + 2 < normalizedParams.count, normalizedParams[index + 1] == 5 {
                    style.foreground = .indexed(normalizedParams[index + 2])
                    index += 2
                } else if index + 4 < normalizedParams.count, normalizedParams[index + 1] == 2 {
                    style.foreground = .rgb(
                        normalizedParams[index + 2],
                        normalizedParams[index + 3],
                        normalizedParams[index + 4]
                    )
                    index += 4
                }
            case 39:
                style.foreground = .default
            case 90...97:
                style.foreground = .indexed(value - 90 + 8)
            default:
                break
            }
            index += 1
        }
    }

    private func promptCharacters(
        after marker: String,
        in characters: [PromptPaneStyledCharacter]
    ) -> [PromptPaneStyledCharacter] {
        var index = 0
        while index < characters.count, characters[index].character.isWhitespace {
            index += 1
        }

        for markerCharacter in marker {
            guard index < characters.count, characters[index].character == markerCharacter else {
                return []
            }
            index += 1
        }

        while index < characters.count, characters[index].character.isWhitespace {
            index += 1
        }

        return Array(characters[index...])
    }

    private func promptTextLooksLikePlaceholder(_ characters: [PromptPaneStyledCharacter]) -> Bool {
        let visibleCharacters = characters.filter { !$0.character.isWhitespace }
        guard !visibleCharacters.isEmpty else { return false }

        let placeholderLikeCount = visibleCharacters.reduce(into: 0) { count, character in
            if character.style.looksPlaceholderLike {
                count += 1
            }
        }

        return placeholderLikeCount * 100 >= visibleCharacters.count * 80
    }

    private func promptContinuationText(
        from line: PromptPaneLine,
        markers: [String]
    ) -> String? {
        let plainText = line.plainText
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !isBottomPinnedAuxiliaryLine(trimmed) else { return nil }
        guard !line.rawText.contains("\u{001B}") else { return nil }

        let leftTrimmed = plainText.drop(while: { $0.isWhitespace })
        let leftTrimmedText = String(leftTrimmed)
        guard markers.allSatisfy({ !leftTrimmedText.hasPrefix($0) }) else { return nil }

        let leadingWhitespaceCount = plainText.prefix(while: { $0.isWhitespace }).count
        guard leadingWhitespaceCount >= 2 else { return nil }

        return trimmed
    }

    private func templatePlaceholderPrefix(from promptText: String) -> String? {
        for (open, close) in [("(", ")"), ("{", "}"), ("[", "]"), ("<", ">")] {
            guard let openCharacter = open.first,
                  promptText.hasSuffix(close),
                  let openIndex = promptText.lastIndex(of: openCharacter) else { continue }
            let prefix = promptText[..<openIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return prefix
            }
        }
        return nil
    }

    private func extractTemplatePlaceholder(from promptText: String) -> String? {
        for (open, close) in [("(", ")"), ("{", "}"), ("[", "]"), ("<", ">")] {
            guard let openCharacter = open.first,
                  promptText.hasSuffix(close),
                  let openIndex = promptText.lastIndex(of: openCharacter) else { continue }
            let placeholderStart = promptText.index(after: openIndex)
            let placeholderEnd = promptText.index(before: promptText.endIndex)
            guard placeholderStart < placeholderEnd else { continue }
            let placeholder = promptText[placeholderStart..<placeholderEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !placeholder.isEmpty {
                return placeholder
            }
        }
        return nil
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
            bringPromptTOCOverlayToFront()
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

    func bringPromptTOCOverlayToFront() {
        guard let tocView = promptTOCView, tocView.superview === terminalContainer else { return }
        terminalContainer.addSubview(tocView, positioned: .above, relativeTo: nil)
    }

    private func sanitizedDefaultsKeySegment(_ text: String) -> String {
        text.map { char in
            char.isLetter || char.isNumber ? char : "_"
        }.reduce(into: "") { $0.append($1) }
    }
}

private final class PromptTOCEntryRowView: NSView {
    let entryIndex: Int
    private let label: NSTextField
    private var showsAlternateBackground = false
    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    init(entryIndex: Int, text: String) {
        self.entryIndex = entryIndex
        self.label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAlternateBackgroundVisible(_ isVisible: Bool) {
        showsAlternateBackground = isVisible
        updateAppearance()
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(resource: .textPrimary)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }

        if isSelected {
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            layer.borderWidth = 1
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            return
        }

        layer.borderWidth = 0
        layer.borderColor = nil
        layer.backgroundColor = showsAlternateBackground
            ? NSColor.separatorColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }
}

final class PromptTableOfContentsView: NSView {
    var onSelectEntry: ((Int) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onDragGesture: ((NSPanGestureRecognizer) -> Void)?
    var onResizeGesture: ((NSPanGestureRecognizer) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Table of Contents")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No prompts yet")
    private let spinner = NSProgressIndicator()
    private let resizeHandle = NSImageView()
    private let closeButton = NSButton()
    private var rowViews: [PromptTOCEntryRowView] = []
    private var selectedEntryIndex: Int?

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
        let previousSelection = selectedEntryIndex
        subtitleLabel.stringValue = subtitle(forCount: entries.count, agentType: agentType)
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        clearRows()

        guard !entries.isEmpty else {
            selectedEntryIndex = nil
            emptyLabel.stringValue = "No prompts yet"
            emptyLabel.isHidden = false
            return
        }

        emptyLabel.isHidden = true
        for (index, entry) in entries.enumerated() {
            let row = PromptTOCEntryRowView(
                entryIndex: index,
                text: "\(index + 1). \(entry.displayText)"
            )
            row.setAlternateBackgroundVisible(!index.isMultiple(of: 2))

            let tap = NSClickGestureRecognizer(target: self, action: #selector(handleEntryRowTap(_:)))
            row.addGestureRecognizer(tap)

            rowsStack.addArrangedSubview(row)
            rowViews.append(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor),
            ])
        }

        if let previousSelection, previousSelection < rowViews.count {
            updateSelection(for: previousSelection)
        } else {
            selectedEntryIndex = nil
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

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Hide Table of Contents"
        )
        closeButton.contentTintColor = NSColor(resource: .textSecondary)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.toolTip = "Hide Table of Contents"
        closeButton.target = self
        closeButton.action = #selector(handleCloseButtonTapped)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.spacing = 1
        textStack.alignment = .leading

        let headerStack = NSStackView(views: [headerIcon, textStack, NSView(), spinner, closeButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        headerStack.addGestureRecognizer(pan)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
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
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = rowsContainer
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        rowsContainer.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

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
        rowViews.removeAll()
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
        guard let row = gesture.view as? PromptTOCEntryRowView else { return }
        updateSelection(for: row.entryIndex)
        onSelectEntry?(row.entryIndex)
    }

    @objc private func handleDrag(_ gesture: NSPanGestureRecognizer) {
        onDragGesture?(gesture)
    }

    @objc private func handleCloseButtonTapped() {
        onCloseRequested?()
    }

    @objc private func handleResize(_ gesture: NSPanGestureRecognizer) {
        onResizeGesture?(gesture)
    }

    private func updateSelection(for entryIndex: Int) {
        selectedEntryIndex = entryIndex
        for row in rowViews {
            row.isSelected = row.entryIndex == entryIndex
        }
    }
}
