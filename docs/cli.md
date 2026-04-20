# CLI Reference

mAgent installs a `magent-cli` script at `/tmp/magent-cli` on launch. It communicates with the running app over a Unix domain socket (`/tmp/magent.sock`).
It also installs launcher commands (`magent`, `magent-cli`, `magent-tmux`) into common user PATH directories when writable.

The CLI is auto-updated when the app version changes. A background watchdog checks every 30 seconds and reinstalls the script if macOS purges `/tmp` while the app is running. The same watchdog covers tmux helper scripts (bell watcher, URL capture).

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

- `interactive`: picker flow `project -> thread (or create) -> tab -> tmux attach`, with ANSI colors when the terminal supports them. Tab rows use real tab names (not `Tab #`). Thread rows show branch/worktree info, PR/Jira details (when present), and live status badges (`done`, `busy`, `input`, `dirty`, `limited`, `delivered`, `♥`) each on their own line. Threads are grouped by section in sidebar order; if a thread has only one tab the tab step is skipped. The CLI remembers the last attached session context and, on the next interactive run (without `--project`), opens directly in that thread when possible; fallback is last project, then project picker. Uses a numbered list (`1) … 2) …`) without fzf for reliable SSH/phone use.
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
| `--agent <type>` | Agent type: `claude`, `codex`, `custom`, or `terminal`. Defaults to project/global setting. Errors if the requested agent is disabled in Settings. |
| `--model <id>` | Model ID to launch the initial tab with (e.g. `claude-opus-4-5`). Falls back to the agent's configured default when omitted. |
| `--reasoning <level>` | Reasoning level for the initial tab: `low`, `medium`, `high`, `max` (Claude) or `low`, `medium`, `high`, `xhigh` (Codex). Omit to use the agent's default. |
| `--prompt <text>` | Initial prompt to send to the agent after creation. |
| `--prompt-file <path>` | Read the initial prompt from a file. Useful for multi-line prompts with special characters. |
| `--name <slug>` | Exact thread name (must be unique). |
| `--description <text>` | Natural-language description — AI generates a slug from it. |
| `--section <name>` | Place the thread in this section (case-insensitive). |
| `--base-thread <name>` | Use an existing thread's branch as the base for the new thread. |
| `--base-branch <name>` | Use an explicit branch as the base for the new thread. |
| `--from-thread <name>` | Inherit base branch and section from the named thread. The new thread is positioned directly below it in the sidebar. Special values: `main` (project's main worktree), `none` (suppress auto-detection). |
| `--priority <1-5>` | Thread priority on a 1–5 scale (1 lowest, 5 highest). Shown as cumulative dots in the sidebar next to the last-activity time. Only set this when the user has given real urgency/importance signal — don't guess from the task description. |
| `--select` | Switch the GUI to the newly created thread. By default, CLI-created threads appear in the sidebar without switching focus. |
| `--no-submit` | Inject the prompt text into the agent input but don't press Enter. The user can review and submit manually. |

`--select` uses the same UI selection semantics as sidebar navigation:
- if the target thread is in the main window, Magent selects it there and shows its content;
- if the target thread is popped out, Magent brings that pop-out window to front instead of replacing the main-window content.

If neither `--name` nor `--description` is given, a random name is generated.
`--base-thread` and `--base-branch` are mutually exclusive.

> **Agent selection**: `--agent` determines the agent type for the thread's *initial tab*. If you want a Claude thread, pass `--agent claude` to `create-thread` — do **not** omit `--agent` and follow up with `create-tab --agent claude`. Omitting `--agent` creates the initial tab using the project/global default agent (often `codex` or `terminal`), leaving you with an unwanted extra tab.

**Auto-detection**: When called from inside a Magent session (i.e. `$MAGENT_THREAD_ID` is set), `create-thread` automatically inherits the current thread's branch, section, and sidebar position — as if `--from-thread` were set to the current thread. This means agents and scripts don't need to manually resolve the current context. Use `--from-thread none` to suppress this behavior. Explicit `--base-branch`, `--base-thread`, or `--section` flags always take precedence over the inherited values.

**Timeout note**: `create-thread` allows up to 120 seconds for the server to respond, since it involves git worktree creation (can be slow on large repos) and optionally an AI agent call to generate a slug from `--description`. Prefer `--name` over `--description` when you want the exact name and faster response.

### batch-create

Create multiple threads in parallel. Threads are created concurrently for maximum throughput with minimal UI blocking.

```bash
magent-cli batch-create --project <name> --file <specs.json> [--from-thread <name|main|none>] [--no-submit]
```

| Option | Description |
|--------|-------------|
| `--project <name>` | **Required.** Project to create all threads in. |
| `--file <specs.json>` | **Required.** Path to a JSON file containing an array of thread specs. |
| `--from-thread <name>` | Inherit base branch, section, and sidebar position for all specs (can be overridden per-spec). Same special values as `create-thread`. |
| `--no-submit` | Apply `--no-submit` to all threads (can also be set per-thread in the spec). |

Each element in the specs array is an object with optional keys:

| Key | Description |
|-----|-------------|
| `prompt` | Initial prompt for the agent (inline string). |
| `promptFile` | Path to a file whose contents are used as the initial prompt. Overrides `prompt` when both are set. Prefer this over `prompt` for long prompts — inline JSON strings with embedded newlines are fragile. |
| `description` | Natural-language description; AI generates a slug from it for the git branch name. |
| `name` | Exact git branch/thread name (sets the branch name directly, no AI generation). Takes precedence over `description`. |
| `agentType` | `claude`, `codex`, `custom`, or `terminal`. Errors if the agent is disabled in Settings. |
| `modelId` | Model ID to launch with (e.g. `claude-opus-4-5`). Falls back to the agent's configured default. |
| `reasoningLevel` | Reasoning level: `low`, `medium`, `high`, `max` (Claude) or `low`, `medium`, `high`, `xhigh` (Codex). |
| `sectionName` | Place thread in this section (case-insensitive). |
| `baseThreadName` | Branch from an existing thread. |
| `baseBranch` | Branch from an explicit branch. |
| `fromThreadName` | Per-spec override for `--from-thread`. |
| `priority` | Thread priority on a 1–5 scale (1 lowest, 5 highest). Only set when the user has given real urgency signal. |
| `noSubmit` | Per-thread override for `--no-submit`. |

> **`name` vs `description`**: Use `name` when you want an exact branch name (e.g. `"ip-1234-fix-login"`). Use `description` when you want AI to generate a short slug. If both are provided, `name` wins. The display name in the sidebar is the same as the branch name.

> **Long prompts**: Use `promptFile` instead of `prompt` for multi-line or long prompts. Inline prompts embedded in the JSON string can cause parse errors if they contain special characters. `promptFile` accepts any absolute or `~`-relative path and is read server-side (same machine).

Example `specs.json`:
```json
[
  {"description": "fix login timeout", "prompt": "The login form times out after 30s..."},
  {"description": "add dark mode support", "promptFile": "~/prompts/dark-mode.txt"},
  {"name": "refactor-api", "prompt": "Refactor the REST API client to use async/await"}
]
```

The response contains a `threads` array with info for each successfully created thread, and a `warning` field if any failed.

> **Agent selection**: Set `agentType` per-spec to control which agent each thread opens with. Omitting `agentType` falls back to the project/global default (often `codex`/`terminal`). If you want Claude threads, include `"agentType": "claude"` in every spec — do **not** omit it and add tabs afterwards.

The same auto-detection behavior as `create-thread` applies: when called from inside a Magent session, base branch, section, and sidebar position are inherited from the current thread unless overridden.

**Timeout note**: `batch-create` allows up to 300 seconds since it may involve multiple AI slug generation calls plus parallel git/tmux setup.

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

### list-archived

List archived threads, most recently archived first. Archived threads live only in the persisted `threads.json` (not in `ThreadManager.threads`), so this is the only way to query them via the CLI.

```bash
magent-cli list-archived [--project <name>] [--limit <n>]
```

Each returned thread includes:
- `branchName` — the git branch the worktree was attached to (the branch is preserved on archive)
- `worktreePath` / `worktreeName` — the full path and last-component directory name of the (now-removed) worktree
- `archivedAt` / `createdAt` — ISO-8601 timestamps for archive and original creation
- `agentType` — the thread's primary agent (`claude`, `codex`, `custom`, `terminal`) derived from the first agent session at archive time
- `jiraTicketKey` — linked Jira ticket key, if any (only when Jira sync is enabled)
- `baseBranch` — the branch the thread was based on
- `priority`, `threadIcon`, `signEmoji`, `isFavorite`, `isPinned`, `isSidebarHidden` — persisted sidebar metadata
- the same `sectionName` / `taskDescription` / `projectName` fields as `list-threads`

Use `--limit` to cap the result count (e.g. `--limit 10` for the ten most recent archives). Use `--project` to scope to a single project.

`thread-info --thread <name>` / `--thread-id <id>` also resolves archived threads, returning the same enriched metadata (without runtime `status`, which is only meaningful for active threads).

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
| `showArchiveSuggestion` | bool | Thread is fully delivered, idle, and has no unsubmitted input |
| `isPinned` | bool | Thread is pinned to top |
| `isFavorite` | bool | Thread is marked as favorite |
| `isSidebarHidden` | bool | Thread is hidden to the bottom of the list and shown dimmed |
| `isArchived` | bool | Thread has been archived |
| `isBlockedByRateLimit` | bool | All agent tabs are rate-limited (thread shows a rate-limit badge) |
| `hasBranchMismatch` | bool | Worktree HEAD doesn't match expected branch |
| `jiraTicketKey` | string? | Associated Jira ticket (e.g. `IP-1234`) |
| `jiraUnassigned` | bool | Jira ticket no longer assigned to user |
| `branchName` | string | Git branch name |
| `taskDescription` | string? | Optional short description shown in the thread row |
| `baseBranch` | string? | Target branch for delivery tracking |
| `rateLimitDescription` | string? | Human-readable reset info (only when rate-limited) |

### current-thread

Identify the current thread from inside a tmux session. Returns the thread's resolved base branch in the `baseBranch` field.

```bash
magent-cli current-thread
```

Must be run from within a mAgent-managed tmux session.

### send-prompt

Send a prompt to a thread's agent.

```bash
magent-cli send-prompt --thread <name> --prompt <text>
magent-cli send-prompt --thread <name> --prompt-file <path>
```

Use `--prompt-file` for multi-line prompts or text with special characters (quotes, dashes, newlines) to avoid shell escaping issues.

### auto-rename-thread

Rename a thread's git branch from a single prompt. This generates both:
- branch slug (only the git branch is renamed; the thread/worktree name stays the same)
- thread description (prefers 2-8 words; longer descriptions are kept)

```bash
magent-cli auto-rename-thread --thread <name> --prompt <text>
```

`rename-thread` remains as a compatibility alias and accepts `--prompt` (or legacy `--description`).
If the generated description exceeds the preferred 2-8 word range, the command succeeds and returns a `warning` so agents can immediately revise it.

### rename-branch

Rename a thread's git branch to an exact name. The thread/worktree name is never changed.

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

### set-priority

Set or clear the thread priority. Priority is a 1–5 scale (1 blue = lowest, 5 red = highest) shown as cumulative dots in the sidebar.

```bash
magent-cli set-priority --thread <name> --priority <1-5>
magent-cli set-priority --thread <name> --clear
```

**Agent guidance**: Only set priority when the user has given real signal about urgency or importance for that specific thread — e.g. a linked Jira priority, an explicit instruction ("this is urgent", "low priority chore"), or a blocker framing. Do not guess priority from the task description alone, do not default every thread to medium, and do not set priority on exploratory/research threads where the user hasn't expressed urgency. When unsure, leave priority unset.

### set-thread-icon

Set a thread icon manually.

```bash
magent-cli set-thread-icon --thread <name> --icon <feature|fix|improvement|refactor|test|other>
```

### set-base-branch

Set the base branch for a thread. This overrides automatic base branch resolution.

```bash
magent-cli set-base-branch --thread <name> --base-branch <branch>
```

### keep-alive-thread

Enable or disable Keep Alive on a thread. When enabled, all sessions in the thread are protected from idle eviction.

```bash
magent-cli keep-alive-thread --thread <name>
magent-cli keep-alive-thread --thread <name> --remove
```

### keep-alive-tab

Enable or disable Keep Alive on a single tab/session. Protected sessions are exempt from both manual cleanup and auto idle eviction.

```bash
magent-cli keep-alive-tab --thread <name> --session <name>
magent-cli keep-alive-tab --thread <name> --session <name> --remove
```

### keep-alive-section

Enable or disable Keep Alive on a section. When enabled, all threads in that section are protected from eviction.

```bash
magent-cli keep-alive-section --name <name> [--project <name>]
magent-cli keep-alive-section --name <name> [--project <name>] --remove
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

### favorite-thread

Mark a thread as favorite. Favorites are capped at 10.

```bash
magent-cli favorite-thread --thread <name>
```

### unfavorite-thread

Remove a thread from favorites.

```bash
magent-cli unfavorite-thread --thread <name>
```

### archive-thread

Archive a thread (removes worktree, keeps git branch).

When project `Local Sync Paths` are configured, archive performs merge-back from the thread's snapshotted path list to the repo root before worktree removal (unless `--skip-local-sync` is passed, or the app-wide archive local-sync setting is disabled). Files unchanged in the thread since creation are skipped. In non-interactive CLI mode, conflicting overwrite targets are skipped.

**Destructive-archive safety.** Archive runs `git worktree remove --force`, which deletes the worktree directory unconditionally. To prevent silent data loss, `archive-thread` refuses to run when:

- the worktree has uncommitted or untracked changes.

The refusal names the worktree path and returns a non-zero exit.

- Recommended: commit/stash the changes, then re-run.
- Dirty worktrees are never force-archived from CLI. `--force` does not bypass dirty-worktree refusal.
- `--force` only continues archiving when local sync fails for a non-conflict reason.
- **Coding agents:** do not reflexively retry with `--force` after a refusal. Pass `--force` only when the user has explicitly confirmed they want to discard the flagged data in the named worktree.

The GUI enforces the same guard: archive first refuses and then prompts a critical confirmation alert. For dirty worktrees, "Commit & Archive" opens a commit-message prompt (pre-filled with `Uncommitted changes on <branch> (<worktree>)`) and archives only after creating that commit.

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
magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--title <text>] [--fresh|--no-resume] [--prompt <text>]
```

| Option | Description |
|--------|-------------|
| `--agent <type>` | Agent type: `claude`, `codex`, `custom`, or `terminal`. Defaults to project/global setting. |
| `--model <id>` | Model ID to launch with. Falls back to the agent's configured default when omitted. |
| `--reasoning <level>` | Reasoning level: `low`, `medium`, `high`, `max` (Claude) or `low`, `medium`, `high`, `xhigh` (Codex). |
| `--title <text>` | Optional tab title shown in the tab bar. |
| `--fresh`, `--no-resume` | Start an isolated Claude/Codex tab that should not adopt an older conversation from the same worktree path during later recovery. |
| `--prompt <text>` | Initial prompt to inject after the agent starts. |

Use `--agent terminal` for a plain shell tab. Errors if the requested agent is disabled in Settings.
When the user explicitly names an agent, pass that exact `--agent` value. Do not silently substitute Claude for Codex or vice versa.

### create-web-tab

Open an in-app web tab at a specific URL in an existing thread. Useful for pinning docs pages, Jira tickets, PR URLs, or internal dashboards next to an agent tab.

```bash
magent-cli create-web-tab --thread <name> --url <http(s)-url> [--title <text>]
```

| Option | Description |
|--------|-------------|
| `--url <url>` | Fully qualified `http://` or `https://` URL to open. |
| `--title <text>` | Optional tab title. Defaults to the URL host. |

The tab always opens in-app (Magent), regardless of the user's external-link preference. The URL and title persist with the thread and survive app restarts.

**Quoting:** always wrap the URL in single quotes so the shell doesn't expand `&`, `?`, `#`, or `$`:

```bash
magent-cli create-web-tab --thread kimchi --url 'https://example.com/search?q=foo&lang=en#top'
```

Spaces and other non-RFC characters must be percent-encoded (`%20`, etc.) — `URL(string:)` rejects unencoded input.

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

Section names are case-insensitive throughout the app — lookups, duplicate detection, and creation all treat `"TODO"` and `"todo"` as the same name.

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
| `MAGENT_THREAD_ID` | Thread UUID — used by `create-thread`/`batch-create` for auto-detection |
| `MAGENT_SOCKET` | Path to the IPC socket (default: `/tmp/magent.sock`) |
