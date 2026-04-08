import Foundation

/// Single source of truth for Magent IPC hints + on-demand CLI docs.
public enum IPCAgentDocs {

    /// CLI commands available through magent-cli.
    nonisolated private static let cliCommands = """
    /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--prompt <text> | --prompt-file <path>] [--name <slug>] [--description <text>] [--section <name>] [--base-thread <name> | --base-branch <name>] [--from-thread <name|main|none>] [--select] [--no-submit]
    /tmp/magent-cli batch-create --project <name> --file <specs.json> [--from-thread <name|main|none>] [--no-submit]
    /tmp/magent-cli list-projects
    /tmp/magent-cli list-threads [--project <name>]
    /tmp/magent-cli send-prompt --thread <name> (--prompt <text> | --prompt-file <path>)
    /tmp/magent-cli archive-thread --thread <name> [--force] [--skip-local-sync]
    /tmp/magent-cli delete-thread --thread <name>
    /tmp/magent-cli list-tabs --thread <name>
    /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--title <text>] [--fresh|--no-resume] [--prompt <text>]
    /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
    /tmp/magent-cli current-thread
    /tmp/magent-cli auto-rename-thread --thread <name> --prompt <text>
    /tmp/magent-cli rename-thread --thread <name> --prompt <text>
    /tmp/magent-cli rename-branch --thread <name> --name <text>
    /tmp/magent-cli set-description --thread <name> [--description <text> | --clear]
    /tmp/magent-cli set-thread-icon --thread <name> --icon <feature|fix|improvement|refactor|test|other>
    /tmp/magent-cli set-base-branch --thread <name> --base-branch <branch>
    /tmp/magent-cli hide-thread --thread <name>
    /tmp/magent-cli unhide-thread --thread <name>
    /tmp/magent-cli keep-alive-thread --thread <name> [--remove]
    /tmp/magent-cli keep-alive-tab --thread <name> --session <name> [--remove]
    /tmp/magent-cli thread-info --thread <name>
    /tmp/magent-cli list-sections [--project <name>]
    /tmp/magent-cli add-section --name <name> [--color <hex>] [--project <name>]
    /tmp/magent-cli remove-section --name <name> [--project <name>]
    /tmp/magent-cli reorder-section --name <name> --position <n> [--project <name>]
    /tmp/magent-cli rename-section --name <name> --new-name <text> [--color <hex>] [--project <name>]
    /tmp/magent-cli hide-section --name <name> [--project <name>]
    /tmp/magent-cli show-section --name <name> [--project <name>]
    /tmp/magent-cli keep-alive-section --name <name> [--project <name>] [--remove]
    """

