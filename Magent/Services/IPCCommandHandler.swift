import Foundation

final class IPCCommandHandler {

    static let shared = IPCCommandHandler()

    private let persistence = PersistenceService.shared
    private let threadManager = ThreadManager.shared
    private let tmux = TmuxService.shared

    func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request.command {
        case "create-thread":
            return await createThread(request)
        case "list-projects":
            return listProjects(request)
        case "list-threads":
            return listThreads(request)
        case "send-prompt":
            return await sendPrompt(request)
        case "archive-thread":
            return await archiveThread(request)
        case "delete-thread":
            return await deleteThread(request)
        case "list-tabs":
            return listTabs(request)
        case "create-tab":
            return await createTab(request)
        case "close-tab":
            return await closeTab(request)
        case "rename-thread":
            return await renameThread(request)
        case "rename-thread-exact":
            return await renameThreadExact(request)
        case "current-thread":
            return currentThread(request)
        case "thread-info":
            return threadInfo(request)
        case "list-sections":
            return listSections(request)
        case "add-section":
            return addSection(request)
        case "remove-section":
            return removeSection(request)
        case "reorder-section":
            return reorderSection(request)
        case "rename-section":
            return renameSection(request)
        case "hide-section":
            return hideSection(request)
        case "show-section":
            return showSection(request)
        default:
            return .failure("Unknown command: \(request.command)", id: request.id)
        }
    }

    // MARK: - Thread Resolution

    private enum ResolveResult {
        case found(MagentThread)
        case error(IPCResponse)
    }

    private func resolveThread(_ request: IPCRequest) -> ResolveResult {
        if let threadId = request.threadId, let uuid = UUID(uuidString: threadId) {
            if let thread = threadManager.threads.first(where: { $0.id == uuid }) {
                return .found(thread)
            }
            return .error(.failure("Thread not found: \(threadId)", id: request.id))
        }
        if let threadName = request.threadName {
            if let thread = threadManager.threads.first(where: {
                $0.name.caseInsensitiveCompare(threadName) == .orderedSame
            }) {
                return .found(thread)
            }
            return .error(.failure("Thread not found: \(threadName)", id: request.id))
        }
        return .error(.failure("Missing required field: threadId or threadName", id: request.id))
    }

    // MARK: - Commands

    private func createThread(_ request: IPCRequest) async -> IPCResponse {
        guard let projectName = request.project else {
            return .failure("Missing required field: project", id: request.id)
        }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: {
            $0.name.caseInsensitiveCompare(projectName) == .orderedSame
        }) else {
            return .failure("Project not found: \(projectName)", id: request.id)
        }

        let requestedAgent: AgentType?
        if let agentStr = request.agentType {
            requestedAgent = AgentType(rawValue: agentStr)
            if requestedAgent == nil {
                return .failure("Unknown agent type: \(agentStr). Valid: claude, codex, custom", id: request.id)
            }
        } else {
            requestedAgent = nil
        }

        // Resolve requested name: --name takes precedence, --description generates a slug
        let requestedName: String?
        if let exactName = request.newName, !exactName.isEmpty {
            requestedName = exactName
        } else if let description = request.description, !description.isEmpty {
            let resolvedAgent = requestedAgent ?? threadManager.resolveAgentType(
                for: project.id, requestedAgentType: nil, settings: settings
            )
            let candidates = await threadManager.autoRenameCandidates(
                from: description, agentType: resolvedAgent, projectId: project.id
            )
            requestedName = candidates.first
        } else {
            requestedName = nil
        }

        let thread: MagentThread
        do {
            thread = try await threadManager.createThread(
                project: project,
                requestedAgentType: requestedAgent,
                initialPrompt: request.prompt,
                requestedName: requestedName
            )
        } catch {
            return .failure("Failed to create thread: \(error.localizedDescription)", id: request.id)
        }

        let projectNameResolved = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? projectName
        let info = IPCThreadInfo(thread: thread, projectName: projectNameResolved)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func listProjects(_ request: IPCRequest) -> IPCResponse {
        let settings = persistence.loadSettings()
        let projects = settings.projects.map { IPCProjectInfo(project: $0) }
        return IPCResponse(ok: true, id: request.id, projects: projects)
    }

    private func listThreads(_ request: IPCRequest) -> IPCResponse {
        let settings = persistence.loadSettings()
        var threads = threadManager.threads

        if let projectName = request.project {
            if let project = settings.projects.first(where: {
                $0.name.caseInsensitiveCompare(projectName) == .orderedSame
            }) {
                threads = threads.filter { $0.projectId == project.id }
            } else {
                return .failure("Project not found: \(projectName)", id: request.id)
            }
        }

        let infos = threads.map { thread in
            let name = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
            return IPCThreadInfo(thread: thread, projectName: name)
        }
        return IPCResponse(ok: true, id: request.id, threads: infos)
    }

    private func sendPrompt(_ request: IPCRequest) async -> IPCResponse {
        guard let prompt = request.prompt, !prompt.isEmpty else {
            return .failure("Missing required field: prompt", id: request.id)
        }

        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let sessionName = thread.agentTmuxSessions.first ?? thread.tmuxSessionNames.first else {
            return .failure("Thread has no tmux sessions", id: request.id)
        }

        do {
            try await tmux.sendKeys(sessionName: sessionName, keys: prompt)
        } catch {
            return .failure("Failed to send prompt: \(error.localizedDescription)", id: request.id)
        }

        return .success(id: request.id)
    }

    private func archiveThread(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        do {
            try await threadManager.archiveThread(thread)
        } catch {
            return .failure("Failed to archive thread: \(error.localizedDescription)", id: request.id)
        }

        return .success(id: request.id)
    }

    private func deleteThread(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        do {
            try await threadManager.deleteThread(thread)
        } catch {
            return .failure("Failed to delete thread: \(error.localizedDescription)", id: request.id)
        }

        return .success(id: request.id)
    }

    // MARK: - Tab Commands

    private func listTabs(_ request: IPCRequest) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        let tabs = thread.tmuxSessionNames.enumerated().map { index, sessionName in
            let isAgent = thread.agentTmuxSessions.contains(sessionName)
            let agentType: String? = isAgent ? (thread.selectedAgentType?.rawValue ?? "unknown") : nil
            return IPCTabInfo(index: index, sessionName: sessionName, isAgent: isAgent, agentType: agentType)
        }
        return IPCResponse(ok: true, id: request.id, tabs: tabs)
    }

    private func createTab(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        let useAgent: Bool
        let requestedAgent: AgentType?
        if let agentStr = request.agentType {
            if agentStr == "terminal" {
                useAgent = false
                requestedAgent = nil
            } else if let agent = AgentType(rawValue: agentStr) {
                useAgent = true
                requestedAgent = agent
            } else {
                return .failure("Unknown agent type: \(agentStr). Valid: claude, codex, custom, terminal", id: request.id)
            }
        } else {
            // Default to thread's agent type
            useAgent = thread.selectedAgentType != nil
            requestedAgent = thread.selectedAgentType
        }

        do {
            let tab = try await threadManager.addTab(
                to: thread,
                useAgentCommand: useAgent,
                requestedAgentType: requestedAgent
            )
            let isAgent = useAgent && requestedAgent != nil
            let info = IPCTabInfo(
                index: tab.index,
                sessionName: tab.tmuxSessionName,
                isAgent: isAgent,
                agentType: isAgent ? (requestedAgent?.rawValue ?? thread.selectedAgentType?.rawValue) : nil
            )

            // Send initial prompt if provided
            if let prompt = request.prompt, !prompt.isEmpty, isAgent {
                try? await tmux.sendKeys(sessionName: tab.tmuxSessionName, keys: prompt)
            }

            return IPCResponse(ok: true, id: request.id, tab: info)
        } catch {
            return .failure("Failed to create tab: \(error.localizedDescription)", id: request.id)
        }
    }

    private func renameThread(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let description = request.newName, !description.isEmpty else {
            return .failure("Missing required field: description (pass via newName)", id: request.id)
        }

        let candidates = await threadManager.autoRenameCandidates(from: description, agentType: thread.selectedAgentType, projectId: thread.projectId)
        guard !candidates.isEmpty else {
            return .failure("Could not generate a name from the given description", id: request.id)
        }

        for candidate in candidates where candidate != thread.name {
            do {
                try await threadManager.renameThread(thread, to: candidate, markFirstPromptRenameHandled: false)
                let settings = persistence.loadSettings()
                let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
                // Re-fetch thread after rename
                guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
                    return .success(id: request.id)
                }
                let info = IPCThreadInfo(thread: updated, projectName: projectName)
                return IPCResponse(ok: true, id: request.id, thread: info)
            } catch ThreadManagerError.duplicateName {
                continue
            } catch {
                return .failure("Failed to rename thread: \(error.localizedDescription)", id: request.id)
            }
        }

        return .failure("All generated name candidates are taken", id: request.id)
    }

    private func renameThreadExact(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let newName = request.newName, !newName.isEmpty else {
            return .failure("Missing required field: name (pass via newName)", id: request.id)
        }

        do {
            try await threadManager.renameThread(thread, to: newName, markFirstPromptRenameHandled: false)
        } catch {
            return .failure("Failed to rename thread: \(error.localizedDescription)", id: request.id)
        }

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func currentThread(_ request: IPCRequest) -> IPCResponse {
        guard let sessionName = request.sessionName, !sessionName.isEmpty else {
            return .failure("Missing required field: sessionName", id: request.id)
        }

        guard let thread = threadManager.threads.first(where: { $0.tmuxSessionNames.contains(sessionName) }) else {
            return .failure("No thread found for session: \(sessionName)", id: request.id)
        }

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        let info = IPCThreadInfo(thread: thread, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func threadInfo(_ request: IPCRequest) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"

        // Resolve section name
        let sections = settings.sections(for: thread.projectId)
        let sectionName: String?
        if let sectionId = thread.sectionId,
           let section = sections.first(where: { $0.id == sectionId }) {
            sectionName = section.name
        } else if let defaultSection = sections.filter(\.isVisible).sorted(by: { $0.sortOrder < $1.sortOrder }).first {
            sectionName = defaultSection.name
        } else {
            sectionName = nil
        }

        // Build tab list
        let tabs = thread.tmuxSessionNames.enumerated().map { index, sessionName in
            let isAgent = thread.agentTmuxSessions.contains(sessionName)
            let agentType: String? = isAgent ? (thread.selectedAgentType?.rawValue ?? "unknown") : nil
            return IPCTabInfo(index: index, sessionName: sessionName, isAgent: isAgent, agentType: agentType)
        }

        let info = IPCThreadInfo(thread: thread, projectName: projectName, sectionName: sectionName, tabs: tabs)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    // MARK: - Section Commands

    /// Resolves the project for section operations. Returns nil (with no error) when --project is omitted (global mode).
    private func resolveProjectForSection(_ request: IPCRequest, settings: AppSettings) -> (project: Project?, error: IPCResponse?) {
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
    private func findSection(named name: String, in sections: [ThreadSection]) -> ThreadSection? {
        sections.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    }

    /// Returns threads currently assigned to a section (across all projects for global, or filtered for project-specific).
    private func threadsInSection(_ sectionId: UUID, projectId: UUID?) -> [MagentThread] {
        let allThreads = threadManager.threads.filter { !$0.isArchived }
        let settings = persistence.loadSettings()
        let knownSectionIds = Set(settings.threadSections.map(\.id))

        return allThreads.filter { thread in
            if let projectId, thread.projectId != projectId { return false }
            let effectiveSectionId: UUID?
            if let sid = thread.sectionId, knownSectionIds.contains(sid) {
                effectiveSectionId = sid
            } else {
                effectiveSectionId = settings.defaultSection?.id
            }
            return effectiveSectionId == sectionId
        }
    }

    private func listSections(_ request: IPCRequest) -> IPCResponse {
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

        let infos: [IPCSectionInfo] = sortedSections.map { section in
            let matchingThreads = allThreads.filter { thread in
                if let projectId, thread.projectId != projectId { return false }
                if projectId == nil { return false } // global listing doesn't include threads
                let effectiveSectionId: UUID?
                if let sid = thread.sectionId, knownSectionIds.contains(sid) {
                    effectiveSectionId = sid
                } else {
                    effectiveSectionId = sortedSections.first?.id
                }
                return effectiveSectionId == section.id
            }

            let threadInfos: [IPCThreadInfo]? = projectId != nil ? matchingThreads.map { thread in
                let projName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
                return IPCThreadInfo(thread: thread, projectName: projName)
            } : nil

            return IPCSectionInfo(section: section, isProjectOverride: isOverride, threads: threadInfos)
        }

        return IPCResponse(ok: true, id: request.id, sections: infos)
    }

    private func addSection(_ request: IPCRequest) -> IPCResponse {
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
            return IPCResponse(ok: true, id: request.id, section: IPCSectionInfo(section: newSection, isProjectOverride: false))
        }
    }

    private func removeSection(_ request: IPCRequest) -> IPCResponse {
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
            let threads = threadsInSection(section.id, projectId: project.id)
            if !threads.isEmpty {
                return .failure("Cannot remove section '\(sectionName)': \(threads.count) thread(s) still in it. Move them first.", id: request.id)
            }
            sections.remove(at: sectionIndex)
            settings.projects[projectIndex].threadSections = sections.isEmpty ? nil : sections
            try? persistence.saveSettings(settings)
            return .success(id: request.id)
        } else {
            // Global: validate across all projects
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            let section = settings.threadSections[sectionIndex]
            let threads = threadsInSection(section.id, projectId: nil)
            if !threads.isEmpty {
                return .failure("Cannot remove global section '\(sectionName)': \(threads.count) thread(s) across projects still in it. Move them first.", id: request.id)
            }
            settings.threadSections.remove(at: sectionIndex)
            try? persistence.saveSettings(settings)
            return .success(id: request.id)
        }
    }

    private func reorderSection(_ request: IPCRequest) -> IPCResponse {
        guard let sectionName = request.sectionName, !sectionName.isEmpty else {
            return .failure("Missing required field: sectionName", id: request.id)
        }
        guard let newPosition = request.position else {
            return .failure("Missing required field: position", id: request.id)
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
            let section = settings.threadSections.remove(at: sectionIndex)
            let clampedPos = max(0, min(newPosition, settings.threadSections.count))
            settings.threadSections.insert(section, at: clampedPos)
            for i in settings.threadSections.indices { settings.threadSections[i].sortOrder = i }
            try? persistence.saveSettings(settings)
        }

        return .success(id: request.id)
    }

    private func renameSection(_ request: IPCRequest) -> IPCResponse {
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
            return IPCResponse(ok: true, id: request.id, section: IPCSectionInfo(section: settings.threadSections[sectionIndex], isProjectOverride: false))
        }
    }

    private func hideSection(_ request: IPCRequest) -> IPCResponse {
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
            let threads = threadsInSection(section.id, projectId: project.id)
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
            let threads = threadsInSection(section.id, projectId: nil)
            if !threads.isEmpty {
                return .failure("Cannot hide global section '\(sectionName)': \(threads.count) thread(s) across projects still in it. Move them first.", id: request.id)
            }
            settings.threadSections[sectionIndex].isVisible = false
            try? persistence.saveSettings(settings)
        }

        return .success(id: request.id)
    }

    private func showSection(_ request: IPCRequest) -> IPCResponse {
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

        return .success(id: request.id)
    }

    private func closeTab(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard thread.tmuxSessionNames.count > 1 else {
            return .failure("Cannot close the last tab — use archive-thread or delete-thread instead", id: request.id)
        }

        do {
            if let sessionName = request.sessionName {
                guard thread.tmuxSessionNames.contains(sessionName) else {
                    return .failure("Session not found: \(sessionName)", id: request.id)
                }
                try await threadManager.removeTab(from: thread, sessionName: sessionName)
            } else if let tabIndex = request.tabIndex {
                try await threadManager.removeTab(from: thread, at: tabIndex)
            } else {
                return .failure("Missing required field: tabIndex or sessionName", id: request.id)
            }
        } catch {
            return .failure("Failed to close tab: \(error.localizedDescription)", id: request.id)
        }

        return .success(id: request.id)
    }
}
