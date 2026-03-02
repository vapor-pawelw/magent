import AppKit

extension NSViewController {

    /// Presents a modal sheet with a spinner and label, runs the async work block,
    /// then dismisses the sheet. Shows an alert on failure.
    func performWithSpinner(message: String, errorTitle: String, work: @escaping () async throws -> Void) {
        guard let window = view.window else { return }

        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: sheetVC.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: sheetVC.view.centerYAnchor),
        ])

        window.contentViewController?.presentAsSheet(sheetVC)

        Task {
            do {
                try await work()
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                }
            } catch {
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                    let alert = NSAlert()
                    alert.messageText = errorTitle
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}
