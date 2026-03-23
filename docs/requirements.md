# mAgent — Requirements

## Overview

mAgent is a native macOS app (AppKit) for managing multiple git worktrees as "threads," each backed by an embedded terminal (libghostty) running tmux.

**Primary goal**: Work on multiple features in the same repo simultaneously via worktrees, with easy SSH + tmux attachment from iPhone (e.g. via Terminus).

## Platform & Framework

- **macOS only**
- **AppKit** — SwiftUI is explicitly avoided for reliability on Mac
- Terminal rendering via **libghostty** (embedded C library from Ghostty)

## Core Concepts

### Threads

A "thread" represents a single feature/task. Each thread:

- Creates a **new git worktree** for the selected project
- Opens an embedded terminal (libghostty) running a **tmux session**
- Automatically launches the user's **preferred agent** (e.g. Claude Code) inside tmux
- Supports **multiple tabs** — each tab is a separate terminal + tmux session, but all tabs within a thread share the **same worktree**
- Is **persistent** — threads survive app restarts; state is loaded on launch
- Can be **archived** — archived threads are cleaned up in git (worktree removed) and disappear from the thread list

### Tabs (within a thread)

Each tab within a thread:

- Is a separate embedded terminal instance
- Runs its own tmux session
- Operates in the same worktree directory as the thread
- Starts in the thread worktree/repo directory on first session creation, but switching back to an already-running tab must not reset the shell's current directory
- `Continue in...` context handoff must not create tracked or untracked files in the repo/worktree root; any transient handoff file should live outside the repo, use a unique filename so concurrent transfers do not collide, and expire automatically after a short retention window

### Web Tabs

Tabs can also display in-app web content (WKWebView) alongside terminal tabs:

- **"Web" type** in the New Thread and New Tab sheets creates a web tab. Threads created with Web type get a worktree and branch but no tmux session. URL is optional — blank creates an empty web tab with an address bar.
- **Middle-click** on the Jira or PR toolbar button opens the page in a web tab instead of the external browser
- **Right-click "+"** on the tab bar quick-creates a blank web tab; on the sidebar it opens the thread sheet with Web pre-selected
- User-created web tabs show a globe icon and auto-update their title from the page hostname on navigation. Jira/PR tabs keep their fixed icons and titles.
- **Middle-click or Cmd-click** on a link inside a web tab opens it in a new web tab instead of navigating the current tab. Links with `target="_blank"` also open in a new tab (via `WKUIDelegate`).
- Web tabs show an editable URL address bar, with back/forward/refresh navigation controls
- **CMD+R** refreshes the active web tab; **CMD+SHIFT+R** hard-refreshes (bypasses cache via `reloadFromOrigin`)
- URL normalization (shared `WebURLNormalizer`): bare hostnames get `https://`, localhost/loopback addresses get `http://`, `host:port` patterns without `://` are detected and normalized
- Web tabs are persisted across app restarts but load lazily — the WKWebView is only created when the tab is first selected
- Web tabs participate in the same tab bar as terminal tabs: they can be pinned, renamed, drag-reordered, and freely mixed with terminal tabs in both the pinned and unpinned sections
- Closing a web tab asks for confirmation, matching terminal tab close behavior

### Draft Tabs

Draft tabs let users save a prompt idea for later without executing it immediately:

- **"Draft" checkbox** on the New Thread and New Tab sheets (agent mode only, unchecked by default) creates a draft tab instead of launching the agent
- Draft tabs display a centered form with an agent type picker (agents only) and an editable prompt text area (max 1200pt wide x 400pt tall, responsive to window size)
- Two actions: "Discard Draft" (with confirmation alert) removes the tab permanently; "Start Agent" converts the draft into a real agent tab and injects the prompt
- Closing a draft tab via the tab bar close button also shows a discard confirmation
- Draft content (agent type + prompt) persists across app restarts via `persistedDraftTabs` on `MagentThread`
- Draft tabs can only be created through the launch sheet checkbox — there is no other way to create them
- Terminal overlays (scroll controls, scroll-to-bottom FAB, prompt TOC) are hidden while a draft tab is active
- Display order is decoupled from content arrays via a `TabSlot` indirection layer, allowing free mixing of terminal and web tabs without breaking terminal view indexing

## Configuration (First Run / Settings)

Before the app is usable, the user must complete a configuration step:

1. **Install dependencies** — tmux and any other required tools (check/install via Homebrew or guide user)
2. **Select active agent** — choose which coding agent to auto-launch in new threads (e.g. Claude Code, Aider, custom command)
3. **Add projects** — register git repositories that the user wants to work with
4. **Worktrees path** — where worktrees are created; default suggestion: `<repo-parent-dir>/<repo-name>-worktrees/`

## Thread Lifecycle

### Creating a Thread