    /// Usage guidance appended after the command listing.
    nonisolated private static let usageNotes = """
    Use current-thread to discover your thread name. The thread/worktree name never changes after creation; only the git branch may be renamed.
    When creating threads for a specific task, ALWAYS provide --description (what the thread is about) and --prompt (the initial task/instructions for the agent). The description appears in the sidebar; the prompt is injected into the agent so it knows what to work on. Only omit --prompt for threads that need no initial task. For multi-line prompts or text with special characters (quotes, dashes, newlines), prefer --prompt-file: write the prompt to a temp file and pass the path. This avoids shell escaping issues that can produce invalid JSON.
    When spawning many threads at once, use batch-create with --no-submit. This creates all threads in parallel and injects the prompt text without pressing Enter, avoiding CPU spikes from concurrent agents. Users can submit each prompt manually when ready. The specs.json file is a JSON array of objects with keys: prompt, description, name, agentType, modelId, reasoningLevel, sectionName, baseThreadName, baseBranch, fromThreadName, noSubmit.
    When creating threads, use --description to name them upfront (AI generates a slug respecting project naming rules). Only use --name when the user explicitly provides a literal name. Omit both for a random name.
    When called from inside a Magent session, create-thread and batch-create automatically inherit the current thread's branch and section (and position the new thread directly below it in the sidebar). This means you do NOT need to manually pass --base-branch or --section in the common case. Use --base-thread or --base-branch only when the user explicitly wants a different base. Use --section only when the user explicitly wants a different section. Use --from-thread none to suppress auto-detection. Use --from-thread main to inherit from the project's main worktree thread instead.
    When the user explicitly names an agent, pass that exact agent in --agent. Do not silently substitute Claude for Codex or vice versa.
    Use create-tab --title when the user asks you to name the tab. Use create-tab --fresh (or --no-resume) when the user wants an isolated review tab that must not adopt an older Claude/Codex conversation from the same worktree path.
    Section names are case-insensitive throughout — "TODO" and "todo" resolve to the same section.
    Use auto-rename-thread (or its rename-thread alias) by default; it generates a branch name and description from one prompt. The thread/worktree name is never changed.
    Use rename-branch ONLY when the user gives a literal branch name (e.g. "rename this to kimchi-ramen"). If the user describes what the thread is about, use auto-rename-thread instead. Only the git branch is renamed; the thread/worktree name stays the same.
    Use set-description to manually set or clear the thread description without renaming the branch.
    Use set-thread-icon to manually set the thread icon type.
    Use hide-thread / unhide-thread to deprioritize a thread in the sidebar without archiving it.
    Use archive-thread --skip-local-sync to avoid writing local sync path changes into the main worktree during archive.
    Section commands without --project operate on global sections. With --project, they operate on project-specific overrides.

    Common user intents and how to handle them:

    "review thread" / "review this thread" / "review magent thread":
    The user wants a code review of the current thread's changes. Create a new agent tab in the current thread to perform the review:
    1. Use `thread-info` to check which agents are enabled (activeAgents field) and which is the default.
    2. Create a review tab: `/tmp/magent-cli create-tab --thread <name> --title "Review" --fresh --prompt "Review the changes on this branch compared to the base branch. Provide feedback on code quality, correctness, and potential issues."` — use the default agent (omit --agent) unless the user explicitly requests a specific agent.
    3. After creating the tab, check its status via `thread-info`. If the new tab shows isBlockedByRateLimit, close it and retry with a different enabled agent: `/tmp/magent-cli close-tab --thread <name> --session <session> && /tmp/magent-cli create-tab --thread <name> --title "Review" --fresh --agent <fallback-agent> --prompt "..."`.
    4. Try each enabled agent in activeAgents until one is not rate-limited, or inform the user if all agents are rate-limited.

    "archive thread" / "archive this thread" / "archive magent thread":
    The user wants to archive the current thread (same as the Archive button in the GUI). This removes the worktree and hides the thread from the sidebar while keeping the git branch. Before archiving:
    1. Ensure all work is committed and pushed if needed.
    2. Run: `/tmp/magent-cli archive-thread --thread <name> --skip-local-sync`
    Use --skip-local-sync by default to avoid modifying the main worktree. Use --force if the thread has uncommitted changes and the user has confirmed they want to discard them.
    """

    /// On-demand CLI reference returned by `magent-cli docs`.
    public nonisolated static let cliReferenceText: String = """
    Magent IPC is available via `/tmp/magent-cli`.

    Commands:
    \(cliCommands)

    Usage guidance:
    \(usageNotes)
    """

    /// Lightweight prompt hint used for Claude's `--append-system-prompt`.
    public static let claudeSystemPrompt: String = """
    Magent IPC is available via `/tmp/magent-cli` when needed.
    Use it only for thread/tab/section management tasks. In Magent, "threads" are managed worktrees with embedded terminals.
    For details on demand, run `/tmp/magent-cli docs` (full reference) or `/tmp/magent-cli help` (quick usage).
    """

    // MARK: - Codex AGENTS.md

    public static let codexIPCMarkerStart = "<!-- magent-ipc-start -->"
    public static let codexIPCMarkerEnd = "<!-- magent-ipc-end -->"
    public static let codexIPCVersion = "<!-- magent-ipc-v20 -->"

    /// Lightweight Codex `AGENTS.md` hint that points to on-demand docs.
    public static let codexAgentsMdBlock: String = """
    \(codexIPCMarkerStart)
    \(codexIPCVersion)
    # Magent IPC

    When the `MAGENT_SOCKET` environment variable is set, you are running inside
    a Magent-managed terminal. Magent IPC is available via `/tmp/magent-cli`.
    In Magent, "threads" are managed worktrees with embedded terminals.

    Use it only for Magent management tasks (threads, tabs, sections).
    Load details on demand with:
    - `/tmp/magent-cli docs` (full command reference + usage guidance)
    - `/tmp/magent-cli help` (quick usage)
    \(codexIPCMarkerEnd)
    """
}
