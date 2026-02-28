import Cocoa

final class ThreadCell: NSTableCellView {

    private var dirtyImageView: NSImageView?
    private var pinImageView: NSImageView?
    private var completionImageView: NSImageView?
    private var busySpinner: NSProgressIndicator?
    private var trailingStackView: NSStackView?
    private var hasInstalledTextTrailingConstraint = false

    private func ensureTrailingStack() {
        guard trailingStackView == nil else { return }

        let dirtyIV = NSImageView()
        dirtyIV.translatesAutoresizingMaskIntoConstraints = false
        dirtyIV.setContentHuggingPriority(.required, for: .horizontal)
        dirtyIV.isHidden = true

        let pinIV = NSImageView()
        pinIV.translatesAutoresizingMaskIntoConstraints = false
        pinIV.setContentHuggingPriority(.required, for: .horizontal)

        let completionIV = NSImageView()
        completionIV.translatesAutoresizingMaskIntoConstraints = false
        completionIV.setContentHuggingPriority(.required, for: .horizontal)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.isHidden = true

        let stack = NSStackView(views: [dirtyIV, pinIV, spinner, completionIV])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -(ThreadListViewController.projectDisclosureTrailingInset + ThreadListViewController.disclosureButtonSize / 2)),
            dirtyIV.widthAnchor.constraint(equalToConstant: 7),
            dirtyIV.heightAnchor.constraint(equalToConstant: 7),
            pinIV.widthAnchor.constraint(equalToConstant: 12),
            pinIV.heightAnchor.constraint(equalToConstant: 12),
            completionIV.widthAnchor.constraint(equalToConstant: 10),
            completionIV.heightAnchor.constraint(equalToConstant: 10),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        trailingStackView = stack
        dirtyImageView = dirtyIV
        pinImageView = pinIV
        completionImageView = completionIV
        busySpinner = spinner

        if !hasInstalledTextTrailingConstraint, let textField {
            textField.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                textField.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -6),
            ])
            hasInstalledTextTrailingConstraint = true
        }
    }

    func configure(with thread: MagentThread, sectionColor: NSColor?) {
        textField?.stringValue = thread.name
        textField?.font = thread.hasUnreadAgentCompletion
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .preferredFont(forTextStyle: .body)

        imageView?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        imageView?.contentTintColor = thread.hasUnreadAgentCompletion
            ? NSColor.controlAccentColor
            : (sectionColor ?? NSColor(resource: .primaryBrand))

        ensureTrailingStack()

        if thread.isDirty {
            dirtyImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Uncommitted changes")
            dirtyImageView?.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.7)
            dirtyImageView?.toolTip = "Uncommitted changes"
            dirtyImageView?.isHidden = false
        } else {
            dirtyImageView?.image = nil
            dirtyImageView?.toolTip = nil
            dirtyImageView?.isHidden = true
        }

        if thread.isPinned {
            pinImageView?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            pinImageView?.contentTintColor = .tertiaryLabelColor
            pinImageView?.isHidden = false
        } else {
            pinImageView?.image = nil
            pinImageView?.isHidden = true
        }

        if thread.hasWaitingForInput {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            completionImageView?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Agent needs input")
            completionImageView?.contentTintColor = .systemYellow
            completionImageView?.toolTip = "Agent needs input"
            completionImageView?.isHidden = false
        } else if thread.hasAgentBusy {
            busySpinner?.startAnimation(nil)
            busySpinner?.isHidden = false
            busySpinner?.toolTip = "Agent working"
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if thread.hasUnreadAgentCompletion {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.toolTip = "Agent finished"
            completionImageView?.isHidden = false
        } else {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        }
    }

    func configureAsMain(isUnreadCompletion: Bool = false, isBusy: Bool = false, isWaitingForInput: Bool = false, isDirty: Bool = false) {
        textField?.stringValue = "Main"
        textField?.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isUnreadCompletion ? .semibold : .regular
        )

        imageView?.image = nil
        imageView?.isHidden = true

        ensureTrailingStack()
        pinImageView?.isHidden = true

        if isDirty {
            dirtyImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Uncommitted changes")
            dirtyImageView?.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.7)
            dirtyImageView?.toolTip = "Uncommitted changes"
            dirtyImageView?.isHidden = false
        } else {
            dirtyImageView?.image = nil
            dirtyImageView?.toolTip = nil
            dirtyImageView?.isHidden = true
        }

        if isWaitingForInput {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            completionImageView?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Agent needs input")
            completionImageView?.contentTintColor = .systemYellow
            completionImageView?.toolTip = "Agent needs input"
            completionImageView?.isHidden = false
        } else if isBusy {
            busySpinner?.startAnimation(nil)
            busySpinner?.isHidden = false
            busySpinner?.toolTip = "Agent working"
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if isUnreadCompletion {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.toolTip = "Agent finished"
            completionImageView?.isHidden = false
        } else {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        }
    }
}
