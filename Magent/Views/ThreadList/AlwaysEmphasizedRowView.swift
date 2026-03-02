import Cocoa

final class AlwaysEmphasizedRowView: NSTableRowView {
    var showsCompletionHighlight = false {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsCompletionHighlight, !isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}
