import Cocoa
import MagentCore

final class DiffImageOverlayView: NSView {
    private let dimView = NSView()
    private let imageCardView = NSView()
    private let imageView = NSImageView()
    private let sourceRectProvider: () -> NSRect?
    private let initialSourceRect: NSRect
    private let image: NSImage
    private var isPresented = false
    private var isDismissing = false

    var onDismiss: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage, sourceRect: NSRect, sourceRectProvider: @escaping () -> NSRect?) {
        self.image = image
        self.initialSourceRect = sourceRect
        self.sourceRectProvider = sourceRectProvider
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.zPosition = 500
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dimView.frame = bounds
        if isPresented, !isDismissing {
            imageCardView.frame = targetFrame(for: bounds)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss(animated: true)
            return
        }
        super.keyDown(with: event)
    }

    func present() {
        layoutSubtreeIfNeeded()
        imageCardView.frame = initialSourceRect
        dimView.alphaValue = 0
        alphaValue = 1
        window?.makeFirstResponder(self)

        let targetFrame = targetFrame(for: bounds)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dimView.animator().alphaValue = 1
            imageCardView.animator().frame = targetFrame
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isPresented = true
            }
        }
    }

    func dismiss(animated: Bool) {
        guard !isDismissing else { return }
        isDismissing = true

        guard animated else {
            finishDismissal()
            return
        }

        let targetRect = sourceRectProvider() ?? initialSourceRect
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dimView.animator().alphaValue = 0
            imageCardView.animator().frame = targetRect
        } completionHandler: {
            Task { @MainActor [weak self] in
                self?.finishDismissal()
            }
        }
    }

    private func setup() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleOverlayClick))
        addGestureRecognizer(click)

        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        dimView.alphaValue = 0
        dimView.autoresizingMask = [.width, .height]
        addSubview(dimView)

        imageCardView.wantsLayer = true
        imageCardView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.35).cgColor
        imageCardView.layer?.shadowOpacity = 1
        imageCardView.layer?.shadowRadius = 30
        imageCardView.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(imageCardView)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.frame = imageCardView.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageCardView.addSubview(imageView)
    }

    @objc private func handleOverlayClick() {
        dismiss(animated: true)
    }

    @MainActor
    private func finishDismissal() {
        removeFromSuperview()
        onDismiss?()
    }

    private func targetFrame(for bounds: NSRect) -> NSRect {
        let horizontalInset = min(max(bounds.width * 0.08, 32), 96)
        let verticalInset = min(max(bounds.height * 0.1, 32), 120)
        let availableRect = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        guard availableRect.width > 0, availableRect.height > 0 else { return initialSourceRect }

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return availableRect }

        let scale = min(
            availableRect.width / imageSize.width,
            availableRect.height / imageSize.height,
            1
        )
        let renderedSize = NSSize(
            width: max(imageSize.width * scale, 120),
            height: max(imageSize.height * scale, 120)
        )
        return NSRect(
            x: availableRect.midX - renderedSize.width / 2,
            y: availableRect.midY - renderedSize.height / 2,
            width: min(renderedSize.width, availableRect.width),
            height: min(renderedSize.height, availableRect.height)
        ).integral
    }
}

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

        let worktreePath = thread.worktreePath
        let baseBranch = thread.isMain ? nil : threadManager.resolveBaseBranch(for: thread)
        NSLog("[DiffViewer] starting async load, baseBranch=%@, worktreePath=%@",
              baseBranch ?? "HEAD", worktreePath)
        Task {
            let diffContent: String?
            let mergeBase: String?
            let entries: [FileDiffEntry]

            if let baseBranch {
                async let diffContentTask = GitService.shared.diffContent(
                    worktreePath: worktreePath,
                    baseBranch: baseBranch
                )
                async let mergeBaseTask = GitService.shared.mergeBase(
                    worktreePath: worktreePath,
                    baseBranch: baseBranch
                )
                async let entriesTask = threadManager.refreshDiffStats(for: thread.id)
                diffContent = await diffContentTask
                mergeBase = await mergeBaseTask
                entries = await entriesTask
            } else {
                async let diffContentTask = GitService.shared.workingTreeDiffContent(worktreePath: worktreePath)
                async let entriesTask = GitService.shared.workingTreeDiffStats(worktreePath: worktreePath)
                diffContent = await diffContentTask
                mergeBase = "HEAD"
                entries = await entriesTask
            }

            guard let diffContent else {
                NSLog("[DiffViewer] diffContent is nil, aborting")
                isLoadingDiffViewer = false
                return
            }
            NSLog("[DiffViewer] got diffContent (%d chars), mergeBase=%@", diffContent.count, mergeBase ?? "nil")

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
                vc.onImageClick = { [weak self] imageView, image in
                    self?.presentDiffImageOverlay(from: imageView, image: image)
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
        dismissDiffImageOverlay(animated: false)
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
        let worktreePath = thread.worktreePath
        let baseBranch = thread.isMain ? nil : threadManager.resolveBaseBranch(for: thread)
        Task {
            let diffContent: String?
            let mergeBase: String?
            let entries: [FileDiffEntry]

            if let baseBranch {
                async let diffContentTask = GitService.shared.diffContent(
                    worktreePath: worktreePath,
                    baseBranch: baseBranch
                )
                async let mergeBaseTask = GitService.shared.mergeBase(
                    worktreePath: worktreePath,
                    baseBranch: baseBranch
                )
                async let entriesTask = threadManager.refreshDiffStats(for: thread.id)
                diffContent = await diffContentTask
                mergeBase = await mergeBaseTask
                entries = await entriesTask
            } else {
                async let diffContentTask = GitService.shared.workingTreeDiffContent(worktreePath: worktreePath)
                async let entriesTask = GitService.shared.workingTreeDiffStats(worktreePath: worktreePath)
                diffContent = await diffContentTask
                mergeBase = "HEAD"
                entries = await entriesTask
            }

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

    func presentDiffImageOverlay(from sourceImageView: NSImageView, image: NSImage) {
        dismissDiffImageOverlay(animated: false)

        let hostView = view.window?.contentView ?? view

        let sourceRectProvider: () -> NSRect? = { [weak sourceImageView, weak hostView] in
            guard let sourceImageView, let hostView, sourceImageView.window === hostView.window else { return nil }
            let rectInWindow = sourceImageView.convert(sourceImageView.bounds, to: nil)
            return hostView.convert(rectInWindow, from: nil)
        }

        guard let sourceRect = sourceRectProvider() else { return }

        let overlay = DiffImageOverlayView(
            image: image,
            sourceRect: sourceRect,
            sourceRectProvider: sourceRectProvider
        )
        overlay.onDismiss = { [weak self, weak overlay] in
            guard let self, let overlay, self.diffImageOverlay === overlay else { return }
            self.diffImageOverlay = nil
        }

        hostView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        hostView.layoutSubtreeIfNeeded()

        diffImageOverlay = overlay
        overlay.present()
    }

    func dismissDiffImageOverlay(animated: Bool) {
        diffImageOverlay?.dismiss(animated: animated)
    }
}
