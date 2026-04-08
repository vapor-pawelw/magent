import Foundation
import MagentCore

final class IPCCommandHandler {

    static let shared = IPCCommandHandler()

    let persistence = PersistenceService.shared
    let threadManager = ThreadManager.shared
    let tmux = TmuxService.shared

    func handle(_ request: IPCRequest) async -> IPCResponse {
        switch request.command {
        case "create-thread":
            return await createThread(request)
        case "batch-create":
            return await batchCreateThreads(request)
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
        case "set-thread-icon":
            return setThreadIcon(request)
        case "set-base-branch":
            return setBaseBranch(request)
        case "hide-thread":
            return setThreadHidden(request, hidden: true)
        case "unhide-thread":
            return setThreadHidden(request, hidden: false)
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
        case "keep-alive-thread":
            return setThreadKeepAlive(request, enabled: request.remove != true)
        case "keep-alive-tab":
            return setTabKeepAlive(request, enabled: request.remove != true)
        case "keep-alive-section":
            return setSectionKeepAlive(request, enabled: request.remove != true)
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

    // MARK: - From-Thread Resolution

    /// Resolves the "from-thread" context: inherits base branch and section from a source thread.
    /// `fromThreadId` is auto-injected by the CLI from `$MAGENT_THREAD_ID`; `fromThreadName`
    /// is set explicitly via `--from-thread`. Special name values: `"none"` suppresses
    /// auto-detection, `"main"` resolves to the project's main worktree thread.
    enum FromThreadResult {
        case none
        case resolved(MagentThread)
        case error(IPCResponse)
    }

    func resolveFromThread(
        fromThreadId: String?,
        fromThreadName: String?,
        project: Project,
        requestId: String?
    ) -> FromThreadResult {
        // Explicit name takes precedence over auto-injected ID
        if let name = fromThreadName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            if name.caseInsensitiveCompare("none") == .orderedSame {
                return .none
            }
            if name.caseInsensitiveCompare("main") == .orderedSame {
                if let mainThread = threadManager.threads.first(where: {
                    $0.projectId == project.id && $0.isMain
                }) {
                    return .resolved(mainThread)
                }
                return .error(.failure("Main thread not found for project: \(project.name)", id: requestId))
            }
            if let thread = threadManager.threads.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                guard thread.projectId == project.id else {
                    return .error(.failure("From-thread '\(name)' belongs to a different project", id: requestId))
                }
                return .resolved(thread)
            }
            return .error(.failure("From-thread not found: \(name)", id: requestId))
        }

        // Fall back to auto-injected thread ID
        if let idStr = fromThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !idStr.isEmpty,
           let uuid = UUID(uuidString: idStr) {
            if let thread = threadManager.threads.first(where: { $0.id == uuid }) {
                guard thread.projectId == project.id else {
                    // Auto-injected ID from a different project — silently ignore
                    return .none
                }
                return .resolved(thread)
            }
            // Auto-injected ID not found — not an error, just ignore
            return .none
        }

        return .none
    }

