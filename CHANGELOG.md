# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Thread
- Added a draggable terminal Table of Contents with a top-bar show/hide toggle that lists submitted Codex/Claude prompts per tab, jumps directly to the selected prompt in scrollback, and remembers panel position per tab.
- New interactive SSH attach flow with persistent launchers, making it much easier to reconnect to remote Magent sessions.
- SSH picker now uses app-like thread rows with back navigation, and has a more reliable fallback path when advanced picker tools are unavailable.
- Project settings now include project reorder and visibility controls.
- Sidebar sections now show thread count badges.
- Project-level **Pre-Agent Command** setting in App Settings to run setup commands before the selected agent starts for new/recreated agent sessions.

### Fixed
- Agent IPC guidance injection is now lightweight by default, with full `magent-cli` docs loaded only on demand (`magent-cli docs`) to reduce token usage.
- Reordering sections no longer changes the default section unexpectedly.
- Auto-generated task descriptions now use cleaner capitalization for better readability.
- Added an `Improvement` thread icon type.
- Added `set-thread-icon` CLI command to manually set thread icon type (`feature`, `fix`, `improvement`, `refactor`, `test`, `other`).

### Sidebar
- Sidebar now has clearer visual separation between project headers and their `Main` thread row, making scanning and navigation easier.
- Sidebar sections now show thread count badges.
- Reordering sections no longer changes the default section unexpectedly.
- Reduced excess top padding in the sidebar for a tighter layout.

### Settings
- Project settings now include project reorder and visibility controls.
- Fixed project visibility eye buttons in Settings so only the icon toggles visibility (no oversized horizontal click area), with trailing-aligned square controls.
- Added update controls in Settings: automatic update checks on launch and a manual **Check for Updates Now** action.

### Agents
- Recreated agent tabs now auto-resume the last Claude/Codex conversation by session ID after tmux/macOS restarts, with automatic fallback to a fresh session if resume is unavailable.
- CLI prompt injection now waits for agent-ready startup paths and submits prompts reliably (text + Enter), avoiding dropped first submissions.
- Project-level **Pre-Agent Command** setting in App Settings to run setup commands before the selected agent starts for new/recreated agent sessions.
- Auto-set thread icons now rely on agent confidence-guided work-type selection, reducing unnecessary fallback to `other`.

### Distribution
- Homebrew installs now work with private release assets by using authenticated GitHub API download URLs in the cask update pipeline.
- Auto-updates now detect Homebrew installs and upgrade via `brew` instead of using in-place app replacement.
