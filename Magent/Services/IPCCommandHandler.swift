import Foundation

final class IPCCommandHandler {

    static let shared = IPCCommandHandler()

    let persistence = PersistenceService.shared
    let threadManager = ThreadManager.shared
    let tmux = TmuxService.shared

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
        case "auto-rename-thread", "rename-thread":
            return await autoRenameThread(request)
        case "rename-branch", "rename-thread-exact":
            return await renameBranch(request)
        case "set-description":
            return setDescription(request)
        case "current-thread":
            return currentThread(request)
        case "thread-info":
            return threadInfo(request)
        case "list-sections":
            return handleListSections(request)
        case "add-section":
            return handleAddSection(request)
        case "remove-section":
            return handleRemoveSection(request)
        case "reorder-section":
            return handleReorderSection(request)
        case "rename-section":
            return handleRenameSection(request)
        case "hide-section":
            return handleHideSection(request)
        case "show-section":
            return handleShowSection(request)
        case "move-thread":
            return await handleMoveThread(request)
        default:
            return .failure("Unknown command: \(request.command)", id: request.id)
        }
    }

    // MARK: - Thread Resolution

    enum ResolveResult {
        case found(MagentThread)
        case error(IPCResponse)
    }

    func resolveThread(_ request: IPCRequest) -> ResolveResult {
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
            let renameResult = await threadManager.autoRenameCandidates(
                from: description, agentType: resolvedAgent, projectId: project.id
            )
            if case .candidates(let slugs) = renameResult {
                requestedName = slugs.first
            } else {
                requestedName = nil
            }
        } else {
            requestedName = nil
        }

        // Resolve requested section
        let requestedSectionId: UUID?
        if let sectionName = request.sectionName, !sectionName.isEmpty {
            let sections = settings.sections(for: project.id)
            guard let section = findSection(named: sectionName, in: sections) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            requestedSectionId = section.id
        } else {
            requestedSectionId = nil
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

        // Move to requested section after creation (if specified)
        if let sectionId = requestedSectionId {
            await threadManager.moveThread(thread, toSection: sectionId)
        }

        let projectNameResolved = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? projectName
        guard let updatedThread = threadManager.threads.first(where: { $0.id == thread.id }) else {
            let info = IPCThreadInfo(thread: thread, projectName: projectNameResolved)
            return IPCResponse(ok: true, id: request.id, thread: info)
        }
        let info = IPCThreadInfo(thread: updatedThread, projectName: projectNameResolved)
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
            // Finalize session context (bell monitoring, cwd enforcement) — same as UI path
            let latestThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
            _ = await threadManager.recreateSessionIfNeeded(
                sessionName: tab.tmuxSessionName,
                thread: latestThread
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

    private func autoRenameThread(_ request: IPCRequest) async -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        let prompt = [request.prompt, request.description, request.newName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        guard let prompt else {
            return .failure("Missing required field: prompt", id: request.id)
        }

        let renameResult = await threadManager.autoRenameCandidates(
            from: prompt,
            agentType: thread.selectedAgentType,
            projectId: thread.projectId
        )
        guard case .candidates(let candidates) = renameResult else {
            return .failure("Could not generate a branch name from the prompt", id: request.id)
        }

        var didRename = false
        let renameCandidates = candidates.filter { $0 != thread.name }
        for candidate in renameCandidates {
            do {
                try await threadManager.renameThread(thread, to: candidate, markFirstPromptRenameHandled: false)
                didRename = true
                break
            } catch ThreadManagerError.duplicateName {
                continue
            } catch {
                return .failure("Failed to rename branch: \(error.localizedDescription)", id: request.id)
            }
        }

        if !renameCandidates.isEmpty, !didRename {
            return .failure("All generated branch name candidates are taken", id: request.id)
        }

        _ = await threadManager.regenerateTaskDescription(threadId: thread.id, prompt: prompt)

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func renameBranch(_ request: IPCRequest) async -> IPCResponse {
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
            return .failure("Failed to rename branch: \(error.localizedDescription)", id: request.id)
        }

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func setDescription(_ request: IPCRequest) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        do {
            try threadManager.setTaskDescription(threadId: thread.id, description: request.description)
        } catch ThreadManagerError.invalidDescription {
            return .failure("Invalid description. Use 2-8 words.", id: request.id)
        } catch {
            return .failure("Failed to set description: \(error.localizedDescription)", id: request.id)
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

        let status = IPCThreadStatus(
            isBusy: thread.hasAgentBusy,
            isWaitingForInput: thread.hasWaitingForInput,
            hasUnreadCompletion: thread.hasUnreadAgentCompletion,
            isDirty: thread.isDirty,
            isFullyDelivered: thread.isFullyDelivered,
            showArchiveSuggestion: thread.showArchiveSuggestion,
            isPinned: thread.isPinned,
            isArchived: thread.isArchived,
            isBlockedByRateLimit: thread.isBlockedByRateLimit,
            hasBranchMismatch: thread.hasBranchMismatch,
            jiraTicketKey: thread.jiraTicketKey,
            jiraUnassigned: thread.jiraUnassigned,
            branchName: thread.branchName,
            baseBranch: thread.baseBranch,
            rateLimitDescription: thread.isBlockedByRateLimit ? thread.rateLimitLiftDescription : nil
        )

        let info = IPCThreadInfo(thread: thread, projectName: projectName, sectionName: sectionName, tabs: tabs, status: status)
        return IPCResponse(ok: true, id: request.id, thread: info)
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
