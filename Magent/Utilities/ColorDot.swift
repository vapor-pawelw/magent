import AppKit

/// Creates a circular color dot image of the given size.
func colorDotImage(color: NSColor, size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }
}
