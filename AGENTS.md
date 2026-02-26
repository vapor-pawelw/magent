# Magent

Multi-worktree agent terminal manager for macOS (with future iPadOS/iOS support).

## What This App Does

Manages git worktrees as "threads," each with embedded terminal (libghostty) running tmux + a coding agent. Enables working on multiple features simultaneously and attaching to sessions remotely via SSH from iPhone.

## Tech Stack

- **AppKit** — NOT SwiftUI
- **libghostty** — embedded terminal rendering
- **tmux** — session persistence and remote SSH attachment
- **Swift** — primary language
- **JSON** — persistence (thread state, settings)

## Key Concepts

- **Thread** = git worktree + tmux session(s) + agent
- **Tab** = additional terminal in same thread/worktree (separate tmux session)
- **Project** = registered git repository
- **Archive** = remove worktree, hide thread from list

## Project Structure

- `docs/` — detailed requirements and architecture docs
- `Magent/` — main app target (AppKit)
- `Libraries/` — vendored dependencies (libghostty)

## Decisions

- **Agent**: Configurable via `AppSettings.activeAgents`, `defaultAgentType`, and `customAgentCommand`.
- **Thread naming**: Auto-generated (random names)
- **Archive**: Remove worktree, keep git branch
- **Terminal**: libghostty (Zig→C→Swift bridge)

## Conventions

- AppKit only — no SwiftUI views
- MVC or Coordinator pattern for navigation
- Services layer for git, tmux, persistence operations
- Thread state persisted in Application Support as JSON
- tmux session naming: `magent-<project>-<thread-id>[-tab-<n>]`
- Worktrees default path: `<repo-parent>/<repo-name>-worktrees/`
- **Agent-specific code must be gated**: Any code specific to a particular agent (e.g. Claude's trust dialog, CLAUDECODE env var) must be gated by selected `AgentType`. Use `ThreadManager.trustDirectoryIfNeeded()` and `agentStartCommand()` — never call trust helpers directly or insert `unset CLAUDECODE` ad hoc.
- **Banner notifications** for user-facing status messages: `BannerManager.shared.show(message:style:duration:isDismissible:actions:)`. Styles: `.info`, `.warning`, `.error`. Set `duration: nil` for persistent banners, `isDismissible: false` to block user dismissal.
- **Worktree recovery** is automatic — when a user selects a thread whose worktree directory is missing, `SplitViewController` triggers recovery via `ThreadManager.recoverWorktree()`, showing progress via banners.
- **Tuist**: Run `mise x -- tuist generate --no-open` after adding/removing Swift files.

## Important Files

- `docs/requirements.md` — full feature requirements
- `docs/architecture.md` — architecture decisions and component design

## Self-Learning

When implementing a new feature, bugfix, or behavioral change, check whether it introduces:
1. A **pattern that future code must follow** (e.g. agent-gating, banner usage) → add to Conventions above
2. A **non-obvious architectural constraint** → add to Decisions or a doc under `docs/`

Don't document things discoverable by reading the code (file locations, API signatures, etc.). Only document things that would cause bugs or inconsistency if a future session didn't know about them.
