# Interactive CLI Picker

This note covers the status-aware thread rows shown by `magent-cli` interactive mode and `magent-cli ls`.

## User-visible behavior

### Thread rows

Each thread row can have up to four lines. Empty lines are omitted.

1. **Title** — thread description (or name), bold cyan for main, bold white otherwise.
2. **Branch/worktree** — `name · branch · worktree · agent` joined with dots. Name is shown only when it differs from the title.
3. **PR / Jira** — `PR #42 (Open) · IP-123`, shown only when PR info or a Jira ticket key is present.
4. **Statuses** — `[busy] [dirty] [done] …`, shown only when at least one status badge is active. Idle threads have no status line.
5. Favorite threads include a heart badge (`[♥]`) in the status line and in `magent-cli ls` status output.

### Tab rows

When multiple tabs exist, the tab picker shows each tab with up to three lines:

1. **Tab label** — real tab display names from thread metadata (custom names when present, otherwise `Tab 0`, `Tab 1`, etc.).
2. **Detail** — `agent-type · session-name`.
3. **Statuses** — per-tab badges (`[busy]`, `[input]`, `[done]`, `[limited]`), shown only when active.

### General

- The interactive picker groups threads by section using styled section headers (`● Section Name` in the section's color), matching the sidebar order in the app.
- Thread order within each section preserves the app's in-memory order (same as the sidebar).
- When a thread has only one tab the tab-picker step is skipped and the session is attached directly.
- Interactive mode remembers the last attached session context. On next launch (without `--project`), it attempts to open that thread's tab picker directly. Fallback order: last thread (if still present) → last project thread list (if project still exists) → project picker.
- The tab picker always includes explicit back actions to both thread list and project list.
- The picker is always the classic numbered list (`1) … 2) …`), which works reliably over SSH and from a phone. `fzf` is not used.
- Section headers are displayed as visual separators without numbers. If accidentally selected the picker reopens.
- When ANSI colors are supported, section names and bullets are rendered in the section's 24-bit true color.

## Implementation notes

- The installed shell script lives inside `IPCSocketServer.installCLIScript()` and is versioned by `cliVersion`. **Bump `cliVersion` whenever changing the embedded script** so `/tmp/magent-cli` is reinstalled on next app launch.
- The interactive picker uses `list-sections` (not `list-threads`) so it gets sections in `sortOrder` order with threads pre-grouped. `handleListSections` populates `status`, `agentType`, `prLabel`, `prStatusText`, and `jiraTicketKey` on each thread info.
- `makeThreadStatus(for:)` on `IPCCommandHandler` is `internal` (not `private`) so `IPCCommandHandler+Sections.swift` can call it when building thread infos for `handleListSections`.
- `listTabs` populates per-tab status fields (`isBusy`, `isWaitingForInput`, `hasUnreadCompletion`, `isBlockedByRateLimit`, `agentType`) and `displayName` on each `IPCTabInfo` from the thread's per-session metadata.
- The `pick_value` awk renderer prints all non-empty SEP-delimited fields after the title as indented lines, so adding new lines only requires appending another `$SEP` field in the formatter.
- `paint_hex` converts a `#RRGGBB` hex string to a 24-bit ANSI escape using POSIX-sh `printf` and `sed`. It strips the leading `#` via `sed 's/^#//'` — avoid `${var#\#}` parameter expansion inside the Swift `#"""..."""#` raw string literal as the `\#` sequence is interpreted as a Swift raw-string escape and causes a build error.
- Color output is optional. `MAGENT_USE_COLOR=0` or `NO_COLOR=1` disables ANSI styling.

## Gotchas

- Keep the shell script POSIX `sh` compatible. Validate changes with `sh -n` against the extracted script body, not just Swift compilation.
- Never use `\#` inside the Swift `#"""..."""#` raw string (i.e. inside the embedded shell script body) — use `sed` or `cut` workarounds instead of `${var#\#}` pattern stripping.
- If you add new badges, update both the interactive picker formatter and the `ls` formatter so they stay in sync.
- `list-sections` returns threads only when a project filter is provided; global (no-project) calls return section metadata only. The picker always has a project context so this is fine.
