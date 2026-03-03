# Rate Limit Detection

Magent monitors agent terminal sessions for rate-limit messages and surfaces them in the UI. This helps you see at a glance which agents are blocked and when they'll be available again.

## How It Works

Every few seconds, Magent reads the last portion of each agent terminal pane and looks for rate-limit phrases (e.g., "rate limited", "too many requests", "try again in 35m", "resets 4pm"). When found, it parses the reset time and displays a countdown in the sidebar and on affected tabs.

### Mandatory Reset Time

Detection only triggers when a **concrete reset time** can be parsed from the terminal text. If the message contains rate-limit keywords but no parseable time (e.g., just "rate limited" with no "resets at..." or "try again in..."), Magent ignores it. This prevents false positives from code discussions or agent output that mentions rate limits without being blocked.

### Fingerprint Cache (Persistence)

When Magent first sees a rate-limit message, it computes a **fingerprint** (normalized text of the rate-limit lines) and stores the fingerprint along with the **concrete reset time** to disk (`rate-limit-cache.json`).

On subsequent checks:
- **Same fingerprint, reset time still in the future** — uses the stored time (no re-parsing, no drift)
- **Same fingerprint, reset time in the past** — rate limit expired, skips detection
- **New fingerprint** — parses fresh, stores the new mapping

This persistence means:
- Restarting Magent doesn't re-detect stale messages as new rate limits
- Overnight sessions with old "resets 8 PM" text won't incorrectly show a countdown for today's 8 PM — the cached time points to yesterday's 8 PM, which is already expired

### Bare-Time Cap (8 Hours)

When a rate-limit message contains only a clock time without a date (e.g., "resets 4pm" vs. "resets Mar 6th, 2026 1:17 AM"), Magent caps the computed reset at **8 hours from now**. If the parsed time would be further out, it's treated as stale and discarded.

This cap does **not** apply when the message includes:
- A full date (month name, year)
- A day of the week (Mon, Wed, etc.) or "tomorrow"
- A relative duration ("try again in 35m") — these are always anchored to the current time

### Global Rate Limits

Rate limits are tracked **per agent type** (Claude, Codex), not per session. When one session detects a Claude rate limit, the same status is shown across all Claude sessions since rate limits apply at the account level.

When any session detects that its agent has resumed work (producing output after being blocked), the rate limit is cleared globally for that agent.

## UI Indicators

- **Sidebar toolbar**: Shows a summary like "Rate limits: Claude: 19m · Codex: 3h 5m"
- **Thread list**: Red hourglass icon on threads where all agent tabs are rate-limited
- **Tab bar**: Red hourglass on individual rate-limited tabs
- **Tooltips**: Show the exact reset time (e.g., "Rate limit reached. Resets Mar 2, 2026 at 8:00 PM")
- **Notifications**: Optional system notification when a rate limit lifts (configurable in Settings)

## Settings

Rate limit tracking can be toggled in **Settings > Agents**:
- **Track agent rate limits** — master toggle for the tracking system
- **Notify when rate limit is lifted** — system notification when countdown reaches zero (Settings > Notifications)
- **Sound** — optional sound for the lift notification

When tracking is disabled, the app no longer parses reset times or shows countdowns. However, rate-limit icons still appear temporarily while the agent is at a rate-limit prompt — they disappear automatically once the conversation resumes. The fingerprint cache continues to be populated in the background so that re-enabling tracking handles stale messages correctly.
