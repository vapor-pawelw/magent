# Magent

A native macOS app for managing coding agents as parallel work sessions — each thread is a git worktree with embedded terminals, agent tabs, and full lifecycle management.

<!-- ![Magent Screenshot](docs/screenshot.png) -->

## Features

### Thread Management

Every thread maps 1:1 to a git worktree. Create a thread, get a fresh branch and workspace instantly.

- **Auto-naming** — threads start with random names (e.g. `swift-falcon`) and auto-rename based on the first agent prompt
- **Sections** — organize threads into color-coded Kanban columns (TODO, In Progress, Reviewing, Done) with per-project overrides
- **Archive & delete** — archive removes the worktree but keeps the branch; delete removes both
- **Pinning** — pin important threads to the top of the list
- **Status indicators** — see at a glance which threads are busy, waiting for input, have unread completions, or have uncommitted changes
- **Delivery tracking** — threads show when all commits have been cherry-picked to the base branch

### Multi-Agent Support

Run Claude Code, Codex, or any custom command as your coding agent.

- **Claude Code** — full support including `--dangerously-skip-permissions` mode and `/resume` for session restoration
- **Codex** — supports standard, `--yolo`, and `--full-auto` modes
- **Custom agents** — use any CLI tool as your agent
- **Per-project defaults** — set different default agents for different repositories
- **Auto-trust** — automatically configures trust settings for new worktree directories
- **Context transfer** — hand off conversation context between agent tabs via `.magent-context.md` export

### Terminal

GPU-accelerated embedded terminal powered by libghostty, with tmux for session persistence.

- **Ghostty rendering** — native GPU-accelerated terminal emulation via libghostty (Zig-built C library)
- **tmux multiplexing** — every tab runs in a tmux session, surviving app restarts and enabling remote SSH attachment
- **Multiple tabs** — open agent tabs, plain terminal tabs, or mixed configurations per thread
- **Tab management** — rename, reorder, pin, close tabs within a thread
- **Bell detection** — smart agent completion detection via tmux pipe-pane with BEL character monitoring

### Git Integration

Deep git awareness without getting in the way.

- **Worktree lifecycle** — create, rename, archive, delete worktrees with automatic branch management
- **Branch tracking** — see branch names, dirty state, and merge status at a glance
- **PR/MR links** — open pull requests directly from the toolbar (GitHub, GitLab, Bitbucket)
- **Default branch detection** — auto-detects `main`, `master`, or `develop` from `origin/HEAD`
- **Diff stats** — per-file additions/deletions with staged/unstaged/untracked breakdown
- **Worktree recovery** — if a worktree directory goes missing, it's recreated from the branch

### CLI Automation

Script everything via `magent-cli` over a Unix domain socket.

```bash
# Thread operations
magent-cli create-thread --project myapp --agent claude --prompt "Add auth"
magent-cli list-threads --project myapp
magent-cli send-prompt --thread swift-falcon --prompt "Now add tests"
magent-cli archive-thread --thread swift-falcon

# Tab operations
magent-cli create-tab --thread swift-falcon --agent terminal
magent-cli list-tabs --thread swift-falcon
magent-cli close-tab --thread swift-falcon --index 2

# Section management
magent-cli list-sections
magent-cli add-section --name "Blocked" --color "#FF3B30"
```

Environment variables injected into every session: `MAGENT_WORKTREE_PATH`, `MAGENT_PROJECT_PATH`, `MAGENT_WORKTREE_NAME`, `MAGENT_PROJECT_NAME`, `MAGENT_SOCKET`.

### Notifications

Stay aware without context-switching.

- **Dock badge** — shows count of threads with unread completions or waiting for input
- **System notifications** — native macOS notifications for agent events
- **Completion sounds** — configurable system sound on agent completion (default: Ping)
- **In-app banners** — slide-down notifications for status messages with optional action buttons

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **tmux** — `brew install tmux`
- **git** — included with Xcode Command Line Tools

## Installation

### Homebrew

```bash
brew tap vapor-pawelw/magent
brew install --cask magent
```

> Since the app is not signed or notarized, macOS will block it on first launch.
> Right-click the app and choose **Open**, then click **Open** in the dialog to bypass Gatekeeper.

### GitHub Releases

Download the latest `.zip` from [Releases](https://github.com/vapor-pawelw/magent/releases), unzip, and move `Magent.app` to `/Applications`.

## Building from Source

### Prerequisites

- **Xcode 26+**
- **[mise](https://mise.jdx.dev/)** — tool version manager (installs Tuist)

### Build

```bash
git clone https://github.com/vapor-pawelw/magent.git
cd magent

# Generate the Xcode project
mise x -- tuist generate --no-open

# Build via Xcode
open Magent.xcworkspace
# Or build from command line:
xcodebuild build -workspace Magent.xcworkspace -scheme Magent -configuration Release
```

### First Run

1. Launch Magent
2. Add your repositories in Settings
3. Choose your default agent (Claude, Codex, or custom)
4. Create your first thread

## License

[PolyForm Shield 1.0.0](./LICENSE)
