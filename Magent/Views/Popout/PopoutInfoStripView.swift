import Cocoa
import MagentCore

/// Thin info bar (48pt) displayed at the top of pop-out windows.
/// Shows thread identity, branch, status, and optional tab name.
final class PopoutInfoStripView: NSView {
    private let threadIconView = NSImageView()
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let jiraLabel = NSTextField(labelWithString: "")
    private let prLabel = NSTextField(labelWithString: "")
    private let statusIndicator = NSImageView()
    private let busySpinner = NSProgressIndicator()
    private let bottomBorder = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        // Thread icon
        threadIconView.translatesAutoresizingMaskIntoConstraints = false
        threadIconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(threadIconView)

        // Description label (line 1)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 1
        addSubview(descriptionLabel)

        // Branch label (line 2)
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.font = .systemFont(ofSize: 11)
        branchLabel.lineBreakMode = .byTruncatingHead
        branchLabel.maximumNumberOfLines = 1
        addSubview(branchLabel)

        // Dirty dot
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3.5
        dirtyDot.isHidden = true
        addSubview(dirtyDot)

        // Jira label (line 2)
        jiraLabel.translatesAutoresizingMaskIntoConstraints = false
        jiraLabel.font = .systemFont(ofSize: 10)
        jiraLabel.isHidden = true
        addSubview(jiraLabel)

        // PR label (line 2)
        prLabel.translatesAutoresizingMaskIntoConstraints = false
        prLabel.font = .systemFont(ofSize: 10)
        prLabel.isHidden = true
        addSubview(prLabel)

        // Status indicator
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.imageScaling = .scaleProportionallyUpOrDown
        statusIndicator.isHidden = true
        addSubview(statusIndicator)

        // Busy spinner
        busySpinner.translatesAutoresizingMaskIntoConstraints = false
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isIndeterminate = true
        busySpinner.isHidden = true
        addSubview(busySpinner)

        // Bottom border
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        addSubview(bottomBorder)

        NSLayoutConstraint.activate([
            // Line 1
            threadIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            threadIconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            threadIconView.widthAnchor.constraint(equalToConstant: 16),
            threadIconView.heightAnchor.constraint(equalToConstant: 16),

            descriptionLabel.leadingAnchor.constraint(equalTo: threadIconView.trailingAnchor, constant: 6),
            descriptionLabel.centerYAnchor.constraint(equalTo: threadIconView.centerYAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusIndicator.leadingAnchor, constant: -8),

            statusIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusIndicator.centerYAnchor.constraint(equalTo: threadIconView.centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: 14),
            statusIndicator.heightAnchor.constraint(equalToConstant: 14),

            busySpinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            busySpinner.centerYAnchor.constraint(equalTo: threadIconView.centerYAnchor),
            busySpinner.widthAnchor.constraint(equalToConstant: 14),
            busySpinner.heightAnchor.constraint(equalToConstant: 14),

            // Line 2
            branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            branchLabel.topAnchor.constraint(equalTo: threadIconView.bottomAnchor, constant: 2),
            branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            dirtyDot.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 4),
            dirtyDot.centerYAnchor.constraint(equalTo: branchLabel.centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 7),
            dirtyDot.heightAnchor.constraint(equalToConstant: 7),

            // Bottom border
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor(resource: .surface).withAlphaComponent(0.85).cgColor
            self.bottomBorder.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            self.dirtyDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            self.descriptionLabel.textColor = NSColor(resource: .textPrimary)
            self.branchLabel.textColor = NSColor(resource: .textSecondary)
            self.jiraLabel.textColor = .controlAccentColor
            self.prLabel.textColor = .controlAccentColor
        }
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - Refresh

    func refresh(from thread: MagentThread) {
        threadIconView.image = NSImage(systemSymbolName: thread.threadIcon.symbolName, accessibilityDescription: nil)
        threadIconView.contentTintColor = .controlAccentColor

        descriptionLabel.stringValue = thread.taskDescription ?? thread.name
        branchLabel.stringValue = thread.currentBranch
        dirtyDot.isHidden = !thread.isDirty

        // Jira
        if let ticket = thread.jiraTicketKey {
            jiraLabel.stringValue = ticket
            jiraLabel.isHidden = false
        } else {
            jiraLabel.isHidden = true
        }

        // PR
        if let prInfo = thread.pullRequestInfo {
            prLabel.stringValue = "#\(prInfo.number)"
            prLabel.isHidden = false
        } else {
            prLabel.isHidden = true
        }

        // Status (priority: busy > rate-limit > waiting > completion > hidden)
        updateStatusIndicator(thread: thread)
    }

    func configureForTab(thread: MagentThread, sessionName: String) {
        let tabIndex = thread.tmuxSessionNames.firstIndex(of: sessionName).map { $0 + 1 } ?? 1
        let threadName = thread.taskDescription ?? thread.name
        descriptionLabel.stringValue = "\(threadName) — Tab \(tabIndex)"
        branchLabel.stringValue = thread.currentBranch
        dirtyDot.isHidden = !thread.isDirty
        threadIconView.image = NSImage(systemSymbolName: thread.threadIcon.symbolName, accessibilityDescription: nil)
        threadIconView.contentTintColor = .controlAccentColor

        // PR info for tab popout
        if let prInfo = thread.pullRequestInfo {
            prLabel.stringValue = "#\(prInfo.number)"
            prLabel.isHidden = false
        } else {
            prLabel.isHidden = true
        }

        updateStatusIndicator(thread: thread)
    }

    private func updateStatusIndicator(thread: MagentThread) {
        if thread.isAnyBusy {
            statusIndicator.isHidden = true
            busySpinner.isHidden = false
            busySpinner.startAnimation(nil)
        } else if thread.isBlockedByRateLimit {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            statusIndicator.isHidden = false
            if thread.isRateLimitPropagatedOnly {
                statusIndicator.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Rate limited (propagated)")
                statusIndicator.contentTintColor = .systemOrange
            } else {
                statusIndicator.image = NSImage(systemSymbolName: "hourglass.circle.fill", accessibilityDescription: "Rate limited")
                statusIndicator.contentTintColor = .systemRed
            }
        } else if thread.hasWaitingForInput {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            statusIndicator.isHidden = false
            statusIndicator.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Waiting for input")
            statusIndicator.contentTintColor = .systemYellow
        } else if thread.hasUnreadAgentCompletion {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            statusIndicator.isHidden = false
            statusIndicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Completed")
            statusIndicator.contentTintColor = .systemGreen
        } else {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            statusIndicator.isHidden = true
        }
    }
}
