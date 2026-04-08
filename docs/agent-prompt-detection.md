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
- **Process title**: Claude Code sets its process title to its version number (e.g. `2.1.92`), so tmux's `pane_current_command` does NOT report "claude". Agent detection falls back to child process args via `ps`, and additionally uses a semver heuristic: if `pane_current_command` matches `^\d+\.\d+\.\d+` and the session has a configured agent type in `sessionAgentTypes`, that type is trusted directly. A 60-second runtime detection cache provides a final safety net against transient `ps` failures.

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

Prompt detection must drop trailing blank/filler lines before clipping to its "recent lines" window. On tall tmux panes, Codex can leave the real `›` placeholder prompt well above a large block of empty bottom space; taking the last N raw lines first can miss the visible prompt entirely and cause false startup timeouts.

The tmux capture window must therefore stay wider than the recent-line suffix used by readiness detection. Current implementation captures the last 120 pane lines, trims filler, and only then narrows to the recent prompt-check window. Future refactors must preserve that order rather than shrinking `capture-pane` back down to the same size as the final suffix.

## Custom / Unknown Agent

Falls back to a content-volume heuristic: the pane is considered ready when it has more than 50 non-whitespace characters.

## Shell & Agent Startup

- **Shell CWD**: Uses managed `ZDOTDIR` (`/tmp/magent-zdotdir`) with `MAGENT_START_CWD` env var. Do not reintroduce post-start `send-keys cd` — the managed zshrc handles cwd after user rc/profile loads. If `/tmp` was cleared, `terminalStartCommand(...)` recreates the zdotdir.
- **Agent binary invocation**: Always prefix with `command` built-in (e.g. `command claude`, `command codex`) in `AppSettings.command(for:)` and `resumableAgentCommand`. User shell functions for `claude`/`codex` can inject conflicting flags; `command` resolves the binary directly, skipping functions and aliases.
- **Interactive shell blockers**: If `waitForAgentPrompt` times out, check pane for `[Y/n]`, `Press any key`, etc. via `detectsInteractiveShellBlocker` before sending text. Abort injection and show retry banner if found.

## Busy State Tracking

- **Magent busy vs agent busy**: `magentBusySessions` tracks Magent's own setup/injection work. `busySessions` tracks the agent's working state. Sidebar shows spinner when either is active (`isAnyBusy`). Use `threadSetupSentinel` for thread-level creation busy (before any tmux session). `clearMagentBusy(sessionName:)` must be called at every exit point of `injectAfterStart`.
- **Runtime process detection**: `syncBusySessionsFromProcessState` detects the running agent per-session from `pane_current_command` and child process args, not from the configured agent type (which can misclassify). Claude idle: `❯` (U+276F); Codex idle: `›` (U+203A). Sessions with no detected agent are treated as not busy.
- **Session rename/migration**: When tmux session names change, re-key transient per-session sets (`busySessions`, `waitingForInputSessions`, `magentBusySessions`, notification dedupe state) so indicators don't get stuck on stale names.

## Session Busy/Idle Detection (Polling)

Separate from one-time prompt readiness, `syncBusySessionsFromProcessState` in `ThreadManager+AgentState.swift` periodically determines whether each session is busy or idle.

### Primary signal: "esc to interrupt"

`paneContentShowsEscToInterrupt` checks the last 15 non-empty lines for Claude's status bar text. Two regex patterns:
- `^\s*(?:[•⏵]+[[:space:]]*)?esc to interrupt\b` — direct status line
- `\s·\s*esc to interrupt\b` — embedded in a longer status bar (e.g. `⏵⏵ bypass permissions on · 1 shell · esc to interrupt · ...`)

If found → definitely busy, regardless of `❯` visibility.

### Secondary signal: background activity indicators

Claude can show the `❯` prompt while background tools or tasks are still running (e.g. `run_in_background` Bash, Agent subagents, active task spinners). When the narrow 15-line capture shows `❯` without "esc to interrupt", a wider 30-line capture is checked for:

- **`⎿` (U+23BF) + "Running"** — active background tool (`⎿  Running… (3m 6s · timeout 10m)`)
- **`✳` (U+2733) at line start** — active task/thinking block (`✳ Building and running tests… (44m 41s · ...)`)

If either is found → session is busy despite the visible prompt.

### Tall pane trailing-blank fix

`PaneCaptureCache.trimmed()` strips trailing blank lines before taking the last-N suffix. Without this, tall tmux panes (e.g. 95 rows) can return all-blank windows when the agent content only occupies the upper portion of the pane.
