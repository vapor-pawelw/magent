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
- **Worktree merge flow**: When merging a thread branch into `main`, do not `git checkout main` from another worktree. Discover the `main` worktree via `git worktree list --porcelain`, ensure it is clean, and run the merge there. Try `git merge --ff-only <branch>` first; only create a merge commit when fast-forward is impossible and the user asked to complete the merge.
- **Agent-specific code must be gated**: Any code specific to a particular agent (e.g. Claude's trust dialog, CLAUDECODE env var) must be gated by selected `AgentType`. Use `ThreadManager.trustDirectoryIfNeeded()` and `agentStartCommand()` — never call trust helpers directly or insert `unset CLAUDECODE` ad hoc.
- **Shell startup CWD must use managed `ZDOTDIR`, not `tmux send-keys cd`**: Build shell session commands through `terminalStartCommand(...)` / `agentStartCommand(...)`, which ensure `/tmp/magent-zdotdir` exists (recreate if `/tmp` was cleared) and set `MAGENT_START_CWD` so cwd is fixed after user rc/profile load. Avoid reintroducing post-start `send-keys` cwd enforcement.
- **Auto-rename-on-first-prompt**: For all non-main worktrees, auto-rename after the first submitted agent prompt. Keep it one-time via persisted state (`didAutoRenameFromFirstPrompt`) and route rename decisions through `ThreadManager.autoRenameThreadAfterFirstPromptIfNeeded(...)`.
- **Auto-rename/task-description agent fallback**: Slug/description generation must prefer the active session/default agent first, then fall back to other built-in generators (Claude/Codex) if the preferred agent fails, instead of skipping rename immediately.
- **First-prompt auto-rename should skip custom branches**: If the current git branch is already custom (not auto-generated), skip auto-rename quietly and mark first-prompt auto-rename handled to avoid repeated retries/banners.
- **Banner notifications** for user-facing status messages: `BannerManager.shared.show(message:style:duration:isDismissible:actions:)`. Styles: `.info`, `.warning`, `.error`. Set `duration: nil` for persistent banners, `isDismissible: false` to block user dismissal.
- **App updates are centralized in `UpdateService`**: Launch-time checks must respect `AppSettings.autoCheckForUpdates`; update checks/download/install flow should go through `UpdateService` rather than ad hoc network/shell logic in controllers.
- **Worktree recovery** is automatic — when a user selects a thread whose worktree directory is missing, `SplitViewController` triggers recovery via `ThreadManager.recoverWorktree()`, showing progress via banners.
- **Stale tmux cleanup** is centralized in `ThreadManager.cleanupStaleMagentSessions()`, scoped to `ma-` sessions only, and should be used for lifecycle hooks + the session-monitor poller (5-minute cadence) instead of ad hoc `tmux kill-session` sweeps in controllers.
- **Agent completion attention** is bell-driven and tracked **per-session**: tmux `alert-bell` hook events are consumed by `ThreadManager` to trigger system notifications and to populate `unreadCompletionSessions: Set<String>` on each thread. The computed `hasUnreadAgentCompletion` checks `!unreadCompletionSessions.isEmpty`. Tab-level green dots in `ThreadDetailViewController` react via `magentAgentCompletionDetected` notification, and selecting a tab calls `markSessionCompletionSeen(threadId:sessionName:)` to clear individual sessions.
- **tmux bell monitoring must be re-applied when sessions are created**: tmux can start lazily, so startup-only hook setup is insufficient. Keep bell hook setup in `TmuxService.configureBellMonitoring(...)`, and call it from both startup setup and `createSession(...)`.
- **Bell pipe must be force-replaced after tmux session rename**: `setupBellPipe` uses `-o` (no-op if a pipe already exists). When a session is renamed, the old pipe survives and keeps writing the pre-rename name — causing `checkForAgentCompletions` to silently drop all subsequent bell events (old name no longer in `agentTmuxSessions`). After rename, always call `TmuxService.forceSetupBellPipe(for:)` which stops the existing pipe first then starts a fresh one without `-o`.
- **tmux zombie overload recovery** is banner-driven: `ThreadManager.checkTmuxZombieHealth()` monitors zombie-heavy tmux parents and offers a one-click `restartTmuxAndRecoverSessions()` action via a persistent warning banner.
- **Thread row naming/description contract**: For non-main threads, render description on line 1 only when present; keep branch/worktree info on the branch-facing line with dot-separated segments (`branch · worktree · PR` variants depending on available values). Keep dirty dot attached to the branch/worktree line, not the description line. Tooltip sections must skip missing fields/statuses. Generated task descriptions are short (2-8 words) and naturally cased (do not force Title Case).
- **Auto icon assignment must respect manual overrides**: AI-driven work-type icon assignment is allowed only when `AppSettings.autoSetThreadIconFromWorkType` is enabled and `MagentThread.isThreadIconManuallySet` is false. Any user-triggered icon change must mark `isThreadIconManuallySet = true`, including no-op re-selections of the current icon.
- **Rate-limit parsing must be scoped to the latest terminal block**: In `ThreadManager+RateLimit`, only treat rate-limit text as active when detected in the latest pane scope (after the last separator) and near the bottom. Avoid pane-wide keyword scans/fingerprints that can ingest quoted logs/diagnostics and poison `rate-limit-cache.json`.
- **Concrete rate-limit fingerprints stay active until expiry/manual lift**: Once `ThreadManager+RateLimit` has anchored a non-ignored fingerprint to a future `resetAt`, later pane output must not auto-clear that limit just because the newest block no longer repeats the message. Only expiry or explicit user lift should remove it.
- **Session rename/migration must re-key transient session state**: When tmux session names change (rename, migration, external reconciliation), always re-key/prune transient per-session sets (`busySessions`, `waitingForInputSessions`, notification dedupe state) so thread-level busy/waiting indicators cannot get stuck on stale session names.
- **Release changelog contract**: Keep user-facing release notes in `CHANGELOG.md` under `## Unreleased` grouped by domain headings (for example: `Thread`, `Sidebar`, `Settings`, `Agents`), with empty domains omitted. Keep bullets short and, within each domain, ordered by user impact (broad/high-impact first) with user-facing improvements above bug/technical items. `scripts/release-interactive.sh` promotes that block into a versioned section, commits it, and creates an annotated tag from those notes.
- **Release artifacts live in `vapor-pawelw/magent-releases`**: Keep that repo public and release-only. Do not add source code there. The source repo's release workflow publishes `Magent.dmg`/`Magent.zip` to that repo, and update checks/Homebrew must consume assets from there.
- **GhosttyKit bootstrap contract**: `Libraries/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a` is local-only and must not be committed (including LFS). Populate/update `Libraries/GhosttyKit.xcframework` via `./scripts/bootstrap-ghosttykit.sh` (default pinned ref), and keep release/CI flows using that script before Tuist/Xcode build steps.
- **Local module split contract**: Shared non-UI code lives in `Packages/MagentModules`. `MagentCore` is the app-facing facade; keep lower-level code split into focused internal targets (`MagentModels`, `ShellInfra`, `GitCore`, `TmuxCore`, `JiraCore`, `IPCCore`, `PersistenceCore`, `UtilityCore`) when the dependency graph allows it. Keep resource-heavy AppKit UI, `ThreadManager`, banners, and update/IPC orchestration in the app target unless you first introduce package-safe resource/theme/localization wrappers. Prefer extracting pure models/services/utilities into package targets rather than moving AppKit controllers directly.
- **Tuist**: Run `mise x -- tuist generate --no-open` after adding/removing Swift files.
- **Build bootstrap (Codex)**: If `mise` trust/toolchain issues appear, run: `mise trust && mise install && mise x -- tuist install && mise x -- tuist generate --no-open && mise x -- tuist build Magent`.
- **Changelog discipline for `main`**: Every user-facing addition merged to `main` must be evaluated for `CHANGELOG.md` inclusion. Follow `docs/releasing.md` changelog guidelines: include only features/fixes/performance items, write user-facing outcomes (no technical internals), group by domain, omit empty domains, and order each domain by impact (largest/broadest first, niche/smaller last).
- **Commit-time changelog gate (agent required)**: Whenever the user asks the agent to commit (for example: "commit", "commit all", "commit and push"), the agent must first review staged/unstaged changes for user-facing impact and update `CHANGELOG.md` `## Unreleased` as needed in the same commit. Do not defer changelog updates to a later commit or only to release time. When a change reverts or supersedes an earlier unreleased entry, remove or rewrite that entry instead of adding a new "removed"/"fixed" bullet — the changelog should reflect only the net user-visible outcome.
- **`archive this thread` intent contract**: When the user says "archive this thread" (or equivalent), execute this sequence: (1) ensure current work is committed, (2) review and update `CHANGELOG.md` if user-facing changes were introduced, (3) add/update relevant docs under `docs/` for features worked on in this thread, including user-facing behavior, implementation details, what changed in this thread, and code quirks/gotchas for future agents, (4) merge current thread branch into its base branch following the worktree merge flow, (5) archive the current thread via `magent-cli` (`/tmp/magent-cli current-thread` then `/tmp/magent-cli archive-thread --thread <name>`). Do not archive before steps 1-4 are done.
- **Commit-time docs gate (agent required)**: Whenever the user asks the agent to commit, also review whether the change introduces or updates behavior/policies/workflows that should be documented. Create or update files in `docs/` in the same commit when needed; do not defer documentation updates to a later follow-up commit.
- **Atomic commits — prefer many small commits over few large ones**: Separate distinct responsibilities into separate commits, even within a single branch or prompt response. It is normal and encouraged to produce several commits per branch or per user prompt. Each commit message must start with the thread/branch topic prefix (e.g. `feat(changes):`, `fix(rate-limit):`) so that commits from the same thread are visually grouped and traceable together in the git log.

## Releasing

When the user asks to "release", "publish", "cut a release", or "bump version":

1. **Determine the version bump** using [Semantic Versioning](https://semver.org/):
   - **patch** (1.0.0 → 1.0.1): bug fixes, minor tweaks
   - **minor** (1.0.0 → 1.1.0): new features, non-breaking changes
   - **major** (1.0.0 → 2.0.0): breaking changes (rare — confirm with user)
   - If the bump type is ambiguous, ask the user
2. **Find the current version**: `git tag --sort=-v:refname | head -1`
3. **Ensure changelog notes exist** under `CHANGELOG.md` → `## Unreleased`
4. **Run release helper**:
   ```bash
   ./scripts/release-interactive.sh
   ```
5. **Manual fallback only if needed**: create an **annotated** tag (`git tag -a v<new_version> -m "<notes>"`) and push it
6. **Monitor the workflow**: `gh run list --limit 1` then `gh run watch <id> --exit-status`
7. **Verify**: `gh release view v<new_version> --repo vapor-pawelw/magent-releases` — confirm the release has `Magent.dmg` attached (plus compatibility `Magent.zip`)

The tag push triggers a GitHub Actions workflow (`.github/workflows/release.yml`) that:
- Builds an unsigned `Magent.app` on `macos-26`
- Publishes a GitHub Release to `vapor-pawelw/magent-releases` with changelog/tag-annotation notes, `Magent.dmg`, and a compatibility `Magent.zip`
- Auto-updates the Homebrew cask in `vapor-pawelw/homebrew-magent`

**Do NOT** manually edit `Project.swift` version strings — the workflow injects them from the git tag automatically.

## Important Files

- `docs/requirements.md` — full feature requirements
- `docs/architecture.md` — architecture decisions and component design
- `docs/cli.md` — complete CLI command reference (all `magent-cli` commands, options, `thread-info` status fields)
- `docs/building.md` — build prerequisites and instructions
- `docs/releasing.md` — release process (tag-driven)
- `docs/changelog.md` — changelog authoring + release-notes flow
- `CHANGELOG.md` — source of truth for user-facing release notes

## Self-Learning

When implementing a new feature, bugfix, or behavioral change, check whether it introduces:
1. A **pattern that future code must follow** (e.g. agent-gating, banner usage) → add to Conventions above
2. A **non-obvious architectural constraint** → add to Decisions or a doc under `docs/`

Don't document things discoverable by reading the code (file locations, API signatures, etc.). Only document things that would cause bugs or inconsistency if a future session didn't know about them.
