# Pending Prompt Recovery

## Overview

When the user submits the New Thread or New Tab sheet, their prompt is written to a crash-recovery temp file in `/tmp` before the draft is cleared. If the app crashes between submission and tmux injection, the file survives and surfaces as a recovery banner on the next launch.

## File Lifecycle

1. **`acceptTapped`** in `AgentLaunchPromptSheetController` — writes `magent-pending-prompt-<UUID>.json` to `/tmp` via `PendingInitialPromptStore.save(...)`, then immediately clears the draft from persistent storage.
2. **`createThread` / `addTab`** in `ThreadManager` — inside the `MainActor.run` block that runs **before** `injectAfterStart` is called, `registerPendingPromptCleanup(fileURL:sessionName:)` subscribes to `magentAgentKeysInjected` for the new session.
3. **`injectAfterStart`** (background `Task`) — sends tmux keys and posts `magentAgentKeysInjected` when done. The subscriber from step 2 deletes the temp file.
4. **60-second fallback** — if injection never fires (e.g., session dies), `DispatchQueue.main.asyncAfter` deletes the file after 60 s.

## Critical Ordering Constraint

`registerPendingPromptCleanup` **must** be called inside the `MainActor.run` block that precedes `injectAfterStart`. This guarantees the listener is set up before the background injection task can post `magentAgentKeysInjected`. Registering it after `createThread`/`addTab` returns is too late — injection can complete before the caller resumes on the main thread.

## Recovery on Launch

`ThreadListViewController.checkForPendingPromptRecovery()` runs once in `viewDidLoad`. It scans `/tmp` for leftover `magent-pending-prompt-*.json` files and shows a dismissible warning banner for each, offering "Reopen" (re-opens the sheet pre-filled) or "Discard" (deletes the file).

## Draft Scope Clearing

On submit, both the **current** draft scope (project the user submitted to) and the **original** scope (`config.draftScope`, which may differ if the project picker was used) are cleared. This prevents stale draft text from appearing when the sheet is reopened for the original project.

`AgentLaunchPromptDraftScope` conforms to `Equatable`, so the two scopes are compared with `!=` directly.
