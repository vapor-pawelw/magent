import Cocoa

final class ThreadCell: NSTableCellView {

    func configure(with thread: MagentThread, sectionColor: NSColor?) {
        textField?.stringValue = thread.name
        textField?.font = .preferredFont(forTextStyle: .body)

        imageView?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        imageView?.contentTintColor = sectionColor ?? NSColor(resource: .primaryBrand)
    }

    func configureAsMain() {
        textField?.stringValue = "Main"
        textField?.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        imageView?.image = nil
        imageView?.isHidden = true
    }
}
