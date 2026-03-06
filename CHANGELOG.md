# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Thread
- A floating "Scroll to bottom" button now appears at the bottom-left of the terminal when scrolled up 3+ lines; clicking it snaps back to live output and fades away.
- Terminal scroll controls (page-up, page-down, jump-to-bottom) are now a compact draggable pill overlay in the bottom-right corner of the terminal panel; it fades to semi-transparent when idle and becomes opaque on hover, keeping the top bar uncluttered.
- Archive now supports project-scoped local file sync merge-back from worktree to repo root with changed-file-only sync, UI conflict prompts (`Override`, `Override All`, `Ignore`, `Cancel Archive`), and safe non-interactive/CLI conflict skipping so existing repo files are not lost.
- Threads now snapshot their project local-sync path list at creation, so later project setting changes do not retroactively change what an already-open thread syncs on archive.
- Archive now supports forced completion after non-conflict local-sync failures, with a UI `Force Archive` path and CLI `archive-thread --force`.
- Non-main thread context menus now include a prompt-based `Rename...` action (under Pin) that generates branch name, description, and icon in one flow.
- Auto-rename slug generation now treats actionable in-project prompts as renamable by default, and only skips (`SLUG: EMPTY`) for prompts unrelated to the current project.
- New interactive SSH attach flow with persistent launchers, making it much easier to reconnect to remote Magent sessions.
- SSH picker now uses app-like thread rows with back navigation, and has a more reliable fallback path when advanced picker tools are unavailable.
- Opening a new thread that reuses an archived thread's worktree name no longer restores the old agent session from the previous thread.
- Auto-generated task descriptions now use cleaner capitalization for better readability.
- Added an `Improvement` thread icon type.
- Added `set-thread-icon` CLI command to manually set thread icon type (`feature`, `fix`, `improvement`, `refactor`, `test`, `other`).

### Table of Contents
- Added a draggable terminal Table of Contents with a top-bar show/hide toggle that lists submitted Codex/Claude prompts per tab, jumps directly to the selected prompt in scrollback, and remembers panel position per tab.
- Prompt TOC can now be resized (minimum size matches the original default), remembers per-tab size, uses 3-line prompt rows with subtle alternating row backgrounds, and lets users click anywhere on a row to jump with the selected prompt anchored at the top.
- Prompt TOC can now be resized from any of the four corners, not just the bottom-right handle; prompt list now shows oldest-first (scrolled to top); close button is pinned to the top-right corner of the panel.
- Prompt TOC now auto-refreshes when the agent finishes responding, so newly submitted prompts appear without requiring a tab switch.
- Right-clicking a prompt in the Table of Contents now offers "Rename thread from this prompt", which feeds the selected prompt directly to the rename agent without requiring a separate input dialog.
- First-prompt auto-rename now triggers from the Prompt TOC when a confirmed prompt appears, rather than on keystroke, so it no longer fires prematurely before a prompt is actually submitted.
- Fixed a Prompt TOC interaction regression where the panel could appear visible but remain unclickable behind terminal content after tab/session view updates.
- Fixed Prompt TOC not detecting Claude prompts due to ANSI color 7 (white) being incorrectly treated as placeholder-gray; "Tool loaded." lines emitted by Claude Code are now also filtered out.
- Prompt TOC prompt rows are now label-like instead of selectable text, and selecting one no longer rewraps a 3-line entry into 4 lines.
- Prompt TOC now rejects dim/grey placeholder composer text, requires later agent output before confirming a submitted prompt, and keeps full-width 3-line rows with selection highlighting plus an inline close button.
- Prompt TOC now includes only prompts that were actually submitted, excluding placeholder/suggestion rows and stale non-submitted composer text after thread/tab switches.
- Prompt TOC now filters generic suggestion templates like `Implement (feature)` so they do not appear as submitted entries.
- Prompt TOC now also filters brace-style suggestion templates like `Implement {feature}` and avoids re-falling back to parser rows once submitted-history exists for a session.
- Prompt TOC confirmation now waits for pane evidence that a prompt moved past the active bottom composer area, and ignores pinned bottom chrome like `gpt-5.4 high · ...` instead of storing raw keystroke submissions immediately.

### Diff Viewer
- Double-clicking a file in the `CHANGES` panel now opens it in the default macOS app, and right-click now includes `Show in Finder`.
- Selecting files in `CHANGES` now opens and scrolls the inline diff to the correct file section, including renamed files and paths that Git would otherwise quote.

### Sidebar
- Selecting a thread no longer causes the sidebar to resize or task descriptions to rewrap between one and two lines.
- Fixed project-row trailing `+` create-thread control so clicks reliably trigger thread creation, including Option-click on the full visible icon frame instead of only the glyph pixels.
- Fixed sidebar row jumping while switching threads by stabilizing thread-row text measurement and trailing status-marker layout.
- Busy threads now show a sweeping shimmer state in sidebar rows for clearer in-progress visibility.
- Sidebar now has clearer visual separation between project headers and their `Main` thread row, making scanning and navigation easier.
- Sidebar sections now show thread count badges.
- Reordering sections no longer changes the default section unexpectedly.
- Reduced excess top padding in the sidebar for a tighter layout.
- Increased top spacing above the global Rate limits summary to 8pt and kept a fixed gap before the first thread row.
- Fixed occasional overlap between the global Rate limits summary and top sidebar rows by reserving measured header space and keeping the summary above scroll content.
- Fixed a remaining overlap case where the global Rate limits summary could still cover the first repo row by shifting the sidebar scroll container down with a dynamic top constraint.

### Settings
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
