import AppKit

/// Creates a titled text-editing section with a resizable text view.
///
/// Returns the `NSTextView` so callers can read its value later.
func createSettingsSection(
    in stackView: NSStackView,
    title: String,
    description: String,
    value: String,
    font: NSFont,
    titleFontSize: CGFloat = 14,
    delegate: (any NSTextViewDelegate)?
) -> NSTextView {
    let sectionStack = NSStackView()
    sectionStack.orientation = .vertical
    sectionStack.alignment = .leading
    sectionStack.spacing = 4

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: titleFontSize, weight: .semibold)
    sectionStack.addArrangedSubview(titleLabel)

    let descLabel = NSTextField(wrappingLabelWithString: description)
    descLabel.font = .systemFont(ofSize: 11)
    descLabel.textColor = NSColor(resource: .textSecondary)
    sectionStack.addArrangedSubview(descLabel)

    let textView = NSTextView()
    textView.font = font
    textView.string = value
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.delegate = delegate
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 4, height: 4)

    let textScrollView = NonCapturingScrollView()
    textScrollView.documentView = textView
    textScrollView.hasVerticalScroller = true
    textScrollView.autohidesScrollers = true
    textScrollView.borderType = .bezelBorder
    textScrollView.translatesAutoresizingMaskIntoConstraints = false

    let lineHeight = font.ascender + abs(font.descender) + font.leading
    let height = max(lineHeight * 3 + 12, 56)

    let container = ResizableTextContainer(scrollView: textScrollView, minHeight: height)
    sectionStack.addArrangedSubview(container)
    sectionStack.translatesAutoresizingMaskIntoConstraints = false
    stackView.addArrangedSubview(sectionStack)

    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
        sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
    ])

    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true

    return textView
}
