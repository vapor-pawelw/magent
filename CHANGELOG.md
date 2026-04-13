# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Sidebar
#### Features
- Added hover tooltips for all thread-row badges, including priority, busy duration, favorite, pinned, keep-alive, Jira status, and PR status badges.
- Threads opened in separate windows now use a subtle purple row tint and a more prominent trailing window icon in the sidebar.

#### Bug Fixes
- Fixed launch-time thread navigation so the selected thread is centered only after the sidebar has fully loaded and laid out, avoiding premature scroll jumps during startup.

### Settings
#### Bug Fixes
- Fixed `Settings > General > Links` preference persistence. "Open web links in" now stays on the selected value after relaunch instead of reverting.

### Web Tab
#### Bug Fixes
- Fixed host:port URL parsing in the in-app web view address bar. Entries like `localhost:3000/docs#api` now open as HTTP(S) URLs and preserve query/fragment anchors.

### Tab
#### Features
- Added tab hover tooltips in the thread detail view. Hover now shows tab type, terminal tmux session name (for terminal tabs), and live tab status details (busy, waiting for input, keep-alive, dead session, and rate-limit state).

#### Bug Fixes
- Fixed stale `Preparing terminal session...` overlays covering already-live Codex tabs. Startup overlay retention now only stays active when the selected tab still resolves to a running agent session.
- Fixed recurring app termination when closing tabs from non-visible threads (or IPC paths) by evicting cached terminal surfaces before tmux session shutdown.
- Fixed slow tab switches showing no progress for non-agent terminal tabs. Tab selection now shows the same debounced loading overlay during tmux/session validation instead of leaving the terminal area blank with no feedback.
- Fixed tab-name deduplication when cloning/resuming/renaming tabs. Names now use a single monotonic suffix sequence per base name (`Codex`, `Codex-1`, `Codex-2`, ...), preventing chained names like `Codex-1-1` and avoiding suffix reuse after deletions.

### Status Bar
#### Features
- Added a `windows` status in the bottom bar for threads opened in separate windows. Clicking it lists those threads, uses the same centered sidebar navigation as Favorites, and includes actions to return individual windows or all windows to the main app.

#### Bug Fixes
- Fixed favorites popover navigation using abrupt sidebar row reveal. Selecting a favorite thread now uses the same centered, smooth animated scroll (with row pulse) as the sidebar's selected-thread jump control.
- Fixed thread icons in `favorites` and `done` popovers ignoring section colors. Popover rows now tint each thread icon with its effective section color (matching sidebar rows when sections are enabled).
- Fixed `favorites`/`done` popover navigation overriding the destination thread's selected tab. Opening a thread from those popovers now preserves that thread's last-selected tab.

### Thread
#### Bug Fixes
- Pop-out windows now use section-colored thread icons in the top info strip (instead of default primary styling), keep that strip synced with section/thread metadata changes from the main window, and mirror the same info strip in the main thread view above the tab/action bar.
- Fixed double header bars in popped-out thread windows by keeping the shared thread info strip only in the pop-out chrome there (while still showing it in the main thread view), and aligned the strip separator baseline to the sidebar selected-thread accent.
- Refined thread info-strip layout/content to mirror sidebar row semantics: centered leading icon, dirty-state dot before the secondary line, and branch/worktree secondary text (showing worktree only when it differs from branch) while keeping description single-line.
- Fixed thread info-strip rate-limit badges (main thread view + pop-out windows) still showing legacy hourglass icons. The strip now shows Claude/Codex glyphs, matching sidebar rate-limit badges.
- Fixed occasional unexpected focus jumps to popped-out thread windows by stopping global thread-navigation notifications from forcing pop-out windows to front.
- Focusing a thread now clears unread completion state immediately, even if the thread was already selected or its separate window was already focused when the agent finished.
- Separate thread and detached-tab windows now persist their latest size and position continuously, so app restart restores the same extracted windows in the same place.
- Fixed separate-window quit/relaunch restore so popped-out thread windows stay popped out across normal app restart instead of collapsing back into the main window.
## 1.5.4 - 2026-04-10


### General
#### Bug Fixes
- Fixed main window size/position resetting on app rerun/relaunch paths that bypass normal app termination. Magent now persists the main-window frame continuously on move/resize/screen changes, so the latest frame restores reliably on next launch.
- Fixed Magent unexpectedly switching macOS Spaces/desktops during display-topology updates. Screen-parameter handling now refreshes off-screen recovery without activating or focusing the app window.
- Improved multi-monitor launch restore reliability. Magent now persists the main window's last display ID on quit and prefers reopening on that display at next launch (with active-screen fallback when the saved display is unavailable).

### Settings
- Fixed rare crashes when opening repository/worktree folder pickers before the Settings/Configuration view had an attached window.
- App updates now use a clear staged action in Settings: `Download` first, disabled `Downloading...` while transfer/prep runs, then `Install & Relaunch` once the update is ready. Prepared downloads are recovered from `/tmp` after app restarts, so you can still install without downloading again.
- Link-opening preference is now persisted correctly across launches. `Settings > General > Links` no longer reverts after restart.

### Web Tab
#### Features
- Added "Open in Browser" button (Safari icon) to the web tab toolbar. Opens the current page in your default browser.
- Default external link destination is now `Magent web tab` for new settings profiles.
- Added in-page find (`Cmd+F`) in web tabs with next/previous controls; Enter advances and Esc dismisses.
- Link-opening overrides now use `Option-click` (toolbar buttons and terminal links) for "open in opposite destination".
- Middle-clicking a link inside the internal webview now opens that link in a new web tab.

#### Bug Fixes
- Reopening Jira/PR tabs from the top-right buttons now resets the tab to the canonical Jira/PR URL and clears prior navigation history instead of keeping the last navigated page.

### Tab
#### Features
- Tab names now automatically reflect the active Claude model and effort when you switch with `/model` (e.g. "Claude" → "Claude (Sonnet 4.6, H)"). Tabs you've manually renamed are never touched.
- Double-clicking a terminal session tab now opens the existing "Rename Tab" prompt directly.

### Terminal
#### Bug Fixes
- Hardened embedded terminal display-link callbacks to safely ignore missing runtime userdata instead of crashing on pointer unwrap.
- Eliminated the tmux zombie process buildup that caused the recurring "tmux health issue: N defunct processes" banner. The per-click URL capture binding now stores mouse state in an in-process tmux option (`set-option -gqF`) instead of spawning a shell script via `run-shell -b` on every mouse click, so fast clicking no longer accumulates defunct children under the tmux server.

### Tab
#### Bug Fixes
- Reorganized the tab context menu for faster session actions: `Resume Agent Session in New Tab` now sits directly below `Continue in...`, tab-level session controls are grouped under a `Session` submenu (`Keep Alive`, `Kill All Sessions`), and `Close Tabs to the Left/Right` now appear immediately above `Close This Tab` (which stays last).

### New Thread Sheet
#### Features
- Terminal and Web type prompts now display as compact single-line fields with placeholder text ("e.g. vim, htop, ssh user@host" / "https://..."), making the expected input obvious and reducing accidental prompt-in-URL mistakes.

#### Bug Fixes
- Fixed project-switch draft restore in the New Thread sheet: each project's in-progress prompt is now saved and restored per mode (`agent`, `terminal`, `web`) when switching between projects.
- Switching projects with non-empty input now asks whether to move the current input to the selected project or save it in the current project; when the destination already has a saved draft, the dialog warns that it will be replaced and shows a quoted preview of the existing draft.

### Sidebar
#### Features
- Added "Sort" submenu to section and repo right-click context menus. Sort threads by description, branch name, priority, or last completion. Sorting always respects pinned/normal/hidden boundaries (pinned threads never drop below unpinned). Hold/release ⌥ Option while the menu is open to live-swap between ascending and descending sort items. Right-clicking the repo name sorts all sections at once (including hidden sections); right-clicking a section sorts only that section. When section grouping is disabled, all threads are treated as one container.
- Added a floating "selected thread" jump capsule at the bottom of the thread list that appears only when the current thread is outside the visible sidebar viewport. The capsule shows thread icon + description (or worktree fallback) and a directional arrow, and clicking it scrolls to center the thread row.

### Thread
#### Features
- New "AI Rename" sheet (⌘⇧R) replaces the old single-line rename dialog: multi-line prompt input, recent prompt picker (last 10), and checkboxes to choose which parts to change (icon, description, branch name). Accessible as a top-level context menu item, TOC right-click, and main Thread menu.
- Restructured thread context menu: "AI Rename" and "Sign" are now top-level items; Icon, Description, Branch name, and Section are grouped under a new "Configure" submenu.
- Grouped session actions in the thread context menu under a new `Session` submenu (`Keep Alive`, `Kill All Sessions`) to reduce top-level menu clutter.
- Added a 1–5 Priority submenu next to Sign. Priority is shown as five cumulative dots on the thread row (immediately left of the busy-state duration), tinted blue → green → yellow → orange → red as the level rises. The ↑ High Priority and ↓ Low Priority sign emojis were removed in favor of this scale; the remaining sign emojis are unchanged.
- Added "Set priority from Jira ticket" to the Jira submenu in the thread context menu, mirroring the existing "Set description from Jira ticket" action. The action is shown when the detected/linked Jira ticket has a priority that maps to the 1–5 scale (Highest → 5 … Lowest → 1).
- Added question and exclamation sign emojis to thread rows; trimmed rarely-used signs (Pause, Book, Bolt, Lock).
- Added ballot box with check (`☑️`) to thread sign emojis (next to the existing checkmark option) for finer task-state labeling.
- Auto-rename now uses all accumulated prompts for context, so if the first prompt gets rate-limited and the user follows up with "continue", the rename model still sees the original task description.
- Manual "Rename from prompt" now updates the thread description and icon to match the new branch, instead of keeping the stale description from the original auto-rename.
- Rename failure banners now include a diagnostic reason (timeout, CLI error, empty output, or parse failure) instead of a generic "could not generate" message.
- Added thread Favorites: right-click `Add to Favorites` / `Remove from Favorites` action (next to pin), max 10 favorites, and a heart badge on favorite thread rows (positioned immediately left of the pin badge when both are present).

#### Bug Fixes
- Fixed missing branch-name compatibility symlinks for some worktrees. Non-main worktrees now auto-create and maintain `<worktrees-base>/<current-branch>` symlinks during branch-state refresh, branch-accept, and branch-rename flows.
- Detached tabs now reopen with their live terminal session instead of a blank window, including after app relaunch, and the main-window `Detach Tab` shortcut now routes correctly.
- Fixed AI Rename sheet hanging (infinite spinner) when typing after clicking at the end of the placeholder text.
- Reduced unnecessary `Starting agent...` flashes when revisiting recently used tabs. Healthy sessions now fast-path across view-controller rebuilds, the loading overlay reveal is debounced for quick switches, and repeated tmux readiness polling during startup tracking was removed.
- Fixed occasional blank thread view on open when a "prepared" terminal tab failed to attach on the first pass. Startup/tab selection now keeps a visible loading state and retries full tmux/session validation instead of leaving an empty panel.
- Improved busy detection for Claude sessions with background tasks. Sessions running `run_in_background` tools or active task spinners are now correctly detected as busy even when the `❯` prompt is visible.
- Fixed busy detection missing the agent status bar in tall terminal panes. Trailing blank lines in tmux captures are now stripped before analysis, preventing all-blank capture windows.
- Fixed archive merge failing when the branch name matches the worktree directory name by using unambiguous `refs/heads/` git references.
- Fixed "Rename from prompt" (TOC and auto-rename) failing silently when the spawned CLI process inherited an invalid stdin from the GUI app. Background `claude -p` and `codex exec` calls now redirect stdin from `/dev/null`, eliminating both the failure and a ~3-second startup delay.
- Fixed stale thread context-menu state after favorite toggles by building menus from the latest thread snapshot.

### CLI
#### Features
- `create-tab` now accepts `--title` to set the tab name from the CLI and `--fresh`/`--no-resume` to keep isolated review tabs from inheriting older agent history.
- `batch-create` specs now accept `"promptFile": "/path/to/prompt.txt"` to load the initial prompt from a file, avoiding JSON escaping issues with long or multi-line prompts. `promptFile` takes precedence over `prompt` when both are set.
- Added thread priority support to the CLI: `create-thread --priority 1-5` and a per-spec `"priority"` key for `batch-create` assign the 1–5 priority at creation time. A new `set-priority --thread <name> (--priority 1-5 | --clear)` command updates or clears priority on existing threads.
- Interactive CLI now remembers the last attached session context and, on the next run, opens directly in that thread when available. If the thread is gone it falls back to the last project; if the project is gone it falls back to project picker.
- Added `favorite-thread --thread <name>` and `unfavorite-thread --thread <name>` commands.
- Interactive picker and `ls` now render favorite threads with a heart status badge (`♥`), and `thread-info`/`list-threads` status now includes `isFavorite`.

#### Bug Fixes
- Fixed multiline prompts sent via `send-prompt` (or agent-to-agent injection) being cut off after the first line. tmux paste-buffer now uses bracketed paste mode so Claude's TUI receives newlines as literal characters rather than Enter keypresses.
- Fixed `batch-create` silently ignoring the `name` field in specs JSON — the JSON key `"name"` was not mapped to the internal Swift property, so threads were always auto-named from `description`.
- Fixed `batch-create` failing with "Invalid JSON" when `specs.json` is pretty-printed. The CLI now compacts the array before sending so embedded newlines don't truncate the IPC message.
- Improved IPC JSON parse error messages: errors now report the specific field or mismatch instead of the generic "couldn't be read" Foundation message; `dataCorrupted` errors include a hint about the newline-truncation pitfall.
- Interactive CLI tab picker now shows real tab names (including custom titles) instead of generic `Tab #` labels.

### Agents
#### Features
- When a rate limit lifts (timer expiry or manual dismiss), threads and tabs where the agent was directly interrupted now show a "waiting for input" indicator so you know which ones to revisit and continue work. The indicator clears as soon as you select the tab or the agent resumes on its own.

