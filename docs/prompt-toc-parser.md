# Prompt TOC Parser Notes

This document covers Prompt TOC parsing and jump behavior.

## User-facing behavior

- The Prompt TOC should list only prompts that were actually submitted.
- Claude Code and Codex sessions can style submitted prompts differently; parser rules must accept both without pulling in placeholder composer content.
- Selecting a TOC row should jump directly to the chosen prompt without visibly flashing to the very top of terminal history first.
- When enough lines exist below the selected prompt, the selected prompt should land at the top edge of the terminal viewport.
- TOC rows may show only a 3-line preview, but prompt actions like `Copy prompt` should use the full submitted prompt text.

## Implementation details

- Prompt extraction lives in `Magent/Views/Terminal/ThreadDetailViewController+PromptTOC.swift`.
- Prompt navigation lives in `Packages/MagentModules/Sources/TmuxCore/TmuxService.swift` in `scrollHistoryLineToTop(...)`.
- Parser line indexes are derived from full `tmux capture-pane -S - -E -` output and are therefore top-relative.
- TOC navigation uses `history-top` + `scroll-down lineIndex`. `scroll-down` moves the viewport 1 line toward newer content regardless of cursor position. After `history-top` (viewport top = 0) + `lineIndex` scroll-downs, viewport top = `lineIndex`. ✓ This is race-condition-free (depends only on `lineIndex`, which is stable — lines above it never shift) and doesn't require querying `history_size` or `pane_height`. All commands are chained with tmux's `\;` separator in a single IPC message so the server processes them atomically — preventing a visible intermediate flash to the top of history.

## Claude Code gotchas

- Current Claude Code sessions can render real submitted prompt text as dim white. Do not reject Claude prompts just because the text is dim.
- Current Claude Code sessions also give submitted prompt rows a distinct non-default dark background. Treat that background as a positive signal that the row is a real submitted prompt.
- Claude's bottom composer area can include a blank prompt row and decorative divider rows. Those rows must be treated as bottom-cluster chrome and excluded from confirmation logic.

## What changed in recent TOC fixes

- Claude prompt placeholder detection became agent-aware: Codex still uses dim/grey placeholder filtering, while Claude no longer treats dimness alone as placeholder evidence.
- Claude prompt parsing now recognizes the dark prompt-row background as a positive submission signal.
- Bottom-cluster exclusion now includes blank prompt rows and footer divider rows.
- TOC jump behavior now uses `history-top` + `scroll-down lineIndex` chained via tmux's `\;` separator. All commands are sent to the tmux server in a single IPC message — the server processes them atomically before rendering, so the intermediate `history-top` position is never visible. `scroll-down` scrolls the viewport directly (not cursor-position-dependent), giving viewport top = `lineIndex` after `lineIndex` scroll-downs from `history-top`. This replaced approaches that depended on `history_size` (which races with agent output) and eliminated the visible double-jump flash.
- Prompt TOC entries now keep both preview text and full submitted text so context-menu actions can copy or reuse the complete prompt even when the row UI is limited to a 3-line preview.

## Auto-rename gate: agent process detection

Auto-rename-on-first-prompt fires only when an agent (Claude or Codex) process is actually detected running in the session at the moment new prompt entries are confirmed. This prevents terminal commands typed at a `❯`-themed shell prompt (e.g. oh-my-zsh Pure/Starship themes) from being mistaken for agent prompts and triggering a rename.

- Detection uses `ThreadManager.detectedAgentTypeInSession(_:)`, which calls `tmux list-panes` for the pane command + PID, then `ps` for child processes, and delegates to `detectedRunningAgentType(paneCommand:childProcesses:)`.
- If the pane is at a plain shell (agent not yet started, exited via Ctrl+C, etc.) the check returns `nil` and the rename is skipped silently.
- This check is separate from the prompt TOC itself — TOC entries are still parsed and displayed regardless; only the auto-rename trigger is gated.

## Future debugging checklist

- If Claude prompts disappear again, capture the pane with attributes (`tmux capture-pane -e -p -S - -E -`) and inspect both foreground and background styling before changing placeholder heuristics.
- If TOC selection jumps to the wrong place, check: (1) `\;` chaining is preserved so all commands arrive at the tmux server in one IPC message — separated shell commands allow intermediate renders; (2) the `scroll-down` count equals exactly `lineIndex` (0-indexed from the capture-pane split); (3) do NOT use `cursor-down` in place of `scroll-down` — `cursor-down` is cursor-position-dependent and produces a wrong offset unless you also account for `pane_height`.
- If a selected prompt lands below the top edge near the end of the conversation, that line is in the live pane area (lineIndex >= historySize) where no scroll-up is issued — expected behavior.
- If a double-jump / flash reappears, confirm the three tmux commands are still chained with `\;` (tmux command separator) in a single tmux invocation — NOT separated by shell `;` (which would be three separate tmux client calls, giving the server time to render the intermediate `history-top` state between them).
