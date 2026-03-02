import Cocoa

final class SettingsSectionCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let blended = NSColor(resource: .surface).blended(withFraction: 0.2, of: NSColor(resource: .appBackground))
        layer?.backgroundColor = (blended ?? NSColor(resource: .surface)).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }
}