#### Bug Fixes
- Fixed active global rate limits incorrectly marking idle shell tabs as limited. Per-tab rate-limit fan-out now applies only to sessions where that agent is currently detected as running.
- Added a direct-source marker to thread rate-limit badges: a tiny red corner dot now appears when the limit was directly detected on that thread (not only propagated globally).
- Fresh Claude/Codex tabs now scope resume discovery to the tab that created them instead of the whole thread age, reducing accidental conversation carryover on older worktrees.
- Fixed Codex busy indicators dropping during long-running tool commands (for example `xcodebuild`) and occasionally staying busy due to stale pane lines. Busy detection now uses Codex working/background status markers near the bottom of the latest pane scope and only applies stored agent-type fallback when live pane content matches that agent.
- Fixed agent tabs staying busy after dropping back to a plain shell prompt. Stored agent-type fallback now requires active busy markers (not prompt glyphs alone), preventing terminal sessions from being misclassified as running Claude/Codex.
- Fixed agent labels in the "+" right-click menu (both new thread and new tab) showing misleading suffixes like "Claude (M)" or "Codex (Codex, M)". The menu now shows the full model and reasoning level verbatim (e.g. `Claude (Opus, high)`, `Codex (GPT 5.3 Codex, xhigh)`), and omits any part set to Auto.
- Fixed `Lift + Ignore Current Messages` over-suppressing later agent limits that reused the same text. Ignore entries are now keyed by exact resolved reset timestamps, and the action captures all visible future reset windows for that agent at once.
### Sidebar
#### Features
- Thread sign emojis (↑ ↓ and custom emoji) now appear inside a small circular badge in the top-left corner of the thread row, with a border that matches the row's current highlight color.
- Right-clicking an unselected thread now briefly highlights its row while the context menu is open, making it clear which thread the action will apply to.

#### Bug Fixes
- Fixed pinned thread badges/icons rendering with a yellow/brand tint in some views; pinned indicators now use the neutral text-secondary tint consistently.
- Fixed bottom-of-list overlap with the floating selected-thread capsule by reserving explicit spacer height in the thread list content, so end-of-list spacing stays consistent whether the changes panel is visible or hidden.
- Fixed thread row state highlights (busy/completion/waiting/rate-limit) disappearing after scrolling away and back. Reused rows now resolve against the latest thread snapshot before rendering.
- Fixed branch rename dialog pre-filling with the worktree name instead of the current git branch, and silently doing nothing when the user accepted it.
- Fixed rate-limit red border not clearing when selecting the rate-limited thread/tab. The in-place sidebar update path was missing `showsRateLimitHighlight`, so the border persisted even after the unread state was cleared.
- Increased thread row vertical spacing so the pin badge is no longer clipped at the top.
- Fixed "Mark as read" appearing in the context menu for threads that aren't visually highlighted as done (when a rate-limit is also active, suppressing the green highlight).
- Fixed thread rows appearing simultaneously green (agent completed) and busy. Busy state now takes precedence — completion highlights are suppressed while the thread is busy and reappear once it goes idle.
- Fixed thread row border widths so only the selected row uses a 2pt border; all non-selected states (including completion, waiting, rate-limit, and busy animation) now use 1pt, and attached sign badges match that width.
- Fixed `Create New Repository…` from the sidebar add-repo menu sometimes appearing to do nothing. Repo creation now shows a persistent progress banner with spinner, reports explicit success/failure banners, and seeds the initial empty commit with transient git identity/signing-hook overrides so local git config does not block creation.

### Status Bar
#### Features
- The `done` status popover now supports read actions directly: each row has a checkmark button to mark that thread as read, and a footer `Mark All as Read` button clears all unread completions.
- Right-clicking the `done` status item now opens a one-action context menu with `Mark All as Read`.
- Added a dedicated favorites status-bar control (`X favorites` with heart icon) shown when favorites exist. Clicking it opens a favorites popover (chronological order) with per-thread remove actions and a limit hint when the 10-favorite cap is reached.

#### Bug Fixes
- Holding `Option` while the thread context menu is open now live-switches `Mark as Read` to `Mark All as Read`, so bulk-clearing read state no longer requires reopening the menu.
- Marking a thread as read from the `done` popover row checkmark now keeps the popover open and refreshes the list in place, so users can clear multiple rows quickly without interruption.
- Fixed delayed `done` count updates while the `done` popover is open. Counts now refresh immediately after each mark-as-read action without dismissing the popover.
- Fixed stale `done` popover UI after manual `Mark as Read` / `Mark All as Read` actions. When read-state changes clear the active `done` list, Magent now closes that stale popover and rebuilds status buttons immediately.
- Fixed `done` popover width jitter while clearing rows: popover content now keeps a constant row width, the popover is 50% wider, and descriptions can wrap to two lines without resizing.

### Distribution
#### Features
- Added `scripts/sync-release-notes-from-changelog.sh` to backfill existing GitHub release bodies from matching `CHANGELOG.md` version sections.

#### Bug Fixes
- GitHub release notes now prefer the matching `CHANGELOG.md` version section (`## <version> - <date>`) instead of falling back to commit-subject-like tag content, so published release pages keep the expected markdown format.


## 1.5.3 - 2026-04-07


### Terminal
- Fixed terminal becoming unresponsive to mouse clicks. The CAMetalLayer backing the terminal surface was missing `isOpaque`, causing the macOS window server to intermittently route mouse events past the terminal region.
- Fixed tmux mouse URL capture script blocking all terminal input by running it in the background (`run-shell -b`).
- Fixed diff image overlay and loading overlay surviving thread switches, permanently blocking mouse events in the terminal area.

### Sidebar
- Rate limit badges now show Claude/Codex agent glyphs instead of generic hourglass icons, so users can see which agent is rate-limited at a glance.
- Threads that directly trigger rate limits now show a red capsule highlight (like the green completion highlight) that clears when the user selects the thread.
- Diff panel can now be collapsed to show only branch info, with a chevron toggle at the top-right of the branch info area. Collapsed state is persisted across sessions.
- Project and section headers now stick to the top of the sidebar while scrolling, so you always know which repo/section the visible threads belong to. Clicking a sticky header smoothly scrolls back to the actual header row.
- Busy threads now show a rotating gradient border animation instead of a spinner icon. All busy threads now animate in lockstep, so their shimmer and rotation stay perfectly aligned.
- Duration labels now tint with a color gradient based on thread age (light blue for <15 min, green for <8 hrs, yellow for <1 day, orange for <3 days, red for 3+ days), providing at-a-glance visual feedback on activity.
- Metadata-only sidebar updates (busy state, rate limits, dirty flag, etc.) no longer recreate row views, preserving running animations.

### CLI
- `create-thread`, `create-tab`, and `batch-create` now accept `--model <id>` and `--reasoning <level>` to launch the initial tab with a specific model or reasoning level.
- `create-thread` no longer switches the GUI to the new thread by default. Use `--select` to opt in. Batch create never switches.

### Agents
- Fixed busy state detection for Claude Code sessions where the agent reports its version number as the process title, causing the sidebar to miss or drop the busy indicator.
- GPT 5.3 is now available as a Codex model option.
- Fixed agent resume/recovery from incorrectly triggering when a plain terminal fallback session is recreated.
- Fixed auto-rename-on-first-prompt to trigger immediately when prompts are injected via CLI, instead of waiting for user interaction or bell events.
- Rate limits anchored to your submitting prompt are now pruned when you move on to new code, so old limit messages don't resurface in the sidebar after the pane scrolls.
- Time-only rate limits (e.g., "resets 4pm") are now session-anchored, preventing cross-session bleed where one session's limit would ghost-appear on another.

### Status Bar
- Rate limit summary now shows inline Claude/Codex agent icons before each agent name.


## 1.5.2 - 2026-04-07


### Sidebar
- Thread rows now use a rounded-border capsule selection style with accent-colored border and subtle fill instead of the full-width highlight.
- Completed threads show a green capsule border and fill; thread icons tint to accent (selected) or green (completed).
- Pinned and rate-limit status indicators are now bare-icon badges on the capsule's top border, with a circular background appearing on selected/completed rows.
- Busy-state duration badge is now a pill sitting on the capsule's top border with a persistent border.
- Right-clicking a thread no longer flashes an extra selection border.
- Hidden/archived thread dimming no longer makes badge backgrounds semi-transparent.
- Waiting-for-input threads now show an orange capsule border and fill, matching the green completion style.
- Keep-alive indicator moved from trailing stack to a top-border badge.
- Duration badge moved to bottom-right of capsule.
- Rate limit badge now shows for all threads (including main), not just non-main.
- Removed vestigial trailing stack items (PR label, Jira icon, completion dot, rate-limit icon, keep-alive icon).
- Thread row heights are now dynamic based on actual content (description lines, subtitle, PR/ticket row) with a minimum height matching 2 description lines + 2 metadata labels.
- Capsule content padding is now consistent: 12pt horizontal and vertical from capsule inner edge.
- Outline view indentation set to zero so thread cells fill the full row width, eliminating coordinate mismatch between capsule and content.
- Section header rows no longer receive thread-style capsule borders.
- Project repo name now uses larger system bold font (20pt) instead of Noteworthy-Bold.
- Removed separator divider between project groups; inter-project gap increased.
- Reduced spacing between repo name header and main worktree row.
- "Add repository" button is now a regular scrollable row at the top of the sidebar instead of a sticky toolbar overlay.


## 1.5.1 - 2026-04-04


### Agents
- "Continue in" and the forward button now show an optional "Extra context" field, letting users provide priority instructions that the receiving agent sees alongside the transferred session context.
- The reasoning/thinking level selection is now remembered per model instead of per agent type, so switching between e.g. Opus and Sonnet restores each model's last-used reasoning level independently.
- Archived worktree names can now be safely reused without reviving old Claude/Codex conversations from the last thread that used that path.
- The thread Review menu now puts the project default agent first and labels it `Default`, removing the separate `Use Project Default` entry.
- The new-tab and new-thread context menus now list agent types directly (default first, marked "(Default)") with last-used model and reasoning shown inline, instead of a separate "Use Project Default" entry.
- Codex threads now mark work as finished more reliably when Codex returns to an idle prompt without emitting a bell, so completion dots and notifications are less likely to be missed.
- Draft tabs now preserve the model and reasoning selections chosen in the initial prompt sheet, and `Start Agent` later launches with those same settings instead of resetting to Auto.
- The launch sheet's `Draft` checkbox now stays in sync as you edit or reload the sheet, and the choice is remembered with the saved prompt instead of resetting on reopen.

### Banner
- Fixed embedded terminal banners (including recovered unsubmitted prompt banners) ignoring clicks due to a coordinate-space bug in the banner overlay hit-test that shifted the point out of the banner's frame in non-flipped containers.
- Banner swipe-to-dismiss now ignores taps that start on banner controls, so action buttons remain clickable even on dismissible banners.
- Banner buttons now accept the first click and hit-test correctly inside the overlay, so banner actions respond immediately when the app is inactive.
- Top-of-window banners now remain clickable under the transparent title bar instead of occasionally starting a window drag when you click a banner action or dismiss button.
- Global top banners now stay tappable even inside the transparent titlebar region because the shared banner overlay is hosted above the window content view instead of under the titlebar event layer.

### General
- External web actions can now open in either the default browser or a Magent web tab by default, configurable in `Settings > General > Links`. PR/Jira buttons and matching thread menu actions follow that preference, while middle-click still opens the opposite destination as a quick override.
- Terminal links now respect the same in-app web flow for HTTP(S) targets: `Cmd`-click follows your default link destination, and `Cmd`+middle-click explicitly opens the link in a Magent web tab.

### Settings
- Startup now treats `settings.json` as incomplete when it no longer covers every project referenced by active threads, recovers from the best available backup or snapshot candidate, and blocks writes that would replace thread-linked settings with an empty/default project list.
- Settings panes now reload the latest `settings.json` before saving UI changes, preventing stale Settings windows from overwriting the registered projects list after a restore or startup recovery.
- Startup now merges duplicate thread records that resolve to the same worktree after project-ID recovery, so restored projects no longer show duplicated main/worktree rows and all tabs stay attached to a single thread.

### Sessions
- Agent completion tracking no longer relies on tmux `pipe-pane` watchers by default. Claude uses the injected Stop hook and Codex completion is inferred from busy→idle transitions, reducing tmux zombie buildup from long-lived watcher children.

### Status Bar
- The session count popover now shows detected tmux defunct-process counts and offers a manual `Restart tmux + Recover` action alongside idle-session cleanup.

### Diff Viewer
- The bottom-left `ALL CHANGES` view now loads branch-wide file lists lazily, and very large diffs show a simple `Diff is too large` placeholder instead of hanging the app.
- The bottom-left git panel now appends compact remote-tracking status to the current branch name, showing short suffixes like `(+1 -3 from remote)` or `(local)` when the branch has no upstream.
- Discarding a file in the CHANGES panel now refreshes the panel immediately, and queues a follow-up refresh if another git refresh is already in progress so the file state does not stay stale.

### Thread
- Rate limit icons now distinguish between direct limits (red hourglass) and propagated limits from other sessions (orange hourglass), making it clearer when the block is in this thread's session vs inherited from another agent/session.
- New threads now appear at the top of their section instead of the bottom, making the latest work immediately visible without scrolling.
- The main worktree context menu no longer shows the "Fork Thread" option.
- Fixed draft and web threads showing an indefinite busy spinner after creation since thread setup cleanup is now properly handled in non-terminal threads.
- Fixed draft threads sometimes restoring as terminal/Codex tabs from stale tmux sessions. Draft-only threads now stay non-terminal until you explicitly start the agent.
- The thread context menu now groups "Rename with Prompt", "Set Description", and "Rename Branch" under a single "Rename" submenu for better organization.
- The new-thread sheet now inlines the section picker next to the project picker when both are present, saving vertical space and improving the dialog layout.
- Added four new sign emojis: Book, Bolt, Magnifying Glass, and Lock. All sign labels now describe the emoji itself rather than intended usage.

