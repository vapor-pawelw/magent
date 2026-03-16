# Prompt TOC Parser Notes

This document covers Prompt TOC parsing and jump behavior.

## User-facing behavior

- The Prompt TOC should list only prompts that were actually submitted.
- Claude Code and Codex sessions can style submitted prompts differently; parser rules must accept both without pulling in placeholder composer content.
- Selecting a TOC row should jump directly to the chosen prompt without visibly flashing to the very top of terminal history first.
- When enough lines exist below the selected prompt, the selected prompt should land at the top edge of the terminal viewport.
- TOC rows may show only a 3-line preview, but prompt actions like `Copy prompt` should use the full submitted prompt text.

## TOC capsule/hover UI

- The TOC rests as a compact 185×36pt floating capsule showing a "Table of Contents" title and a badge with the prompt count.
- Hovering expands the capsule to the full panel (default 320×250pt, user-resizable) with animation; mouse exit collapses it back.
- The toolbar toggle button and in-panel × close button are removed — TOC is always-on; users disable it in Settings.
- No agent name appears in the header; only the title and count badge.

### Animation sequence

**Expand (hover enter):**
1. Corner radius animates 18pt → 8pt via `CABasicAnimation` (0.22s).
2. Scroll constraints swap: `scrollViewCollapseConstraint` deactivated, `scrollBottomConstraint` activated.
3. Controller frame expands via `NSAnimationContext` (0.22s, easeOut).
4. After 0.20s delay, scroll view + header background + corner handles fade in (0.14s) — delayed so rows don't clip while the frame is still growing.

**Collapse (hover exit):**
1. Scroll view + header background + corner handles fade out (0.13s).
2. On completion: hide views, swap constraints back, call `onCollapseCompleted`.
3. Controller frame shrinks via `NSAnimationContext` (0.18s, easeIn).
4. Corner radius animates 8pt → 18pt via `CABasicAnimation` (0.15s).

### Race condition: rapid hover

The collapse completion handler is guarded by `!isExpanded`. If the user re-hovers before the 0.13s fade-out completes:
- `isExpanded` is set to `true` in `mouseEntered` before `setCollapsedState(false)` is called.
- The stale collapse completion fires and checks `!isExpanded` → guard passes, completion is a no-op.
- This prevents the stale handler from swapping scroll constraints back to collapsed state mid-expansion.

`isExpanded` is set eagerly (before animation) in `mouseEntered`/`mouseExited` so it serves as the authoritative signal for pending completion handlers.

### Position normalization

Position is always normalized relative to `promptTOCExpandedSize` (not the current frame). Dragging the collapsed capsule saves position relative to the expanded dimensions so restoring later yields the correct panel position.

## Implementation details

- Prompt extraction lives in `Magent/Views/Terminal/ThreadDetailViewController+PromptTOC.swift`.
- Prompt navigation lives in `Packages/MagentModules/Sources/TmuxCore/TmuxService.swift` in `scrollHistoryLineToTop(...)`.
- Parser line indexes are derived from full `tmux capture-pane -S - -E -` output and are therefore top-relative.
- TOC navigation uses `history-top` + `scroll-down lineIndex`. `scroll-down` moves the viewport 1 line toward newer content regardless of cursor position. After `history-top` (viewport top = 0) + `lineIndex` scroll-downs, viewport top = `lineIndex`. ✓ This is race-condition-free (depends only on `lineIndex`, which is stable — lines above it never shift) and doesn't require querying `history_size` or `pane_height`. All commands are chained with tmux's `\;` separator in a single IPC message so the server processes them atomically — preventing a visible intermediate flash to the top of history.
- `captureFullPane` must return the **raw, untrimmed** stdout. Leading empty lines are part of the copy-mode coordinate space (history-top = line 0) and must not be stripped. Trailing newlines produce one harmless trailing empty element in the split that no prompt marker can match. Any trimming of leading content shifts all split array indexes and causes `scroll-down` to land at the wrong position.

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

