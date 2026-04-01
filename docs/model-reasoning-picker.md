# Model & Reasoning Picker

Per-agent model and reasoning level selection when starting new threads or tabs.

## Overview

Users can pick a model and reasoning level from the agent launch sheet before starting a new thread or tab. Each agent type (Claude, Codex) maintains its own independent last-selected values. Selections persist across sessions and are reused by fast-path creation (Option+click, context menu).

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

## Persistence: Per-Agent Last Selection

Each agent independently remembers its last-selected model and reasoning level:

```swift
struct AgentSessionConfig: Codable, Equatable {
    var claudeModel: String?       // nil = "Auto"
    var codexModel: String?        // nil = "Auto"
    var claudeEffort: String?      // nil = "Auto"
    var codexReasoning: String?    // nil = "Auto"
}
```

Stored in `AgentLastSelectionStore` (or equivalent persistence). **Not stored per-thread** — model/reasoning is only used at fresh-start time. Resume inherits from the agent session itself.

### Switching Agent in Picker

Switching between Claude and Codex in the agent picker swaps the displayed model/reasoning to that agent's own last-selected values. **No cross-agent mapping** — each agent's selections are fully independent.

### Stale Selection Recovery

If the user's last-selected model no longer exists in the current JSON (after a remote update), silently fall back to "Auto."

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