### Tab
- The tab context menu now opens a single `Continue in...` sheet instead of a nested agent submenu, and the continuation sheet now focuses the receiving agent model, title, and model/reasoning fields without showing a prompt box.
- Tabs created via `Continue in...` now show the same forward icon as the header handoff button, making forwarded sessions easier to spot in the tab bar.
- Agent-backed tabs now expose `Resume Agent Session in New Tab` in the tab context menu, opening a fresh tab that resumes the same Claude/Codex conversation when a saved resume ID is available.


## 1.5.0 - 2026-04-02


### General
- Updated app icon.

### Banner
- Fixed long banner messages overlapping the top-right dismiss button, so the archived-thread banner and other shared banners close reliably.
- Fixed shared banner buttons sometimes ignoring clicks, including the recovered unsubmitted prompt banners and other top-of-window action banners.

### Thread
- Grouped `Set description`, `Icon`, and `Sign` under a new `Appearance` submenu in the thread right-click menu.
- Reordered the non-main thread context menu so `Fork Thread` sits directly under `Pin`, and `Move to` appears before `Hide` while `Keep Alive` and `Kill All Sessions` stay grouped below.
- Added a separator above `Hide` in the non-main thread right-click menu to make the menu grouping clearer.
- Added a discard action to the CHANGES panel file context menu for non-committed rows, with a warning confirmation before tracked changes are reset or untracked files are removed.

### CLI
- `current-thread` now returns the resolved base branch in the response.
- New `set-base-branch` command to override a thread's base branch.
- New `keep-alive-thread`, `keep-alive-tab`, and `keep-alive-section` commands to enable/disable Keep Alive protection (`--remove` to disable).

### Local Sync
- Local Sync now uses clearer pull/push/reconcile wording in the top-bar menu, shows `Repo root` instead of `Project`, and hides the button entirely when a project only has `Shared Link` entries.
- Project settings now use a row-based `Local Sync Paths` editor with per-path modes: `Copy` or `Shared Link`.
- `Shared Link` local sync entries now create direct symlinks to the main repo copy during thread creation and forked-thread setup, while archive/push-back remains limited to `Copy` entries.
- Local Sync menus now separate one-way sync from two-way agentic reconcile, and conflict dialogs rename `Agentic Merge` to `Resolve with Agent` so the chosen direction remains clear.
- Copy-mode Local Sync now flattens symlinked source files/directories when seeding or syncing, while destination-side symlink paths are still treated as conflicts instead of being traversed implicitly.

### Tab
- Simplified the tab context menu by moving `Keep Alive` directly above `Kill Session`, removing the extra separator before `Rename Tab...`, and keeping the menu text-only.
- Retained startup prompts now include a "Copy Prompt" action while the new thread/tab waits for the agent to become ready. If a built-in agent drops back to a shell during launch (for example after a self-update), Magent retries one relaunch automatically and then offers a "Relaunch Agent" recovery action on that tab.
- New "Switch to new tab" checkbox in the New Tab prompt sheet — works like the existing "Switch to new thread" option, remembers the last selection, and defaults to on.
- Option+middle-click on a tab now closes it immediately without a confirmation alert.
- Recovered unsubmitted thread/tab prompt banners now show a short prompt preview, with a "Copy Prompt" action and expandable "Show More" details before you reopen or discard them.
- New agent tabs now keep flagship model names out of the default title, and combine any visible model label plus reasoning into a single suffix like `Mini, M` instead of separate parentheses.

### Agents
- Review tabs now use the plain name `Review` when only one agent is enabled, and `Review (Claude)` / `Review (Codex)` when multiple agents are available, so the launch target stays clear without the older hyphenated suffix.
- Review tabs now always launch built-in agents on their flagship model with elevated reasoning (`Opus`/`GPT 5.4` with `High` by default), and holding Option switches the Review menu to max-reasoning launches with a discoverability hint in the menu header.
- New thread/tab prompt sheets are slightly wider so the Type, Model, and Reasoning pickers fit more comfortably on one row.
- Type, Model, and Reasoning pickers now share a single compact row in the launch sheet, and model/reasoning default labels read "Auto" instead of "Default" to avoid ambiguity with the agent-type default set in Settings.
- Rate-limit markers now propagate across every tab using the same agent, so a Claude or Codex limit is shown consistently across the app instead of only on the session that surfaced it.
- Fixed Claude interactive rate-limit prompts sometimes being missed when only the wait/switch options were visible, so blocked Claude tabs show the rate-limit marker more reliably.
- Fixed stale rate-limit prompts (visible after the limit has lifted) keeping all Claude tabs marked as rate-limited indefinitely.

### Pull Requests
- Fixed GitLab MR sync falsely failing on `glab` setups that reject `glab mr list --state ...`; Magent now uses the default open-MR listing and only falls back to `--all`.

### Settings
- Startup now restores `settings.json` and `threads.json` from the newest rolling backup or snapshot when the primary file is missing or corrupt, instead of falling back to onboarding with an empty app state.
- `Settings > General` now includes a `Data Backup` card with `Back Up Now` and `Restore from Backup…` actions. Magent keeps rolling backups of `threads.json`, `settings.json`, and prompt drafts on every save, takes 30-minute snapshots while the app is running, and lets you restore from those snapshots with an automatic safety backup before relaunch.
- The `Data Backup` card now shows when the most recent backup snapshot was created.
- Backup restore now leaves any current file in place when the selected snapshot does not contain that file, instead of deleting it as part of the restore.
- Moved `Inject Magent IPC instructions into agent prompts` and `Track agent rate limits` out of `Agent Permissions` into a dedicated `Agent Behavior` section in Settings > Agents.

### Local Sync
- Agentic Merge now falls back to the first enabled non-rate-limited agent when the project's default agent is currently rate-limited.

### Thread
- Fixed deleted threads reappearing in the sidebar after app relaunch when the worktree directory wasn't fully cleaned up.
- Failed thread creation now offers a persistent retry banner that reopens the sheet in the original mode and context (including fork/draft/web/terminal state) without overwriting saved new-thread drafts.

### Status Bar
- When the bottom-right sync status fails, hover text and the sync right-click menu now show the last error reason instead of only `Sync failed`.

## 1.4.0 - 2026-03-31


### Menu
- New "Changelog…" menu item (mAgent > Changelog…) shows the bundled changelog.
- About panel now displays build number (git commit count) and commit hash.

### Thread
- Fixed draft threads incorrectly spawning an agent tab alongside the draft tab — new draft threads now start with only the draft tab.
- Prompt injection failure banner now includes a "Copy Prompt" button so users can paste the prompt manually when automatic injection fails.
- "New Thread from This Branch" renamed to "Fork Thread" — the prompt sheet now shows "Fork Thread" as the title with source thread info displayed below, and the project picker is locked to the source thread's project.
- Forking a thread now copies local sync paths from the source thread, merged with current project paths (new paths added, removed paths filtered out).
- Draft-originated threads now auto-rename and generate a "DRAFT: " prefixed description; the prefix is derived from live draft-tab state so it disappears once the draft is consumed.
- "Rename with prompt" context menu now includes draft tab prompts (prefixed with "DRAFT:") as rename options.
- Fixed false-positive "Base branch X no longer exists" banner when the base branch and project default are the same (e.g. `develop`), and fixed stale reset banners persisting across refreshes even after the missing branch became available again.
- Fixed Manual Local Sync popup having overlapping UI elements by using proper Auto Layout constraints and pre-computing the accessory view size.
- Manual Local Sync popup now labels the worktree picker as "Worktree:" instead of "Target Worktree:" since it serves as both source and target depending on direction.
- Local Sync context menu hides the "Other…" option when only one other worktree exists, since the direct menu items already cover it.
- Local Sync merge tool now uses the user's configured `git mergetool` instead of hardcoded opendiff — supports vimdiff, meld, custom commands, and any tool git recognizes.
- New "Agentic Merge" option in Local Sync conflict dialogs delegates the entire sync to an agent tab for intelligent conflict resolution.
- Removed "Show Diff" panel from conflict dialogs — conflicts are now handled by the merge tool or agent instead.

### CLI
- IPC helper scripts (`magent-cli`, bell watcher, URL capture) are now automatically reinstalled if macOS purges `/tmp` while Magent is running.
- `magent-cli docs` now includes a "Common user intents" section teaching agents how to handle "review thread" (create a review tab with rate-limit fallback) and "archive thread" (commit + archive via CLI).
- `create-thread` and `send-prompt` now support `--prompt-file <path>` for multi-line prompts, avoiding shell escaping issues.
- Fixed `--prompt` failing with "Invalid JSON" when the prompt text contains newlines, carriage returns, or other control characters.
- `create-tab` and `batch-create` now reject disabled agents with an explicit error, matching `create-thread` behavior.

### Agents
- IPC system prompt now mentions "threads" so agents better associate the term with Magent management commands.

### Sidebar
- Fixed busy-state duration label showing stale elapsed time (e.g. "35m" instead of "<1m") after busy/idle transitions — debounce commits now always propagate to the sidebar.
- Dead-session threads now show a gray icon and dimmed description text, making them visually distinct from hidden threads (which dim the entire row).

### Sessions
- Sections can now be marked as Keep Alive — right-click a section header to toggle. All threads in a shielded section are protected from idle eviction and manual cleanup, and a cyan shield icon appears on the section header.
- New "Kill Session" option in the tab right-click menu lets you manually kill a single tmux session without closing the tab.
- New "Kill All Sessions" option in the thread right-click menu kills all live tmux sessions in a thread at once.
- Idle eviction now protects sessions during Magent setup/injection and while rate-limited, preventing premature kills of sessions that are still initializing or waiting on API limits.
- New tmux sessions are now stamped with a visit timestamp at creation time, preventing idle eviction from treating freshly created sessions as ancient when the user switches away.
- Enabling Keep Alive on a thread or tab now instantly recovers any dead or evicted sessions, instead of waiting for the next monitor tick or manual tab selection.
- Sessions with unsubmitted typed input at the agent prompt are now protected from idle eviction, manual cleanup, and archive suggestion — typed-but-unsent text is no longer silently lost.
- Keep Alive now has two independent levels: thread-level (protects all tabs) and tab-level (protects individual sessions). A light-blue half-shield icon appears in the sidebar for thread-level keep alive.
- When all tabs in a thread are individually marked Keep Alive, a one-time banner offers to promote to thread-level keep alive.
- Thread-level keep alive hides per-tab shield icons and per-tab keep alive menu items (redundant).
- Sidebar keep alive shield is hidden on pinned threads when "Protect pinned from eviction" is enabled (protection still active, just no visual clutter).
- New "Protect pinned threads and tabs from eviction" setting (Settings > Threads, enabled by default) — pinned threads and pinned tabs are automatically protected from cleanup.
- Manual session cleanup now protects sessions that were busy within the last 5 minutes, preventing accidental closure of recently active agents.
- Closing idle sessions from the status bar now shows a confirmation alert listing which threads/tabs will be killed, with a scrollable breakdown.
- Idle session auto-eviction now enabled by default (limit: 30 sessions), with a more conservative 10-minute non-busy threshold (previously 1 minute).
- Session count indicator moved to leftmost position in the status bar for better visibility, with a brighter label color in dark mode.
- Status bar now shows active session count (live/total when some are suspended). Click to see breakdown and one-click "Close all idle sessions" to free memory/CPU — tab metadata is preserved and sessions are lazily recreated when you revisit them.
- Dead sessions are no longer eagerly recreated — only the currently visible session auto-recovers. Background dead sessions stay suspended (dimmed in sidebar and tab bar) until selected, reducing unnecessary resource usage.
- Fixed force-closing sessions from the status bar not graying out sidebar threads and tabs.
- Fixed auto idle eviction not updating sidebar/tab appearance when sessions are killed.

### Performance
- Session monitor polling is now split into fast (5s) and slow (~1 min) cadences — agent completions, busy state, and dead session recovery stay responsive while heavier checks (worktree scans, zombie detection, idle eviction) run less frequently.

### Terminal
- Fixed Prompt TOC showing 0 entries after session restore/recreation — the pane content wasn't fully rendered when the TOC captured it; a delayed retry now picks up the scrollback once tmux settles.
- Fixed unwanted slow scroll animation when switching to an agent tab — the CAMetalLayer-backed terminal surface could trigger implicit Core Animation transitions on visibility toggle, causing content to visually slide down from the top.

### Agents
- New Model and Reasoning pickers in the launch sheet let you choose which model tier (e.g. Opus/Sonnet/Haiku for Claude, GPT 5.4/Mini for Codex) and reasoning level to use per session. Selections are remembered per agent and applied to fast-path creation (Option+click, context menu, keyboard shortcut). Available models auto-update from a remote manifest without requiring an app update.
- Fixed agent completion notifications sometimes not appearing — bell events could be lost during the read-then-truncate of the event log, and accumulated events were wiped on app relaunch before they could be consumed.
- Codex sessions inside tmux now keep their full color palette more reliably instead of appearing bland when Magent inherits color-disabling shell environment from the parent terminal.
- Fixed agent session resume when a tmux session is killed — previously always launched a fresh agent instead of resuming the existing conversation via `--resume`.
- Restoring an archived thread now resumes the agent conversation instead of starting fresh — previously, conversation history was lost because Claude Code doesn't always write a `sessions-index.json` file.
### Tabs
- Switching threads now restores the last-selected tab, including web and draft tabs — previously only terminal tabs were remembered.

### Settings
- Section names are now case-insensitive throughout the app — "TODO" and "todo" are treated as the same section in all lookups, creation, and rename flows.
- "Remember type selection" now remembers the last agent type globally across all projects, not per-project.
- Software update now shows explicit download progress before closing the app. After download completes, an "Install and Relaunch" button lets you choose when to restart.
- Magent now checks for new versions every hour in the background (respects the existing auto-check setting and responds immediately to setting toggles).

