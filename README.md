<p align="center">
  <img src="https://github.com/user-attachments/assets/9f6309e2-102a-4070-9076-3eec6b7d6505" alt="mAgent icon" width="128" height="128">
</p>

<h1 align="center">mAgent</h1>

<p align="center">
  Native macOS app for running coding agents in parallel git worktrees.<br>
  Each thread is a worktree + embedded terminal + agent session.
</p>

<p align="center">
  <img src="docs/screenshots/main-view.png" alt="mAgent main view" width="800">
</p>

## Install

**Homebrew:**
```bash
brew tap vapor-pawelw/tap && brew install --cask magent
```

**Manual:** grab the `.dmg` from [Releases](https://github.com/vapor-pawelw/mAgent/releases).

Requires **macOS 14+**, **tmux** (`brew install tmux`), and **git**.

## Threads & Worktrees

Create a thread and get a git worktree, branch, and agent session instantly. Threads auto-name themselves and rename the branch based on your first prompt.

Organize with color-coded Kanban sections (TODO, In Progress, Reviewing, Done), drag-to-reorder, pinning, and auto-assigned work type icons. The sidebar shows live status at a glance: busy, waiting for input, rate-limited, unread completions, and uncommitted changes.

<p align="center">
  <img src="docs/screenshots/new-thread.png" alt="New thread dialog" width="600">
</p>

## Multi-Agent Terminal

GPU-accelerated embedded terminal (libghostty) with tmux for session persistence. Run Claude Code, Codex, or any custom CLI as your agent, with per-project defaults.

Each thread supports multiple tabs: agent, terminal, web, and draft. Tabs can be pinned, reordered, and renamed. Agent completion is detected automatically with configurable sounds and system notifications.

<p align="center">
  <img src="docs/screenshots/agent-working.png" alt="Agent working in terminal" width="800">
</p>

## Git Integration

Branch stacking with base branch selection and automatic retargeting when parent branches rename. PR detection and creation for GitHub, GitLab, and Bitbucket with review status badges. Bidirectional file sync between worktrees with merge tool support.

One-click code review tabs, delivery tracking (cherry-pick detection), diff stats, and automatic worktree recovery.

<p align="center">
  <img src="docs/screenshots/context-menu.png" alt="Thread context menu" width="800">
</p>

## Smart Session Management

Idle sessions are automatically evicted to keep resource usage low, with configurable limits and Keep Alive protection for important threads. Rate limits are detected from terminal output with countdown timers and sound alerts when limits lift.

A persistent status bar shows active sessions, rate limit state, and thread counts.

<p align="center">
  <img src="docs/screenshots/prompt-toc.png" alt="Prompt Table of Contents" width="800">
</p>

## CLI Automation

Full programmatic control via `magent-cli` over a Unix domain socket.

```bash
magent-cli create-thread --project myapp --agent claude --prompt "Add auth"
magent-cli send-prompt --thread omanyte --prompt "Now add tests"
magent-cli move-thread --thread omanyte --section "In Progress"
magent-cli batch-create --file threads.json
magent-cli archive-thread --thread omanyte
```

See [docs/cli.md](docs/cli.md) for the full command reference.

## Building from Source

See [docs/building.md](docs/building.md).

## License

[Apache License 2.0](./LICENSE)
