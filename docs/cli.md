# CLI Reference

mAgent installs a `magent-cli` script at `/tmp/magent-cli` on launch. It communicates with the running app over a Unix domain socket (`/tmp/magent.sock`).
It also installs launcher commands (`magent`, `magent-cli`, `magent-tmux`) into common user PATH directories when writable.

The CLI is auto-updated when the app version changes.

## Interactive Commands

`magent-cli` with no arguments opens interactive mode when run in a TTY.

```bash
magent-cli
magent-cli interactive [--project <name>]
magent-cli ls [--project <name>]
magent-cli attach --session <tmux-session>
magent-cli attach (--thread <name> | --thread-id <id>) [--index <n>]
magent-cli docs
```

- `interactive`: picker flow `project -> thread (or create) -> tab -> tmux attach`, with live status badges (`done`, `busy`, `input`, `dirty`, `limited`, `delivered`) and ANSI colors when the terminal supports them
- `ls`: table view (project/thread/branch/type/status/description/session), reusing the same live thread status data
- `attach`: attach directly by session or by thread + tab index
- `docs`: full on-demand IPC command reference + usage guidance (for agent/tooling prompts)

## Thread Commands

### create-thread

Create a new thread (worktree + agent session).

```bash
magent-cli create-thread --project <name> [options]
```

| Option | Description |
|--------|-------------|
| `--project <name>` | **Required.** Project to create the thread in. |
| `--agent <type>` | Agent type: `claude`, `codex`, `custom`, or `terminal`. Defaults to project/global setting. |
| `--prompt <text>` | Initial prompt to send to the agent after creation. |
| `--name <slug>` | Exact thread name (must be unique). |
| `--description <text>` | Natural-language description — AI generates a slug from it. |
| `--section <name>` | Place the thread in this section. |
| `--base-thread <name>` | Use an existing thread's branch as the base for the new thread. |
| `--base-branch <name>` | Use an explicit branch as the base for the new thread. |

If neither `--name` nor `--description` is given, a random name is generated.
`--base-thread` and `--base-branch` are mutually exclusive.

### list-projects

List all registered projects.

```bash
magent-cli list-projects
```

### list-threads

List all threads, optionally filtered by project.

```bash
magent-cli list-threads [--project <name>]
```

Each returned thread now includes the same `status` object described under `thread-info`, so CLI tools can render live state without issuing one request per thread.

### thread-info

Get full details for a thread, including runtime status.

```bash
magent-cli thread-info --thread <name>
magent-cli thread-info --thread-id <id>
```

The response includes a `status` object with all UI-visible indicators:

| Field | Type | Description |
|-------|------|-------------|
| `isBusy` | bool | Agent is actively working (spinner in UI) |
| `isWaitingForInput` | bool | Agent needs user input (yellow `!` in UI) |
| `hasUnreadCompletion` | bool | Agent finished, not yet viewed (green dot) |
| `isDirty` | bool | Uncommitted changes in worktree (orange dot) |
| `isFullyDelivered` | bool | All commits merged to base branch |
| `showArchiveSuggestion` | bool | Thread is fully delivered and idle |
| `isPinned` | bool | Thread is pinned to top |
| `isSidebarHidden` | bool | Thread is hidden to the bottom of the list and shown dimmed |
| `isArchived` | bool | Thread has been archived |
| `isBlockedByRateLimit` | bool | All agent tabs are rate-limited (red hourglass) |
| `hasBranchMismatch` | bool | Worktree HEAD doesn't match expected branch |
| `jiraTicketKey` | string? | Associated Jira ticket (e.g. `IP-1234`) |
| `jiraUnassigned` | bool | Jira ticket no longer assigned to user |
| `branchName` | string | Git branch name |
| `taskDescription` | string? | Optional short description shown in the thread row |
| `baseBranch` | string? | Target branch for delivery tracking |
| `rateLimitDescription` | string? | Human-readable reset info (only when rate-limited) |

### current-thread

Identify the current thread from inside a tmux session.

```bash
magent-cli current-thread
```