### Banner
- Fixed banner buttons and dismiss (X) being unresponsive — clicks were silently ignored due to a coordinate-space mismatch between the flipped split view and the unflipped banner overlay.
- Fixed the archived-thread banner's `X` button, and the shared banner overlay fix applies to other banner buttons too.
- "Unsubmitted prompt recovered" banners for tab prompts now appear only on the affected thread instead of as a global overlay. Dismiss hides the banner until the thread is re-selected; only "Discard" deletes the recovered prompt.

### Status Bar
- New persistent status bar at the bottom of the window shows aggregate thread counts (busy, waiting, done, rate-limited) with colored SF Symbol indicators, global rate-limit countdowns, and sync status.
- Rate-limit and sync status moved from the sidebar header to the status bar — right-click to lift rate limits or force-refresh sync.
- Sync tooltip explains what is being synced (PR status, and Jira info when enabled).
- Thread counts are clickable — show a compact popover listing up to 3 matching threads; clicking one jumps straight to that thread.

### Local Sync
- Local file sync now targets the base branch's worktree instead of always syncing with the main repo. When the base branch belongs to an active thread, sync goes to/from that worktree; otherwise falls back to the project root.
- Fixed sync target resolution falling back to the project root when the base branch was stored with an `origin/` prefix (e.g. from auto-detection) — the prefix is now stripped so it correctly matches the sibling worktree's local branch.
- Sync menu items now show explicit worktree names (e.g. "feature-login → primeape") instead of generic "Project → Worktree" labels.
- Hold Option when clicking sync to force syncing with the main repo regardless of base branch.
- Local Sync now includes an `Other…` picker for manually choosing both sync direction and any other worktree in the repo, including the main worktree.
- The main worktree now exposes the Local Sync button too, opening the manual picker directly instead of a quick-action menu.
- The Local Sync button now stays hidden until the project has configured Local Sync Paths and at least one other active worktree to sync against.
- Text file conflicts during interactive sync (resync and archive) now offer a "Resolve in Merge Tool" button that opens FileMerge (opendiff) for side-by-side resolution. If the tool resolves the conflict the alert is dismissed; otherwise it re-appears with the existing Override/Ignore options.

### Thread
- Archiving a thread no longer blocks the UI — the thread disappears from the sidebar immediately while local sync, persistence, and cleanup run in the background.
### Sidebar
- New threads created from a pinned thread now land at the top of the visible group (right below pinned threads) instead of at the bottom of the section.
- Unpinning a thread now places it at the top of the visible group instead of at the bottom.
- Fixed new threads created from another thread (Cmd+N, Cmd+Shift+N, context menu, CLI) landing one position too low instead of directly below the source thread.
- New threads created via CLI or Cmd+N now automatically inherit the current thread's branch, section, and sidebar position — no manual flags needed. CLI supports `--from-thread` for explicit control (`main`, `none`, or any thread name).
- Cmd+N now places the new thread directly below the selected thread in the same section, instead of at the bottom of the default section.
- Creating a new repository from Magent now works end-to-end — the initial commit is created automatically so threads can branch off immediately.
- New "Add repo" button (folder.badge.plus) in the top-right corner of the sidebar lets you create a new repository or import an existing one without opening Settings.
- The sidebar now reserves a dedicated top row for the "Add repo" button so repository rows and status content never overlap it.
- The changes panel in the bottom left is now always visible, even for threads with no commits or changes — shows "No commits" / "No changes in this branch" empty states instead of hiding entirely.
- Fixed target branch in the changes panel not reflecting the base branch when creating a thread off another thread.
- Fixed UI freezing when archiving a thread — persistence I/O now runs off the main actor so the archiving overlay stays responsive.
- Fixed app silently terminating after archiving or deleting a thread — cached ghostty terminal surfaces kept live PTY connections that triggered libghostty's `_exit()` when the tmux sessions were killed.
- Thread row contents now visually dim while archiving is in progress.
- "Rename Using Prompt" in the thread context menu is now a "Rename with prompt" submenu showing the 3 most recent agent prompts for quick one-click rename, plus a "Custom…" option for free-form input.
- Right-clicking a completed thread now offers "Mark as Read" at the top of the context menu, clearing the completion badge without switching to it.
- Thread rows now show how long the thread has been busy or idle (e.g. "<1m", "5m", "2h") in a subtle label at the bottom-right corner. Can be toggled off in Settings > Threads.
- Cmd+Shift+N creates a new thread branching from the selected thread's branch, inheriting its section and inserting right below it in the sidebar.
- Base branch is no longer auto-detected from git history — it stays as set during thread creation (or project default) and only changes via explicit user action (context menu, CLI, or "Use PR target"). If the stored base branch no longer exists, it falls back to the project default and shows a warning banner.
- Branch mismatch banner now appears for non-main threads too — if the worktree is on a different branch than expected, the user can accept or switch back.

### Auto-Rename
- Thread/worktree names are now permanent — rename commands (auto-rename, CLI, context menu) only change the git branch name, never the thread name or worktree directory. The original auto-generated name stays visible in the sidebar forever.
- Auto-rename now triggers on every first prompt, including questions — previously, prompts classified as questions were silently skipped.

### Thread
- Fixed target branch in bottom-left not matching the base branch typed during thread creation — the project default was incorrectly overriding the user's explicit choice.
- Renaming a thread branch now retargets sibling threads that use it as their base branch, including explicit base-branch overrides, so stacked threads keep diffing and archiving against the renamed parent branch.
- Fixed tab sessions restarting when switching between threads — terminal surfaces are now preserved in the reuse cache instead of being destroyed and recreated.
- Fixed prompt Table of Contents overlay not appearing on threads that have pinned web tabs.
- New "Draft" checkbox on the initial prompt window lets you save a prompt as a draft tab instead of running it immediately. Draft tabs persist across relaunches, show an editable agent picker and prompt, and can be discarded or started when ready.
- Sync status in the sidebar now shows "Sync failed" in red when PR or Jira sync encounters network or auth errors, instead of silently showing the last successful sync time.
- Local Sync now shows a persistent spinner banner while syncing files, replacing the toolbar-only spinner that was easy to miss.
- Local Sync conflict diffs are now readable in dark mode — added/removed lines use colored text instead of relying solely on background tinting.
- Option-clicking the Local Sync button now syncs files to/from the base branch's worktree instead of the project root, useful for stacked worktree workflows.
- Local Sync conflict alerts now offer a "Show Diff" button for text files, letting you inspect exactly what changed before choosing to override or ignore.
- Fixed UI freezing during Local Sync Path resync by moving filesystem copy and hash work off the main thread.
- PR/MR actions now stay hidden until Magent has a definitive CLI lookup result, so threads without detected PRs no longer show dead "Show PR" actions.
- When a thread branch has no PR/MR yet, Magent now offers Create PR/MR actions that prefill source branch, target branch, and the thread description as the initial title when the hosting provider supports it.

### Web Tabs
- Web tabs now remember the current page URL across app restarts, reopening where you left off instead of the original URL.
- Renamed web tabs now stick — the custom name overrides the default URL-based title until you clear it. Renaming to an empty string restores automatic hostname-based naming.
- Web tabs now identify as Safari so sites like Confluence no longer show "unsupported browser" errors.
- Middle-click and Cmd-click on links now open them in a new web tab instead of navigating the current tab.
- Links with `target="_blank"` now open in a new web tab instead of being silently dropped.
- Toolbar buttons are now consistently sized with improved spacing, and Refresh is moved to the right of the address bar.

### CLI
- Interactive thread picker now shows statuses (busy, input, done, dirty, etc.) on a dedicated line instead of inline with branch info. PR and Jira ticket details appear on their own line when present.
- Tab picker now shows per-tab status badges (busy, input, done, limited) on a separate line.
- Fixed `magent-cli` not being installed to `/tmp` on launch — atomic file write silently failed across filesystem boundaries.


## 1.3.2 - 2026-03-22


### Agents
- When a thread starts with a pre-injected prompt, a "Prompt will be injected once the agent is ready" info banner now appears immediately with an "Inject Now" button to bypass polling. The banner disappears automatically once injection succeeds, or is replaced by the failure banner if injection times out.
- Fixed another startup prompt-injection timeout on tall panes by widening the tmux readiness capture window before trimming blank filler lines, so newly started agents are less likely to miss a visible input prompt.

### Settings
- Added a read-only Keyboard Shortcuts reference card to General settings showing all app keybinds.
- Keyboard shortcuts (New Thread, New Tab, Close Tab, Refresh/Hard Refresh Web Tab) are now configurable via settings and update at runtime without restart.
- Jira ticket detection in Settings can now be limited to specific project prefixes, using a comma- or semicolon-separated filter like `IP, APPL, UT`.

### Pull Requests
- Fixed PR/MR detection failing silently on newer `gh` CLI versions that removed the `--sort` flag.

### Sidebar
- Added colored priority arrows (↑ High Priority in red, ↓ Low Priority in green) to the thread sign menu alongside existing emoji signs. Arrow signs use a larger font than emoji signs for better visibility.
- Thread rows now show a busy spinner from the moment a thread is created until the agent is ready (or prompt injection finishes), so new threads no longer appear idle during setup.
- File rows in the changes panel now show filename first (in status color) followed by the directory path (gray, smaller) for better scannability.
- Right-clicking a file row now offers Copy Filename, Show in Finder, and Stage/Unstage (for uncommitted files and directories).
- Right-clicking a commit row now offers Copy Hash and Copy Message.
- Changed files are now sorted by status group (untracked → unstaged → staged → committed), then alphabetically within each group.
- Target branch picker no longer shows unrelated historical branches — only branches between the default branch and HEAD are listed.
- Target branch picker now includes an "Other…" option that opens a dialog with a searchable combo box of all local and remote branches, so you can target any branch even if it's not in the ancestor list.
- The changes panel now has a refresh button in its top-right corner so you can manually reload git status, branch/base info, commits, and file changes for the selected thread without waiting for background polling.
- Branch info at the bottom of the changes panel now displays on two lines — current branch on top, base/target branch below with a `⤷` arrow — and strips `origin/` prefixes for cleaner display.

### Thread
- New "Web" type in the New Thread and New Tab sheets opens a web tab instead of a terminal/agent session. Threads created with Web type still get a worktree and branch but no tmux session. URL field is optional — blank creates an empty web tab with an address bar to type into later.
- Web tabs now show a globe icon and auto-update their tab title from the page hostname as you navigate.
- Right-click the "+" button on the tab bar or sidebar to quickly add a Web tab (tab bar creates instantly, sidebar opens the sheet for branch/description fields).
- Closing a web tab now asks for confirmation, matching the terminal tab close behavior.
- Fixed: renaming a tab via right-click no longer starts a fresh agent when switching back to it. Session-keyed caches are now properly rekeyed so the renamed tab takes the fast path instead of triggering session re-validation.
- Web tabs now show an editable URL address bar instead of a read-only title label. The field reflects the current page URL, supports typing a new URL and pressing Return to navigate, and auto-prepends `https://` (or `http://` for localhost/loopback addresses) when no scheme is given.
- Description, branch, and base branch fields in the new-thread sheet are now editable for terminal-type threads (previously greyed out).
- Added "Continue in" forward button next to the review button in the terminal header, letting you hand off the current tab's context to another agent without opening the tab's context menu.
- Tightened thread header button spacing so the top bar actions sit closer together.
- Fixed: switching back to a detached tab after tmux recovery no longer drops you into a fresh blank agent session. Lazy-selected tabs now revalidate and rebuild their terminal view before first attach so saved resume state is preserved.
- Fixed "Creating tab..." spinner getting stuck after a new tab finishes creation, blocking keyboard input to the terminal.
- Fixed unnecessary `Starting agent...` flashes when switching to an already-live tab whose tmux session did not need recovery.
- Fixed: switching threads no longer lets a Codex tab come back as a fresh Claude tab or get cleaned up immediately. Session restore now preserves each tab's stored agent type and gives orphan cleanup a grace period instead of running zero-grace on every thread switch.
- Fixed: pinned tabs could cause the wrong terminal surface to display or the wrong tab to be selected when navigating to a specific session.
- Fixed: closing a session tab could crash the app when the Ghostty surface outlived the terminal process during async tmux cleanup.

### Performance
- Switching between threads now reuses cached terminal views and skips redundant recent session validation, so already-live tabs appear faster.

### Agents
- New threads with a preinjected prompt now show an info banner ("Prompt will be injected once the agent is ready.") with an "Inject Now" button to bypass polling and send the prompt immediately.
- Initial prompt recovery now waits for the actual prompt paste to finish before clearing startup banners or crash-recovery state, so prefilled prompts no longer disappear silently after a prompt-less startup injection completes first.
- Fixed initial prompt injection failing for Codex threads — prompt detection now uses ANSI-aware capture to recognize the `›` marker with placeholder text, and avoids injecting when the user has already typed input.
- Fixed initial prompt silently lost on both Claude and Codex when session recreation races with prompt injection during thread creation.
- Fixed Codex initial prompt injection timing out on tall tmux panes where the visible `›` prompt sat above trailing blank space at the bottom of the pane.
- If the initial prompt does not reach the agent input within startup timeout, only the affected tab now shows a persistent recovery banner with actions to re-inject the prompt or confirm it was already entered manually.


## 1.3.1 - 2026-03-20


### Performance
- Archiving a thread no longer freezes the app while Local Sync Paths merge back into the main worktree. The non-interactive archive sync now runs off the UI path before background cleanup continues.

### Sidebar
- The "Archiving…" tint and spinner now cover the full selected thread row instead of only the row's content area.

### Settings
- In-app updates now clear macOS launch-blocking app attributes before relaunch, preventing some installs from requiring a manual `xattr -cr /Applications/Magent.app` fix after update.


## 1.3.0 - 2026-03-19


### Settings
- Critical persistence files (threads.json, settings.json) are now validated on launch. If a file is corrupted or was written by a newer app version, a recovery alert explains the problem and offers two choices: quit to fix manually (file is never overwritten), or continue with defaults (broken file is backed up with a `.corrupted` suffix first). Previously, corrupted files were silently replaced with defaults, making recovery impossible.

### Thread
- Code review button moved from the right-side utility group to next to the "+" (new tab) button for quicker access, and its icon changed from an eye to a magnifying glass over text.

