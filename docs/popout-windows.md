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
- Trailing strip accessories are limited to rate-limit/waiting indicator, keep-alive, favorite, and pinned badges.
- Clicking a popped-out thread row in the sidebar is focus-only: Magent brings that pop-out window to front, focuses its active/recent tab, and pulses the row in place. It does not switch main-window content.
- Popped-out rows are visually persistent in the sidebar (purple + pop-out icon) and use a 2pt capsule border to match the selected-row weight.
- The thread top bar (above the terminal) also includes a pop-out button next to Archive in the main window thread view.
- That top-bar pop-out button is hidden for the main thread, hidden in pop-out windows themselves, and hidden when the thread is already popped out.
- Hiding a project in `Settings > Projects` force-closes any thread/tab pop-outs from that project and moves main-window selection to the first remaining visible thread.

## Implementation notes

- Detached terminal identity must flow through `ThreadDetailViewController.terminalReuseKey(for:sessionName:)`. Do not build ad hoc cache keys in pop-out controllers. A mismatch here causes blank detached windows or failed return-to-tab restores.
- `terminalViews` is indexed by `thread.tmuxSessionNames` order, not by `tabSlots` display order. Any detach/return/rebuild path must resolve the terminal-array index from the session name first, especially when web or draft tabs are interleaved.
- Detaching a background tab must not replace the currently visible content with a detached placeholder. Only the selected detached tab should show `DetachedTabPlaceholderView` in the main thread view.
- Cold-launch restoration cannot rely on `ReusableTerminalViewCache` alone. Detached-tab windows must be able to recreate their `TerminalSurfaceView` from the same tmux command used by the in-thread terminal view when no cached surface survives the relaunch.
- Persist pop-out state on structural changes (`pop out`, `return`, `detach`, `reattach`) and on window frame changes. Saving only during app termination is not enough if the user restarts from a crash, force-quit, or any path that bypasses orderly shutdown.
- During app termination, pop-out windows must not "return to main" as part of their normal close handlers before state is saved. That shutdown path can wipe `popout-windows.json` and make relaunch restore look broken even when launch-time restore is correct.
- Do not focus pop-out windows on generic `.magentNavigateToThread` notifications. Those events are shared across multiple UI flows (status bar, sidebar jumps, etc.); pop-out windows should only come front when the user explicitly opens/reveals them.
- "Reveal without focus" paths (restore/reopen/app-activation recovery) must not use focus-stealing APIs (`showWindow`, `orderFrontRegardless`, `makeKeyAndOrderFront`, `NSApp.activate`). Use non-focusing `orderFront` behavior and preserve the existing key window.
- Main-window `activeThreadId` is for main content routing only. Popped-out threads should not become the main active thread through sidebar selection/navigation paths.
- Project-hide flows should close pop-outs via `PopoutWindowManager.closePopouts(forProjectId:)` and then use main-window fallback selection (`ThreadListViewController.selectFirstAvailableThread()`) instead of restoring last-opened thread/project defaults.
- Context handoff must avoid non-key responder churn. Pop-out windows should post `.magentFocusedThreadContextChanged` with explicit `isPopoutContext` on key-window focus and on direct terminal interaction. Main-window context must not auto-switch on key-window activation alone; it should switch on sidebar selection or direct interaction with the main terminal session.
- Ghostty clipboard/link callbacks are app-global, so pop-out/main focus handoff must keep the active surface synchronized. When a pop-out (thread or detached tab) becomes key, force its terminal surface as first responder and mark it active; when main regains key, re-mark the current main terminal surface active. URL-open callbacks should prefer the source `GHOSTTY_TARGET_SURFACE` over global focused-surface fallback to avoid opening/pasting against the wrong window.

## Relevant files

- `Magent/App/PopoutWindowManager.swift`
- `Magent/App/ThreadPopoutWindowController.swift`
- `Magent/App/TabPopoutWindowController.swift`
- `Magent/Views/Popout/PopoutInfoStripView.swift`
- `Magent/Views/Terminal/ThreadDetailViewController.swift`
- `Magent/Views/Terminal/ThreadDetailViewController+Actions.swift`
- `Magent/Views/Terminal/ThreadDetailViewController+TabBar.swift`
