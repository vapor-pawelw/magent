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

## Multi-line prompt capture

When a user submits a multi-line prompt (e.g. a context-setting block with separate paragraphs), Claude's TUI renders the continuation lines with ANSI color codes and separates paragraphs with bare blank lines (`\n\n` — no ANSI). The parser collects continuation lines via `promptContinuationText` and the surrounding loop in `parsePromptCandidates`.

**Two gotchas fixed:**

1. **Continuation lines have ANSI.** Claude's TUI wraps every line of a submitted prompt in `\e[38;2;255;255;255m…\e[39m` (bright-white foreground/reset). The original `guard !rawText.contains("\u{001B}")` in `promptContinuationText` rejected every one of them. Removed: `plainText` (already ANSI-stripped) is used for all structural checks; the indentation requirement (≥2 leading spaces) is the guard against accidentally capturing agent output, which starts at column 0.

2. **Blank paragraph separators.** Multi-paragraph prompts separate blocks with bare `\n\n`. In the parsed line array these become entries whose `plainText.trimmed` is empty → the old loop exited immediately. The continuation loop now does a one-step lookahead when it hits a blank line: if the next line would be a valid continuation (2+ spaces, no marker), the blank is bridged (stored as `""`) and collection continues; otherwise the loop exits. The `""` entries are filtered out for `displayPromptText` but kept in `fullPromptText` (joined with `"\n"`) so the slug-generation agent receives the full paragraph structure.

**Why this is safe against false positives:**
- Agent response lines (`⏺ …`) start at column 0 → fail the ≥2-space guard → break the chain immediately.
- Tool result lines (`  ⎿ …`) have 2+ spaces but always follow a `⏺` line which already broke the chain.
- A blank line is only bridged if the line after it also passes the continuation check. If the blank is followed by a column-0 agent line, the lookahead fails and the loop exits.

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

Right-clicking a TOC entry shows a context menu with "AI Rename…". This opens the AI Rename sheet (`AIRenameSheetController`) pre-filled with the selected prompt text. The sheet provides a multi-line editor, a picker with the last 10 recent prompts, and checkboxes to selectively rename icon, description, and/or branch name. On submit, it calls `renameThreadFromPrompt` with the selected options — bypassing all first-prompt eligibility gates (`didAutoRenameFromFirstPrompt`, `isAutoGenerated`, agent-process-detection) so it can be triggered at any time.

**Visual feedback:** `renameThreadFromPrompt` adds the thread to `autoRenameInProgress` before the AI call and removes it (via `defer`) when it exits. This drives the same sidebar pulse animation as the auto-rename path. Without this, the user sees nothing for up to 60 seconds while the agent call is in-flight.

**Agent fallback:** Uses `slugGenerationAgentOrder` (same as auto-rename), which always appends `.claude` as a final fallback even when no trackable agent (Claude/Codex) is configured as active. Since Claude is a prerequisite for the app, this guarantees at least one attempt.

**Slug-generation `claude -p` flags:** The background `claude -p` call that generates the slug uses `--tools ""`, `--setting-sources ""`, and `< /dev/null`. This is critical: without `--setting-sources ""`, Claude loads the project's CLAUDE.md/AGENTS.md as system-prompt context, regularly causing timeouts. Without `< /dev/null`, the CLI inherits the GUI app's invalid stdin fd, which can cause hangs or failures (the CLI waits ~3 s for stdin data before proceeding). The flags keep the system prompt minimal and stdin clean so haiku responds in a few seconds.

**Error handling:** If all agents fail, throws `nameGenerationFailed(diagnostic:)`. The banner includes a specific failure reason (e.g. timeout, CLI exit code + stderr, empty output, or slug parse failure) instead of a generic message, aiding diagnosis.

## Five auto-rename trigger paths

There are five independent paths that can fire auto-rename for a thread's first prompt:

1. **Early path (launch sheet):** `createThread` fires `autoRenameThreadAfterFirstPromptIfNeeded` in an unstructured `Task` immediately after the tmux session is created, using the prompt captured from the launch sheet. This path bypasses the agent-process-detection gate because the agent is not yet running at that point — the prompt is already known from the sheet. It typically completes before the agent has even started processing.

