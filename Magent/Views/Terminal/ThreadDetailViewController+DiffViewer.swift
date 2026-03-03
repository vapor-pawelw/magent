import Cocoa

extension ThreadDetailViewController {

    // MARK: - Inline Diff Viewer

    func showDiffViewer(scrollToFile: String? = nil) {
        NSLog("[DiffViewer] showDiffViewer called, scrollToFile=%@, diffVC=%@, isLoading=%d, view.window=%@",
              scrollToFile ?? "nil", String(describing: diffVC), isLoadingDiffViewer ? 1 : 0,
              String(describing: view.window))

        if let existing = diffVC {
            if let file = scrollToFile {
                existing.expandFile(file, collapseOthers: false)
            }
            return
        }

        // Prevent duplicate creation if async load is already in progress
        guard !isLoadingDiffViewer else { return }
        isLoadingDiffViewer = true

        let baseBranch = threadManager.resolveBaseBranch(for: thread)
        let worktreePath = thread.worktreePath
        NSLog("[DiffViewer] starting async load, baseBranch=%@, worktreePath=%@", baseBranch, worktreePath)
        Task {
            async let diffContentTask = GitService.shared.diffContent(
                worktreePath: worktreePath,
                baseBranch: baseBranch
            )
            async let mergeBaseTask = GitService.shared.mergeBase(
                worktreePath: worktreePath,
                baseBranch: baseBranch
            )

            guard let diffContent = await diffContentTask else {
                NSLog("[DiffViewer] diffContent is nil, aborting")
                isLoadingDiffViewer = false
                return
            }
            let mergeBase = await mergeBaseTask
            NSLog("[DiffViewer] got diffContent (%d chars), mergeBase=%@", diffContent.count, mergeBase ?? "nil")

            let entries = await threadManager.refreshDiffStats(for: thread.id)
            let fileCount = entries.count
            NSLog("[DiffViewer] got %d entries, entering MainActor", fileCount)

            await MainActor.run {
                NSLog("[DiffViewer] MainActor.run start, diffVC=%@, view.window=%@",
                      String(describing: diffVC), String(describing: view.window))

                // Double-check diffVC wasn't created while we were loading
                guard diffVC == nil else {
                    isLoadingDiffViewer = false
                    if let file = scrollToFile {
                        diffVC?.expandFile(file, collapseOthers: false)
                    }
                    return
                }

                let vc = InlineDiffViewController()
                vc.onClose = { [weak self] in
                    self?.hideDiffViewer()
                }
                vc.onResizeDrag = { [weak self] phase, delta in
                    self?.handleDiffResizeDrag(phase: phase, delta: delta)
                }
                NSLog("[DiffViewer] addChild")
                addChild(vc)

                NSLog("[DiffViewer] accessing vc.view")
                let diffView = vc.view
                diffView.translatesAutoresizingMaskIntoConstraints = false
                NSLog("[DiffViewer] adding diffView to view hierarchy")
                view.addSubview(diffView)

                // Calculate default height (70% of available space)
                let availableHeight = terminalContainer.frame.height
                let savedHeight = UserDefaults.standard.object(forKey: Self.diffHeightKey) as? CGFloat
                let defaultHeight = availableHeight * Self.diffDefaultRatio
                let height = savedHeight ?? defaultHeight
                let clampedHeight = max(min(height, availableHeight - 60), Self.diffMinHeight)
                NSLog("[DiffViewer] availableHeight=%.1f, clampedHeight=%.1f", availableHeight, clampedHeight)

                // Deactivate old bottom constraint, create new ones
                NSLog("[DiffViewer] deactivating terminalBottomToView, activating new constraints")
                terminalBottomToView?.isActive = false
                terminalBottomToDiff = terminalContainer.bottomAnchor.constraint(equalTo: diffView.topAnchor)
                diffHeightConstraint = diffView.heightAnchor.constraint(equalToConstant: clampedHeight)

                NSLayoutConstraint.activate([
                    terminalBottomToDiff!,
                    diffView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    diffView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    diffView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    diffHeightConstraint!,
                ])
                NSLog("[DiffViewer] constraints activated")

                NSLog("[DiffViewer] calling setDiffContent")
                vc.setDiffContent(diffContent, fileCount: fileCount, worktreePath: worktreePath, mergeBase: mergeBase)
                diffVC = vc
                isLoadingDiffViewer = false
                NSLog("[DiffViewer] setDiffContent done")

                if let file = scrollToFile {
                    DispatchQueue.main.async {
                        NSLog("[DiffViewer] expandFile %@", file)
                        vc.expandFile(file, collapseOthers: false)
                        NSLog("[DiffViewer] expandFile done")
                    }
                } else {
                    NSLog("[DiffViewer] expandAll")
                    vc.expandAll()
                    NSLog("[DiffViewer] expandAll done")
                }
                NSLog("[DiffViewer] showDiffViewer complete")
            }
        }
    }

    func hideDiffViewer() {
        guard let vc = diffVC else { return }
        // Save height before removing
        if let h = diffHeightConstraint?.constant {
            UserDefaults.standard.set(h, forKey: Self.diffHeightKey)
        }
        terminalBottomToDiff?.isActive = false
        diffHeightConstraint?.isActive = false
        vc.view.removeFromSuperview()
        vc.removeFromParent()
        diffVC = nil
        isLoadingDiffViewer = false

        terminalBottomToView?.isActive = true
    }

    func refreshDiffViewerIfVisible() {
        guard diffVC != nil else { return }
        let baseBranch = threadManager.resolveBaseBranch(for: thread)
        let worktreePath = thread.worktreePath
        Task {
            async let diffContentTask = GitService.shared.diffContent(
                worktreePath: worktreePath,
                baseBranch: baseBranch
            )
            async let mergeBaseTask = GitService.shared.mergeBase(
                worktreePath: worktreePath,
                baseBranch: baseBranch
            )

            let diffContent = await diffContentTask
            let mergeBase = await mergeBaseTask
            let entries = await threadManager.refreshDiffStats(for: thread.id)

            await MainActor.run {
                if let content = diffContent {
                    self.diffVC?.setDiffContent(content, fileCount: entries.count, worktreePath: worktreePath, mergeBase: mergeBase)
                } else {
                    // No more changes — auto-dismiss
                    self.hideDiffViewer()
                }
            }
        }
    }

    func handleDiffResizeDrag(phase: NSPanGestureRecognizer.State, delta: CGFloat) {
        switch phase {
        case .began:
            isDiffDragging = true
            diffDragStartHeight = diffHeightConstraint?.constant ?? 200

        case .changed:
            let currentHeight = diffHeightConstraint?.constant ?? 200
            let availableHeight = terminalContainer.frame.height + currentHeight
            let maxHeight = availableHeight - 60
            let newHeight = max(min(currentHeight + delta, maxHeight), Self.diffMinHeight)
            diffHeightConstraint?.constant = newHeight

        case .ended, .cancelled:
            isDiffDragging = false
            if let h = diffHeightConstraint?.constant {
                UserDefaults.standard.set(h, forKey: Self.diffHeightKey)
            }

        default:
            break
        }
    }
}
