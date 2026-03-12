# Prompt TOC Parser Notes

This document covers the Prompt TOC parsing and jump behavior that was adjusted in the `fix-claude-toc` thread.

## User-facing behavior

- The Prompt TOC should list only prompts that were actually submitted.
- Claude Code and Codex sessions can style submitted prompts differently; parser rules must accept both without pulling in placeholder composer content.
- Selecting a TOC row should jump directly to the chosen prompt without visibly flashing to the very top of terminal history first.
- When enough lines exist below the selected prompt, the selected prompt should land at the top edge of the terminal viewport.

## Implementation details

- Prompt extraction lives in `Magent/Views/Terminal/ThreadDetailViewController+PromptTOC.swift`.
- Prompt navigation lives in `Packages/MagentModules/Sources/TmuxCore/TmuxService.swift` in `scrollHistoryLineToTop(...)`.
- Parser line indexes are derived from full `tmux capture-pane -S - -E -` output and are therefore top-relative.
- tmux copy-mode `goto-line` is bottom-relative (`1` is the newest line), so TOC navigation must convert from capture-pane top-relative indexes using current `history_size + pane_height` before issuing `goto-line`.

## Claude Code gotchas

- Current Claude Code sessions can render real submitted prompt text as dim white. Do not reject Claude prompts just because the text is dim.
- Current Claude Code sessions also give submitted prompt rows a distinct non-default dark background. Treat that background as a positive signal that the row is a real submitted prompt.
- Claude's bottom composer area can include a blank prompt row and decorative divider rows. Those rows must be treated as bottom-cluster chrome and excluded from confirmation logic.

## What changed in this thread

- Claude prompt placeholder detection became agent-aware: Codex still uses dim/grey placeholder filtering, while Claude no longer treats dimness alone as placeholder evidence.
- Claude prompt parsing now recognizes the dark prompt-row background as a positive submission signal.
- Bottom-cluster exclusion now includes blank prompt rows and footer divider rows.
- TOC jump behavior now uses tmux `goto-line` plus `scroll-top` with top-relative to bottom-relative line conversion instead of `history-top` plus a long cursor walk.

## Auto-rename gate: agent process detection

Auto-rename-on-first-prompt fires only when an agent (Claude or Codex) process is actually detected running in the session at the moment new prompt entries are confirmed. This prevents terminal commands typed at a `❯`-themed shell prompt (e.g. oh-my-zsh Pure/Starship themes) from being mistaken for agent prompts and triggering a rename.

- Detection uses `ThreadManager.detectedAgentTypeInSession(_:)`, which calls `tmux list-panes` for the pane command + PID, then `ps` for child processes, and delegates to `detectedRunningAgentType(paneCommand:childProcesses:)`.
- If the pane is at a plain shell (agent not yet started, exited via Ctrl+C, etc.) the check returns `nil` and the rename is skipped silently.
- This check is separate from the prompt TOC itself — TOC entries are still parsed and displayed regardless; only the auto-rename trigger is gated.

## Future debugging checklist

- If Claude prompts disappear again, capture the pane with attributes (`tmux capture-pane -e -p -S - -E -`) and inspect both foreground and background styling before changing placeholder heuristics.
- If TOC selection jumps to the wrong place, verify whether tmux line numbers are being interpreted from the top or bottom before changing parser indexes.
- If a selected prompt lands below the top edge near the end of the conversation, check whether there are enough lines below it to satisfy tmux `scroll-top`; near-bottom prompts cannot always be top-anchored.
