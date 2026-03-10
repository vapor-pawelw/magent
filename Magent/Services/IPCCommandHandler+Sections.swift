import Foundation
import MagentCore

extension IPCCommandHandler {

    // MARK: - Section Commands

    func notifySectionsDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        }
    }

    /// Resolves the project for section operations. Returns nil (with no error) when --project is omitted (global mode).
    func resolveProjectForSection(_ request: IPCRequest, settings: AppSettings) -> (project: Project?, error: IPCResponse?) {
        guard let projectName = request.project else {
            return (nil, nil) // global mode
        }
        guard let project = settings.projects.first(where: {
            $0.name.caseInsensitiveCompare(projectName) == .orderedSame
        }) else {
            return (nil, .failure("Project not found: \(projectName)", id: request.id))
        }
        return (project, nil)
    }

    /// Finds a section by name in the given section list.
    func findSection(named name: String, in sections: [ThreadSection]) -> ThreadSection? {
        sections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    }

    /// Returns threads currently assigned to a section (across all projects for global, or filtered for project-specific).
    func threadsInSection(_ sectionId: UUID, projectId: UUID?, settings: AppSettings) -> [MagentThread] {
        if Thread.isMainThread {
            return threadManager.threadsAssigned(toSection: sectionId, projectId: projectId, settings: settings)
        }

        var result: [MagentThread] = []
        DispatchQueue.main.sync {
            result = threadManager.threadsAssigned(toSection: sectionId, projectId: projectId, settings: settings)
        }
        return result
    }

    func reassignThreadsInSection(
        from oldSectionId: UUID,
        to newSectionId: UUID,
        projectId: UUID?,
        settings: AppSettings
    ) {
        if Thread.isMainThread {
            threadManager.reassignThreadsAssigned(
                toSection: oldSectionId,
                toSection: newSectionId,
                projectId: projectId,
                settings: settings
            )
            return
        }

        _ = DispatchQueue.main.sync {
            threadManager.reassignThreadsAssigned(
                toSection: oldSectionId,
                toSection: newSectionId,
                projectId: projectId,
                settings: settings
            )
        }
    }

    func handleListSections(_ request: IPCRequest) -> IPCResponse {
        let settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }

        let projectId = project?.id
        let sections: [ThreadSection]
        let isOverride: Bool

        if let project, let override = project.threadSections {
            sections = override
            isOverride = true
        } else {
            sections = settings.threadSections
            isOverride = false
        }

        let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }
        let allThreads = threadManager.threads.filter { !$0.isArchived }
        let knownSectionIds = Set(sections.map(\.id))
        let sectionFallbackId = if let projectId {
            settings.defaultSection(for: projectId)?.id
        } else {
            settings.defaultSection?.id
        }

        let infos: [IPCSectionInfo] = sortedSections.map { section in
            let matchingThreads = allThreads.filter { thread in
                if let projectId, thread.projectId != projectId { return false }
                if projectId == nil { return false } // global listing doesn't include threads
                return thread.resolvedSectionId(knownSectionIds: knownSectionIds, fallback: sectionFallbackId) == section.id
            }

            let threadInfos: [IPCThreadInfo]? = projectId != nil ? matchingThreads.map { thread in
                let projName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
                return IPCThreadInfo(thread: thread, projectName: projName)
            } : nil

            return IPCSectionInfo(section: section, isProjectOverride: isOverride, threads: threadInfos)
        }

        return IPCResponse(ok: true, id: request.id, sections: infos)
    }

    func handleAddSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }

        var settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }

        let colorHex = request.sectionColor ?? ThreadSection.randomColorHex()

        if let project {
            // Project-level: add to project's section overrides
            let projectIndex = settings.projects.firstIndex(where: { $0.id == project.id })!
            var sections = settings.projects[projectIndex].threadSections ?? settings.threadSections
            if findSection(named: sectionName, in: sections) != nil {
                return .failure("Section '\(sectionName)' already exists in project '\(project.name)'", id: request.id)
            }
            let maxOrder = sections.map(\.sortOrder).max() ?? -1
            let newSection = ThreadSection(name: sectionName, colorHex: colorHex, sortOrder: maxOrder + 1)
            sections.append(newSection)
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
            notifySectionsDidChange()
            return IPCResponse(ok: true, id: request.id, section: IPCSectionInfo(section: newSection, isProjectOverride: true))
        } else {
            // Global: add to global sections
            if findSection(named: sectionName, in: settings.threadSections) != nil {
                return .failure("Section '\(sectionName)' already exists", id: request.id)
            }
            let maxOrder = settings.threadSections.map(\.sortOrder).max() ?? -1
            let newSection = ThreadSection(name: sectionName, colorHex: colorHex, sortOrder: maxOrder + 1)
            settings.threadSections.append(newSection)
            try? persistence.saveSettings(settings)
            notifySectionsDidChange()
            return IPCResponse(ok: true, id: request.id, section: IPCSectionInfo(section: newSection, isProjectOverride: false))
        }
    }

    func handleRemoveSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }

        var settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }

        if let project {
            let projectIndex = settings.projects.firstIndex(where: { $0.id == project.id })!
            var sections = settings.projects[projectIndex].threadSections ?? settings.threadSections
            guard let sectionIndex = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            let section = sections[sectionIndex]
            guard sections.count > 1 else {
                return .failure("Cannot remove section '\(sectionName)': at least one section is required.", id: request.id)
            }
            guard let defaultSection = settings.defaultSection(for: project.id) else {
                return .failure("Cannot remove section '\(sectionName)': no default section is available.", id: request.id)
            }
            if defaultSection.id == section.id {
                return .failure("Cannot remove section '\(sectionName)': change the default section first.", id: request.id)
            }
            reassignThreadsInSection(from: section.id, to: defaultSection.id, projectId: project.id, settings: settings)
            sections.remove(at: sectionIndex)
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
            notifySectionsDidChange()
            return .success(id: request.id)
        } else {
            // Global: validate across all projects
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            let section = settings.threadSections[sectionIndex]
            guard settings.threadSections.count > 1 else {
                return .failure("Cannot remove global section '\(sectionName)': at least one section is required.", id: request.id)
            }
            guard let defaultSection = settings.defaultSection else {
                return .failure("Cannot remove global section '\(sectionName)': no default section is available.", id: request.id)
            }
            if defaultSection.id == section.id {
                return .failure("Cannot remove global section '\(sectionName)': change the default section first.", id: request.id)
            }
            reassignThreadsInSection(from: section.id, to: defaultSection.id, projectId: nil, settings: settings)
            settings.threadSections.remove(at: sectionIndex)
            try? persistence.saveSettings(settings)
            notifySectionsDidChange()
            return .success(id: request.id)
        }
    }

    func handleReorderSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }
        guard let newPosition = request.position else {
            return .failure("Missing required field: position", id: request.id)
        }

        var settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }
        let previousGlobalDefaultId = settings.defaultSection?.id

        if let project {
            let projectIndex = settings.projects.firstIndex(where: { $0.id == project.id })!
            var sections = settings.projects[projectIndex].threadSections ?? settings.threadSections
            guard let sectionIndex = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            let section = sections.remove(at: sectionIndex)
            let clampedPos = max(0, min(newPosition, sections.count))
            sections.insert(section, at: clampedPos)
            for i in sections.indices { sections[i].sortOrder = i }
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            if settings.defaultSectionId == nil {
                settings.defaultSectionId = previousGlobalDefaultId
            }
            let section = settings.threadSections.remove(at: sectionIndex)
            let clampedPos = max(0, min(newPosition, settings.threadSections.count))
            settings.threadSections.insert(section, at: clampedPos)
            for i in settings.threadSections.indices { settings.threadSections[i].sortOrder = i }
            try? persistence.saveSettings(settings)
        }

        notifySectionsDidChange()
        return .success(id: request.id)
    }

    func handleRenameSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }
        guard let newName = request.newName, !newName.isEmpty else {
            return .failure("Missing required field: newName", id: request.id)
        }

        var settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }

        if let project {
            let projectIndex = settings.projects.firstIndex(where: { $0.id == project.id })!
            var sections = settings.projects[projectIndex].threadSections ?? settings.threadSections
            guard let sectionIndex = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            if sections.contains(where: { $0.name.caseInsensitiveCompare(newName) == .orderedSame && $0.id != sections[sectionIndex].id }) {
                return .failure("Section '\(newName)' already exists in project '\(project.name)'", id: request.id)
            }
            sections[sectionIndex].name = newName
            if let color = request.sectionColor { sections[sectionIndex].colorHex = color }
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
            notifySectionsDidChange()
            return IPCResponse(ok: true, id: request.id, section: IPCSectionInfo(section: sections[sectionIndex], isProjectOverride: true))
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            if settings.threadSections.contains(where: { $0.name.caseInsensitiveCompare(newName) == .orderedSame && $0.id != settings.threadSections[sectionIndex].id }) {
                return .failure("Section '\(newName)' already exists", id: request.id)
            }
            settings.threadSections[sectionIndex].name = newName
            if let color = request.sectionColor { settings.threadSections[sectionIndex].colorHex = color }
            try? persistence.saveSettings(settings)
            notifySectionsDidChange()
            return IPCResponse(ok: true, id: request.id, section: IPCSectionInfo(section: settings.threadSections[sectionIndex], isProjectOverride: false))
        }
    }

    func handleHideSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }

        var settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }

        if let project {
            let projectIndex = settings.projects.firstIndex(where: { $0.id == project.id })!
            var sections = settings.projects[projectIndex].threadSections ?? settings.threadSections
            guard let sectionIndex = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            let section = sections[sectionIndex]
            let threads = threadsInSection(section.id, projectId: project.id, settings: settings)
            if !threads.isEmpty {
                return .failure("Cannot hide section '\(sectionName)': \(threads.count) thread(s) still in it. Move them first.", id: request.id)
            }
            sections[sectionIndex].isVisible = false
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            let section = settings.threadSections[sectionIndex]
            let threads = threadsInSection(section.id, projectId: nil, settings: settings)
            if !threads.isEmpty {
                return .failure("Cannot hide global section '\(sectionName)': \(threads.count) thread(s) across projects still in it. Move them first.", id: request.id)
            }
            settings.threadSections[sectionIndex].isVisible = false
            try? persistence.saveSettings(settings)
        }

        notifySectionsDidChange()
        return .success(id: request.id)
    }

    func handleShowSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }

        var settings = persistence.loadSettings()
        let (project, error) = resolveProjectForSection(request, settings: settings)
        if let error { return error }

        if let project {
            let projectIndex = settings.projects.firstIndex(where: { $0.id == project.id })!
            var sections = settings.projects[projectIndex].threadSections ?? settings.threadSections
            guard let sectionIndex = sections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            sections[sectionIndex].isVisible = true
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            settings.threadSections[sectionIndex].isVisible = true
            try? persistence.saveSettings(settings)
        }

        notifySectionsDidChange()
        return .success(id: request.id)
    }

    func handleMoveThread(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName (pass via --section)", id: request.id)
        }

        let settings = persistence.loadSettings()
        let sections = settings.sections(for: thread.projectId)
        guard let section = findSection(named: sectionName, in: sections) else {
            return .failure("Section not found: \(sectionName)", id: request.id)
        }

        threadManager.moveThread(thread, toSection: section.id)

        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        var info = IPCThreadInfo(thread: updated, projectName: projectName)
        info.sectionName = sectionName
        return IPCResponse(ok: true, id: request.id, thread: info)
    }
}
