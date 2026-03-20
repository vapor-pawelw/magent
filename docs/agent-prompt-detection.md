# Agent Prompt Detection

## Overview

Before injecting an initial prompt or agent context, Magent polls the tmux pane to detect when the agent's input prompt is ready. This avoids sending text before the TUI is accepting input.

Detection is agent-specific and handled by `isAgentPromptReady` in `ThreadManager+Helpers.swift`.

## Claude

- **Marker**: `❯` (U+276F, Heavy Right-Pointing Angle Quotation Mark Ornament)
- **Encoding**: UTF-8 `e2 9d af`
- **Layout**: The `❯` appears alone on its own line, surrounded by separator lines (`────...`)
- **Busy guard**: If `paneContentShowsEscToInterrupt` detects "esc to interrupt" in the last 15 lines, the prompt is considered busy regardless of `❯` visibility
- **Capture**: Uses plain `capture-pane -p` (no ANSI escapes needed since `❯` is always bare)

## Codex

- **Marker**: `›` (U+203A, Single Right-Pointing Angle Quotation Mark)
- **Layout**: The `›` appears with placeholder text on the same line (e.g. `› Write tests for @filename`), or with user-typed text (e.g. `› actual input`)
- **Capture**: Uses ANSI-aware `capture-pane -p -e` to distinguish placeholder from user input

### Placeholder vs User Input (ANSI styling)

Codex renders placeholder text with SGR dim (`\e[2m`) and user-typed text without it:

| State | Raw ANSI | Prompt ready? |
|-------|----------|---------------|
| Bare marker | `\e[1m›\e[0m` | Yes |
| Placeholder | `\e[1m›\e[0m \e[2mExplain this codebase\e[0m` | Yes |
| User input | `\e[1m›\e[0m\e[48;2;65;69;76m actual input` | No |

The key difference: text after `›` wrapped in `\e[2m` (dim) = placeholder = safe to inject. Text without `\e[2m` = user has typed something = do NOT inject.

This is checked by `isPromptLineEmpty(_:marker:)` in `ThreadManager+Helpers.swift`.

### Scoped lines

Codex uses `─────────` separator lines between conversation turns. `latestScopedPaneLines` extracts only content after the last separator to avoid matching stale prompt markers from earlier turns.

## Custom / Unknown Agent

Falls back to a content-volume heuristic: the pane is considered ready when it has more than 50 non-whitespace characters.