### Agents
- CLI docs now explicitly instruct agents to always provide `--description` and `--prompt` when creating threads for specific tasks, so new threads get proper sidebar descriptions and the spawned agent receives its initial instructions.

### CLI
- New `batch-create` command creates multiple threads in parallel from a JSON specs file, with minimal UI blocking. Recommended with `--no-submit` for spawning many threads without concurrent agent CPU load.
- New `--no-submit` flag on `create-thread` and `batch-create` injects the prompt text into the agent input without pressing Enter, letting users review and submit manually.
- `--description` now sets the thread's task description immediately (previously the description text was consumed for slug generation but never persisted on the thread).
- `--section` now places the thread in the correct section during creation instead of moving it after, eliminating a visible "jump" in the sidebar.
- Archiving a thread via the CLI now shows the sidebar archiving overlay (spinner + "Archiving…") just like the UI-triggered archive.

### Sidebar
- Jira context menu now includes a "Copy Link" option below "Open in Jira" to copy the ticket URL to the clipboard.
- Tapping the archive suggestion button on a sidebar row no longer selects the thread first, avoiding a heavyweight detail-view load that was immediately discarded.
- Thread sign emoji submenu now toggles: selecting the already-active sign clears it, removing the need for a separate "Clear" option.
- The base branch label in the changes panel is now clickable — opens a menu of ancestor branches to quickly change the base branch for diff comparison. The menu stops at the project's default branch (no deep ancestors beyond it) and lists closest ancestors at the bottom to match the upward pop direction.
- When a PR/MR target branch differs from the app's base branch, a mismatch banner offers a one-click "Use PR target" action to align them.
- The changes panel now always shows the "branch ← base" info label when viewing a non-main thread, even when there are no uncommitted changes. Previously the label was hidden unless the working tree was dirty.

### Web Tabs
- CMD+R refreshes the current web tab page; CMD+SHIFT+R hard-refreshes (bypasses cache).

### Thread
- New thread sheet now includes a "Base branch" combo box that lets you type a branch name or pick from existing local branches (sorted most-recently-modified first, default branch listed first). The field uses the project's default branch as placeholder rather than prefilling it, with a hint label explaining the default. Validates the chosen (or implied default) branch exists before accepting — shows an inline error if not found.
- Fixed: base branch hint label not updating when switching projects via the project picker in the new-thread sheet.
- "Create from this branch" context menu action now opens the full new-thread sheet (pre-filled with base branch) instead of a submenu that skipped the sheet.
- Fixed: after pinning/unpinning or dragging tabs to reorder, the terminal surface could show the wrong tab's content despite the tab bar highlighting the correct tab.
- Fixed: clicking a tab sometimes failed to select it when the drag-to-reorder gesture intercepted the click.
- Fixed: previous tab's terminal content briefly visible behind the loading overlay when creating a new tab or switching to an unprepared tab.
- Fixed: the GUI launch sheet's description field was silently ignored — descriptions entered in the sheet now appear on the thread immediately.

### Jira
- New "Jira Integration" master toggle in Jira settings — controls all Jira features (ticket detection, status badges, toolbar button, context menu). Enabled by default, auto-disabled when acli is not installed or authenticated with an explanation.
- Thread right-click Jira option is now a submenu named after the ticket (e.g. "IP-1234: Fix login bug") with "Open in Jira" and "Set description to ticket title" as sub-options.
- Jira submenu now appears at the top of the thread context menu (above pin/hide) and includes a "Change Status" flyout with all project statuses shown with category-colored dots. Selecting a status transitions the ticket via acli, with banner feedback on success or failure.
- Jira status transitions now show a non-dismissible progress banner with a spinner while in-flight. Multiple concurrent transitions are tracked and displayed together; errors flash briefly before restoring the progress view.
- Jira submenu now includes a "Refresh" option that force-refreshes the ticket's status and title from Jira.
- Middle-click on the Jira toolbar button opens the ticket in an in-app web tab instead of the external browser. The tab shows a Jira icon and ticket number, supports back/forward/refresh navigation, and deduplicates (re-clicking focuses the existing tab).
- Fixed: the toolbar Jira ticket button now updates immediately when a branch change is detected, instead of staying stale until settings changed or the view was recreated.
- Jira ticket keys (e.g. IP-1234) are now automatically detected from branch names (case-insensitive) and shown in the toolbar, sidebar, and context menu with a link to open the ticket in Jira.
- Detected tickets are verified against Jira via acli and cached persistently so they survive app restarts and acli disconnection. Verification runs on startup, branch rename, branch change detection, acli auth success, and when selecting a thread (throttled to once per minute per ticket).
- The Jira settings tab (acli auth + site URL) is now always visible in Settings, not gated behind the debug feature flag. A "Detect Jira tickets from branch names" checkbox (enabled by default, grayed out when acli is disconnected) controls detection.
- The toolbar Jira button shows the ticket key next to the Jira icon (matching the PR button pattern). Tooltip shows the verified ticket summary when available.
- Ticket numbers appear on the same sidebar line as PR info, separated by a dot when both are present.
- Jira project statuses (used for the "Change Status" context menu) are now cached to disk, so the status list appears instantly on subsequent launches without re-fetching from Jira.
- "Change Status" menu now sorts statuses by workflow phase (To Do → In Progress → Done), then alphabetically within each phase, instead of displaying them in arbitrary discovery order.
- Fixed: context menu status dots used system colors (blue/yellow/green) instead of matching the Jira badge colors used elsewhere in the sidebar.
- Jira sync features (board config, section sync, auto-thread creation) remain debug-only behind the renamed `FEATURE_JIRA_SYNC` flag.

### Terminal
- Fixed: tab drag-to-reorder was completely non-functional — the pan gesture recognizer was never attached to tab views.
- Fixed: selecting a thread with pinned web tabs could leave no tab selected, because web tab restoration shifted tab indices after the initial selection index was computed.
- Scroll overlay arrows now scroll half a page per click instead of a full page, making it easier to browse terminal output incrementally.
- Mouse wheel now scrolls 6 lines per tick instead of 1, for faster scrolling without jumping a full page.
- Fixed: clicking on the terminal surface no longer shows a "returned 127" error after a reboot. The mouse-click URL capture script in `/tmp` had its shebang on the wrong line, causing the OS to fail to find the interpreter.
### Sidebar
- Selecting a thread now also refreshes Jira and PR statuses for the previously selected thread, so its sidebar row updates while you view another thread.
- Jira ticket status changes (summary, status, category) are now detected correctly when refreshing — previously only ticket key changes triggered a sidebar update.
- PR and Jira ticket status badges now appear as small colored pills inline with the ticket/PR labels in the sidebar. PR badges show review state (Approved, Changes Requested) in addition to lifecycle state (Open, Draft, Merged, Closed) with distinct colors for each. Jira badge colors are sourced from the Jira API status category. Both can be toggled independently in Settings > Threads > Sidebar.
- A "Synced Xm ago" label at the top of the sidebar shows when PR and Jira statuses were last refreshed. A refresh button triggers an immediate re-sync. The label now shows "Syncing…" on launch while the initial sync is in flight, instead of staying blank.
- PR and Jira statuses now refresh every 5 minutes in the background (previously ~30s for PR and ~100s for Jira). The longer interval reduces system load; selecting a thread still triggers an immediate refresh for that thread.
- Threads can now be marked with a sign emoji (🛑, ✅, ⏸️, ⚠️, 🔥) via the right-click context menu. The emoji appears to the left of the thread icon, persists across restarts, and can be cleared from the same menu.
- The diff panel's CHANGES tab is now ALL CHANGES and always shows the full branch diff (all committed + uncommitted changes since the merge base), instead of switching between uncommitted and per-commit views on selection.
- The "Uncommitted" row in the COMMITS tab is now hidden when the working tree is clean.

### Thread
- Middle-click on the PR toolbar button opens the pull request in an in-app web tab with hosting-provider icon and PR number.
- Web tabs (Jira, PR) persist across app restarts and load lazily when selected. They can be pinned, renamed, reordered via drag-and-drop, and freely mixed with terminal tabs.
- Thread descriptions set manually or from Jira are no longer truncated to 8 words. The word limit now only applies to auto-generated descriptions.
- Auto-rename now triggers for non-visible threads: when a thread completes its first agent turn in the background (not selected in the sidebar), the bell-based completion handler extracts the first prompt from pane content and triggers auto-rename immediately, instead of waiting until the thread is selected.
- PR and Jira buttons are now the leftmost action buttons in the toolbar, separated from utility buttons by a divider.
- The PR button is now hidden on non-main threads when no PR has been detected. Main worktree always shows it.
- PR info is now cached persistently so PR indicators appear immediately on app launch instead of waiting for the first background sync.
- The resync spinner has been replaced by an inline icon swap on the resync button itself, removing a separate view from the toolbar.
- The resync button (↺) now shows a menu to choose sync direction: "Project → Worktree" copies files from the main repo into the worktree; "Worktree → Project" pushes changes back to the main repo. A spinner replaces the button while sync is in progress.
- Fixed: the New Tab sheet subtitle now shows "Thread: Main" for the main project thread instead of "Thread:" with no label.
- The "New Thread" sheet now includes a Section picker, pre-selected to the project's default section. The picker shows each section's color dot, matching how sections appear in the sidebar. Different projects can have different section settings. The "All fields are optional" hint has moved below the form fields, just above the checkboxes.
- Fixed: initial prompt sometimes silently lost when opening a new tab — the text never appeared in the agent input. Root cause was a tmux paste-buffer race where concurrent buffer operations could collide on the global default buffer. Now uses named buffers. Also shows a warning banner with Retry if paste fails, instead of swallowing the error.
- Fixed: the "Rename branch" dialog now pre-fills with the current branch name instead of the worktree name.
- Fixed: multi-line prompts are now captured in full in the Prompt TOC and used in full for auto-rename. Previously only the first line was captured because continuation lines are ANSI-styled by Claude's TUI and blank paragraph separators broke the collection loop.
- Fixed: "Rename thread from this prompt" (TOC right-click, thread context menu, and CLI `rename-thread`) now works on context-setting prompts that auto-rename would classify as questions (e.g. "You're working on branch X"). Explicit rename actions always generate a name.

### Performance
- Thread creation sets tmux environment variables in parallel instead of sequentially, reducing per-thread setup time.
- Archiving a thread is now instant and non-blocking: clicking Archive immediately shows an "Archiving…" overlay on the thread row and returns to normal UI, with all cleanup running in the background. The thread disappears when done, or the overlay clears on failure.
- Multiple background state changes (busy, rate-limit, completions) within the same polling cycle are now coalesced into a single sidebar refresh instead of triggering one per change.
- Settings are now cached in memory — eliminates repeated disk reads and JSON decoding that previously happened dozens of times per polling cycle and during every cell render.
- Thread state persistence (dirty flags, completion markers, branch state) is now debounced so rapid changes within a polling tick produce one disk write instead of many.
- Multiple tmux sessions are now killed in parallel during archive instead of one at a time.
- Git status, branch, and delivery checks now run in parallel across all threads instead of sequentially, significantly reducing background polling time with many threads open.
- Agent completion no longer triggers a full git-status scan of every thread — only the threads that just completed are refreshed.
- Sidebar no longer rebuilds immediately on every settings-changed notification; rapid successive saves are coalesced into one reload.
- SF Symbol images in sidebar thread cells are now cached, reducing per-cell allocation overhead during redraws.
- Git remote availability checks are now deduplicated — rapid sidebar reloads no longer spawn redundant `git remote` subprocesses.

### Settings
- Thread Settings › Sidebar now has a "Move completed threads to top" checkbox, letting you disable auto-reorder on agent completion without leaving the Threads tab.

### Sidebar
- Deleting an empty section (0 threads) no longer shows a confirmation alert — it removes immediately. The confirmation dialog only appears when the section has threads that need to be moved.
- Fixed: the archive icon now appears in the same position as the busy/completion indicators (right-aligned status slot), instead of to the left of them.
- Fixed: the archive icon no longer appears when a thread's PR is merged remotely but commits are still present locally ahead of the base branch. The icon now only shows once the local base branch has been updated and the branch is truly fully delivered.
- Fixed: the thread icon is now properly vertically centered when a thread row shows only a single line (no subtitle or PR).
- Sections can now be reordered by drag and drop directly in the sidebar, just like in Settings.
- "Add Section…" from a section's context menu now inserts the new section immediately below the right-clicked one instead of at the end.
- Right-clicking the + button next to a project header now shows an agent picker menu to create a thread immediately, without the prompt sheet. Left-click still opens the full sheet.
- Right-clicking a section header now shows a context menu to add a new section, delete the section, or change its color. New sections get a random color from the palette. Color changes are reflected immediately via the system color picker.
- Fixed: the selected thread no longer loses its highlight every few seconds due to background metadata refreshes (git status, branch state, busy state).
- Thread rows now show PR/MR info on its own dedicated line below the branch/worktree line, making it easier to scan at a glance. When there's no task description, the branch name is the primary label and the worktree (if different) appears on the secondary line; when a description is set, branch and worktree move to the secondary line and PR stays on its own third line.
- PR/MR labels in thread rows are now shown in the app accent color, making them easier to spot at a glance.
- Fixed: the PR/MR line no longer appears indented relative to the branch/worktree line above it.
- The thread label pulses in the app accent color while auto-rename is in progress, making it visible when naming is happening.
- Fixed: sections no longer animate open/closed on every background sidebar reload. The root causes: (1) every agent completion was triggering a full structural reload even when thread ordering was not affected; (2) the restore loop was calling expandItem() with the default animation duration on brand-new SidebarSection objects after each reload. Completion-date is now only a structural signal when "reorder threads on completion" is enabled, and the restore loop suppresses animations so sections snap back instantly.
- Fixed: sections no longer expand or collapse unexpectedly during background sidebar updates (busy state, rate limits, agent completions, etc.). The root cause was that NSOutlineView was permitted to expand/collapse items on its own initiative — during reloadItem calls, nil-currentEvent callbacks, and other internal triggers — because shouldExpandItem/shouldCollapseItem returned true for all non-keyboard events. Both methods now gate every change through the programmatic restore loop exclusively.
- Fixed: collapsing a section no longer jumps focus to the Main thread. Previously, when the selected thread was inside a just-collapsed section, the sidebar lost the selection and the next background refresh picked the Main thread automatically.
- Fixed: clicking a section name to trigger a delayed collapse no longer fires if the user selects a thread before the double-click window expires.

