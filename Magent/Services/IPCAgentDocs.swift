import Foundation

/// Single source of truth for IPC CLI command documentation injected into agents.
enum IPCAgentDocs {

    /// CLI commands available through magent-cli.
    private static let cliCommands = """
    /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom] [--prompt <text>] [--name <slug>] [--description <text>]
    /tmp/magent-cli list-projects
    /tmp/magent-cli list-threads [--project <name>]
    /tmp/magent-cli send-prompt --thread <name> --prompt <text>
    /tmp/magent-cli archive-thread --thread <name>
    /tmp/magent-cli delete-thread --thread <name>
    /tmp/magent-cli list-tabs --thread <name>
    /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
    /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
    /tmp/magent-cli current-thread
    /tmp/magent-cli rename-thread --thread <name> --description <text>
    /tmp/magent-cli rename-thread-exact --thread <name> --name <text>
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
    private static let usageNotes = """
    Use current-thread to discover your thread name (do not rely on the worktree directory name — it may differ after renames).
    When creating threads, use --description to name them upfront (AI generates a slug respecting project naming rules). Only use --name when the user explicitly provides a literal name. Omit both for a random name.
    Use rename-thread by default (generates a slug from the description). Only use rename-thread-exact when the user specifies an exact name.
    rename-thread-exact is ONLY for when the user gives a literal name (e.g. "rename this to kimchi-ramen"). If the user describes what the thread is about (e.g. "rename this to something about authentication"), use rename-thread with that description instead.
    Section commands without --project operate on global sections. With --project, they operate on project-specific overrides.
    """

    /// Plain-text format used for Claude's `--append-system-prompt`.
    static let claudeSystemPrompt: String = """
    You have access to Magent IPC. Use `/tmp/magent-cli` to manage threads and tabs:
    \(cliCommands.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
    \(usageNotes)
    """

    // MARK: - Codex AGENTS.md

    static let codexIPCMarkerStart = "<!-- magent-ipc-start -->"
    static let codexIPCMarkerEnd = "<!-- magent-ipc-end -->"
    static let codexIPCVersion = "<!-- magent-ipc-v6 -->"

    /// Markdown format used for Codex's `AGENTS.md` file.
    static let codexAgentsMdBlock: String = """
    \(codexIPCMarkerStart)
    \(codexIPCVersion)
    # Magent IPC

    When the `MAGENT_SOCKET` environment variable is set, you are running inside
    a Magent-managed terminal. Use `/tmp/magent-cli` to manage threads and tabs:

    ```
    \(cliCommands)
    ```

    Use `current-thread` to discover your thread name (do not rely on the worktree directory name — it may differ after renames).
    When creating threads, use `--description` to name them upfront (AI generates a slug respecting project naming rules). Only use `--name` when the user explicitly provides a literal name. Omit both for a random name.
    Use `rename-thread` by default (generates a slug from the description).
    Only use `rename-thread-exact` when the user specifies an exact name.
    `rename-thread-exact` is ONLY for when the user gives a literal name (e.g. "rename this to kimchi-ramen"). If the user describes what the thread is about (e.g. "rename this to something about authentication"), use `rename-thread` with that description instead.
    Section commands without `--project` operate on global sections. With `--project`, they operate on project-specific overrides.
    \(codexIPCMarkerEnd)
    """
}