Must be run from within a mAgent-managed tmux session.

### send-prompt

Send a prompt to a thread's agent.

```bash
magent-cli send-prompt --thread <name> --prompt <text>
```

### auto-rename-thread

Rename a thread from a single prompt. This generates both:
- branch slug
- thread description (2-8 words)

```bash
magent-cli auto-rename-thread --thread <name> --prompt <text>
```

`rename-thread` remains as a compatibility alias and accepts `--prompt` (or legacy `--description`).

### rename-branch

Rename a thread branch to an exact name.

```bash
magent-cli rename-branch --thread <name> --name <text>
```

`rename-thread-exact` remains as a compatibility alias.

### set-description

Set or clear a thread description without renaming the branch.

```bash
magent-cli set-description --thread <name> --description <text>
magent-cli set-description --thread <name> --clear
```

### set-thread-icon

Set a thread icon manually.

```bash
magent-cli set-thread-icon --thread <name> --icon <feature|fix|improvement|refactor|test|other>
```

### hide-thread

Hide a thread to the bottom of its section/list without archiving it.

```bash
magent-cli hide-thread --thread <name>
```

### unhide-thread

Restore a hidden thread to the normal sidebar group.

```bash
magent-cli unhide-thread --thread <name>
```

### archive-thread

Archive a thread (removes worktree, keeps git branch).

When project `Local Sync Paths` are configured, archive performs merge-back from the thread's snapshotted path list to the repo root before worktree removal (unless `--skip-local-sync` is passed, or the app-wide archive local-sync setting is disabled). Files unchanged in the thread since creation are skipped. In non-interactive CLI mode, conflicting overwrite targets are skipped. Pass `--force` to continue archiving even if local sync fails for a non-conflict reason.

```bash
magent-cli archive-thread --thread <name> [--force] [--skip-local-sync]
```

### delete-thread

Delete a thread (removes worktree and git branch).

```bash
magent-cli delete-thread --thread <name>
```

### move-thread

Move a thread to a different section.

```bash
magent-cli move-thread --thread <name> --section <name>
```

## Tab Commands

### create-tab

Add a tab to an existing thread.

```bash
magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
```

Use `--agent terminal` for a plain shell tab. If `--agent` is omitted, defaults to the project/global default agent from Settings.

### list-tabs

List all tabs in a thread.

```bash
magent-cli list-tabs --thread <name>
magent-cli list-tabs --thread-id <id>
```

### close-tab

Close a tab by index or session name. Cannot close the last tab — use `archive-thread` or `delete-thread` instead.

```bash
magent-cli close-tab --thread <name> --index <n>
magent-cli close-tab --thread <name> --session <session-name>
```

## Section Commands

All section commands accept an optional `--project <name>` flag. Without it, they operate on global sections. With it, they operate on project-specific overrides.

### list-sections

```bash
magent-cli list-sections [--project <name>]
```

### add-section

```bash
magent-cli add-section --name <name> [--color <hex>] [--project <name>]
```

### remove-section

Cannot remove a section that still contains threads.

```bash
magent-cli remove-section --name <name> [--project <name>]
```

### rename-section

```bash
magent-cli rename-section --name <name> --new-name <text> [--color <hex>] [--project <name>]
```

### reorder-section

```bash
magent-cli reorder-section --name <name> --position <n> [--project <name>]
```

### hide-section / show-section

Hidden sections are excluded from the UI but not deleted.

```bash
magent-cli hide-section --name <name> [--project <name>]
magent-cli show-section --name <name> [--project <name>]
```

## Environment Variables

These are injected into every mAgent-managed tmux session:

| Variable | Description |
|----------|-------------|
| `MAGENT_WORKTREE_PATH` | Absolute path to the thread's git worktree |
| `MAGENT_PROJECT_PATH` | Absolute path to the main repository |
| `MAGENT_WORKTREE_NAME` | Thread name |
| `MAGENT_PROJECT_NAME` | Project name |
| `MAGENT_SOCKET` | Path to the IPC socket (default: `/tmp/magent.sock`) |