    /// Extracts the branch from a source thread, using the same resolution cascade as `--base-thread`.
    func branchFromThread(_ thread: MagentThread, project: Project) -> String? {
        if let actualBranch = thread.actualBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !actualBranch.isEmpty,
           actualBranch != "HEAD" {
            return actualBranch
        }
        let explicitBranch = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitBranch.isEmpty {
            return explicitBranch
        }
        if let expected = threadManager.resolveExpectedBranch(for: thread)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            return expected
        }
        return nil
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
        let useAgentCommand: Bool
        if let agentStr = request.agentType {
            if agentStr == "terminal" {
                requestedAgent = nil
                useAgentCommand = false
            } else {
                requestedAgent = AgentType(rawValue: agentStr)
                guard requestedAgent != nil else {
                    return .failure("Unknown agent type: \(agentStr). Valid: claude, codex, custom, terminal", id: request.id)
                }
                useAgentCommand = true
            }
        } else {
            requestedAgent = nil
            useAgentCommand = true
        }
        if let requestedAgent, !settings.availableActiveAgents.contains(requestedAgent) {
            return .failure("Agent type is not enabled: \(requestedAgent.rawValue)", id: request.id)
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

        // Resolve from-thread context (auto-injected from $MAGENT_THREAD_ID or explicit --from-thread)
        let fromThread: MagentThread?
        switch resolveFromThread(
            fromThreadId: request.fromThreadId,
            fromThreadName: request.fromThreadName,
            project: project,
            requestId: request.id
        ) {
        case .none: fromThread = nil
        case .resolved(let t): fromThread = t
        case .error(let err): return err
        }

        // Resolve optional base branch (explicit branch or from an existing thread)
        let normalizedBaseThreadName = request.baseThreadName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseBranch = request.baseBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedBaseThreadName, !normalizedBaseThreadName.isEmpty,
           let normalizedBaseBranch, !normalizedBaseBranch.isEmpty {
            return .failure("Use either baseThreadName or baseBranch, not both", id: request.id)
        }

        let hasExplicitBase = (normalizedBaseThreadName != nil && !normalizedBaseThreadName!.isEmpty) ||
            (normalizedBaseBranch != nil && !normalizedBaseBranch!.isEmpty)

        let requestedBaseBranch: String?
        if let normalizedBaseBranch, !normalizedBaseBranch.isEmpty {
            requestedBaseBranch = normalizedBaseBranch
        } else if let normalizedBaseThreadName, !normalizedBaseThreadName.isEmpty {
            guard let baseThread = threadManager.threads.first(where: {
                $0.name.caseInsensitiveCompare(normalizedBaseThreadName) == .orderedSame
            }) else {
                return .failure("Base thread not found: \(normalizedBaseThreadName)", id: request.id)
            }
            guard baseThread.projectId == project.id else {
                return .failure("Base thread '\(normalizedBaseThreadName)' belongs to a different project", id: request.id)
            }

            if let actualBranch = baseThread.actualBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !actualBranch.isEmpty,
                      actualBranch != "HEAD" {
                requestedBaseBranch = actualBranch
            } else {
                let explicitThreadBranch = baseThread.branchName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !explicitThreadBranch.isEmpty {
                    requestedBaseBranch = explicitThreadBranch
                } else if let expectedBranch = threadManager.resolveExpectedBranch(for: baseThread)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                          !expectedBranch.isEmpty {
                    requestedBaseBranch = expectedBranch
                } else if let projectDefault = project.defaultBranch?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                          !projectDefault.isEmpty {
                    requestedBaseBranch = projectDefault
                } else {
                    return .failure("Could not determine base branch from thread: \(normalizedBaseThreadName)", id: request.id)
                }
            }
        } else if !hasExplicitBase, let fromThread, let inheritedBranch = branchFromThread(fromThread, project: project) {
            // Inherit base branch from from-thread when no explicit base was provided
            requestedBaseBranch = inheritedBranch
        } else {
            requestedBaseBranch = nil
        }

        // Resolve requested section
        let hasExplicitSection = request.sectionName != nil && !request.sectionName!.isEmpty
        let requestedSectionId: UUID?
        if let sectionName = request.sectionName, !sectionName.isEmpty {
            let sections = settings.sections(for: project.id)
            guard let section = findSection(named: sectionName, in: sections) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            requestedSectionId = section.id
        } else if !hasExplicitSection, let fromThread, let fromSectionId = fromThread.sectionId {
            // Inherit section from from-thread when no explicit section was provided
            requestedSectionId = fromSectionId
        } else {
            requestedSectionId = nil
        }

        let thread: MagentThread
        do {
            let isPinnedSource = fromThread?.sidebarListState == .pinned
            thread = try await threadManager.createThread(
                project: project,
                requestedAgentType: requestedAgent,
                useAgentCommand: useAgentCommand,
                initialPrompt: request.prompt,
                shouldSubmitInitialPrompt: request.noSubmit != true,
                requestedName: requestedName,
                requestedBaseBranch: requestedBaseBranch,
                requestedSectionId: requestedSectionId,
                insertAfterThreadId: isPinnedSource ? nil : fromThread?.id,
                insertAtTopOfVisibleGroup: isPinnedSource,
                skipAutoSelect: request.select != true,
                modelId: request.modelId,
                reasoningLevel: request.reasoningLevel
            )
        } catch {
            return .failure("Failed to create thread: \(error.localizedDescription)", id: request.id)
        }

        // Set task description from --description (slug generation consumed it for the name,
        // but the thread itself still needs the description persisted).
        if let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            try? threadManager.setTaskDescription(threadId: thread.id, description: description)
        }

        let projectNameResolved = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? projectName
        guard let updatedThread = threadManager.threads.first(where: { $0.id == thread.id }) else {
            let info = IPCThreadInfo(thread: thread, projectName: projectNameResolved)
            return IPCResponse(ok: true, id: request.id, thread: info)
        }
        let info = IPCThreadInfo(thread: updatedThread, projectName: projectNameResolved)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    // MARK: - Batch Create

