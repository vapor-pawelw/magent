# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Thread
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
- Right-clicking a prompt in the Table of Contents now offers "Rename thread from this prompt", which feeds the selected prompt directly to the rename agent without requiring a separate input dialog.
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
- Selecting text in the inline diff viewer now supports standard `Cmd+C` copy to the macOS clipboard.
- Left-clicking an image diff now opens an enlarged animated overlay with background dimming; click anywhere (or press Escape) to dismiss it without disturbing the current diff scroll position.
- Image diffs now stay fully visible while capping preview height to the diff pane, avoiding clipped previews and overly tall image blocks.
- The `CHANGES` panel now has an `ⓘ` button in the top-right corner that shows a color legend explaining what each file color means (staged, unstaged, untracked, committed).
- Fixed inconsistent padding in the `CHANGES` legend popover so all rows keep the same inset from the panel edge.
- Double-clicking a file in the `CHANGES` panel now opens it in the default macOS app, and right-click now includes `Show in Finder`.
- Selecting files in `CHANGES` now reliably opens and scrolls the inline diff to the correct file section, including renamed files, quoted paths, and cases where AppKit layout had not settled yet.

### Sidebar
- When section grouping is disabled, the flat sidebar now behaves like one combined section: new threads land at the bottom, agent-completed threads jump to the top of their pin group, and manual reordering works without changing each thread's stored section.
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
- Added Terminal Overlay visibility settings to permanently hide/show: `Scroll to bottom` indicator, terminal scroll controls, and Prompt TOC overlay.
- Project settings now include `Local Sync Paths` (line-separated repo-relative files/directories) copied into new thread worktrees and merged back on archive.
- Project settings now include project reorder and visibility controls.
- Fixed project visibility eye buttons in Settings so only the icon toggles visibility (no oversized horizontal click area), with trailing-aligned square controls.
- Added update controls in Settings: automatic update checks on launch and a manual **Check for Updates Now** action.

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
- GitHub releases now include an installable `Magent.dmg`, and in-app updates/homebrew release automation now understand the DMG packaging while keeping a compatibility `.zip` asset.
- Homebrew installs now work with private release assets by using authenticated GitHub API download URLs in the cask update pipeline.
- Auto-updates now detect Homebrew installs and upgrade via `brew` instead of using in-place app replacement.
- GhosttyKit bootstrap now auto-recovers from stale iTerm2 themes dependency URLs: it retries once by patching to Ghostty's maintained mirror when the initial build fails with the known `ghostty-themes.tgz` `404`.
- Fixed local build/relaunch failures after Ghostty API changes by updating runtime callback compatibility in the embedded terminal bridge.
