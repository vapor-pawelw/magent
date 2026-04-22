# Pop-out Windows

This doc covers thread pop-out windows and detached terminal tabs.

## User-facing behavior

- A non-main thread can be opened in a separate window while keeping the main-window thread selection independent.
- Individual terminal tabs can be detached into their own windows and later returned to the parent thread.
- Detached sessions stay protected from idle eviction and manual session cleanup while visible in a pop-out window.
- Pop-out window state is persisted across app relaunch. Reopened detached tabs should reconnect to the same live tmux session instead of showing an empty placeholder.
- Pop-out window frames are saved continuously on move/resize/screen changes, so restart restores separate thread and detached-tab windows at their latest size and position instead of their last graceful-quit frame.
- The separate-window header is clickable: clicking anywhere in the info strip selects and centers that thread in the main sidebar.
- The separate-window header strip mirrors sidebar thread naming semantics: primary text is task description (single-line in strip), secondary text is `branch · worktree` when they differ, and the dirty-dot sits before the secondary line.
- The same strip is also shown above the tab/action bar in the main thread view. In pop-out thread windows, keep only one strip (the pop-out chrome strip) to avoid duplicated headers.
- The strip uses sidebar-like state language: the bottom separator line carries completion/waiting/rate-limit/busy state; busy is shown only via separator animation (no trailing spinner).
- Rate-limit state in the strip uses agent-specific glyphs (Claude/Codex) with the same color semantics as sidebar badges (red for direct, orange for propagated-only), not generic hourglass symbols.
- The strip's right side uses a two-row layout that mirrors the left side: the top-right row holds status indicators (rate-limit/waiting state, keep-alive, favorite, pinned badges) and the bottom-right row holds compact capsule action buttons (Pull Request / Jira). Visibility of each capsule still follows the existing PR/Jira refresh logic — Jira hides when the project lacks a Jira config, PR hides on non-main threads with no detected PR.
- The capsule action row is owned by the host: in the main window the `ThreadDetailViewController` installs PR/Jira into its own `headerInfoStrip`; in pop-out windows `ThreadPopoutWindowController` installs the same buttons into its own `infoStrip`. The detail VC styles them as inline capsules in either case (`.inline` bezel, `.small` control size), and skips adding them to its top utility bar so they don't appear twice.
- Clicking a popped-out thread row in the sidebar is focus-only: Magent brings that pop-out window to front, focuses its active/recent tab, and pulses the row in place. It does not switch main-window content.
- Popped-out rows are visually persistent in the sidebar (purple + pop-out icon) and use a 2pt capsule border to match the selected-row weight.
- The thread top bar (above the terminal) also includes a pop-out button next to Archive in the main window thread view.
- That top-bar pop-out button is hidden for the main thread, hidden in pop-out windows themselves, and hidden when the thread is already popped out.
- Sidebar thread rows can be dragged over thread pop-out windows. A dark overlay appears on valid hover targets to indicate drop-to-replace behavior.
- Dropping a thread over another thread's pop-out window shows a confirmation alert. Confirming returns the currently popped-out thread to the main window and replaces it with the dropped thread in that pop-out window.
- Dropping a thread onto the same pop-out window where it is already open is a silent no-op. Dropping a thread that is already popped out in a different window prompts the user to either move it into the target window or swap the two pop-out windows.
- Hiding a project in `Settings > Projects` force-closes any thread/tab pop-outs from that project and moves main-window selection to the first remaining visible thread.
- Thread actions use key-window context across main and pop-out windows. When a detached tab window is key, thread-level actions resolve to that tab's parent thread.
- Keyboard shortcuts and Thread menu actions are parity-routed across window types (`New Thread`, `Fork Thread`, `AI Rename`, and contextual tab/thread actions).
- Detached-tab shortcut behavior is explicit: `Cmd+W` returns the detached tab to its parent thread window, while `Cmd+Shift+O` is no-op with feedback.
- CLI-created tabs (`create-tab`, `create-web-tab`) target popped-out thread windows when the thread is popped out, and the created tab is selected in that pop-out window.
- Tab detaching is production-disabled. In debug builds it can be re-enabled via `Settings > Debug > Experimental > Enable tab detaching` (off by default); all detach UI and shortcut paths must honor `AppSettings.isTabDetachFeatureEnabled`.

## Implementation notes

