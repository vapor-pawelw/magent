# Magent

Magent is a native macOS app for managing git worktrees as thread-like work sessions, each with embedded terminal tabs.

## What it does

- Creates and manages git worktrees per thread
- Opens terminal/chat tabs per thread
- Supports Claude, Codex, or Terminal-only tabs
- Persists threads and restores previous context

## Requirements

- macOS 14+
- Xcode 26+
- [mise](https://mise.jdx.dev/) (for Tuist)
- `tmux`

## Run

1. Generate the Xcode project: `mise x -- tuist generate --no-open`
2. Open the generated `Magent.xcworkspace` in Xcode.
3. Build and run the `Magent` scheme.
4. In app settings, add your repositories and choose active agents.

## License

This project is licensed under **PolyForm Shield 1.0.0**.

See [LICENSE](./LICENSE) for full terms.
