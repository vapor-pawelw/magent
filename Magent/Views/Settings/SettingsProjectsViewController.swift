import Cocoa
import MagentCore

final class SettingsProjectsViewController: NSViewController {
    static let projectRowPasteboardType = NSPasteboard.PasteboardType("com.magent.settings.project-row")
    static let sectionRowPasteboardType = NSPasteboard.PasteboardType("com.magent.settings.section-row")
    static let sectionColorPanelIdentifier = NSUserInterfaceItemIdentifier("SettingsProjectsSectionColorPanel")
    static let sectionNameLabelTag = 203
    static let sectionInlineRenameFieldTag = 204

    let persistence = PersistenceService.shared
    var settings: AppSettings!

    var projectTableView: NSTableView!
    var detailScrollView: NSScrollView!
    var emptyLabel: NSTextField!
    var removeProjectButton: NSButton!

    // Detail fields
    var nameField: NSTextField!
    var repoPathLabel: NSTextField!
    var worktreesPathLabel: NSTextField!
    var defaultBranchField: NSTextField!
    var localFileSyncPathsTextView: NSTextView!
    var archiveCleanupGlobsTextView: NSTextView!
    var agentTypePopup: NSPopUpButton!
    var terminalInjectionTextView: NSTextView!
    var preAgentInjectionTextView: NSTextView!
    var agentContextTextView: NSTextView!
    var slugPromptCheckbox: NSButton!
    var slugPromptTextView: NSTextView!
    var slugPromptContainer: NSView!
    var threadListLayoutPopup: NSPopUpButton!

    // Default section
    var defaultSectionContainer: NSStackView!
    var defaultSectionPopup: NSPopUpButton!

    // Sections management
    var sectionsOverridesStack: NSStackView!
    var sectionsModePopup: NSPopUpButton!
    var sectionsContentStack: NSStackView!
    var sectionsTableView: NSTableView!
    var currentEditingSectionId: UUID?
    var isUpdatingSectionColorPanel = false
    var activeInlineRenameSectionId: UUID?

    var projectSortedSections: [ThreadSection] {
        guard let index = selectedProjectIndex,
              let sections = settings.projects[index].threadSections else { return [] }
        return sections.sorted { $0.sortOrder < $1.sortOrder }
    }

    // Jira fields
    var jiraProjectKeyField: NSTextField!
    var jiraBoardPopup: NSPopUpButton!
    var jiraAssigneeField: NSTextField!
    var jiraSyncButton: NSButton!
    var jiraAutoSyncCheckbox: NSButton!
    var jiraSectionsSyncControlsStack: NSStackView!
    var jiraBoards: [JiraBoard] = []

    var selectedProjectIndex: Int? {
        let row = projectTableView.selectedRow
        return row >= 0 ? row : nil
    }

    var selectedProject: Project? {
        guard let index = selectedProjectIndex, index < settings.projects.count else { return nil }
        return settings.projects[index]
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        setupProjectList()
        setupDetailPane()
        setupLayout()
        reloadProjectsAndSelect()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        dismissProjectSectionColorPickerIfNeeded()
    }

    private func setupProjectList() {
        projectTableView = NSTableView()
        projectTableView.headerView = nil
        projectTableView.style = .inset
        projectTableView.rowSizeStyle = .default
        projectTableView.selectionHighlightStyle = .regular
        projectTableView.registerForDraggedTypes([Self.projectRowPasteboardType])
        projectTableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectColumn"))
        projectTableView.addTableColumn(column)
        projectTableView.dataSource = self
        projectTableView.delegate = self
    }

    private func setupDetailPane() {
        detailScrollView = NSScrollView()
        detailScrollView.hasVerticalScroller = true
        detailScrollView.autohidesScrollers = true
        detailScrollView.drawsBackground = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "Select a project")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = NSColor(resource: .textSecondary)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupLayout() {
        // Left: project list with add/remove buttons
        let listScrollView = NSScrollView()
        listScrollView.documentView = projectTableView
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(
            image: NSImage(named: NSImage.addTemplateName) ?? NSImage(),
            target: self,
            action: #selector(addProjectTapped)
        )
        addButton.bezelStyle = .texturedRounded
        addButton.controlSize = .small
        addButton.imagePosition = .imageOnly
        addButton.toolTip = "Add Project"

        removeProjectButton = NSButton(
            image: NSImage(named: NSImage.removeTemplateName) ?? NSImage(),
            target: self,
            action: #selector(removeProjectTapped)
        )
        removeProjectButton.bezelStyle = .texturedRounded
        removeProjectButton.controlSize = .small
        removeProjectButton.imagePosition = .imageOnly
        removeProjectButton.toolTip = "Remove Project"

        let buttonBar = NSStackView(views: [addButton, removeProjectButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 6
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(listScrollView)
        leftPane.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            listScrollView.topAnchor.constraint(equalTo: leftPane.topAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: 4),
            buttonBar.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor, constant: -4),
        ])

        // Right: scrollable detail or empty state
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(detailScrollView)
        rightPane.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            detailScrollView.topAnchor.constraint(equalTo: rightPane.topAnchor),
            detailScrollView.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: rightPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: rightPane.centerYAnchor),
        ])

        view.addSubview(leftPane)
        view.addSubview(rightPane)

        NSLayoutConstraint.activate([
            leftPane.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            leftPane.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            leftPane.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            leftPane.widthAnchor.constraint(equalToConstant: 180),

            rightPane.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            rightPane.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: 12),
            rightPane.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rightPane.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        updateRemoveButtonState()
    }

    func updateRemoveButtonState() {
        removeProjectButton?.isEnabled = selectedProjectIndex != nil
    }

    func reloadProjectsAndSelect(row preferredRow: Int? = nil) {
        let currentRow = selectedProjectIndex
        projectTableView.reloadData()

        guard !settings.projects.isEmpty else {
            projectTableView.deselectAll(nil)
            updateRemoveButtonState()
            showEmptyState()
            return
        }

        let target = max(0, min(preferredRow ?? currentRow ?? 0, settings.projects.count - 1))
        projectTableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        showDetailForProject(settings.projects[target])
        updateRemoveButtonState()
    }

    func showEmptyState() {
        detailScrollView.isHidden = true
        emptyLabel.isHidden = false
    }
}
