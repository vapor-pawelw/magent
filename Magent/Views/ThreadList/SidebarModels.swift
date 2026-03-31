import Cocoa
import MagentCore

class SidebarProject {
    let projectId: UUID
    let name: String
    let isPinned: Bool
    var children: [Any] // Mix of MagentThread (main) and SidebarSection

    init(projectId: UUID, name: String, isPinned: Bool, children: [Any]) {
        self.projectId = projectId
        self.name = name
        self.isPinned = isPinned
        self.children = children
    }
}

class SidebarSection {
    let projectId: UUID
    let sectionId: UUID
    let name: String
    let color: NSColor
    var isKeepAlive: Bool
    var threads: [MagentThread]

    init(projectId: UUID, sectionId: UUID, name: String, color: NSColor, isKeepAlive: Bool = false, threads: [MagentThread]) {
        self.projectId = projectId
        self.sectionId = sectionId
        self.name = name
        self.color = color
        self.isKeepAlive = isKeepAlive
        self.threads = threads
    }
}

final class SidebarSpacer {}
final class SidebarProjectMainSpacer {}
