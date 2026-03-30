# Pending Prompt Recovery

## Overview

When the user submits the New Thread or New Tab sheet, their prompt is written to a crash-recovery temp file in `/tmp` before the draft is cleared. If the app crashes between submission and tmux injection, the file survives and surfaces as a recovery banner on the next launch.

## Non-tmux Tab Exemption

Tab types that don't go through tmux injection (web tabs, draft tabs) must set `pendingPromptFileURL = nil` in `performAccept`. The cleanup listener (`clearAfterInjection`) only fires on `magentAgentKeysInjected`, which never arrives for non-tmux tabs — so any temp file written for them would linger and trigger a stale recovery banner on next launch.

## File Lifecycle

1. **`acceptTapped`** in `AgentLaunchPromptSheetController` — writes `magent-pending-prompt-<UUID>.json` to `/tmp` via `PendingInitialPromptStore.save(...)`, then immediately clears the draft from persistent storage. Non-tmux tab types (web, draft) skip this step entirely.
2. **`createThread` / `addTab`** in `ThreadManager` — immediately after tmux session creation, `markSessionContextKnownGood` is called so that the concurrent `setupTabs` → `recreateSessionIfNeeded` path short-circuits. Then, inside the `MainActor.run` block that runs **before** `injectAfterStart` is called, `registerPendingPromptCleanup(fileURL:sessionName:)` subscribes to `magentAgentKeysInjected` for the new session.
3. **`injectAfterStart`** (background `Task`) — waits for the agent-specific prompt marker via `waitForAgentPrompt` (see `docs/agent-prompt-detection.md` for per-agent detection details), sends tmux keys, and posts `magentAgentKeysInjected` only after the full startup injection for that session is complete. The subscriber from step 2 deletes the temp file.
4. **60-second fallback** — if injection never fires (e.g., session dies), `DispatchQueue.main.asyncAfter` deletes the file after 60 s.

## Critical Ordering Constraint

`registerPendingPromptCleanup` **must** be called inside the `MainActor.run` block that precedes `injectAfterStart`. This guarantees the listener is set up before the background injection task can post `magentAgentKeysInjected`. Registering it after `createThread`/`addTab` returns is too late — injection can complete before the caller resumes on the main thread.

## Pending Injection Banner

When `injectAfterStart` is called with an initial prompt, the session is registered in `pendingPromptInjectionSessions` and a `.magentPendingPromptInjection` notification fires **before** the background polling Task begins. `ThreadDetailViewController` observes this notification and shows a non-dismissible info banner on the affected tab:

> "Prompt will be injected once the agent is ready."

- **Inject Now** — cancels the in-flight polling task (`pendingPromptInjectionTasks[sessionName]`), then directly sends the prompt to tmux via `injectPendingPromptNow(...)`, bypassing `waitForAgentPrompt`.
- The banner auto-dismisses only when a prompt-bearing `magentAgentKeysInjected` fires (`includedInitialPrompt == true`) or when `magentInitialPromptInjectionFailed` fires (transitions to the failure banner below).
- Scoped to the current tab only — switching tabs re-evaluates via `refreshPendingPromptBanner()`.

`magentAgentKeysInjected` is completion-only. It carries `includedInitialPrompt` so prompt-specific UI and cleanup react only to the completion that actually pasted/submitted the prompt. Do not let prompt-less terminal-command or agent-context injections masquerade as prompt completion, otherwise the pending banner and crash-recovery cleanup can clear too early.

First-prompt auto-rename must not rename tmux sessions until that prompt-bearing injection has actually settled. `injectAfterStart` addresses tmux by session name while it polls for readiness and later sends the prompt; renaming the session before `magentAgentKeysInjected` arrives strands the task on the old session name, breaks prompt delivery, and makes rebuilt thread views lose the pending/failure banner unless the prompt-injection state is re-keyed with the rename.

### Cancellation safety

`injectAfterStart` stores its `Task` in `pendingPromptInjectionTasks[sessionName]`. Both prompt-wait paths (`shouldSubmitInitialPrompt` true/false) check `Task.isCancelled` after `waitForAgentPrompt` returns and exit silently if cancelled, preventing double-injection when the user clicks "Inject Now" while polling is in progress.

Cancellation is **conditional**: a new `injectAfterStart` call only cancels the pending prompt task when it also carries a prompt. Prompt-less calls (e.g., agent context injection from `recreateSessionIfNeeded`) leave an in-flight prompt task intact. This prevents a race where session recreation during `setupTabs` silently cancels the initial prompt injection.

## Injection Failure Handling

If `sendText` fails (e.g., tmux session died between readiness check and paste), `injectAfterStart` does **not** post `magentAgentKeysInjected`. Instead it transitions into the same per-tab initial-prompt failure state as a readiness timeout, so the recovery file is intentionally preserved and the user still gets an `Inject Prompt` retry path.

If the agent prompt marker never appears within the initial-prompt timeout, Magent also keeps the pending prompt state instead of blindly pasting into the pane. The affected terminal tab shows a persistent, non-dismissable warning banner with:

- **Inject Prompt** — retries prompt injection for that same session/tab
- **Copy Prompt** — copies the prompt text to the clipboard so the user can paste it manually, then dismisses the banner
- **Already Injected** — clears the warning when the user has already entered the prompt manually

This banner is scoped to the affected terminal tab only. Switching to another tab or a web tab should not surface it there.

### Named tmux buffers

`TmuxService.sendText` uses a unique named tmux buffer (`-b magent-<uuid>`) for each paste operation rather than the global default buffer. This prevents a race condition where concurrent `load-buffer`/`paste-buffer` calls (e.g., two tabs injecting simultaneously) could collide and silently drop one paste.

## Recovery on Launch

`ThreadListViewController.checkForPendingPromptRecovery()` runs once in `viewDidAppear`. It scans `/tmp` for leftover `magent-pending-prompt-*.json` files and handles them by scope:

- **`.newThread`** — shown as a global `BannerManager` banner with "Reopen" / "Discard" buttons. The "(N of M)" counter only counts `.newThread` entries, so `.newTab` entries that were silently stored don't inflate the count.
- **`.newTab`** — stored on `ThreadManager.pendingPromptRecoveriesByThread` (keyed by thread ID, supports multiple recoveries per thread). No global banner is shown. Instead, `ThreadDetailViewController` shows an embedded per-thread recovery banner when the affected thread is selected.

### Per-thread recovery banner

When a thread with pending recoveries is selected, `ThreadDetailViewController.refreshRecoveryBanner()` shows the first recovery as an embedded warning banner in the terminal container:

- **Reopen as Thread** — removes that single recovery entry, posts `.magentRecoveryReopenRequested` (observed by `ThreadListViewController` to present the recovery sheet), then shows the next recovery if any remain.
- **Discard** — deletes the temp file, removes the entry, and shows the next.
- **Dismiss (X)** — hides the banner without deleting data. The banner reappears on next thread selection, giving the user a "deal with it later" option.

### Cleanup on archive/delete

When a thread is archived or deleted, `ThreadManager.cleanupPendingPromptRecoveries(for:)` removes all pending recovery entries for that thread and deletes their temp files from `/tmp`.

## Draft Scope Clearing

On submit, both the **current** draft scope (project the user submitted to) and the **original** scope (`config.draftScope`, which may differ if the project picker was used) are cleared. This prevents stale draft text from appearing when the sheet is reopened for the original project.

`AgentLaunchPromptDraftScope` conforms to `Equatable`, so the two scopes are compared with `!=` directly.
