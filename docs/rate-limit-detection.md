# Rate Limit Detection

Magent monitors agent terminal sessions for rate-limit messages and surfaces them in the UI. This helps you see at a glance which agents are blocked and when they'll be available again.

## How It Works

Every 5 seconds, Magent reads the last portion of each agent terminal pane and looks for rate-limit phrases (e.g., "rate limited", "too many requests", "try again in 35m", "resets 4pm"). When found, it parses the reset time and displays a countdown in the sidebar and on affected tabs.

### Scan Frequency

- **Active session** (currently visible tab): scanned every monitor tick (~5s).
- **Background sessions**: scanned at most once every 15 seconds to reduce CPU usage.

Pane content is also cached for up to 5 seconds and shared across all periodic checks (busy detection, waiting-for-input detection, rate-limit scanning), so multiple checks in the same tick reuse a single `tmux capture-pane` subprocess result.

### Agent-Specific Parsing

- **Codex**: Detection is scoped to the latest pane block after the last separator line (`────…`) when present, to avoid stale matches from older output. If no separator is present, Magent scans the full captured tail.
- **Claude**: Detection does not rely on separator scoping for the interactive limit menu. When the pane shows the numbered wait/switch choices (for example `1. Stop and wait for limit to reset` and `2. Switch to Pro`), Magent treats that menu as an active rate-limit signal and scans the choice line plus nearby context above it to find and parse the reset deadline (for example, `You've hit your limit · resets Mar 6 at 10am`). This still works when the latest visible block shows only the choices and reset line, without repeating broader "rate limit" wording.

### Mandatory Reset Time

Detection only triggers when a **concrete reset time** can be parsed from the terminal text. If the message contains rate-limit keywords but no parseable time (e.g., just "rate limited" with no "resets at..." or "try again in..."), Magent ignores it. This prevents false positives from code discussions or agent output that mentions rate limits without being blocked.

### Fingerprint Cache (Persistence)

When Magent first sees a rate-limit message, it computes a **fingerprint** (normalized text of the rate-limit lines) and stores the fingerprint along with the **concrete reset time** to disk (`rate-limit-cache.json`).

Magent also stores a per-agent ignore list for fingerprints you manually dismiss (`ignored-rate-limit-fingerprints.json`).

On subsequent checks:
- **Same fingerprint, reset time still in the future** — uses the stored time (no re-parsing, no drift)
- **Same fingerprint, reset time in the past** — rate limit expired, skips detection
- **New fingerprint** — parses fresh, stores the new mapping

This persistence means:
- Restarting Magent doesn't re-detect stale messages as new rate limits
- Session recreation or app relaunch keeps the same concrete reset deadline for the same fingerprint instead of recalculating from freshly captured text
- Overnight sessions with old "resets 8 PM" text won't incorrectly show a countdown for today's 8 PM — the cached time points to yesterday's 8 PM, which is already expired

### Bare-Time Cap (8 Hours)

When a rate-limit message contains only a clock time without a date (e.g., "resets 4pm" vs. "resets Mar 6th, 2026 1:17 AM"), Magent caps the computed reset at **8 hours from now**. If the parsed time would be further out, it's treated as stale and discarded.

This cap does **not** apply when the message includes:
- A full date (month name, year)
- A day of the week (Mon, Wed, etc.) or "tomorrow"
- A relative duration ("try again in 35m") — these are always anchored to the current time

### Global Rate Limits

Rate limits are tracked **per agent type** (Claude, Codex), not per session. When one session detects a Claude rate limit, the same status is shown across all Claude sessions since rate limits apply at the account level.

That propagation is applied to the per-tab/thread markers too, not just the status-bar summary. Once any Claude or Codex session detects a concrete limit, every tab using that agent gets the red hourglass marker until the limit expires or is lifted manually.

Claude's prompt-only blocker follows the same rule: if any Claude session is currently showing the interactive wait/switch prompt **and** the pane's reset time is still in the future, Magent mirrors a prompt-based rate-limit marker onto all Claude tabs for that tick so the thread list, tab bar, and cleanup protection stay in sync. If the reset time has expired (e.g., the user opened `/rate-limit-options` after the limit lifted), the prompt is treated as stale — no markers are applied and the session is treated as idle.

Once Magent has matched a non-ignored rate-limit fingerprint and anchored a concrete `resetAt`, that rate limit stays active until the timer expires or you lift it manually.
Newer pane output such as `/status` must not auto-clear an already-anchored limit just because the latest block no longer shows the original rate-limit text.

## UI Indicators

- **Bottom status bar**: Shows a global rate-limit countdown (e.g. "⏳ Claude: 19m · Codex: 3h 5m") on the right side. Right-click offers:
  - Lift Claude/Codex limit now
  - Lift + ignore currently visible fingerprints for Claude/Codex (so only future/new messages are tracked)
- **Thread list**: Hourglass icon on threads with active rate limits:
  - **Red hourglass** (⏳): Direct rate limit detected in this thread's session(s)
  - **Orange hourglass** (⏳): Propagated from another session/agent (global account limit, but detected elsewhere)
- **Tab bar**: Same hourglass distinction for individual rate-limited tabs
- **Tooltips**: Show the exact reset time (e.g., "Rate limit reached. Resets Mar 2, 2026 at 8:00 PM") and whether the limit is direct or propagated
- **Notifications**: Optional system notification when a rate limit lifts (configurable in Settings)

## Settings

Rate limit tracking can be toggled in **Settings > Agents > Agent Behavior**:
- **Track agent rate limits** — master toggle for the tracking system
- **Show system notification when rate limit is lifted** — post a system notification when countdown reaches zero (Settings > Notifications)
- **Play sound when rate limit is lifted** — optional lift sound

When tracking is disabled, the app no longer parses reset times or shows countdowns. However, rate-limit icons still appear temporarily while the agent is at a rate-limit prompt — they disappear automatically once the conversation resumes. The fingerprint cache continues to be populated in the background so that re-enabling tracking handles stale messages correctly.