## Explicit rename from TOC context menu

Right-clicking a TOC entry shows a context menu with "Rename thread from this prompt". This calls `renameThreadFromPrompt` directly — it bypasses all first-prompt eligibility gates (`didAutoRenameFromFirstPrompt`, `isAutoGenerated`, agent-process-detection) and can be triggered at any time.

**Visual feedback:** `renameThreadFromPrompt` adds the thread to `autoRenameInProgress` before the AI call and removes it (via `defer`) when it exits. This drives the same sidebar pulse animation as the auto-rename path. Without this, the user sees nothing for up to 30 seconds while the agent call is in-flight.

**Agent fallback:** Uses `slugGenerationAgentOrder` (same as auto-rename), which always appends `.claude` as a final fallback even when no trackable agent (Claude/Codex) is configured as active. Since Claude is a prerequisite for the app, this guarantees at least one attempt.

**Error handling:** If all agents fail, throws `nameGenerationFailed`. The banner reads "Could not generate a thread name. Ensure Claude or Codex is configured and reachable, then try again." (not "unique thread name" — that wording was misleading since the failure here is agent availability, not duplicate names).

## Two auto-rename trigger paths

There are now two independent paths that can fire auto-rename for a thread's first prompt:

1. **Early path (launch sheet):** `createThread` fires `autoRenameThreadAfterFirstPromptIfNeeded` in an unstructured `Task` immediately after the tmux session is created, using the prompt captured from the launch sheet. This path bypasses the agent-process-detection gate because the agent is not yet running at that point — the prompt is already known from the sheet. It typically completes before the agent has even started processing.

2. **TOC path (confirmed pane):** The existing path — fires when the prompt TOC parser confirms a new submitted prompt in the pane. This path goes through the agent-process-detection gate.

**Deduplication:** Both paths share the `didAutoRenameFromFirstPrompt` flag. Whichever fires first and succeeds sets the flag; the other path sees it set and exits early. `autoRenameInProgress` prevents concurrent AI calls from both paths running simultaneously.

**Rename payload cache:** Both paths check `promptRenameResultCache` (keyed by `threadId + normalizedPrompt`) before calling the agent. If the early path already cached a result, the TOC path reuses it instantly. See architecture.md §4.2 for details.

## TOC scroll navigation: full history of attempts and lessons learned

This section documents every approach tried for `scrollHistoryLineToTop`, the failure mode of each, and why the final solution works. Took many iterations to reach a correct solution — record everything for the next time.

### The coordinate system (verified empirically on tmux 3.6a)

- `tmux capture-pane -S - -E -` outputs `history_size + pane_height` lines, oldest first. Line 0 = oldest history line. Line `history_size - 1` = newest history line. Lines `history_size..history_size+pane_height-1` = current visible pane rows.
- In copy-mode, `history-top` moves the viewport so line 0 (oldest) is at the top. `scroll_position` (oy) is set to `history_size`.
- `goto-line N` sets `scroll_position = N` directly (absolute setter). At `scroll_position P`, viewport top = `history_size - P`. To show capture-pane line `L` at top: `goto-line (history_size - L)`.
- `scroll-up` increases `scroll_position` by 1 (shows older content). `scroll-down` decreases `scroll_position` by 1 (shows newer content).
- `cursor-down` moves the cursor within the viewport, and scrolls the viewport only once the cursor reaches the bottom edge (cursor_y = pane_height - 1).
- After `history-top`, cursor is at row 0 (top of viewport), cursor_y = 0.

### Attempt 1: `history-top` + `cursor-down (lineIndex + paneHeight - 1)`

**Reasoning:** From history-top (cursor_y = 0, viewport_top = 0), after N cursor-downs where N >= pane_height - 1, cursor_y pins to pane_height - 1 and viewport scrolls. viewport_top = N - (pane_height - 1). Setting N = lineIndex + pane_height - 1 → viewport_top = lineIndex.