- Detached terminal identity must flow through `ThreadDetailViewController.terminalReuseKey(for:sessionName:)`. Do not build ad hoc cache keys in pop-out controllers. A mismatch here causes blank detached windows or failed return-to-tab restores.
- `terminalViews` is indexed by `thread.tmuxSessionNames` order, not by `tabSlots` display order. Any detach/return/rebuild path must resolve the terminal-array index from the session name first, especially when web or draft tabs are interleaved.
- Detaching a background tab must not replace the currently visible content with a detached placeholder. Only the selected detached tab should show `DetachedTabPlaceholderView` in the main thread view.
- Cold-launch restoration cannot rely on `ReusableTerminalViewCache` alone. Detached-tab windows must be able to recreate their `TerminalSurfaceView` from the same tmux command used by the in-thread terminal view when no cached surface survives the relaunch.
- Persist pop-out state on structural changes (`pop out`, `return`, `detach`, `reattach`) and on window frame changes. Saving only during app termination is not enough if the user restarts from a crash, force-quit, or any path that bypasses orderly shutdown.
- During app termination, pop-out windows must not "return to main" as part of their normal close handlers before state is saved. That shutdown path can wipe `popout-windows.json` and make relaunch restore look broken even when launch-time restore is correct.
- Do not focus pop-out windows on generic `.magentNavigateToThread` notifications. Those events are shared across multiple UI flows (status bar, sidebar jumps, etc.); pop-out windows should only come front when the user explicitly opens/reveals them.
- Generic navigation can still include a tab/session identifier. `SplitViewController.handleNavigateToThread` must apply that identifier to both contexts: main thread detail and an existing popped-out thread detail (`displayIndex(forIdentifier:)`), with a deferred retry because tab creation may complete on the next run-loop tick.
- "Reveal without focus" paths (restore/reopen/app-activation recovery) must not use focus-stealing APIs (`showWindow`, `orderFrontRegardless`, `makeKeyAndOrderFront`, `NSApp.activate`). Use non-focusing `orderFront` behavior and preserve the existing key window.
- Returning one popped-out thread to main must not steal focus from another currently focused pop-out window. In `SplitViewController.handleThreadReturnedToMain`, only re-key the main window when the current key window is not a pop-out.
- Main-window `activeThreadId` is for main content routing only. Popped-out threads should not become the main active thread through sidebar selection/navigation paths.
- Project-hide flows should close pop-outs via `PopoutWindowManager.closePopouts(forProjectId:)` and then use main-window fallback selection (`ThreadListViewController.selectFirstAvailableThread()`) instead of restoring last-opened thread/project defaults.
- Fallback selection triggered as a side-effect of pop-out (`SplitViewController.selectFallbackMainThread`) must not auto-scroll the sidebar. Drop-to-replace and move-between-popouts both fire `.magentThreadPoppedOut` for the dragged thread, which can in turn cause `selectThread(byId:)` to run for whichever fallback row exists. Pass `scrollRowToVisible: false` so the user's current sidebar scroll position is preserved — the fallback only needs to populate the detail pane, not jump the sidebar. Note that `scrollRowToVisible: false` alone is not enough: `NSOutlineView.selectRowIndexes` drives its own internal `scrollRowToVisible(_:)` path, so when the caller opts out `ThreadListViewController.selectThread(byId:)` must additionally wrap the selection in `preserveSidebarSelectionViewport` (which toggles `SidebarOutlineView.suppressSelectionAutoScroll`). Without that wrapper, AppKit's internal auto-scroll still yanks the sidebar to the fallback row during drop-to-replace flows.
- Context handoff must avoid non-key responder churn. Pop-out windows should post `.magentFocusedThreadContextChanged` with explicit `isPopoutContext` on key-window focus and on direct terminal interaction. Main-window context must not auto-switch on key-window activation alone; it should switch on sidebar selection or direct interaction with the main terminal session.
- Thread-command routing should use key-window precedence:
  - key `ThreadPopoutWindowController` -> popped-out thread
  - key `TabPopoutWindowController` -> detached tab's parent thread
  - otherwise -> main selected/visible thread context
- Thread menu actions should not target `SplitViewController` selectors directly. Route through `AppDelegate` context-aware handlers so menu invocation matches keyboard behavior in pop-outs.
- Ghostty clipboard/link callbacks are app-global, so pop-out/main focus handoff must keep the active surface synchronized. When a pop-out (thread or detached tab) becomes key, force its terminal surface as first responder and mark it active; when main regains key, re-mark the current main terminal surface active. URL-open callbacks should prefer the source `GHOSTTY_TARGET_SURFACE` over global focused-surface fallback to avoid opening/pasting against the wrong window.
- Pop-out windows host their own `BannerOverlayView` registered with `BannerManager.shared.registerContainer(_:)` at setup and unregistered in `tearDown()`. Without this, errors surfaced during work triggered from a pop-out (AI rename failures, etc.) would only render in the main window and be invisible when the user has the main window hidden or behind the pop-out. See `docs/banner-behavior.md` → "Multi-window routing".
- Thread archive/delete must tear down pop-out windows synchronously before the detached `tmux kill-session` task runs. Both paths call `ThreadManager.releaseLivingGhosttySurfaces(for:)`, which invokes `PopoutWindowManager.returnThreadToMain(_:)` plus per-session `returnTabToThread(sessionName:)` and then evicts `ReusableTerminalViewCache` again (the return path re-caches the view with `preserveSurfaceOnDetach = true`). Both paths also post `.magentArchivedThreadsDidChange` — `PopoutWindowManager.startObserving` listens for it as a belt-and-suspenders cleanup signal. See `docs/libghostty-integration.md` → "Surface Lifecycle: Thread Archive/Delete Contract" for the full rationale.

## Relevant files

- `Magent/App/PopoutWindowManager.swift`
- `Magent/App/ThreadPopoutWindowController.swift`
- `Magent/App/TabPopoutWindowController.swift`
- `Magent/Views/Popout/PopoutInfoStripView.swift`
- `Magent/Views/Terminal/ThreadDetailViewController.swift`
- `Magent/Views/Terminal/ThreadDetailViewController+Actions.swift`
- `Magent/Views/Terminal/ThreadDetailViewController+TabBar.swift`
