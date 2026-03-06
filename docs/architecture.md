# mAgent — Architecture

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

mAgent is now macOS-only and uses AppKit directly. This gives us:
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

Thread rename updates branch/session names, but running agent processes cannot have their cwd/env rewritten in-place.
The underlying worktree directory is not moved. To keep active sessions stable, rename creates a compatibility symlink from the new thread-name path to the existing worktree path and updates tmux session environment for future shells/panes.

### 4.2 Prompt-Based Rename Reuse

Manual `Rename...` from the non-main thread context menu reuses the same model payload path as first-prompt auto-rename so branch slug generation, task description generation, and icon suggestion stay behaviorally aligned.
This manual path intentionally skips first-prompt eligibility gates (for example "already auto-renamed") so users can explicitly request a regenerated name/description/icon at any time.

### 4.3 Prompt TOC Source of Truth

Prompt TOC content is confirmation-driven, not raw-keystroke-driven. Persist per-session TOC-confirmed prompt history only after pane evidence shows the prompt is no longer just active bottom composer text.
The parser must exclude the active bottom input cluster (prompt line plus pinned status/helper rows such as model/usage lines) so draft text like `Implement {feature}` and pinned chrome like `gpt-5.4 high · ...` never enter confirmed history.
When session names are renamed/migrated, re-key this confirmed prompt history together with other session-scoped maps; when sessions are removed, prune it.

### 4.4 Prompt TOC Layout + Interaction Persistence

Prompt TOC geometry is session-scoped UI state:
- Persist panel position and size per `(threadID, sessionName)` in `UserDefaults`.
- Restore size first, then restore position, and clamp both against current terminal container bounds.
- Keep minimum size fixed at `320x250` (the original default panel dimensions).

Prompt row interaction/visual rules:
- Row hit target is the full row (not only text), so clicking anywhere in the row triggers navigation.
- Row labels can wrap up to 3 lines and then truncate.
- Apply subtle alternating row backgrounds to improve scanability without dominating the terminal UI.

Navigation behavior:
- TOC selection uses tmux copy-mode positioning (`scrollHistoryLineToTop`) so the selected prompt line is anchored at the top of the viewport whenever enough lines exist below it.

### 4.4 Project Local File Sync Paths

Projects can define repo-relative local sync paths (files or directories).

- On thread creation, configured paths are copied from repo root into the new worktree.
- On thread archive, configured paths are merged back from worktree to repo root before worktree removal.
- Merge-back is additive/safe: do not delete destination files that are missing in worktree.
- If a copy would overwrite an existing destination (including file-vs-directory collisions at intermediate paths), require explicit user choice in UI archive flows:
  - `Override`
  - `Override All`
  - `Ignore`
  - `Cancel Archive`
- CLI/non-interactive archive paths should avoid destructive overwrite prompts and skip conflicting targets by default.

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