    private func batchCreateThreads(_ request: IPCRequest) async -> IPCResponse {
        guard let projectName = request.project else {
            return .failure("Missing required field: project", id: request.id)
        }
        guard let specs = request.threads, !specs.isEmpty else {
            return .failure("Missing required field: threads (array of thread specs)", id: request.id)
        }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: {
            $0.name.caseInsensitiveCompare(projectName) == .orderedSame
        }) else {
            return .failure("Project not found: \(projectName)", id: request.id)
        }

        // Resolve request-level from-thread (auto-injected from $MAGENT_THREAD_ID or explicit --from-thread)
        let requestFromThread: MagentThread?
        switch resolveFromThread(
            fromThreadId: request.fromThreadId,
            fromThreadName: request.fromThreadName,
            project: project,
            requestId: request.id
        ) {
        case .none: requestFromThread = nil
        case .resolved(let t): requestFromThread = t
        case .error(let err): return err
        }

        // Phase 1: Resolve all names upfront (may involve AI slug generation).
        // This is sequential but lets us validate everything before creating anything.
        struct ResolvedSpec {
            let agentType: AgentType?
            let useAgentCommand: Bool
            let modelId: String?
            let reasoningLevel: String?
            let prompt: String?
            let noSubmit: Bool
            let requestedName: String?
            let description: String?
            let requestedBaseBranch: String?
            let requestedSectionId: UUID?
            let fromThread: MagentThread?
        }

