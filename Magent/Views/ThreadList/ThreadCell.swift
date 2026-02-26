import Cocoa

final class ThreadCell: NSTableCellView {

    private var pinImageView: NSImageView?

    func configure(with thread: MagentThread, sectionColor: NSColor?) {
        textField?.stringValue = thread.name
        textField?.font = .preferredFont(forTextStyle: .body)

        imageView?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        imageView?.contentTintColor = sectionColor ?? NSColor(resource: .primaryBrand)

        if pinImageView == nil {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerYAnchor.constraint(equalTo: centerYAnchor),
                iv.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                iv.widthAnchor.constraint(equalToConstant: 12),
                iv.heightAnchor.constraint(equalToConstant: 12),
            ])
            pinImageView = iv
        }
        if thread.isPinned {
            pinImageView?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
            pinImageView?.contentTintColor = .tertiaryLabelColor
            pinImageView?.isHidden = false
        } else {
            pinImageView?.image = nil
            pinImageView?.isHidden = true
        }
    }

    func configureAsMain() {
        textField?.stringValue = "Main"
        textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        imageView?.image = nil
        imageView?.isHidden = true
    }
}