### Thread
- New tabs now appear in the tab bar immediately when created, with a "Creating tab…" overlay while the session is being set up in the background.
- The "New Tab" sheet now includes an optional "Title" field to set a custom tab name at creation time. Leave it blank to get the default auto-generated name.
- Fixed: "Rename with AI" from the TOC and context menus no longer consistently fails with "rename failed". The slug-generation `claude -p` call now skips loading CLAUDE.md/AGENTS.md (`--setting-sources ""`) and disables tools (`--tools ""`), keeping the system prompt minimal. The per-agent timeout is also raised to 60 s (from 30 s) as an extra safety margin.
- Fixed: closing a tab via the IPC path (e.g. magent-cli close-tab) no longer crashes the app. The Ghostty surface was not being freed when the tmux session was killed remotely, causing a use-after-free on the next display tick.
- Fixed: stale "Unsubmitted prompt recovered" recovery banners no longer appear after a successful thread or tab creation. A race between the injection notification and the cleanup listener could leave the crash-recovery file in `/tmp` for up to 60 seconds, causing a false-positive banner on the next app launch.
- Fixed: when a thread is created via the project picker after switching to a different project, the original project's draft is now also cleared on submit, so reopening the sheet for the original project no longer shows the previously submitted text.
- Right-clicking the + button next to tabs now shows an agent picker menu (project default, individual agents, terminal) to create a tab immediately without the prompt sheet. Left-click still opens the full sheet.

- Undo (⌘Z) and redo (⌘⇧Z) now work reliably in the initial prompt text field.
- The Review button (eye icon) is now always visible on non-main threads, including those marked as fully delivered.
- Fixed: "Rename with AI" from the prompt TOC context menu now shows the sidebar pulse animation while the AI call is in flight, matching the visual feedback from auto-rename on first prompt.
- Fixed: "Rename with AI" from the prompt TOC and context menu no longer fails when the active agent is a custom agent with no built-in Claude/Codex configured; it now always falls back to Claude (a prerequisite for the app) as a last resort.
- Fixed: "Rename with AI" from the prompt TOC and context menu no longer fails when the preferred agent is rate-limited; it now falls back to the next available agent automatically.
- New "Switch to new thread" checkbox in the new-thread sheet (default: on): uncheck it to create a thread in the background without switching focus to it. The preference is remembered across sessions. The CLI gains a matching `--no-select` flag for `create-thread`.
- The "Remember type selection" and "Switch to new thread" checkboxes in the launch sheet are now placed at the bottom, just above the action buttons, keeping the top of the form focused on content fields.
- Fixed: "Switch to new thread" checkbox no longer appears in the Add Tab sheet, where it has no effect.
- Fixed: selecting Terminal in the agent picker was not remembered correctly on next open due to a separator item offset; the saved selection now restores reliably.
- Initial prompts are now protected against interactive shell blockers (e.g. an oh-my-zsh update prompt): if the agent doesn't become ready within the timeout and the pane shows a yes/no prompt, Magent aborts injection and shows a warning banner with a Retry button instead of sending the text into the wrong context.

### Onboarding
- Missing dependencies (git, tmux) now show an "Install..." button: clicking it triggers the Xcode Command Line Tools installer for git, or opens a Terminal window running `brew install tmux` for tmux. A "Re-check" button appears below the list to re-verify after installing.
- The "Add Project" step now includes a brief explanation of how git worktrees work and how Magent uses them — one isolated checkout per branch per thread.

### Appearance
- New "Don't override agent color theme" checkbox in Appearance settings: when enabled, Magent won't force a color theme on Claude or Codex at startup, letting agents use their own default theme.

### Changes Panel
- Double-tapping a commit row in the COMMITS panel enters a commit detail view: the tab bar is replaced by a "‹ Back" header with the commit title, and the file list shows only files changed in that commit. Clicking any file opens the diff viewer scoped to that commit. Double-tapping the "Uncommitted" row similarly drills into working-tree-only changes. Tapping Back or switching threads returns to the normal view.
- Fixed: the active tab and commit selection are now preserved across background refreshes (e.g. agent completion) and sidebar structural reloads; the panel no longer auto-jumps back to "Uncommitted" or the COMMITS tab. Background refresh calls no longer reset commit pagination, so a selected commit that was loaded beyond page 1 is no longer lost. A task generation counter ensures that a slow initial-load task (no-preserve) cannot overwrite the result of a faster background-refresh task (preserve).
- Fixed: the "from \<hash\> · \<message\>" subtitle no longer lingers on the COMMITS tab after a background refresh resets the selection.
- COMMITS is now the left-most (default) tab in the bottom panel; it always shows an "Uncommitted" row at the top so you can quickly switch between working-tree changes and any branch commit.
- Fixed: the "Uncommitted" row in the COMMITS tab now correctly shows only actual working-tree changes (vs HEAD) rather than all changes across the entire branch since the merge base.
- Selecting "Uncommitted" in the COMMITS tab shows the same working-tree file list as before; selecting a commit switches the CHANGES tab to the files changed in that commit, with a subtitle ("from \<hash\> · \<message\>") below the tab bar.
- The inline diff viewer now matches the selection: clicking a file while a commit is selected shows that commit's diff; switching back to "Uncommitted" restores the working-tree diff.

### Diff Viewer
- The CHANGES tab now tracks the diff viewer as you scroll: the selected file follows the sticky header automatically, keeping the sidebar in sync with what you're reading in the diff.
- Fixed image diffs spilling over adjacent file sections with oversized borders; images now use true aspect-fit scaling (up or down proportionally) instead of scale-down-only, and a duplicate conflicting height constraint was removed.
### Updates
- Update progress is now shown inside the app: tapping Update downloads and unpacks the new version in-app (with "Downloading…" / "Preparing update…" banners), so the app only closes at the very end to swap the binary and relaunch — eliminating the long invisible wait.

### Terminal
- Fixed severe app freeze and unresponsiveness caused by an infinite RELOAD_CONFIG feedback loop with libghostty v1.3.1: in that version, `ghostty_surface_update_config` fires a RELOAD_CONFIG action as a side effect; our handler was responding by rebuilding and re-applying config, which triggered another RELOAD_CONFIG → saturating the main thread. The handler now acknowledges the action without acting on it, and the override config file write is memoized to avoid triggering ghostty's file watcher unnecessarily.
- Fixed a crash and full UI freeze introduced with link hover detection: calling the Ghostty word-under-cursor C API from a background Task deadlocked against Ghostty's 60 fps render loop (both competed for the main actor). That code path is now removed entirely — Ghostty's native OSC 8 callback handles rendered-word detection, and a debounced tmux fallback covers everything else.
- Fixed significant UI lag introduced with link hover detection: the Ghostty C API call and URL checks were running synchronously on the main thread for every mouse-move event; both are now behind a 45 ms debounce and skipped entirely when Ghostty already owns the hover state via OSC 8.
- Links in the terminal are now clickable: Cmd+click opens URLs in the default browser. Hovering over a link shows an animated URL pill at the bottom of the terminal and changes the cursor to a pointing hand. Link detection combines ghostty-native OSC 8 hyperlinks and tmux pane content.

### Sidebar
- Fixed: sections no longer collapse after any sidebar status change (busy state, agent completion, etc.). AppKit fires collapse notifications for expanded projects during structural reloads; these notifications now no-op while a reload is in progress, and the collapse-state snapshot is captured before the reload begins.
- Fixed: keyboard navigation (arrow keys) across section headers no longer accidentally collapses or expands those sections.
- Fixed: pressing keys (arrow keys, letter keys) while the sidebar has focus no longer accidentally expands or collapses sections.
- Fixed: sections no longer flash expand/collapse while dragging a thread — background state updates no longer trigger a full sidebar reload mid-drag; the reload is deferred until the drag ends.
- Fixed: threads can no longer be dragged across projects when sections are enabled.

### Thread
- Auto-rename now starts immediately when the initial prompt sheet is accepted, rather than waiting for the prompt to appear in the agent's transcript. For threads with an initial prompt, the name is typically resolved before the agent has finished loading.
- AI rename results (slug, description, icon) are now cached per thread and prompt. Re-using a previously auto-renamed prompt (e.g. right-clicking a TOC entry to rename back) skips the agent call and reuses the cached result immediately.
- The new thread prompt sheet now shows a project picker when you have more than one project, so you can switch the target project before creating the thread.
- Creating a new thread or tab now opens a prompt sheet where you can write the initial message, choose an agent, and (for threads) set a description and branch name — all before creation starts. Option-click the + button to skip the sheet and create immediately with the project default.
- Fixed: selecting Terminal in the prompt sheet now works correctly — the Accept button was silently doing nothing because the separator menu item caused an off-by-one index mismatch between the popup and the internal picker list. The label now also correctly shows "Initial command" instead of "Initial prompt" when Terminal is selected.
- If the app crashes between accepting the prompt sheet and the agent receiving your message, the prompt is recovered on next launch with a banner offering to reopen the sheet or discard.
- ⌘N now appears in the Thread menu in the menu bar (previously it was only handled by a key monitor).
- Fixed: the branch name in the sidebar row now updates immediately after a manual branch rename, instead of waiting for the next background poll (~30 s).
- Removed the extra separator between "Close Tabs to the Left/Right" and "Close This Tab" in the tab context menu.
- Fixed: "Close Tabs to the Right" / "Close Tabs to the Left" context menu items were missing on initial load; `setupTabs` now calls `rebindTabActions()` so tab indices and counts are set before the first right-click.
- Fixed: closing a tab no longer crashes the app. The session monitor was posting a dead-session notification from a background thread; the UI handler then accessed terminal views and tab state off the main thread, causing a data race. Notification is now dispatched on the main actor, and tab-array access in the close path has additional bounds guards. Additionally, concurrent tab closes could race on the `threads` array after `tmux kill-session` suspended the main actor; `removeTabBySessionName` is now `@MainActor` so all mutations remain serialised on the main actor. A further use-after-free was fixed: `destroySurface()` now clears `focusedSurface` before calling `ghostty_surface_free`, preventing clipboard-request callbacks from passing a freed surface pointer to Ghostty after a tab is closed. Surface destruction is also now deferred to `viewDidMoveToWindow(window: nil)` (after the Metal layer is fully detached from the window) rather than `viewWillMove(toSuperview: nil)` (while the layer is still live), eliminating a GPU use-after-free race between the display link and `ghostty_surface_free`.
- Creating a thread no longer blocks the app with a modal spinner: the thread appears in the sidebar immediately and setup progress is shown as an overlay in the thread detail area instead.
- Fixed: Claude sessions were not showing as busy when the status bar included trailing context after "esc to interrupt" (e.g. `7% until auto-compact`); the busy-detection regex now matches regardless of trailing content.
- The project/thread context in the new-thread and new-tab prompt sheets is now shown as a prominent accent-tinted chip with an icon, making it immediately clear which project or thread you're creating into.
- The "Resync Local Sync Paths" top-bar button is now hidden when the parent project has no Local Sync Paths configured; it reappears automatically once paths are added in Settings.
- Archive suggestion now also appears when the thread's PR or MR has been merged — even before the local base branch is fetched — so the archivebox shows up as soon as GitHub or GitLab confirms the merge.
- Merged PRs and MRs are now detected and shown alongside open ones: the sidebar row, top-right button, tooltip, and context menu all display the PR/MR number with a "(✅ Merged)" suffix so you can see at a glance that the branch has landed.
- Tabs opened via the Review button are now named `<Agent>-review` (e.g. `Claude-review`) instead of plain `<Agent>`, making them easy to distinguish from regular agent tabs.
- Archive suggestion and commit counts in the Changes panel now use the actual remote base branch detected from git history (e.g. `origin/develop`) instead of a stored branch name, so they remain accurate when the worktree switches branches.
- Archive is only suggested after the worktree has actually done work (become dirty or accumulated commits); fresh untouched worktrees are never suggested for archiving regardless of how the branch state looks.

### Table of Contents
- Fixed TOC staying hidden after updating from a version where it had been manually dismissed; the stale "hidden" flag is now cleared on launch.


## 1.2.2 - 2026-03-13


### Table of Contents
- The TOC now rests as a compact floating capsule (185×36pt) showing "Table of Contents" and a badge count; hovering expands it to the full panel with an animation, then collapses back when the cursor leaves.
- Removed the toolbar toggle button and the in-panel × close button; the TOC is always-on and can be disabled in Settings.
- Badge count is vertically centered in the capsule, uses a 13pt bold number in a pill badge.
- Prompts list now fades in only after the panel has fully expanded, eliminating the clip-from-top artifact.
- Agent name removed from the TOC header.
- Fixed Prompt TOC prompt selection landing at the wrong scrollback position; prompt taps now use deterministic tmux copy-mode positioning that keeps the selected prompt at the top whenever enough lines exist below it.

