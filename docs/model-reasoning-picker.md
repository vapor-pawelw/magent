# Model & Reasoning Picker

Per-agent model and reasoning level selection when starting new threads or tabs.

## Overview

Users can pick a model and reasoning level from the agent launch sheet before starting a new thread or tab. Each agent type (Claude, Codex) maintains its own last-selected model, and reasoning is remembered per model (not per agent type). Selections persist across sessions and are reused by fast-path creation (Option+click, context menu).

## Data Source: `agent-models.json`

A JSON file defines available models and reasoning levels per agent. The file lives in two places:

- **Bundled resource** — `config/agent-models.json` in the app bundle (compiled from repo). Serves as the hardcoded fallback.
- **Remote** — `https://raw.githubusercontent.com/vapor-pawelw/mAgent/main/config/agent-models.json`. Fetched on app launch and cached locally in Application Support.
- **Local cache** — `~/Library/Application Support/Magent/agent-models.json`. Updated from remote; read at runtime. Falls back to bundled resource if missing or corrupt.

### JSON Structure

```json
{
  "version": 1,
  "agents": {
    "claude": {
      "models": [
        { "id": "opus", "label": "Opus" },
        { "id": "sonnet", "label": "Sonnet" },
        { "id": "haiku", "label": "Haiku" }
      ],
      "reasoningLevels": ["low", "medium", "high", "max"]
    },
    "codex": {
      "models": [
        { "id": "gpt-5.4", "label": "GPT 5.4" },
        { "id": "gpt-5.4-mini", "label": "GPT 5.4 Mini" }
      ],
      "reasoningLevels": ["low", "medium", "high", "xhigh"]
    }
  }
}
```

- **Agent-level `reasoningLevels`** — default reasoning options for all models under that agent.
- **Per-model `reasoningLevels` override** — optional. When present on a model object, replaces the agent-level list for that model. Example:
  ```json
  { "id": "gpt-5.1-codex-mini", "label": "GPT 5.1 Codex Mini", "reasoningLevels": ["medium", "high"] }
  ```

### Remote Fetch Strategy

- **On app launch**: fetch remote JSON, update local cache if newer.
- **When showing launch sheet**: re-fetch if >10 minutes since last fetch.
- **On fetch failure**: silently use local cache (or bundled fallback if no cache).
- **`version` field**: reserved for future schema migrations. Current version: 1.

## Persistence: Per-Model Last Selection

Each agent independently remembers its last-selected model. Reasoning level is remembered **per model** (not just per agent), so switching between e.g. Opus and Sonnet restores each model's own last-used reasoning level.

Storage keys in `agent-last-selections.json`:
- `model:<agent>` — e.g. `model:claude` → `"opus"`
- `reasoning:<agent>:<model>` — e.g. `reasoning:claude:opus` → `"high"`
- `reasoning:<agent>` — fallback key when model is `nil` (Auto)

Stored in `AgentLastSelectionStore`. **Not stored per-thread** for normal live sessions — model/reasoning is only used at fresh-start time, and resume inherits from the agent session itself.

Draft tabs are the exception: if the user checks `Draft` in the launch sheet, the selected model and reasoning are persisted alongside the saved prompt so `Start Agent` later launches with the same explicit configuration. Missing values remain `nil` and mean `Auto`, which keeps older persisted drafts backward-compatible.

The `Draft` checkbox state itself is also persisted with the saved launch-sheet draft, so reopening the sheet restores whether that prompt was meant to stay parked or launch immediately. The checkbox updates live while editing the sheet, which keeps the saved draft state aligned with what the user sees.

### Switching Agent or Model in Picker

Switching between Claude and Codex in the agent picker swaps the displayed model/reasoning to that agent's own last-selected values. **No cross-agent mapping** — each agent's selections are fully independent.

Switching models within the same agent restores that model's own last-used reasoning level. For example, if you set Claude Opus to "High" and Sonnet to "Low", switching between models in the picker restores each one's setting.

### Stale Selection Recovery

If the user's last-selected model no longer exists in the current JSON (after a remote update), silently fall back to "Auto."

When a new thread or agent tab is created without an explicit custom title, Magent keeps the default title focused on the agent name and appends a single suffix for any visible model label plus reasoning. Built-in reasoning labels are abbreviated to `L`, `M`, `H`, `xH`, and `Max`; any other value is left as-is.

## UI: Launch Sheet

Type, Model, and Reasoning pickers share a **single row** in `AgentLaunchPromptSheetController`:

```
Type [picker]  Model [picker]  Reasoning [picker]
```

The launch sheet uses a wider default content width so the three pickers have enough room to stay readable on one line without crowding the prompt field below.

- **Model picker**: "Auto" + models from JSON for the selected agent.
- **Reasoning picker**: "Auto" + reasoning levels. Items update when:
  - Agent changes (load that agent's reasoning levels).
  - Model changes, if the selected model has a per-model `reasoningLevels` override.

Model and Reasoning pickers are **hidden** (individually, not the whole row) when agent is `.custom` or Terminal or Web.

"Auto" means no flags are passed — the agent uses its own configured default.

### Fast Path (Option+click / Context Menu)

Uses last-selected model + reasoning for the relevant agent. No sheet shown. Equivalent to accepting the sheet with last-used values.

### Draft Tabs

Draft tabs reuse the same picker semantics as the launch sheet:

- The draft editor shows `Model` and `Reasoning` pickers with the same `Auto` behavior.
- Changing the agent swaps the visible model/reasoning choices to that agent's own remembered values.
- Starting the draft later passes the persisted explicit selections into normal agent-tab creation, so the launched session matches the draft sheet state instead of re-reading the current global last-used values.

## Command Building

Flags are appended in `freshAgentCommand` only when the selection is not "Auto":

### Claude

```
claude --model <id> --effort <level>
```

- `--model` omitted when "Auto"
- `--effort` omitted when "Auto"

### Codex

```
codex -m <id> -c model_reasoning_effort=<level>
```

- `-m` omitted when "Auto"
- `-c model_reasoning_effort=...` omitted when "Auto"

### Resume

No model/reasoning flags passed on resume. The agent session retains its own state.

### Custom Agent

Model and reasoning pickers are hidden. No flags appended. Custom agents manage their own configuration via `customAgentCommand`.

## New Types (MagentModels)

```swift
/// Decoded from agent-models.json
struct AgentModelsManifest: Codable {
    let version: Int
    let agents: [String: AgentModelConfig]
}

struct AgentModelConfig: Codable {
    let models: [AgentModel]
    let reasoningLevels: [String]
}

struct AgentModel: Codable {
    let id: String
    let label: String
    let reasoningLevels: [String]?  // overrides agent-level when present
}
```

## File Locations

| Concern | Path |
|---------|------|
| Source JSON (repo) | `config/agent-models.json` |
| Bundled resource | Embedded in app bundle via Tuist resource |
| Local cache | `~/Library/Application Support/Magent/agent-models.json` |
| Remote URL | `https://raw.githubusercontent.com/vapor-pawelw/mAgent/main/config/agent-models.json` |
| Persistence (last selection) | `AgentLastSelectionStore` (existing pattern) |
| Launch sheet UI | `AgentLaunchPromptSheetController` |
| Command building | `ThreadManager+Helpers.swift` (`freshAgentCommand`) |
