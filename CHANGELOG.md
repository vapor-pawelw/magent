# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Thread
- The "New Thread" sheet now includes a Section picker, pre-selected to the project's default section. The picker shows each section's color dot, matching how sections appear in the sidebar. Different projects can have different section settings. The "All fields are optional" hint has moved below the form fields, just above the checkboxes.
- Fixed: the "Rename branch" dialog now pre-fills with the current branch name instead of the worktree name.
- Fixed: multi-line prompts are now captured in full in the Prompt TOC and used in full for auto-rename. Previously only the first line was captured because continuation lines are ANSI-styled by Claude's TUI and blank paragraph separators broke the collection loop.
- Fixed: "Rename thread from this prompt" (TOC right-click, thread context menu, and CLI `rename-thread`) now works on context-setting prompts that auto-rename would classify as questions (e.g. "You're working on branch X"). Explicit rename actions always generate a name.

### Performance
- Git status, branch, and delivery checks now run in parallel across all threads instead of sequentially, significantly reducing background polling time with many threads open.
- Agent completion no longer triggers a full git-status scan of every thread — only the threads that just completed are refreshed.
- Sidebar no longer rebuilds immediately on every settings-changed notification; rapid successive saves are coalesced into one reload.

### Settings
- Thread Settings › Sidebar now has a "Move completed threads to top" checkbox, letting you disable auto-reorder on agent completion without leaving the Threads tab.

### Sidebar
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
