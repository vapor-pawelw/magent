import Foundation

/// Single source of truth for Magent IPC hints + on-demand CLI docs.
public enum IPCAgentDocs {

    /// CLI commands available through magent-cli.
    nonisolated private static let cliCommands = """
    /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom|terminal] [--prompt <text>] [--name <slug>] [--description <text>] [--base-thread <name> | --base-branch <name>] [--no-select]
    /tmp/magent-cli list-projects
    /tmp/magent-cli list-threads [--project <name>]
    /tmp/magent-cli send-prompt --thread <name> --prompt <text>
    /tmp/magent-cli archive-thread --thread <name> [--force] [--skip-local-sync]
    /tmp/magent-cli delete-thread --thread <name>
    /tmp/magent-cli list-tabs --thread <name>
    /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
    /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
    /tmp/magent-cli current-thread
    /tmp/magent-cli auto-rename-thread --thread <name> --prompt <text>
    /tmp/magent-cli rename-thread --thread <name> --prompt <text>
    /tmp/magent-cli rename-branch --thread <name> --name <text>
    /tmp/magent-cli set-description --thread <name> [--description <text> | --clear]
    /tmp/magent-cli set-thread-icon --thread <name> --icon <feature|fix|improvement|refactor|test|other>
    /tmp/magent-cli hide-thread --thread <name>
    /tmp/magent-cli unhide-thread --thread <name>
    /tmp/magent-cli thread-info --thread <name>
    /tmp/magent-cli list-sections [--project <name>]
    /tmp/magent-cli add-section --name <name> [--color <hex>] [--project <name>]
    /tmp/magent-cli remove-section --name <name> [--project <name>]
    /tmp/magent-cli reorder-section --name <name> --position <n> [--project <name>]
    /tmp/magent-cli rename-section --name <name> --new-name <text> [--color <hex>] [--project <name>]
    /tmp/magent-cli hide-section --name <name> [--project <name>]
    /tmp/magent-cli show-section --name <name> [--project <name>]
    """

    /// Usage guidance appended after the command listing.
    nonisolated private static let usageNotes = """
    Use current-thread to discover your thread name (do not rely on the worktree directory name — it may differ after renames).
    When creating threads, use --description to name them upfront (AI generates a slug respecting project naming rules). Only use --name when the user explicitly provides a literal name. Omit both for a random name.
    To branch from an existing thread, pass --base-thread <name>. Use --base-branch <name> only when you need an exact branch literal.
    Use auto-rename-thread (or its rename-thread alias) by default; it generates both branch name and description from one prompt.
    Use rename-branch ONLY when the user gives a literal branch name (e.g. "rename this to kimchi-ramen"). If the user describes what the thread is about, use auto-rename-thread instead.
    Use set-description to manually set or clear the thread description without renaming the branch.
    Use set-thread-icon to manually set the thread icon type.
    Use hide-thread / unhide-thread to deprioritize a thread in the sidebar without archiving it.
    Use archive-thread --skip-local-sync to avoid writing local sync path changes into the main worktree during archive.
    Section commands without --project operate on global sections. With --project, they operate on project-specific overrides.
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
    Use it only for thread/tab/section management tasks.
    For details on demand, run `/tmp/magent-cli docs` (full reference) or `/tmp/magent-cli help` (quick usage).
    """

    // MARK: - Codex AGENTS.md

    public static let codexIPCMarkerStart = "<!-- magent-ipc-start -->"
    public static let codexIPCMarkerEnd = "<!-- magent-ipc-end -->"
    public static let codexIPCVersion = "<!-- magent-ipc-v11 -->"

    /// Lightweight Codex `AGENTS.md` hint that points to on-demand docs.
    public static let codexAgentsMdBlock: String = """
    \(codexIPCMarkerStart)
    \(codexIPCVersion)
    # Magent IPC

    When the `MAGENT_SOCKET` environment variable is set, you are running inside
    a Magent-managed terminal. Magent IPC is available via `/tmp/magent-cli`.

    Use it only for Magent management tasks.
    Load details on demand with:
    - `/tmp/magent-cli docs` (full command reference + usage guidance)
    - `/tmp/magent-cli help` (quick usage)
    \(codexIPCMarkerEnd)
    """
}
