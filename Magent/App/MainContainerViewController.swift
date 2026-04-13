import Cocoa

/// Wraps the split view controller and a bottom status bar into a single
/// content view controller for the main window.
final class MainContainerViewController: NSViewController {

    let statusBar = StatusBarView()
    let splitViewController: SplitViewController

    init(splitViewController: SplitViewController) {
        self.splitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(splitViewController)
        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBar)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
