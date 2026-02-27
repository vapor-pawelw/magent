import Cocoa
import UserNotifications

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class NonCapturingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if let nextResponder {
            nextResponder.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Resizable Text Container

final class ResizableTextContainer: NSView {
    private static let handleHeight: CGFloat = 10

    init(scrollView: NSScrollView, minHeight: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let handle = ResizeHandleView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        let heightConst = scrollView.heightAnchor.constraint(equalToConstant: minHeight)
        handle.scrollViewHeightConstraint = heightConst
        handle.minHeight = minHeight

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            handle.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.heightAnchor.constraint(equalToConstant: Self.handleHeight),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightConst,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ResizeHandleView: NSView {
    var scrollViewHeightConstraint: NSLayoutConstraint?
    var minHeight: CGFloat = 56
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let gripWidth: CGFloat = 36
        let gripHeight: CGFloat = 2
        let rect = NSRect(
            x: (bounds.width - gripWidth) / 2,
            y: (bounds.height - gripHeight) / 2,
            width: gripWidth,
            height: gripHeight
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        dragStartHeight = scrollViewHeightConstraint?.constant ?? minHeight
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = dragStartY - event.locationInWindow.y
        scrollViewHeightConstraint?.constant = max(minHeight, dragStartHeight + delta)
    }
}

// MARK: - Settings Category

enum SettingsCategory: Int, CaseIterable {
    case general, agents, notifications, projects

    var title: String {
        switch self {
        case .general: return "General"
        case .agents: return "Agents"
        case .notifications: return "Notifications"
        case .projects: return "Projects"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "cpu"
        case .notifications: return "bell"
        case .projects: return "folder"
        }
    }
}

// MARK: - SettingsSplitViewController

final class SettingsSplitViewController: NSSplitViewController {

    private let sidebarVC = SettingsSidebarViewController()
    private let detailContainerVC = NSViewController()
    private let generalVC = SettingsGeneralViewController()
    private let agentsVC = SettingsAgentsViewController()
    private let notificationsVC = SettingsNotificationsViewController()
    private let projectsVC = SettingsProjectsViewController()
    private var detailSplitItem: NSSplitViewItem!
    private var currentCategory: SettingsCategory = .general

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 900, height: 640)

        sidebarVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 200
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        setupDetailContainer()
        showCategoryContent(.general)

        detailSplitItem = NSSplitViewItem(viewController: detailContainerVC)
        detailSplitItem.canCollapse = false
        detailSplitItem.minimumThickness = 500
        addSplitViewItem(detailSplitItem)

        splitView.dividerStyle = .thin
    }

    override func cancelOperation(_ sender: Any?) {
        if let window = view.window, window.sheetParent == nil {
            window.performClose(nil)
        } else {
            dismiss(nil)
        }
    }

    private func setupDetailContainer() {
        detailContainerVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
        let container = detailContainerVC.view

        let allVCs: [NSViewController] = [generalVC, agentsVC, notificationsVC, projectsVC]
        for vc in allVCs {
            detailContainerVC.addChild(vc)
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vc.view)
            NSLayoutConstraint.activate([
                vc.view.topAnchor.constraint(equalTo: container.topAnchor),
                vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    private func showCategoryContent(_ category: SettingsCategory) {
        generalVC.view.isHidden = category != .general
        agentsVC.view.isHidden = category != .agents
        notificationsVC.view.isHidden = category != .notifications
        projectsVC.view.isHidden = category != .projects
    }

    fileprivate func showCategory(_ category: SettingsCategory) {
        guard category != currentCategory else { return }
        currentCategory = category

        showCategoryContent(category)
    }
}

// MARK: - SettingsSidebarDelegate

@MainActor
protocol SettingsSidebarDelegate: AnyObject {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect category: SettingsCategory)
    func settingsSidebarDidDismiss(_ sidebar: SettingsSidebarViewController)
}

extension SettingsSplitViewController: SettingsSidebarDelegate {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect category: SettingsCategory) {
        showCategory(category)
    }

    func settingsSidebarDidDismiss(_ sidebar: SettingsSidebarViewController) {
        if let window = view.window, window.sheetParent == nil {
            window.performClose(nil)
        } else {
            dismiss(nil)
        }
    }
}

// MARK: - SettingsSidebarViewController

final class SettingsSidebarViewController: NSViewController {

    weak var delegate: SettingsSidebarDelegate?
    private var tableView: NSTableView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.selectionHighlightStyle = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -8),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func doneTapped() {
        delegate?.settingsSidebarDidDismiss(self)
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsCategory.allCases.count
    }
}

extension SettingsSidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let category = SettingsCategory.allCases[row]
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.imageView = iv
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                iv.heightAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        cell.textField?.stringValue = category.title
        cell.imageView?.image = NSImage(systemSymbolName: category.symbolName, accessibilityDescription: category.title)
        cell.imageView?.contentTintColor = NSColor(resource: .textSecondary)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        delegate?.settingsSidebar(self, didSelect: SettingsCategory.allCases[row])
    }
}