        var resolved: [ResolvedSpec] = []
        for (i, spec) in specs.enumerated() {
            let agentType: AgentType?
            let useAgentCommand: Bool
            if let agentStr = spec.agentType {
                if agentStr == "terminal" {
                    agentType = nil
                    useAgentCommand = false
                } else {
                    guard let at = AgentType(rawValue: agentStr) else {
                        return .failure("Thread \(i): unknown agent type: \(agentStr)", id: request.id)
                    }
                    if !settings.availableActiveAgents.contains(at) {
                        return .failure("Thread \(i): agent type is not enabled: \(agentStr)", id: request.id)
                    }
                    agentType = at
                    useAgentCommand = true
                }
            } else {
                agentType = nil
                useAgentCommand = true
            }

            // Resolve per-spec from-thread (falls back to request-level)
            let specFromThread: MagentThread?
            if let specFromName = spec.fromThreadName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !specFromName.isEmpty {
                switch resolveFromThread(
                    fromThreadId: nil,
                    fromThreadName: specFromName,
                    project: project,
                    requestId: request.id
                ) {
                case .none: specFromThread = nil
                case .resolved(let t): specFromThread = t
                case .error(let err): return err
                }
            } else {
                specFromThread = requestFromThread
            }

            // Resolve name from --name or --description
            let requestedName: String?
            if let exactName = spec.newName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !exactName.isEmpty {
                requestedName = exactName
            } else if let description = spec.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !description.isEmpty {
                let resolvedAgent = agentType ?? threadManager.resolveAgentType(
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

            // Resolve base branch
            let hasExplicitBase = (spec.baseBranch != nil && !spec.baseBranch!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                (spec.baseThreadName != nil && !spec.baseThreadName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            let baseBranch: String?
            if let bb = spec.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bb.isEmpty {
                baseBranch = bb
            } else if let bt = spec.baseThreadName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !bt.isEmpty {
                guard let baseThread = threadManager.threads.first(where: {
                    $0.name.caseInsensitiveCompare(bt) == .orderedSame
                }) else {
                    return .failure("Thread \(i): base thread not found: \(bt)", id: request.id)
                }
                baseBranch = baseThread.actualBranch ?? baseThread.branchName
            } else if !hasExplicitBase, let ft = specFromThread, let inherited = branchFromThread(ft, project: project) {
                baseBranch = inherited
            } else {
                baseBranch = nil
            }

            // Resolve section
            let hasExplicitSection = spec.sectionName != nil &&
                !spec.sectionName!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            let sectionId: UUID?
            if let sectionName = spec.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sectionName.isEmpty {
                let sections = settings.sections(for: project.id)
                guard let section = findSection(named: sectionName, in: sections) else {
                    return .failure("Thread \(i): section not found: \(sectionName)", id: request.id)
                }
                sectionId = section.id
            } else if !hasExplicitSection, let ft = specFromThread, let ftSection = ft.sectionId {
                sectionId = ftSection
            } else {
                sectionId = nil
            }

            resolved.append(ResolvedSpec(
                agentType: agentType,
                useAgentCommand: useAgentCommand,
                modelId: spec.modelId,
                reasoningLevel: spec.reasoningLevel,
                prompt: spec.prompt,
                noSubmit: spec.noSubmit == true || request.noSubmit == true,
                requestedName: requestedName,
                description: spec.description,
                requestedBaseBranch: baseBranch,
                requestedSectionId: sectionId,
                fromThread: specFromThread
            ))
        }

        // Phase 2: Create threads concurrently. All specs passed validation,
        // so failures here are infrastructure-level (git/tmux).
        // Each thread passes skipAutoSelect: true so batch create doesn't jump focus.
        let results = await withTaskGroup(of: (Int, Result<MagentThread, Error>).self) { group in
            for (i, spec) in resolved.enumerated() {
                group.addTask { [threadManager] in
                    do {
                        // Don't pass insertAfterThreadId here — concurrent creates
                        // targeting the same fromThread would race on phase 1 ordering.
                        // A deterministic post-pass below handles positioning.
                        let thread = try await threadManager.createThread(
                            project: project,
                            requestedAgentType: spec.agentType,
                            useAgentCommand: spec.useAgentCommand,
                            initialPrompt: spec.prompt,
                            shouldSubmitInitialPrompt: !spec.noSubmit,
                            requestedName: spec.requestedName,
                            requestedBaseBranch: spec.requestedBaseBranch,
                            requestedSectionId: spec.requestedSectionId,
                            skipAutoSelect: true,
                            modelId: spec.modelId,
                            reasoningLevel: spec.reasoningLevel
                        )
                        return (i, .success(thread))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<MagentThread, Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted(by: { $0.0 < $1.0 })
        }

        // Position new threads after their from-thread and set descriptions
        // (outside task group for main-actor safety, in request order for determinism).
        var needsSave = false
        for (i, result) in results {
            if case .success(let thread) = result {
                if let ft = resolved[i].fromThread {
                    if ft.sidebarListState == .pinned {
                        threadManager.bumpThreadToTopOfSection(thread.id)
                    } else {
                        threadManager.placeThreadAfterSibling(threadId: thread.id, afterThreadId: ft.id)
                    }
                    needsSave = true
                }
                if let desc = resolved[i].description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !desc.isEmpty {
                    try? threadManager.setTaskDescription(threadId: thread.id, description: desc)
                }
            }
        }
        if needsSave {
            try? threadManager.persistence.saveActiveThreads(threadManager.threads)
            await MainActor.run {
                threadManager.delegate?.threadManager(threadManager, didUpdateThreads: threadManager.threads)
            }
        }

        // Build response with all created threads
        var threadInfos: [IPCThreadInfo] = []
        var errors: [String] = []
        for (i, result) in results {
            switch result {
            case .success(let thread):
                let updated = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
                threadInfos.append(IPCThreadInfo(thread: updated, projectName: projectName))
            case .failure(let error):
                errors.append("Thread \(i): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty, threadInfos.isEmpty {
            return .failure("All threads failed: \(errors.joined(separator: "; "))", id: request.id)
        }

        var response = IPCResponse(ok: true, id: request.id, threads: threadInfos)
        if !errors.isEmpty {
            response.warning = "Some threads failed: \(errors.joined(separator: "; "))"
        }
        return response
    }

    private func listProjects(_ request: IPCRequest) -> IPCResponse {
        let settings = persistence.loadSettings()
        let projects = settings.projects.map { IPCProjectInfo(project: $0) }
        let activeAgents = settings.availableActiveAgents.map(\.rawValue)
        return IPCResponse(ok: true, id: request.id, projects: projects, activeAgents: activeAgents)
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
            let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
            var info = IPCThreadInfo(thread: thread, projectName: projectName)
            info.sectionName = resolveSectionName(for: thread, settings: settings)
            info.sectionId = thread.sectionId?.uuidString
            info.status = makeThreadStatus(for: thread)
            return info
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
            try await tmux.sendText(sessionName: sessionName, text: prompt)
            try? await Task.sleep(nanoseconds: 200_000_000)
            try await tmux.sendEnter(sessionName: sessionName)
        } catch {
            return .failure("Failed to send prompt: \(error.localizedDescription)", id: request.id)
        }

        if thread.agentTmuxSessions.contains(sessionName) {
            threadManager.scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: sessionName)
            // Record in submitted history so auto-rename fires immediately,
            // without waiting for the user to open the thread or a bell event.
            threadManager.appendToSubmittedPromptHistory(
                threadId: thread.id,
                sessionName: sessionName,
                prompt: prompt
            )
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
            Task { @MainActor in threadManager.markThreadArchiving(id: thread.id) }
            let syncOverride: Bool? = request.skipLocalSync == true ? false : nil
            let warning = try await threadManager.archiveThread(
                thread,
                force: request.force ?? false,
                syncLocalPathsBackToRepo: syncOverride,
                awaitLocalSync: true
            )
            return .success(id: request.id, warning: warning)
        } catch {
            return .failure("Failed to archive thread: \(error.localizedDescription)", id: request.id)
        }
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
            var tab = IPCTabInfo(index: index, sessionName: sessionName, isAgent: isAgent)
            if isAgent {
                tab.agentType = threadManager.agentType(for: thread, sessionName: sessionName)?.rawValue
                tab.isBusy = thread.busySessions.contains(sessionName) || thread.magentBusySessions.contains(sessionName)
                tab.isWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
                tab.hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
                tab.isBlockedByRateLimit = thread.rateLimitedSessions[sessionName] != nil
            }
            return tab
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
            // Default to project/global default agent
            useAgent = !thread.agentTmuxSessions.isEmpty
            requestedAgent = nil
        }
        if let requestedAgent, !persistence.loadSettings().availableActiveAgents.contains(requestedAgent) {
            return .failure("Agent type is not enabled: \(requestedAgent.rawValue)", id: request.id)
        }

        do {
            let initialPrompt: String?
            if useAgent, let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                initialPrompt = prompt
            } else {
                initialPrompt = nil
            }
            let tab = try await threadManager.addTab(
                to: thread,
                useAgentCommand: useAgent,
                requestedAgentType: requestedAgent,
                initialPrompt: initialPrompt,
                startFresh: request.fresh == true,
                customTitle: request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                modelId: request.modelId,
                reasoningLevel: request.reasoningLevel
            )
            // Finalize session context (legacy pipe cleanup/rollback path, cwd enforcement)
            // — same as UI path.
            let latestThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
            _ = await threadManager.recreateSessionIfNeeded(
                sessionName: tab.tmuxSessionName,
                thread: latestThread
            )

            let isAgent = useAgent
            let info = IPCTabInfo(
                index: tab.index,
                sessionName: tab.tmuxSessionName,
                isAgent: isAgent
            )

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
            agentType: threadManager.effectiveAgentType(for: thread.projectId),
            projectId: thread.projectId
        )
        guard case .candidates(let candidates) = renameResult else {
            return .failure("Could not generate a branch name from the prompt", id: request.id)
        }

        var didRename = false
        let renameCandidates = candidates.filter { $0 != thread.branchName }
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

    private func setThreadIcon(_ request: IPCRequest) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let iconRaw = request.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return .failure("Missing required field: icon", id: request.id)
        }

        guard let icon = ThreadIcon(rawValue: iconRaw) else {
            let validIcons = ThreadIcon.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure("Unknown icon: \(iconRaw). Valid: \(validIcons)", id: request.id)
        }

        do {
            try threadManager.setThreadIcon(threadId: thread.id, icon: icon)
        } catch {
            return .failure("Failed to set thread icon: \(error.localizedDescription)", id: request.id)
        }

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func setBaseBranch(_ request: IPCRequest) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let baseBranch = request.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseBranch.isEmpty else {
            return .failure("Missing required field: baseBranch", id: request.id)
        }

        threadManager.setBaseBranch(baseBranch, for: thread.id)

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let resolvedBase = threadManager.resolveBaseBranch(for: updated)
        let info = IPCThreadInfo(thread: updated, projectName: projectName, baseBranch: resolvedBase)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func setThreadHidden(_ request: IPCRequest, hidden: Bool) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        if thread.isMain {
            return .failure("Main threads cannot be hidden", id: request.id)
        }

        guard thread.isSidebarHidden != hidden else {
            let settings = persistence.loadSettings()
            let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
            let info = IPCThreadInfo(thread: thread, projectName: projectName)
            return IPCResponse(ok: true, id: request.id, thread: info)
        }

        threadManager.toggleThreadHidden(threadId: thread.id)

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func setThreadKeepAlive(_ request: IPCRequest, enabled: Bool) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard thread.isKeepAlive != enabled else {
            let settings = persistence.loadSettings()
            let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
            let info = IPCThreadInfo(thread: thread, projectName: projectName)
            return IPCResponse(ok: true, id: request.id, thread: info)
        }

        threadManager.toggleThreadKeepAlive(threadId: thread.id)

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func setTabKeepAlive(_ request: IPCRequest, enabled: Bool) -> IPCResponse {
        let thread: MagentThread
        switch resolveThread(request) {
        case .found(let t): thread = t
        case .error(let err): return err
        }

        guard let sessionName = request.sessionName, !sessionName.isEmpty else {
            return .failure("Missing required field: sessionName (pass via --session)", id: request.id)
        }

        guard thread.tmuxSessionNames.contains(sessionName) else {
            return .failure("Session not found in thread: \(sessionName)", id: request.id)
        }

        let isProtected = thread.protectedTmuxSessions.contains(sessionName)
        guard isProtected != enabled else {
            let settings = persistence.loadSettings()
            let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
            let info = IPCThreadInfo(thread: thread, projectName: projectName)
            return IPCResponse(ok: true, id: request.id, thread: info)
        }

        threadManager.toggleSessionKeepAlive(threadId: thread.id, sessionName: sessionName)

        let settings = persistence.loadSettings()
        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "unknown"
        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else {
            return .success(id: request.id)
        }
        let info = IPCThreadInfo(thread: updated, projectName: projectName)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func setSectionKeepAlive(_ request: IPCRequest, enabled: Bool) -> IPCResponse {
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
            guard sections[sectionIndex].isKeepAlive != enabled else { return .success(id: request.id) }
            sections[sectionIndex].isKeepAlive = enabled
            settings.projects[projectIndex].threadSections = sections
            try? persistence.saveSettings(settings)
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.name.caseInsensitiveCompare(sectionName) == .orderedSame }) else {
                return .failure("Section not found: \(sectionName)", id: request.id)
            }
            guard settings.threadSections[sectionIndex].isKeepAlive != enabled else { return .success(id: request.id) }
            settings.threadSections[sectionIndex].isKeepAlive = enabled
            try? persistence.saveSettings(settings)
        }

        notifySectionsDidChange()
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil)
        return .success(id: request.id)
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
        let resolvedBase = threadManager.resolveBaseBranch(for: thread)
        let info = IPCThreadInfo(thread: thread, projectName: projectName, baseBranch: resolvedBase)
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
        let sectionName = resolveSectionName(for: thread, settings: settings)

        // Build tab list
        let tabs = thread.tmuxSessionNames.enumerated().map { index, sessionName in
            let isAgent = thread.agentTmuxSessions.contains(sessionName)
            return IPCTabInfo(index: index, sessionName: sessionName, isAgent: isAgent)
        }

        let status = makeThreadStatus(for: thread)

        let info = IPCThreadInfo(thread: thread, projectName: projectName, sectionName: sectionName, tabs: tabs, status: status)
        return IPCResponse(ok: true, id: request.id, thread: info)
    }

    private func resolveSectionName(for thread: MagentThread, settings: AppSettings) -> String? {
        let sections = settings.sections(for: thread.projectId)
        if let sectionId = thread.sectionId,
           let section = sections.first(where: { $0.id == sectionId }) {
            return section.name
        }
        return settings.defaultSection(for: thread.projectId)?.name
    }

    func makeThreadStatus(for thread: MagentThread) -> IPCThreadStatus {
        IPCThreadStatus(
            isBusy: thread.isAnyBusy,
            isWaitingForInput: thread.hasWaitingForInput,
            hasUnreadCompletion: thread.hasUnreadAgentCompletion,
            isDirty: thread.isDirty,
            isFullyDelivered: thread.isFullyDelivered,
            showArchiveSuggestion: thread.showArchiveSuggestion,
            isPinned: thread.isPinned,
            isSidebarHidden: thread.isSidebarHidden,
            isArchived: thread.isArchived,
            isBlockedByRateLimit: thread.isBlockedByRateLimit,
            hasBranchMismatch: thread.hasBranchMismatch,
            jiraTicketKey: AppFeatures.jiraSyncEnabled ? thread.jiraTicketKey : nil,
            jiraUnassigned: AppFeatures.jiraSyncEnabled ? thread.jiraUnassigned : false,
            branchName: thread.branchName,
            baseBranch: thread.baseBranch,
            rateLimitDescription: thread.isBlockedByRateLimit ? thread.rateLimitLiftDescription : nil
        )
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
