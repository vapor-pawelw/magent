# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- New interactive SSH attach flow with persistent launchers, making it much easier to reconnect to remote Magent sessions.
- SSH picker now uses app-like thread rows with back navigation, and has a more reliable fallback path when advanced picker tools are unavailable.
- Project settings now include project reorder and visibility controls.
- Sidebar sections now show thread count badges.
- Project-level **Pre-Agent Command** setting in App Settings to run setup commands before the selected agent starts for new/recreated agent sessions.

### Fixed
- Reordering sections no longer changes the default section unexpectedly.
- Auto-generated task descriptions now use cleaner capitalization for better readability.
- Reduced excess top padding in the sidebar for a tighter layout.
- Auto-set thread icons now rely on agent confidence-guided work-type selection, reducing unnecessary fallback to `other`.