### Terminal
- Fixed clicks on the bottom-right scroll-controls overlay (page-up/down/jump-to-bottom pill) starting an unwanted text selection in the terminal; the overlay now absorbs all mouse events so none leak through to the Ghostty surface below.
- `Continue in...` context handoff files now live in a transient worktrees-side cache with unique filenames and automatic cleanup, so transfers no longer dirty the repo and concurrent handoffs do not collide.
- Prompt TOC "Copy prompt" now copies the full submitted prompt instead of the 3-line TOC preview text.
- Fixed the terminal scrollbar reappearing during tmux history browsing; Magent now keeps tmux `pane-scrollbars` disabled so embedded Ghostty panes stay chrome-free.
- Fixed Ghostty terminals remaining dark in Light mode: the override config now writes explicit `background`/`foreground` colors for light appearance (white/black) since `window-theme = light` only affects window chrome and `ghostty_surface_set_color_scheme` is a no-op when ghostty's default conditional state is already `.light`. System mode also applies light colors when the OS is in light mode.
- Fixed the terminal wheel-behavior setting not taking effect for already-open embedded Ghostty tabs; switching between scroll-history, app-capture, and Ghostty-global modes now reapplies immediately.
- Embedded terminals now hide Ghostty's native scrollbar for a cleaner in-app terminal surface while Magent uses its own scroll affordances.
- Fixed Ghostty surface-level `reload_config` actions being ignored in embedded terminals, so current-terminal wheel-behavior changes now refresh the selected surface instead of only the app-wide setting path working.
- Fixed mouse-wheel scrolling not working after app restart: terminal history scrolling now works via tmux copy-mode (requires tmux mouse support enabled by Magent). The "Scroll terminal history" mode forces copy-mode on every scroll-up event; "Send wheel input to apps/prompts" restores tmux's default behavior.
- Unselected tab borders in dark mode are now slightly more visible.

