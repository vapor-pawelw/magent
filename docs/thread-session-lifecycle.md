# Thread & Session Lifecycle

## Thread Creation (Pending Thread Pattern)

`ThreadManager.createThread` registers the thread in the sidebar immediately (phase 1: name generation only), then runs git worktree + tmux setup in the background (phase 2). The thread is tracked in `pendingThreadIds: Set<UUID>` while phase 2 runs.

- `SplitViewController.showThread` skips the worktree-existence check for pending threads.
- `ThreadDetailViewController.setupTabs` detects pending via `pendingThreadIds`, shows overlay, waits for `.magentThreadCreationFinished`.
- On error, the pending thread is removed via `delegate?.threadManager(self, didDeleteThread:)` and the notification fires with `"error"` in userInfo.
- Pending threads are never persisted; only save after phase 2 succeeds.
- New tmux sessions must seed `sessionLastVisitedAt` immediately when registered, or idle eviction treats them as ancient after the user switches away.

## Worktree Recovery

Automatic — when a user selects a thread whose worktree directory is missing, `SplitViewController` triggers recovery via `ThreadManager.recoverWorktree()`, showing progress via banners.

## Session Lifecycle

- **Stale tmux cleanup** is centralized in `ThreadManager.cleanupStaleMagentSessions()`, scoped to `ma-` sessions only. Used for lifecycle hooks + session-monitor poller (5-minute cadence) instead of ad hoc `tmux kill-session` sweeps.
- **Dead session recreation is lazy**: `checkForDeadSessions` updates `thread.deadSessions` but only auto-recreates the currently visible session. Others stay dead until the user selects the tab → `ensureSessionPrepared` → `recreateSessionIfNeeded`. Never post `.magentTabWillClose` to clean up sessions that should be preserved — use `evictedIdleSessions` + `ReusableTerminalViewCache.evictSessions()` instead.
- **Recent-session fast path spans VC rebuilds**: `ensureSessionPrepared` consults `ThreadManager.isSessionPreparedFastPath(...)` (backed by `knownGoodSessionContexts`) before any tmux probe, so switching away and back to a recently validated thread can skip `tmux has-session` and avoid startup-overlay churn.
- **Slow non-agent tab switches must still show progress**: `startLoadingOverlayTracking(...)` should not immediately dismiss for plain terminal tabs. Keep the same debounced loading overlay active during `ensureSessionPrepared`/tmux validation so users get visible feedback when a switch takes longer than the fast path.
- **Startup-overlay retention must be agent-only**: after `setupTabs(...)` or `selectTab(...)` resolves the selected session, only keep the startup overlay alive when that tab still resolves to a live agent session. If runtime detection says the pane is back at a plain terminal, dismiss `Preparing terminal session...` immediately instead of honoring stale startup-overlay tokens.
- **Prepared-tab attach failures must degrade to visible recovery, never blank UI**: if `selectPreparedTab(...)` cannot attach/select the terminal view during startup or tab selection, keep the loading overlay visible with explicit diagnostic text and immediately retry through the full `selectTab(...)` path (`ensureSessionPrepared` / tmux validation) instead of returning silently.
- **Tab hover status hints must be refreshed from the same notification paths as tab indicators**: tooltip text is derived from live thread/session state (busy, waiting, rate-limit, dead, keep-alive, unread markers). Any code path that updates tab badges/indicator dots must also refresh tab tooltips to avoid stale hover details.
- **Manual session cleanup** (`ThreadManager+SessionCleanup.swift`) must use the same eviction model as idle eviction: mark in `evictedIdleSessions`, evict from cache before killing, never touch tab metadata. Protected sessions (busy, waiting, rate-limited, magent-busy, visible) must never be killed.
- **Resume metadata boundaries**: Claude/Codex resume lookup is keyed by worktree path, so when an archived auto-generated worktree name is reused, only conversations newer than the current thread's `createdAt` may be adopted.
- **tmux zombie overload recovery** is banner-driven: `ThreadManager.checkTmuxZombieHealth()` monitors zombie-heavy tmux parents and offers a one-click `restartTmuxAndRecoverSessions()` action.

## Startup Recovery

If `threads.json` records are reassigned onto an existing project during `settings.json` recovery, do not keep multiple active threads that resolve to the same normalized `worktreePath`. Merge their tabs/state into one canonical thread and de-duplicate terminal tab titles (especially for the main worktree).
