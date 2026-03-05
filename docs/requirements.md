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
4. A new git worktree is created for the selected project
5. A tmux session is started in the worktree directory
6. The configured agent is launched inside tmux
7. The terminal is displayed in the main pane

### Archiving a Thread

1. User triggers archive action on a thread
2. The git worktree is removed/pruned
3. The thread disappears from the sidebar/list
4. Thread metadata may be retained for history

### Persistence

- Thread state (which worktrees are active, tmux session names, project association) is saved to disk
- On app launch, threads are restored and terminals reconnected to existing tmux sessions

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

## Thread Row Display Rules

For non-main threads, naming and labels in the sidebar follow these rules:

- `thread.name` is the branch-facing thread identifier.
- Worktree directory name is derived from `worktreePath` basename.
- `taskDescription` is optional; it can be generated from the first agent prompt or set manually.
- Generated description should be short (2-8 words) and naturally cased (not forced Title Case).

### Non-Main Thread Rename Actions

- Context menu order for non-main threads starts with `Pin/Unpin`, then `Rename...`, then a separator.
- `Rename...` is prompt-based: user enters a natural-language task prompt, and Magent generates:
  - branch slug candidate(s)
  - short task description
  - suggested thread icon/work type
- Prompt-based rename uses the same AI behavior as first-prompt auto-rename and is allowed even if the thread was already renamed before.
- Exact branch rename remains available via `Rename branch...` and uses user-provided branch text directly.

### Line 1 / Line 2 Layout

- If `taskDescription` exists:
  - Line 1: description (up to 2 lines)
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
- **Worktrees path**: Per-project or global path for worktrees (default: `<parent>/<repo>-worktrees/`)
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