### CLI
- The interactive thread picker now groups threads by section with styled section headers (matching the app's sidebar order), instead of a flat alphabetically-sorted list.
- Selecting a thread that has only one tab now attaches directly without showing the tab picker.
- Fixed `magent-cli create-thread` silently producing no output and not creating the thread: the IPC socket timeout was too short (5s) for operations that involve git worktree creation on large repos or AI-based name generation from `--description`. Timeouts are now 120s for `create-thread`, 60s for `create-tab` and `auto-rename-thread`, and 10s for all other commands.

### Agents
- Fixed Codex failing to launch when a user shell function for `codex` injects `--dangerously-bypass-approvals-and-sandbox`, which conflicts with the equivalent `--yolo` flag in newer Codex versions. Agent binaries are now invoked with the `command` built-in to bypass shell wrappers, and the Codex resume command is updated to use `--yolo`.

### Thread
- Auto-rename no longer triggers when terminal commands are typed in an agent session — it now checks that an agent process (Claude or Codex) is actually running before treating pane output as a submitted prompt.
- Fixed local-sync directory entries on thread creation so empty folders and directory trees containing only empty subfolders are copied into new worktrees again; the archive-only "copy dirs on demand" rule no longer suppresses sync-in.
- Non-main threads now include a top-bar `Resync Local Sync Paths` action that copies configured local-sync files/directories from the main repo back into the thread worktree, with conflict prompts and missing-path warnings.
- Local-sync conflict alerts now use simpler `Override` / `Ignore` / `Cancel` buttons, with Option-key variants for `Override All` and `Ignore All` shown directly in the alert.
- Thread creation now warns when configured Local Sync Paths are missing in the source repo, with the missing repo-relative paths listed in the banner details instead of silently skipping them.
### Terminal
- Fixed "Scroll to bottom" on both the scroll overlay and the FAB pill landing with the last output at the top of the viewport; Ghostty's viewport is now scrolled after tmux redraws the live pane, not before.
- Added a terminal mouse-wheel setting so Magent can default wheel input to terminal scrolling, inherit the user's Ghostty config, or let prompts/apps capture wheel input.
- App appearance can now follow macOS or be forced to Light/Dark, and open terminals now switch immediately along with terminal overlays and the terminal top bar.
- Fixed terminal overlays and other terminal chrome staying dark after switching to Light mode; open Ghostty surfaces now receive the new color scheme directly during appearance refresh.
- Fixed newly opened terminal panes always starting in dark mode when Light mode is active; the full current config and color scheme are now applied at surface creation time, matching what the settings-change path does for already-open panes.
- Terminals now react to macOS system appearance changes directly, without requiring a manual settings re-toggle; each surface responds to its own effective-appearance change event.
- Tab bar items now have a visible border and fully appearance-reactive colors for selected and deselected states; the close button uses the circular `xmark.circle.fill` icon.
- Fixed unselected tabs appearing dark in Light mode; dynamic catalog colors with alpha modifiers are now fully resolved inside `effectiveAppearance.performAsCurrentDrawingAppearance` so the correct light/dark variant is captured.
- Fixed Ghostty terminals remaining dark after switching the app to Light mode; `applyEmbeddedPreferences` now runs before window appearances are refreshed so any `viewDidChangeEffectiveAppearance` callbacks already see the updated color scheme.

### Sidebar
- Fixed the Changes panel blinking/disappearing briefly during periodic sidebar refreshes; the panel now stays bound to the selected thread state instead of transient `NSOutlineView` deselection noise.
- Fixed a periodic scroll-position glitch in the sidebar (visible every ~5 seconds): thread status updates (busy, rate-limit, dirty flag, etc.) now refresh cell views in-place instead of triggering a full outline-view reload that briefly disrupted scroll position.
- Fixed the main worktree row title being invisible in Light mode (white text on a light background); the text color now adapts to the selection state and the current appearance.

### Settings
- Fixed Restore buttons in the Recently Archived Threads section now lining up at the trailing edge of the list, regardless of thread name or description length.
- Added a dedicated `Appearance` settings category. Terminal keeps wheel behavior and terminal overlay visibility, while app light/dark mode moved out of Terminal.
- Fixed settings section cards remaining dark after switching to Light mode; dynamic asset colors are now resolved in the correct appearance context when the mode changes.

### General
- Banner notifications now keep high-contrast text and icons on their fixed tinted backgrounds instead of reusing semantic light/dark text colors.
- Fixed banner action buttons showing dark text on colored (blue/orange/red) backgrounds; buttons now always render with light text regardless of the system appearance setting.
- Banner message text is now centered between the icon and dismiss button for a balanced layout.
- Timed in-app banners now always show a dismiss button and support swipe-to-dismiss in any direction, while long-running progress banners remain pinned until the operation completes.
- Fixed archive/restore banner text jumping to centered alignment after interaction; banner headlines now stay leading-aligned and no longer enter selectable text-editing mode.


## 1.2.1 - 2026-03-12


### Thread
- Switching threads now restores the selected tab first, prepares other tabs in the background, and ties the `Starting agent...` overlay to the actual selected session so startup no longer waits on the wrong tab.
- Agent tabs now remember whether they were created for Claude or Codex, so reopening older tabs keeps the correct startup behavior even after you change the project default agent. If the agent has already exited and the tab is back at a shell, Magent now skips the startup overlay instead of waiting for a timeout.
- GitLab merge-request actions now open the direct MR page when Magent can resolve the MR, instead of landing on the filtered MR list, and MR badges/details appear sooner after launch or MR creation.
- Banner notifications now use an almost opaque background for better readability over terminal and sidebar content.
- Fixed false Claude busy markers when pane content included quoted text like "esc to interrupt" in normal output; busy detection now matches status-line format instead of any substring hit.

### Agents
- Claude/Codex agent tabs now launch through an interactive login zsh shell, so agent commands installed via `.zshrc` PATH setup are found correctly instead of dropping into a plain terminal with `command not found`.

### Thread
- Terminal tabs now set their startup directory only when a tmux session is created, instead of re-sending `cd <worktree>` every time the app reattaches to an existing session.

### Sidebar
- The main worktree now shows the same dirty marker as feature worktrees, and its bottom-left panel always stays available with working-tree changes plus recent commits. That panel now pages commit history in batches of 10, hides entirely for clean feature branches with nothing to show, and marks added directories with folder icons plus full-path hover tooltips.
- Dragging a thread over sidebar project or section headers no longer expands/collapses them; disclosure now reacts only to clicks.
- Fixed a sidebar resize regression where showing the bottom-left `COMMITS` tab could force the sidebar wider than the normal minimum.


## 1.2.0 - 2026-03-11


### Sidebar
- Trailing-edge padding for all sidebar rows (thread markers, section disclosure buttons, project `+` button, separators) is now consistent and symmetric with the leading edge.

### Performance
- Reduced CPU usage from periodic polling: session monitor now runs every 5 seconds (was 3s), pane output is cached for 5 seconds and shared across concurrent checks, and rate-limit scanning for background sessions is throttled to once every 15 seconds.

### Sidebar
- Added a dedicated "Recently Archived" toolbar button (archive box icon) next to the Settings gear, opening a compact popover with up to 10 recently archived threads and one-click Restore actions.
- Recently archived popover rows now include branch/worktree metadata (matching the main thread row style) plus project/archive-date context, so similarly named archived threads are easier to distinguish before restoring.

### Settings
- Archived thread rows in `Settings > Threads` now lead with a "Thread archived" caption, show the task description (or thread name) in a larger prominent font, and display branch and worktree folder more prominently.

### Thread
- The archive and restore banners now lead with the task description (or thread name) in a larger bold font, with branch and worktree folder on a secondary monospace line — secondary details (project, base branch, Jira, tabs) are in a collapsible "More Info" section.
- Fixed Codex tabs being incorrectly shown as busy when the project or global default agent is set to Claude — agent type is now detected from the actual running process instead of the configured default.
- "Use project default" in the add-tab menu now always resolves to the current project/global default agent from Settings instead of the agent the thread was originally created with.

### Settings
- `Settings > Threads` recently-archived list now persists archived threads across app restarts — they were previously lost whenever any active-thread save occurred after archive. Each row now shows the thread's icon, with separators between entries for a cleaner layout.
- `Settings > Threads` now shows up to 10 recently archived threads with one-click restore actions, so quick restores remain available after the archive banner disappears.
- Archiving a thread now shows a 5-second in-app banner with thread details and a one-click `Restore` action, including when the archive was triggered through `magent-cli`.
- Fixed `archive-current-thread.sh` failing when the base worktree match was the last entry in `git worktree list`, so the helper now resolves the main worktree correctly before merging and archiving.
- `magent-cli`'s interactive picker now shows live thread status badges (`done`, `busy`, `input`, `dirty`, `limited`, `delivered`) and uses ANSI colors to make thread state easier to scan.
- `Open in Finder` and pull-request actions now reuse the same Finder/repo-host icons across top-bar buttons, thread right-click menus, and the `CHANGES` file menu.
- When Magent is in the background, new unread agent completions can now bounce the Dock icon and show a Dock badge with the number of unread completed threads, with a Notifications setting to disable that behavior.
- Changing a worktree's branch now updates the thread's stored branch immediately, so auto-rename, CLI renames, and manual branch switches keep sidebar and `CHANGES` footer branch info in sync.
- Fixed a relaunch edge case where a stale/zombie previous process could be mistaken for a live Magent instance, causing the new launch to quit immediately.
- Fixed first-prompt auto-rename treating multi-line `SLUG: EMPTY` agent replies as the literal branch name `empty`; those prompts now stay skipped unless a real slug was generated.
- Auto-generated thread descriptions from rename prompts are now biased toward concrete task labels instead of vague abstractions, improving sidebar names for bug-fix threads.
- Rate-limited threads whose reset time has passed now show a green "ready to resume" indicator instead of the red hourglass, so it's clear the thread can be resumed without waiting.
- The top-right Review button now opens the same active-agent picker style as `+`, excluding `Terminal`; Option-click starts review immediately with the default agent.
- The `+` add-tab menu now shows a "New Tab" header so its purpose is clear at a glance.
- Fixed "agent needs input" marker appearing while the agent is actively busy — the waiting-for-input detector now correctly ignores waiting-style phrases when the Claude Code "esc to interrupt" status bar is visible.
- Expanded auto-generated thread name pool from 85 to 403 Pokémon, covering Generations 1–4 in order.
- Fixed a spurious "Terminal scroll failed: not in a mode" error banner when tapping scroll-to-bottom while the terminal is not in copy-mode.
- A floating `Scroll to bottom` pill now appears only after you scroll meaningfully away from live output, stays fully opaque for readability, uses tighter 8 pt icon/text spacing, and eases in/out with a smoother slide from 24 pt below its resting position.
- Terminal scroll controls (page-up, page-down, jump-to-bottom) are now a compact draggable pill overlay in the bottom-right corner of the terminal panel with shared semi-transparent idle styling and 48 pt bottom clearance, keeping the top bar uncluttered.
- Archive now supports project-scoped local file sync merge-back from worktree to repo root with changed-file-only sync, UI conflict prompts (`Override`, `Override All`, `Ignore`, `Cancel Archive`), and safe non-interactive/CLI conflict skipping so existing repo files are not lost.
- Threads now snapshot their project local-sync path list at creation, so later project setting changes do not retroactively change what an already-open thread syncs on archive.
- Archive now supports forced completion after non-conflict local-sync failures, with a UI `Force Archive` path and CLI `archive-thread --force`.
- Archive local-sync merge-back can now be disabled to keep the main worktree clean for parallel merges, via Settings -> General -> Archive and per-command CLI override `archive-thread --skip-local-sync`.
- Local sync archive merge-back is now stricter: only currently configured Local Sync Paths are eligible, and no-op directory entries no longer create destination folders when no file copy is needed.
- Fixed CLI archive behavior so app-wide Archive local-sync setting is respected when `--skip-local-sync` is not provided.
- Archive completion banner now stays visible for 10 seconds and can be dismissed early via the close (`x`) button.
- Non-main thread context menus now include a prompt-based `Rename...` action (under Pin) that generates branch name, description, and icon in one flow.
- Auto-rename slug generation now treats actionable in-project prompts as renamable by default, and only skips (`SLUG: EMPTY`) for prompts unrelated to the current project.
- New interactive SSH attach flow with persistent launchers, making it much easier to reconnect to remote Magent sessions.
- SSH picker now uses app-like thread rows with back navigation, and has a more reliable fallback path when advanced picker tools are unavailable.
- Opening a new thread that reuses an archived thread's worktree name no longer restores the old agent session from the previous thread.
- Renaming a thread is now fully atomic: if the tmux session rename fails after the git branch was already renamed, the git branch is rolled back and the symlink is cleaned up so the thread state never ends up inconsistent (which previously caused a spurious "branch changed" warning).
- Auto-rename failures now show a one-time error banner per thread instead of silently failing.
- Fixed a race where auto-description generation completing before the first-prompt TOC scan caused the branch rename to be skipped entirely.
- First-prompt auto-rename now falls back through all active agents (Claude → Codex) before giving up, instead of permanently disabling rename on first failure.
- Fixed a race window where two concurrent TOC refreshes could both start independent rename AI calls; the in-progress lock is now acquired before the first async operation.
- Thread cells now display the live git branch instead of the potentially stale stored branch name.
- The "branch changed" panel is now an info indicator (blue) instead of a warning; it shows for both worktree threads (when the actual branch differs from the thread's expected branch) and the main thread (when not on the project's default branch).
- Added an **Accept** button to the branch info panel: for worktree threads it updates the thread's expected branch to match the current one; for the main thread it updates the project's default branch.
- The main thread cell now shows the actual branch name as a subtitle when it is on a non-default branch.
- Auto-generated task descriptions now use cleaner capitalization for better readability.
- Added an `Improvement` thread icon type.
- Added `set-thread-icon` CLI command to manually set thread icon type (`feature`, `fix`, `improvement`, `refactor`, `test`, `other`).

### Table of Contents
- Selecting a prompt in the TOC now jumps to the correct history position without first flashing to history-top, and tmux now anchors the selected prompt at the top edge whenever enough lines exist below it.
- Fixed Prompt TOC in current Claude Code sessions where real submitted prompts render as dim white text with a distinct dark row background; the parser now uses Claude's prompt background as a positive signal, treats Claude dimness separately from placeholder styling, and excludes Claude's blank prompt/footer divider rows from the active composer cluster.
- Prompt TOC header now uses a slightly darker top band so the draggable area is easier to spot at a glance.
- Prompt TOC now opens/loads anchored to the newest prompts by default; during refresh it stays pinned to bottom when you are at/near bottom, but preserves your offset if you scrolled up.
- Prompt TOC now stays pinned to the bottom when new prompts are appended while you were already scrolled to the bottom.
- Fixed Prompt TOC not refreshing after an agent completes its first reply when auto-rename is enabled: the bell pipe was not replaced after the tmux session was renamed, so subsequent completion events were silently dropped.
- Prompt TOC background is now semi-transparent when idle and fades to opaque on hover, reducing visual clutter while keeping the panel accessible; the fade now applies to the whole panel (including text) using the same mechanism as the scroll overlay.
- Prompt TOC now defaults to bottom-right placement (above the prompt/status bar area) for new sessions instead of top-right.
- Fixed Prompt TOC showing "No prompts yet" when the session's agent type was incorrectly inferred (e.g., Codex assigned to a Claude session via migration); the parser now falls back to searching both markers when the specific-marker pass finds nothing.
- Added a draggable terminal Table of Contents with a top-bar show/hide toggle that lists submitted Codex/Claude prompts per tab, jumps directly to the selected prompt in scrollback, and remembers panel position per tab.
- Prompt TOC show/hide state now persists across app launches and applies consistently across all open thread panels instead of being tracked per panel window.
- Prompt TOC can now be resized (minimum size matches the original default), remembers per-tab size, uses 3-line prompt rows with subtle alternating row backgrounds, and lets users click anywhere on a row to jump with the selected prompt anchored at the top.
- Prompt TOC can now be resized from any of the four corners, not just the bottom-right handle; prompt list now shows oldest-first (scrolled to top); close button is pinned to the top-right corner of the panel.
- Prompt TOC now auto-refreshes when the agent finishes responding, so newly submitted prompts appear without requiring a tab switch.
- Right-clicking a prompt in the Table of Contents now offers "Copy prompt" to copy the prompt text to the clipboard, and "Rename thread from this prompt" to feed the selected prompt directly to the rename agent without requiring a separate input dialog.
- First-prompt auto-rename now triggers from the Prompt TOC when a confirmed prompt appears, rather than on keystroke, so it no longer fires prematurely before a prompt is actually submitted.
- Fixed Prompt TOC not detecting prompts whose text is rendered in RGB white (`rgb(255,255,255)`); the gray-like check now excludes very bright colors so normal white terminal text is no longer classified as placeholder text.
- Fixed Prompt TOC not detecting Claude prompts due to ANSI color 7 (white) being incorrectly treated as placeholder-gray; "Tool loaded." lines emitted by Claude Code are now also filtered out.
- Prompt TOC prompt rows are now label-like instead of selectable text, and selecting one no longer rewraps a 3-line entry into 4 lines.
- Prompt TOC now rejects dim/grey placeholder composer text, requires later agent output before confirming a submitted prompt, and keeps full-width 3-line rows with selection highlighting plus an inline close button.
- Prompt TOC now includes only prompts that were actually submitted, excluding placeholder/suggestion rows and stale non-submitted composer text after thread/tab switches.
- Prompt TOC now filters generic suggestion templates like `Implement (feature)` so they do not appear as submitted entries.
- Prompt TOC now also filters brace-style suggestion templates like `Implement {feature}` and avoids re-falling back to parser rows once submitted-history exists for a session.
- Prompt TOC confirmation now waits for pane evidence that a prompt moved past the active bottom composer area, and ignores pinned bottom chrome like `gpt-5.4 high · ...` instead of storing raw keystroke submissions immediately.
- Prompt TOC position and size are now remembered globally across all threads, so the panel stays where you left it when switching threads.
- Fixed Prompt TOC shifting position when the diff viewer is opened or closed; position is now frozen while the diff panel is visible and restored correctly when it closes.

### Diff Viewer
- The changes panel now shows a `COMMITS (n)` tab next to `CHANGES (n)` when the branch has more than one commit ahead of its base, listing each commit's short hash and subject.
- Selecting text in the inline diff viewer now supports standard `Cmd+C` copy to the macOS clipboard.
- Left-clicking an image diff now opens an enlarged animated overlay with background dimming; click anywhere (or press Escape) to dismiss it without disturbing the current diff scroll position.
- Image diffs now stay fully visible while capping preview height to the diff pane, avoiding clipped previews and overly tall image blocks.
- The `CHANGES` panel now has an `ⓘ` button in the top-right corner that shows a color legend explaining what each file color means (staged, unstaged, untracked, committed).
- Fixed inconsistent padding in the `CHANGES` legend popover so all rows keep the same inset from the panel edge.
- Double-clicking a file in the `CHANGES` panel now opens it in the default macOS app, and right-click now includes `Show in Finder`.
- Selecting files in `CHANGES` now reliably opens and scrolls the inline diff to the correct file section, including renamed files, quoted paths, and cases where AppKit layout had not settled yet.

### Sidebar
- Section headers can now be renamed: double-click the section name to edit inline, or right-click for a "Rename Section" context menu option.
- Added a `Narrow threads` option that limits sidebar thread descriptions to one line and shrinks all thread rows to that denser height, while staying off by default.
- All thread rows now use the same measured height as description rows, so the sidebar stays visually even even when some threads only render a single text line.
- Threads can now be hidden to the bottom of their section/list and appear dimmed, with matching right-click and CLI hide/unhide actions so inactive work stays visible without competing with active threads.
- When section grouping is disabled, the flat sidebar now behaves like one combined section: new threads land at the bottom, agent-completed threads jump to the top of their pin group, and manual reordering works without changing each thread's stored section.
- Sidebar thread groups now have a clearer visual separator between pinned, normal, and hidden rows, with a bit more vertical breathing room around the divider.
- Fixed sidebar background refreshes from auto-scrolling the thread list while you were browsing older rows, including cases where Magent was restoring the current selection.
- Added a fixed 8 pt gap between each repository header and its `Main worktree` row for clearer visual separation.
- Fixed a sidebar row-jump case where selecting threads could make non-description rows expand/collapse; compact rows now keep a stable one-line height.
- Fixed another sidebar row-height jitter case caused by selection-dependent scrollbar width changes affecting description line wrapping.
- Fixed pinned description rows switching between one and two lines on selection by keeping description text style stable across unread/selected state changes.
- Fixed intermittent top/bottom padding collapse on description rows by using a stable fixed height for description-style thread cells.
- In flat list mode (sections disabled), pinned threads now always render before all unpinned threads while preserving ordering within each group.
- Fixed a sidebar-width restore edge case that could re-trigger resize handling and cause width instability while reopening/restoring the window.
- The `+` create-thread menu now shows a header (e.g. "New Thread in ios-apps") so its purpose is immediately clear.
- Selecting a thread no longer causes the sidebar to resize, gradually shrink, rewrap task descriptions, or make rows jump taller/shorter when unread-completion state clears on selection.
- Fixed project-row trailing `+` create-thread control so clicks reliably trigger thread creation, including Option-click on the full visible icon frame instead of only the glyph pixels.
- Pulled the enlarged project-row `+` create-thread control closer to the trailing edge so it stays easier to scan and hit.
- Fixed sidebar row jumping while switching threads by stabilizing thread-row text measurement and trailing status-marker layout.
- Fixed a trailing-inset regression on launch where sidebar markers and project `+` controls could appear flush to the edge until the first manual resize.
- Fixed sidebar live-resize lag where selection highlight and trailing markers could appear to trail divider movement while dragging.
- Kept trailing marker alignment stable by reserving a fixed status slot and keeping pin as the rightmost marker.
- Busy threads now show a sweeping shimmer state in sidebar rows for clearer in-progress visibility.
- Sidebar project headers, sections, and `Main worktree` rows now use a cleaner shared alignment system with tighter spacing, a main-row accent bar, and clearer branch labeling.
- Sidebar sections now show thread count badges.
- Reordering sections no longer changes the default section unexpectedly.
- Reduced excess top padding in the sidebar for a tighter layout.
- Increased top spacing above the global Rate limits summary to 8pt and kept a fixed gap before the first thread row.
- Fixed occasional overlap between the global Rate limits summary and top sidebar rows by reserving measured header space and keeping the summary above scroll content.
- Fixed a remaining overlap case where the global Rate limits summary could still cover the first repo row by shifting the sidebar scroll container down with a dynamic top constraint.

### Settings
- Sections can now be renamed: double-click any section name in Settings → Threads or Settings → Projects to edit it inline (Enter to confirm, Escape to cancel).
- Update checks now detect new releases on launch only when enabled, show a persistent dismissible banner with `Update Now`, `Skip this version`, and expandable changelog notes, and mirror the same version/changelog state in Settings with an `Update to …` action.
- Settings now split thread-focused preferences into a dedicated `Threads` category for naming, sections, startup injection, and review defaults, while `General` keeps app-wide updates, terminal overlay toggles, and environment-variable help.
- Local release-gated features now use build flags, and debug-only Settings surfaces are labeled accordingly; Jira integration is currently available only in `Debug` builds and hidden from releases.
- Section settings now let you delete any non-default section immediately, with a confirmation showing how many threads will be moved into the current default section.
- Fixed section color pickers so switching to another section no longer resets the previously edited dot color, and only one picker stays active at a time.
- Added Terminal Overlay visibility settings to permanently hide/show: `Scroll to bottom` indicator, terminal scroll controls, and Prompt TOC overlay.
- Project settings now include `Local Sync Paths` (line-separated repo-relative files/directories) copied into new thread worktrees and merged back on archive.
- Project settings now include project reorder and visibility controls.
- Fixed project visibility eye buttons in Settings so only the icon toggles visibility (no oversized horizontal click area), with trailing-aligned square controls.
- Checking for updates no longer shows a raw `HTTP 404` warning when the public releases repo exists but has no published releases yet; Magent now reports that there are no new releases available.

### Agents
- Recreated agent tabs now auto-resume the last Claude/Codex conversation by session ID after tmux/macOS restarts, with automatic fallback to a fresh session if resume is unavailable.
- Restored Claude/Codex session auto-resume when recreating or reopening agent tabs, ensuring persisted conversation IDs are applied again after startup/recovery flows.
- Reopening an already-live agent tab no longer blocks on conversation-ID refresh work before the tmux attach check, reducing cases where "Starting agent..." could hang for an extended time until the view refreshed.
- The "Starting agent..." overlay now shows a muted under-the-hood status line when Magent is doing extra recovery work, such as rebuilding a missing tmux session or replacing one tied to the wrong worktree.
- CLI prompt injection now waits for agent-ready startup paths and submits prompts reliably (text + Enter), avoiding dropped first submissions.
- Project-level **Pre-Agent Command** setting in App Settings to run setup commands before the selected agent starts for new/recreated agent sessions.
- First-prompt rename generation now considers the `Improvement` icon type when auto-setting thread icons from AI work-type classification.
- Auto-set thread icons now rely on agent confidence-guided work-type selection, reducing unnecessary fallback to `other`.
- Codex rate-limit timers now stay active until the cached reset time expires or you lift them manually, even if newer pane output like `/status` replaces the original limit message.
- Rate-limit parsing now handles Claude's interactive "Stop and wait for limit to reset" prompt reliably by reading the reset deadline shown above the options list.
- Codex rate-limit parsing now keeps latest-scope separator filtering, while still falling back to full-tail parsing when no separator is present.
- Agent IPC guidance injection is now lightweight by default, with full `magent-cli` docs loaded only on demand (`magent-cli docs`) to reduce token usage.
- First-prompt auto-rename now generates branch slug and thread description in one AI call, reducing duplicate background model usage.

### Distribution
- Releases, in-app update checks, and Homebrew downloads now point at the public release-only repo `vapor-pawelw/magent-releases`, so updates no longer depend on source-repo access.
- GitHub releases now include an installable `Magent.dmg`, and in-app updates/homebrew release automation now understand the DMG packaging while keeping a compatibility `.zip` asset.
- Homebrew cask updates now use the public GitHub release download URL for `Magent.dmg`, removing the private-asset token requirement.
- Auto-updates now detect Homebrew installs and upgrade via `brew` instead of using in-place app replacement.
- GhosttyKit bootstrap now auto-recovers from stale iTerm2 themes dependency URLs: it retries once by patching to Ghostty's maintained mirror when the initial build fails with the known `ghostty-themes.tgz` `404`.
- Fixed local build/relaunch failures after Ghostty API changes by updating runtime callback compatibility in the embedded terminal bridge.
