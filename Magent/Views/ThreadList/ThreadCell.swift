import Cocoa

final class ThreadCell: NSTableCellView {

    private var pinImageView: NSImageView?
    private var completionImageView: NSImageView?
    private var trailingStackView: NSStackView?

    func configure(with thread: MagentThread, sectionColor: NSColor?) {
        textField?.stringValue = thread.name
        textField?.font = thread.hasUnreadAgentCompletion
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .preferredFont(forTextStyle: .body)

        imageView?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        imageView?.contentTintColor = thread.hasUnreadAgentCompletion
            ? NSColor.controlAccentColor
            : (sectionColor ?? NSColor(resource: .primaryBrand))

        if trailingStackView == nil {
            let pinIV = NSImageView()
            pinIV.translatesAutoresizingMaskIntoConstraints = false
            pinIV.setContentHuggingPriority(.required, for: .horizontal)

            let completionIV = NSImageView()
            completionIV.translatesAutoresizingMaskIntoConstraints = false
            completionIV.setContentHuggingPriority(.required, for: .horizontal)

            let stack = NSStackView(views: [completionIV, pinIV])
            stack.orientation = .horizontal
            stack.spacing = 3
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                pinIV.widthAnchor.constraint(equalToConstant: 12),
                pinIV.heightAnchor.constraint(equalToConstant: 12),
                completionIV.widthAnchor.constraint(equalToConstant: 10),
                completionIV.heightAnchor.constraint(equalToConstant: 10),
            ])
            trailingStackView = stack
            pinImageView = pinIV
            completionImageView = completionIV
        }
        if thread.isPinned {
            pinImageView?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            pinImageView?.contentTintColor = .tertiaryLabelColor
            pinImageView?.isHidden = false
        } else {
            pinImageView?.image = nil
            pinImageView?.isHidden = true
        }

        if thread.hasUnreadAgentCompletion {
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.isHidden = false
        } else {
            completionImageView?.image = nil
            completionImageView?.isHidden = true
        }
    }

    func configureAsMain(isUnreadCompletion: Bool = false) {
        textField?.stringValue = "Main"
        textField?.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isUnreadCompletion ? .semibold : .regular
        )

        imageView?.image = nil
        imageView?.isHidden = true
        completionImageView?.isHidden = true
        pinImageView?.isHidden = true
    }
}