**Failure mode:** Double-jump / visible flash. `history-top` is a separate tmux command from `cursor-down`, giving the tmux server time to render the intermediate `history-top` state (oldest history visible) before scrolling to the target. libghostty renders every intermediate tmux copy-mode state, so users saw a jarring flash to the top of history before the correct position appeared.

**Also broken:** `cursor-down` behavior depends on cursor_y at the start. If `history-top` doesn't guarantee cursor_y = 0 in the installed tmux version, or the cursor starts somewhere else, the formula `lineIndex + pane_height - 1` is wrong by exactly that cursor_y offset.

### Attempt 2: `history-top` + `scroll-top` (discarded)

`scroll-top` after any navigation compounded the scroll by `pane_height - 1` extra lines (because `goto-line` leaves cursor_y = pane_height - 1, so `scroll-top` shifts the viewport up by that many more lines). Do not use `scroll-top` after any positioning command.

### Attempt 3: `goto-line (historySize - lineIndex)` with two separate `ShellExecutor.run` calls

**Reasoning:** `goto-line N` sets scroll_position = N. With N = historySize - lineIndex, viewport_top = historySize - (historySize - lineIndex) = lineIndex.

**Failure mode:** Race condition. The first `ShellExecutor.run` call queried `historySize` and the second sent `goto-line`. Between the two calls (~100ms async overhead), the agent output many new lines, shifting `historySize`. In one test, `historySize` jumped from 4 to 29 in milliseconds, causing a 25-line positioning error.

### Attempt 4: `goto-line` with `historySize` query in one shell invocation

**Reasoning:** Combine the `display-message` and `goto-line` into a single `/bin/sh -c` command so the historySize sample and navigation happen in the same process, reducing the race window from ~100ms to ~1ms.

```swift
"tmux copy-mode -t \(sn); " +
"HIST=$(tmux display-message -p -t \(sn) '#{history_size}'); " +
"GOTO=$(( HIST > \(normalizedLine) ? HIST - \(normalizedLine) : 0 )); " +
"tmux send-keys -t \(sn) -X goto-line $GOTO"
```

**Failure mode:** Still has a race condition (1ms window instead of 100ms), still two separate tmux IPC calls for copy-mode and goto-line (allowing intermediate render), and historySize can still shift enough to land a few lines off in active sessions. Also still had the double-jump because `copy-mode` and `goto-line` are separate tmux invocations.

### Attempt 5: `history-top` + `cursor-down` chained with `\;`

**Reasoning:** Use tmux's own `\;` command separator so the tmux client sends all commands to the server in ONE IPC message. The server processes the entire list before returning to its event loop → no intermediate render → no flash. Formula: `cursor-down (lineIndex + paneHeight - 1)` from history-top.

**Failure mode:** Overshooting. The formula assumes cursor_y = 0 after history-top, but in practice, cursor_y after history-top may not be exactly 0 (ambiguous from tmux source across versions). The overshoot varied by exactly cursor_y lines. Flash was eliminated but position was wrong.

### Attempt 6: `history-top` + `scroll-down lineIndex` chained with `\;` ✓ CORRECT

**Why this works:**
- `scroll-down` moves the viewport directly by 1 line toward newer content, completely independent of cursor_y. Starting from history-top (viewport_top = 0), N `scroll-down` operations → viewport_top = N. With N = lineIndex: viewport_top = lineIndex. The `›` line is at the viewport top. ✓
- Race-condition-free: depends only on `lineIndex` (stable — lines above it never shift as the agent adds new lines at the bottom) and nothing else.
- No `pane_height` needed.
- All commands chained with `\;`: `tmux copy-mode \; send-keys -X history-top \; send-keys -X -N lineIndex scroll-down`. Single IPC → no intermediate flash. ✓

**Key formula:** `N = lineIndex` (not `lineIndex + pane_height - 1`). The extra `pane_height - 1` was only needed for cursor-down to account for cursor movement within the viewport before scrolling began.

### The `captureFullPane` trimming problem