1. User taps **"+"** button
2. If **1 project** is configured → immediately create thread for that project
3. If **multiple projects** → show a project selection menu first
4. The new-thread sheet offers optional fields: **Description**, **Branch**, **Base branch** (combo box with type-ahead — lists local branches sorted most-recently-modified first, with default branch shown as placeholder; field left empty defaults to the project's default branch, falling back to "main"; validates branch existence on accept), **Prompt**, agent type picker, project picker (multi-project setups), and section picker. A "Switch to new thread" checkbox (default: on, persisted) controls whether focus switches to the new thread.
5. The thread appears in the sidebar immediately and is auto-selected by default; a "Creating thread..." overlay is shown in the detail area while background setup runs.
6. A new git worktree is created for the selected project (background), branching from the chosen base branch
7. If the project has local sync paths configured, those repo-relative files/directories are copied from the repo root into the new worktree and snapshotted onto the thread (background)
8. A tmux session is started in the worktree directory (background)
9. The configured agent is launched inside tmux (background)
10. The creation overlay is dismissed and the terminal is displayed; normal "Starting agent..." overlay takes over until the agent is ready

### Archiving a Thread

1. User triggers archive action on a thread
2. If the project has local sync paths configured and archive local-sync is enabled, only listed local-sync files/directories are candidates for merge-back into the repo root before removal
3. Existing files in the repo that are not present in the worktree are preserved (no delete sync)
4. Directory paths are merged recursively on a per-file basis; intermediate directories are created only when needed for copied files
5. If merge-back would overwrite an existing target, user can choose `Override`, `Override All`, `Ignore`, or `Cancel Archive`
6. The git worktree is removed/pruned
7. The thread disappears from the sidebar/list
8. Thread metadata may be retained for history

### Persistence

- Thread state (which worktrees are active, tmux session names, project association) is saved to disk
- On app launch, threads are restored and terminals reconnected to existing tmux sessions
- Agent tabs must preserve their own resolved agent type (for example Claude vs Codex) across relaunches and project-default changes, rather than being reinterpreted from the current project default each time they reopen.
- While an agent tab is opening, the loading overlay may show a small, low-contrast technical status line only for non-routine recovery work (for example recreating a missing tmux session or replacing one tied to the wrong worktree). Routine agent startup should keep the simple `Starting agent...` message.
- If a live agent tab has already returned to a normal shell prompt, reopening that tab should skip the `Starting agent...` overlay instead of waiting for agent-ready output that will never arrive.
- Agent startup must source normal user zsh PATH setup before resolving the agent command, including setups that define `claude`/`codex` from `.zshrc`.

## UI Structure

```
┌──────────────┬────────────────────────────────────┐
│              │  Tab 1 │ Tab 2 │ Tab 3 │    [+]    │
│   Threads    ├────────────────────────────────────┤
│              │                                    │
│  ┌────────┐  │                                    │
│  │Thread 1│  │      Terminal / Main Pane          │
│  ├────────┤  │      (libghostty rendering)        │
│  │Thread 2│  │                                    │
│  ├────────┤  │                                    │
│  │Thread 3│  │                                    │
│  └────────┘  │                                    │
│              │                                    │
│    [+]       │                                    │
│   [⚙️]       │                                    │
└──────────────┴────────────────────────────────────┘
```

- **Left pane**: Thread list with "+" button to create, gear for settings
- **Main pane**: Terminal display with tab bar for multiple terminals per thread
- **Settings**: Accessible from sidebar or menu bar

### Project Header Controls

- In each project header row, the trailing `+` create-thread control must treat the entire visible icon frame as clickable, and both normal click and Option-click must reliably trigger from that full hit area instead of only the drawn plus glyph.

## Prompt Table of Contents (TOC)

- TOC entries must represent only user-submitted prompts for the active agent tab.
- Do not include non-submitted composer content, placeholder suggestions, or interactive selector rows.
- Treat a prompt as TOC-eligible only after later terminal activity shows it is no longer the active bottom composer text.
- Placeholder/draft composer text should be filtered using pane styling when available (for example dim/grey prompt text), not only string heuristics.
- Prompt extraction must preserve wrapped continuation lines that belong to the same submitted input block.
- Ignore pinned bottom chrome/status rows (for example model/usage/path lines) when deciding whether a prompt was actually submitted.
- Switching threads/tabs must not surface stale non-submitted prompt text in TOC.
- TOC entry ordering follows actual submission order for that session.
- If the TOC is already scrolled to the bottom, appending a newly confirmed prompt must keep the list pinned to the bottom.
- TOC panel must be draggable and resizable by the user.
- The minimum TOC expanded size is 320×250pt.
- TOC rests as a compact floating capsule (185×36pt) showing "Table of Contents" and a prompt count badge; hovering expands it to the full panel with animation, then collapses back when the cursor leaves.
- The toolbar toggle button and in-panel × close button are removed; the TOC is always-on. Users can disable it entirely in Settings.
- The prompt count badge is a pill-shaped 20pt-tall view with a 13pt bold number. No agent name is shown in the TOC header.
- Position is normalized relative to the expanded size so dragging the capsule does not corrupt the restored expanded-panel position.
- TOC visibility is a single app-wide preference: toggling show/hide in Settings must immediately apply to other open thread panels and persist across app relaunches.
- Selecting a TOC row must jump to that prompt and anchor it at the top of the terminal scroll viewport when possible.
- Prompt rows support up to 3 lines and use subtle alternating background stripes for readability.
- TOC context-menu actions that operate on prompt text (for example `Copy prompt`) must use the full submitted prompt payload, not the 3-line row preview.
- When the TOC is visible, it must remain directly clickable; the terminal surface must not intercept pointer events over the panel.

## Terminal Scrollback

- The terminal panel must expose a reliable scrollback fallback that does not depend on mouse-wheel behavior inside the agent session.
- Users must be able to page up, page down, and jump back to live output even when the embedded terminal forwards wheel input to the agent instead of tmux scrollback.
- Users must be able to choose whether Magent overrides wheel input to scroll terminal history, allows apps/prompts to capture it, or inherits the user's Ghostty global setting.
- Changing that wheel-behavior setting must take effect immediately for already-open terminals, not only for newly created tabs.
- The page-up/page-down/jump controls may live in floating terminal chrome instead of the top bar, as long as they stay visible and usable above the embedded terminal surface.
- The bottom-left floating `Scroll to bottom` pill should appear only after the user has scrolled meaningfully away from live output, not on tiny incidental near-bottom scrolls.
- Floating terminal scroll overlays should keep the default 48 pt bottom clearance. The bottom-right multi-action overlay may use a semi-transparent idle state with hover opacity, while the bottom-left `Scroll to bottom` pill should stay fully opaque with no hover-specific fade.

## Thread Row Display Rules

For non-main threads, naming and labels in the sidebar follow these rules:

- `thread.name` is the branch-facing thread identifier.
- Worktree directory name is derived from `worktreePath` basename.
- `taskDescription` is optional; it can be generated from the first agent prompt or set manually.
- Generated description should be short (2-8 words) and naturally cased (not forced Title Case).
- Generated description should describe the same concrete task as the branch slug and read like a useful sidebar label; avoid vague abstractions such as "readiness" when the work is really a fix or feature.

For the main thread, the sidebar uses these rules:

- Line 1: `Main worktree`
- Line 2: current branch name when available
- A vertical accent bar appears on the main-thread row instead of the project header row.

### Non-Main Thread Rename Actions

- Hidden threads stay at the bottom of their section/list and render with dimmed row content so they read as deprioritized rather than archived.
- Context menu order for non-main threads starts with `Pin/Unpin`, then `Hide/Unhide`, then `Rename...`, then a separator.
- `Rename...` is prompt-based: user enters a natural-language task prompt, and Magent generates:
  - branch slug candidate(s)
  - short task description
  - suggested thread icon/work type
- Prompt-based rename uses the same AI behavior as first-prompt auto-rename and is allowed even if the thread was already renamed before.
- Exact branch rename remains available via `Rename branch...` and uses user-provided branch text directly.

### Line 1 / Line 2 Layout

- If `taskDescription` exists:
  - Line 1: description (up to 2 lines, or 1 line when `Narrow threads` is enabled)
  - Line 2: `branch · worktree · PR` (PR segment shown only when present)
- If no `taskDescription` and branch differs from worktree:
  - Line 1: `branch`
  - Line 2: `worktree · PR` (PR segment optional)
- If no `taskDescription` and branch equals worktree:
  - Single line: `branch · PR` (PR segment optional)

### Dirty Dot and Hover Details

- Dirty dot is attached to the branch/worktree line (never the description line).
- Hover tooltip should:
  - Show description as plain text (no "Description:" prefix) only when present
  - Show branch/worktree lines when values are present
  - Show PR line only when PR exists
  - Show status section only when at least one status is active

## Settings

- **Projects**: Add/remove git repositories
- **Terminal**: App-wide appearance (`System`, `Light`, `Dark`) that also controls the embedded terminal, plus wheel-behavior and overlay preferences
- **Worktrees path**: Per-project or global path for worktrees (default: `<parent>/<repo>-worktrees/`)
- **Local sync paths** (per project): Line-separated repo-relative files/directories copied into new thread worktrees and merged back on archive
- **Agent command**: The command to run in new threads (e.g. `claude`, `aider`, custom)
- **Dependencies**: Check/install tmux, verify ghostty availability
- **tmux configuration**: Optional custom tmux config or prefix key

## SSH / Remote Access

The tmux-based architecture enables remote access:

- Each thread's tmux session can be attached to via SSH from any device
- Users can SSH into their Mac from iPhone (e.g. via Terminus) and `tmux attach -t <session>`
- The app should use predictable/discoverable tmux session names

## Decided

- **Agent**: Claude Code only (for now)
- **Worktree naming**: Auto-generated names (random, like city names)
- **Archive behavior**: Remove worktree only, keep the git branch
- **Terminal library**: libghostty (build from Ghostty source, Zig→C→Swift bridge)
