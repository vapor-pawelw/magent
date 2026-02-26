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
- `tmux`

## Run

1. Open `Magent.xcodeproj` in Xcode.
2. Build and run the `Magent` app target.
3. In app settings, add your repositories and choose active agents.

## License

This project is licensed under **PolyForm Noncommercial 1.0.0**.

- You can use, fork, and modify it for noncommercial use.
- Selling this software or commercializing forks is not allowed.

See [LICENSE](./LICENSE) for full terms.
