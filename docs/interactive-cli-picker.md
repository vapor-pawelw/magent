# Interactive CLI Picker

This note covers the status-aware thread rows shown by `magent-cli` interactive mode and `magent-cli ls`.

## User-visible behavior

- Thread rows show live status badges such as `done`, `busy`, `input`, `dirty`, `limited`, and `delivered`.
- The interactive picker groups threads by section using styled section headers (`● Section Name` in the section's color), matching the sidebar order in the app.
- Thread order within each section preserves the app's in-memory order (same as the sidebar).
- When a thread has only one tab the tab-picker step is skipped and the session is attached directly.
- The picker is always the classic numbered list (`1) … 2) …`), which works reliably over SSH and from a phone. `fzf` is not used.
- Section headers are displayed as visual separators without numbers. If accidentally selected the picker reopens.
- When ANSI colors are supported, section names and bullets are rendered in the section's 24-bit true color.

## Implementation notes

- The installed shell script lives inside `IPCSocketServer.installCLIScript()` and is versioned by `cliVersion`. **Bump `cliVersion` whenever changing the embedded script** so `/tmp/magent-cli` is reinstalled on next app launch.
- The interactive picker uses `list-sections` (not `list-threads`) so it gets sections in `sortOrder` order with threads pre-grouped. `handleListSections` populates `status` on each thread so badges are available.
- `makeThreadStatus(for:)` on `IPCCommandHandler` is `internal` (not `private`) so `IPCCommandHandler+Sections.swift` can call it when building thread infos for `handleListSections`.
- `paint_hex` converts a `#RRGGBB` hex string to a 24-bit ANSI escape using POSIX-sh `printf` and `sed`. It strips the leading `#` via `sed 's/^#//'` — avoid `${var#\#}` parameter expansion inside the Swift `#"""..."""#` raw string literal as the `\#` sequence is interpreted as a Swift raw-string escape and causes a build error.
- Color output is optional. `MAGENT_USE_COLOR=0` or `NO_COLOR=1` disables ANSI styling.

## Gotchas

- Keep the shell script POSIX `sh` compatible. Validate changes with `sh -n` against the extracted script body, not just Swift compilation.
- Never use `\#` inside the Swift `#"""..."""#` raw string (i.e. inside the embedded shell script body) — use `sed` or `cut` workarounds instead of `${var#\#}` pattern stripping.
- If you add new badges, update both the interactive picker formatter and the `ls` formatter so they stay in sync.
- `list-sections` returns threads only when a project filter is provided; global (no-project) calls return section metadata only. The picker always has a project context so this is fine.
