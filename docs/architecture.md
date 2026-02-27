# Magent — Architecture

## Technology Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| UI Framework | AppKit | Reliability and native behavior on macOS |
| Terminal | libghostty | High-performance GPU-rendered terminal; embeddable C library |
| Session management | tmux | Persistent sessions; SSH-attachable from mobile devices |
| Build system | Xcode + Swift Package Manager | Standard Apple toolchain |
| Persistence | JSON files or SQLite | Thread state, project config, settings |

## Project Structure (Planned)

```
magent/
├── CLAUDE.md
├── docs/
│   ├── requirements.md
│   ├── architecture.md
│   └── libghostty-integration.md
├── Magent/                          # Main app target
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   ├── SceneDelegate.swift
│   │   └── AppCoordinator.swift
│   ├── Models/
│   │   ├── Thread.swift             # Thread model (worktree + sessions)
│   │   ├── Project.swift            # Git project configuration
│   │   ├── Tab.swift                # Tab within a thread
│   │   └── AppSettings.swift        # User settings/preferences
│   ├── Services/
│   │   ├── GitService.swift         # Git/worktree operations
│   │   ├── TmuxService.swift        # tmux session management
│   │   ├── ThreadManager.swift      # Thread lifecycle (create, archive, restore)
│   │   ├── PersistenceService.swift # Save/load thread state
│   │   └── DependencyChecker.swift  # Check/install tmux, etc.
│   ├── Views/
│   │   ├── ThreadList/
│   │   ├── TerminalPane/
│   │   ├── TabBar/
│   │   ├── Settings/
│   │   └── Configuration/          # First-run setup wizard
│   └── Resources/
├── Magent.xcodeproj/
└── Libraries/
    └── libghostty/                  # Ghostty terminal library (vendored or submodule)
```

## Key Architecture Decisions

### 1. Native AppKit

Magent is now macOS-only and uses AppKit directly. This gives us:
- Native platform behavior without Catalyst bridging layers
- Reliable layout and interaction handling (vs SwiftUI quirks on Mac)
- Full access to AppKit APIs without conditional compilation

### 2. libghostty Integration

Ghostty is a GPU-accelerated terminal emulator. `libghostty` is the core library that handles:
- Terminal emulation (VT parsing, state machine)
- GPU rendering via Metal
- Input handling

Integration approach:
- Build libghostty from Ghostty source (Zig build system)
- Create a Swift/C bridging layer
- Embed the terminal view in AppKit view hierarchy

### 3. tmux as Session Layer

Every terminal in the app runs inside a tmux session. This provides:
- Session persistence across app restarts
- SSH attachment from remote devices (iPhone via Terminus)
- Multiple windows/panes if needed

Session naming convention: `magent-<project>-<thread-id>[-tab-<n>]`

### 4. Thread ↔ Worktree Mapping

Each thread is 1:1 with a git worktree:
- Creating a thread → `git worktree add`
- Archiving a thread → `git worktree remove` + `git worktree prune`
- Thread state stored separately from git (JSON/SQLite)

### 4.1 Worktree Rename Compatibility

Thread rename updates branch/worktree/session names, but running agent processes cannot have their cwd/env rewritten in-place.
To keep active sessions stable, rename creates a compatibility symlink from the old worktree path to the new path and updates tmux session environment for future shells/panes.

### 5. Persistence Model

Thread state persisted as JSON in app's Application Support directory:

```json
{
  "threads": [
    {
      "id": "uuid",
      "projectId": "uuid",
      "worktreePath": "/path/to/worktree",
      "branchName": "feature/my-feature",
      "tmuxSessions": ["magent-proj-abc123", "magent-proj-abc123-tab-2"],
      "createdAt": "2026-02-25T12:00:00Z",
      "archived": false
    }
  ],
  "projects": [
    {
      "id": "uuid",
      "name": "ios-apps",
      "repoPath": "/Users/pawelw/xcode/ios-apps",
      "worktreesPath": "/Users/pawelw/xcode/ios-apps-worktrees"
    }
  ]
}
```

## Component Interactions

```
User Action (+ button)
        │
        ▼
  ThreadManager
        │
        ├──► GitService.createWorktree()
        │
        ├──► TmuxService.createSession(workdir)
        │
        ├──► TmuxService.runCommand(agentCmd)
        │
        ├──► TerminalView.connect(tmuxSession)
        │
        └──► PersistenceService.save()
```

## Platform Scope

- **macOS**: Full experience — sidebar + terminal + tabs, keyboard-driven
