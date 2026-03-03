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
- **Shell startup CWD must use managed `ZDOTDIR`, not `tmux send-keys cd`**: Build shell session commands through `terminalStartCommand(...)` / `agentStartCommand(...)`, which ensure `/tmp/magent-zdotdir` exists (recreate if `/tmp` was cleared) and set `MAGENT_START_CWD` so cwd is fixed after user rc/profile load. Avoid reintroducing post-start `send-keys` cwd enforcement.
- **Auto-rename-on-first-prompt**: For all non-main worktrees, auto-rename after the first submitted agent prompt. Keep it one-time via persisted state (`didAutoRenameFromFirstPrompt`) and route rename decisions through `ThreadManager.autoRenameThreadAfterFirstPromptIfNeeded(...)`.
- **Auto-rename/task-description agent fallback**: Slug/description generation must prefer the active session/default agent first, then fall back to other built-in generators (Claude/Codex) if the preferred agent fails, instead of skipping rename immediately.
- **First-prompt auto-rename should skip custom branches**: If the current git branch is already custom (not auto-generated), skip auto-rename quietly and mark first-prompt auto-rename handled to avoid repeated retries/banners.
- **Banner notifications** for user-facing status messages: `BannerManager.shared.show(message:style:duration:isDismissible:actions:)`. Styles: `.info`, `.warning`, `.error`. Set `duration: nil` for persistent banners, `isDismissible: false` to block user dismissal.
- **Worktree recovery** is automatic — when a user selects a thread whose worktree directory is missing, `SplitViewController` triggers recovery via `ThreadManager.recoverWorktree()`, showing progress via banners.
- **Stale tmux cleanup** is centralized in `ThreadManager.cleanupStaleMagentSessions()`, scoped to `ma-` sessions only, and should be used for lifecycle hooks + the session-monitor poller (5-minute cadence) instead of ad hoc `tmux kill-session` sweeps in controllers.
- **Agent completion attention** is bell-driven and tracked **per-session**: tmux `alert-bell` hook events are consumed by `ThreadManager` to trigger system notifications and to populate `unreadCompletionSessions: Set<String>` on each thread. The computed `hasUnreadAgentCompletion` checks `!unreadCompletionSessions.isEmpty`. Tab-level green dots in `ThreadDetailViewController` react via `magentAgentCompletionDetected` notification, and selecting a tab calls `markSessionCompletionSeen(threadId:sessionName:)` to clear individual sessions.
- **tmux bell monitoring must be re-applied when sessions are created**: tmux can start lazily, so startup-only hook setup is insufficient. Keep bell hook setup in `TmuxService.configureBellMonitoring(...)`, and call it from both startup setup and `createSession(...)`.
- **tmux zombie overload recovery** is banner-driven: `ThreadManager.checkTmuxZombieHealth()` monitors zombie-heavy tmux parents and offers a one-click `restartTmuxAndRecoverSessions()` action via a persistent warning banner.
- **Thread row naming/description contract**: For non-main threads, render description on line 1 only when present; keep branch/worktree info on the branch-facing line with dot-separated segments (`branch · worktree · PR` variants depending on available values). Keep dirty dot attached to the branch/worktree line, not the description line. Tooltip sections must skip missing fields/statuses. Generated task descriptions are short (2-8 words) and naturally cased (do not force Title Case).
- **Tuist**: Run `mise x -- tuist generate --no-open` after adding/removing Swift files.
- **Build bootstrap (Codex)**: If `mise` trust/toolchain issues appear, run: `mise trust && mise install && mise x -- tuist install && mise x -- tuist generate --no-open && mise x -- tuist build Magent`.

## Releasing

When the user asks to "release", "publish", "cut a release", or "bump version":

1. **Determine the version bump** using [Semantic Versioning](https://semver.org/):
   - **patch** (1.0.0 → 1.0.1): bug fixes, minor tweaks
   - **minor** (1.0.0 → 1.1.0): new features, non-breaking changes
   - **major** (1.0.0 → 2.0.0): breaking changes (rare — confirm with user)
   - If the bump type is ambiguous, ask the user
2. **Find the current version**: `git tag --sort=-v:refname | head -1`
3. **Tag and push**:
   ```bash
   git tag v<new_version>
   git push origin v<new_version>
   ```
4. **Monitor the workflow**: `gh run list --limit 1` then `gh run watch <id> --exit-status`
5. **Verify**: `gh release view v<new_version>` — confirm the release has `Magent.zip` attached

The tag push triggers a GitHub Actions workflow (`.github/workflows/release.yml`) that:
- Builds an unsigned `Magent.app` on `macos-26`
- Creates a GitHub Release with the zipped app
- Auto-updates the Homebrew cask in `vapor-pawelw/homebrew-magent`

**Do NOT** manually edit `Project.swift` version strings — the workflow injects them from the git tag automatically.

## Important Files

- `docs/requirements.md` — full feature requirements
- `docs/architecture.md` — architecture decisions and component design
- `docs/cli.md` — complete CLI command reference (all `magent-cli` commands, options, `thread-info` status fields)
- `docs/building.md` — build prerequisites and instructions
- `docs/releasing.md` — release process (tag-driven)

## Self-Learning

When implementing a new feature, bugfix, or behavioral change, check whether it introduces:
1. A **pattern that future code must follow** (e.g. agent-gating, banner usage) → add to Conventions above
2. A **non-obvious architectural constraint** → add to Decisions or a doc under `docs/`

Don't document things discoverable by reading the code (file locations, API signatures, etc.). Only document things that would cause bugs or inconsistency if a future session didn't know about them.
