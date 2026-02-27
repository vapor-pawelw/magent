import Cocoa

final class ThreadCell: NSTableCellView {

    private var pinImageView: NSImageView?
    private var completionImageView: NSImageView?
    private var busySpinner: NSProgressIndicator?
    private var trailingStackView: NSStackView?
    private var hasInstalledTextTrailingConstraint = false

    private func ensureTrailingStack() {
        guard trailingStackView == nil else { return }

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

        let stack = NSStackView(views: [pinIV, spinner, completionIV])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            pinIV.widthAnchor.constraint(equalToConstant: 12),
            pinIV.heightAnchor.constraint(equalToConstant: 12),
            completionIV.widthAnchor.constraint(equalToConstant: 10),
            completionIV.heightAnchor.constraint(equalToConstant: 10),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        trailingStackView = stack
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
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent needs input")
            completionImageView?.contentTintColor = .systemOrange
            completionImageView?.isHidden = false
        } else if thread.hasAgentBusy {
            busySpinner?.startAnimation(nil)
            busySpinner?.isHidden = false
            completionImageView?.image = nil
            completionImageView?.isHidden = true
        } else if thread.hasUnreadAgentCompletion {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.isHidden = false
        } else {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            completionImageView?.image = nil
            completionImageView?.isHidden = true
        }
    }

    func configureAsMain(isUnreadCompletion: Bool = false, isBusy: Bool = false, isWaitingForInput: Bool = false) {
        textField?.stringValue = "Main"
        textField?.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isUnreadCompletion ? .semibold : .regular
        )

        imageView?.image = nil
        imageView?.isHidden = true

        ensureTrailingStack()
        pinImageView?.isHidden = true

        if isWaitingForInput {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent needs input")
            completionImageView?.contentTintColor = .systemOrange
            completionImageView?.isHidden = false
        } else if isBusy {
            busySpinner?.startAnimation(nil)
            busySpinner?.isHidden = false
            completionImageView?.image = nil
            completionImageView?.isHidden = true
        } else if isUnreadCompletion {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.isHidden = false
        } else {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            completionImageView?.image = nil
            completionImageView?.isHidden = true
        }
    }
}