2. **Draft path (draft tab):** When a thread is created with the "Draft" checkbox checked, the prompt is not submitted to an agent — it's stored as a `PersistedDraftTab`. `ThreadListViewController+SidebarActions` calls `autoRenameThreadFromDraftPromptIfNeeded` (awaited, not fire-and-forget) immediately after adding the draft tab. This path uses `performAutoRename` with `requireSession: nil` (no tmux session exists yet) and `prefixDraft: true` to prepend "DRAFT: " to the generated description. When the draft is later consumed ("Start Agent") or discarded, `stripDraftDescriptionPrefixIfNeeded` removes the prefix if no draft tabs remain.

3. **TOC path (confirmed pane):** Fires when the prompt TOC parser in `ThreadDetailViewController+PromptTOC` confirms a new submitted prompt in the pane. This path goes through the agent-process-detection gate. **Requires the thread to be selected** — `ThreadDetailViewController` must exist for TOC parsing to run.

4. **IPC path (CLI injection):** Fires from `IPCCommandHandler.handleSendPrompt` when a prompt is injected via CLI/IPC (`sendPrompt` command). After submitting the prompt, the handler appends it to the session's `submittedPromptsBySession` via `appendToSubmittedPromptHistory`, which immediately triggers `autoRenameThreadAfterFirstPromptIfNeeded` if history grew and the thread hasn't been renamed yet. This covers workflows where a CLi agent sends prompts to Magent threads; auto-rename fires immediately without waiting for user interaction or bell events.

5. **Bell path (non-visible threads):** Fires from `checkForAgentCompletions` in `ThreadManager+AgentState` when a bell event arrives for a thread that hasn't been auto-renamed yet. Uses `triggerAutoRenameFromBellIfNeeded` (in `ThreadManager+Rename`) which captures pane content via `tmux.capturePane`, extracts the first prompt with a lightweight marker-based parser (`extractFirstPromptFromPane`), verifies an agent is running, and calls `autoRenameThreadAfterFirstPromptIfNeeded`. This covers threads that were never displayed — e.g. created, then the user switched to another thread before the agent finished its first turn. Spawned as a fire-and-forget `Task` to avoid blocking the completion notification flow.

**Deduplication:** All five paths share the `didAutoRenameFromFirstPrompt` flag. Whichever fires first and succeeds sets the flag; the other paths see it set and exit early. `autoRenameInProgress` prevents concurrent AI calls from multiple paths running simultaneously.

**Shared implementation:** Paths 1–2 (early and draft) and paths 3–4 (TOC and bell, which both call `autoRenameThreadAfterFirstPromptIfNeeded`) all converge on the private `performAutoRename(threadId:requireSession:prompt:prefixDraft:)` helper. The only differences are whether a tmux session is required and whether the "DRAFT: " prefix is applied.

**Rename payload cache:** All paths check `promptRenameResultCache` (keyed by `threadId + normalizedPrompt`) before calling the agent. If an earlier path already cached a result, later paths reuse it instantly. See architecture.md §4.2 for details.

**Lightweight prompt extractor vs full TOC parser:** The bell path uses `extractFirstPromptFromPane` — a simplified version of the TOC parser that scans for `❯`/`›` markers and collects multiline continuation lines (2+ leading spaces). It does not handle ANSI stripping, placeholder detection, or bottom-cluster exclusion because it only needs the first prompt text for slug generation, not a full TOC. The full TOC parser remains in `ThreadDetailViewController+PromptTOC` for display purposes.

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

## Refresh lifecycle after session restore

When a session is recreated (dead-session recovery, idle-eviction restore, worktree recovery), `selectTerminalTab` takes the slow path through `ensureSessionPrepared` → `selectPreparedTab`. `selectPreparedTab` calls `schedulePromptTOCRefresh()` immediately, but the tmux pane may not have rendered its full scrollback yet — `captureFullPane` can return an empty pane, producing 0 entries. A second delayed refresh (0.5s) is scheduled after recreation/eviction to pick up the content once the pane has settled. Without this, the TOC shows "0" until the user manually switches tabs.

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