After the navigation was correct, a subtle per-session offset remained: sessions with leading empty lines in the capture-pane output (common in sessions that started with a blank line before the first shell output) had lineIndex shifted.

**Attempts and outcomes:**

1. **ShellExecutor.run (original):** Trims BOTH leading and trailing whitespace/newlines. If the capture output has K leading empty lines, they get stripped. The split array then starts at the first non-empty line, which is copy-mode line K. All lineIndexes are K too small. Scrolling by lineIndex lands K lines above the target prompt (undershoot). In active sessions (pichu/magent) where K ≈ 0, this was invisible. In sessions with more leading blank lines (ios-apps Codex sessions), K > 0 caused visible undershoot.

2. **Right-trim only:** Only remove trailing newlines. Preserves leading empty lines. Reasoning: split indexes become 1:1 with copy-mode line numbers. This OVERCORRECTED for sessions where the original undershoot was not caused by leading empty lines — lineIndex was inflated by K, causing overshoot. For a Codex session with K leading empty lines and a prompt at split-index P (before fix) = P+K (after fix), we now scroll K too many lines → land K lines past the prompt at "List docs" just below.

3. **No trimming at all (correct):** Return raw stdout from `ShellExecutor.execute` with zero trimming. Leading empty lines preserved → split[i] = copy-mode line i → lineIndex always correct. Trailing newline from tmux output adds one trailing empty element in the split, but this element has no `›` marker so it is never matched as a prompt and never used as a lineIndex. ✓

**Why no-trim is unambiguously correct:** `tmux capture-pane -S - -E -` outputs exactly `history_size + pane_height` lines, one per terminal row, oldest first. copy-mode's `history-top` positions viewport at row 0 of the same space. The split array must start at row 0 without any offset. Any trimming that removes leading lines shifts ALL lineIndexes. The only safe invariant is: no trimming of leading content.

### Key invariants for correct TOC scroll positioning

1. `captureFullPane` must return raw, untrimmed stdout so split array indexes = copy-mode absolute line numbers.
2. Navigation: `history-top \; send-keys -X -N lineIndex scroll-down` (or no scroll-down if lineIndex = 0).
3. All tmux commands chained with `\;` in a single tmux invocation (single IPC, no intermediate renders).
4. Never use `cursor-down` in place of `scroll-down` — cursor-down behavior depends on cursor_y and requires `pane_height` in the formula.
5. Never use `scroll-top` after positioning — it compounds by `pane_height - 1` extra lines.
6. Never use `goto-line` unless you can guarantee historySize is stable (it isn't when an agent is running).
7. `historySize` query in a separate shell call has ~100ms race window. Even in the same shell command, historySize can change in <1ms during active agent output. Only approaches that don't depend on historySize are race-condition-free.

## Future debugging checklist

- If Claude prompts disappear again, capture the pane with attributes (`tmux capture-pane -e -p -S - -E -`) and inspect both foreground and background styling before changing placeholder heuristics.
- If TOC selection jumps to the wrong place:
  1. Verify `captureFullPane` returns **untrimmed** stdout (no leading or trailing trim). Any trim of leading content shifts lineIndexes.
  2. Verify all tmux commands use `\;` chaining (single IPC) — separate invocations allow intermediate renders AND allow historySize to race.
  3. Verify the scroll count is exactly `lineIndex` (not `lineIndex + pane_height - 1` — that formula only applies to cursor-down, not scroll-down).
  4. Do NOT use `cursor-down` in place of `scroll-down`.
  5. Do NOT add `scroll-top` after any positioning command.
  6. Do NOT use `goto-line` — it depends on `history_size` which races with agent output.
- If a selected prompt lands below the top edge near the end of the conversation, that line is in the live pane area (lineIndex >= historySize) where scroll-down from history-top hits the live bottom and stops — expected behavior for prompts in the active pane area.
- If a double-jump / flash reappears, confirm all commands are in a single tmux invocation using `\;` — shell `;` separates them into multiple tmux client calls, allowing the server to render the intermediate history-top state.
