# mAgent

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
- `Packages/MagentModules/` — local SwiftPM modules (`MagentCore`, `GhosttyBridge`)
- `Libraries/` — vendored dependencies (libghostty)

## Conventions

- AppKit only — no SwiftUI views
- MVC or Coordinator pattern for navigation
- Services layer for git, tmux, persistence operations
- Agent-specific code must be gated by `AgentType` — never call agent-specific helpers directly
- Banner notifications: `BannerManager.shared.show(message:style:duration:isDismissible:actions:)`
- `@unchecked Sendable` is a last resort — only with a comment explaining the safety mechanism
- **Tuist**: Run `mise x -- tuist generate --no-open` after adding/removing Swift files
- **Build bootstrap (Codex)**: `mise trust && mise install && mise x -- tuist install && mise x -- tuist generate --no-open && mise x -- tuist build Magent`
- **GhosttyKit**: Populate via `./scripts/bootstrap-ghosttykit.sh` — never commit `libghostty.a`
- **Atomic commits**: Separate distinct responsibilities into separate commits. Each message starts with the thread/branch topic prefix (e.g. `feat(changes):`, `fix(rate-limit):`)
- **Commit-time changelog gate**: Review staged changes for user-facing impact and update `CHANGELOG.md` `## Unreleased` in the same commit. When a change supersedes an earlier unreleased entry, rewrite that entry instead of adding a new bullet.
- **Commit-time docs gate**: Review whether the change introduces behavior that should be documented. Check existing docs in `docs/` first; update in the same commit.
- **`archive this thread` intent**: (1) commit work, (2) update `CHANGELOG.md`, (3) update relevant docs under `docs/`, (4) run `./scripts/archive-current-thread.sh`.
- **Changelog discipline**: Follow `docs/changelog.md` guidelines — user-facing outcomes, grouped by domain, ordered by impact.

## Required Reading

**Before touching code in any of these areas, read the corresponding doc first.** Domain-specific invariants, gotchas, and implementation contracts live in docs, not here. **This table may not be exhaustive** — always scan `docs/` for anything that looks related to the area you're working on, even if no row below seems to match.

| Area | Doc |
|------|-----|
| Agent prompt detection, busy/idle state, shell startup | `docs/agent-prompt-detection.md` |
| Agent completion notifications, Dock badges | `docs/agent-completion-notifications.md` |
| Rate-limit parsing, fingerprints, fan-out | `docs/rate-limit-detection.md` |
| Thread creation, session lifecycle, cleanup | `docs/thread-session-lifecycle.md` |
| Worktree branch tracking, auto-rename, merge flow | `docs/worktree-branch-tracking.md` |
| Sidebar row layout, thread naming, icons, CALayer colors | `docs/sidebar-row-layout.md` |
| Sidebar flat reordering, drag-drop | `docs/sidebar-flat-reordering.md` |
| Crash-recovery prompt, pending prompt store | `docs/pending-prompt-recovery.md` |
| Update flow, xattr scrubbing, release checks | `docs/update-flow.md` |
| Releasing, changelog promotion, feature flags | `docs/releasing.md` |
| Local module split, package targets | `docs/local-modules.md` |
| Architecture, platform scope | `docs/architecture.md` |
| Full feature requirements | `docs/requirements.md` |
| CLI command reference | `docs/cli.md` |

When you add a new doc or an existing doc's scope changes, **update this table** to keep it discoverable.

## Releasing

Read `docs/releasing.md` for the full process. Key constraints:
- Use `./scripts/release-interactive.sh` — do **NOT** manually edit `Project.swift` version strings
- Ensure `CHANGELOG.md` has notes under `## Unreleased` before releasing
- Release artifacts publish to `vapor-pawelw/mAgent` as GitHub Releases

## Self-Learning

When implementing a new feature, bugfix, or behavioral change, check whether it introduces:
1. A **non-obvious constraint or gotcha** → add to the relevant doc under `docs/`
2. A **universal convention** (applies to every interaction) → add to Conventions above

Prefer docs over AGENTS.md. Only add to Conventions if it's something every commit/interaction needs to know.
