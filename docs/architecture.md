# mAgent — Architecture

## Technology Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| UI Framework | AppKit | Reliability and native behavior on macOS |
| Terminal | libghostty | High-performance GPU-rendered terminal; embeddable C library |
| Session management | tmux | Persistent sessions; SSH-attachable from mobile devices |
| Build system | Xcode + Swift Package Manager | Standard Apple toolchain |
| Persistence | JSON files or SQLite | Thread state, project config, settings |

## Project Structure

```
magent/
├── CLAUDE.md
├── docs/
│   ├── requirements.md
│   ├── architecture.md
│   └── libghostty-integration.md
├── Packages/
│   └── MagentModules/
│       ├── Package.swift
│       └── Sources/
│           ├── MagentCore/          # Facade re-export for app target imports
│           ├── MagentModels/        # Shared domain models and DTOs
│           ├── ShellInfra/          # Shell execution + quoting primitives
│           ├── GitCore/             # Git/worktree operations
│           ├── TmuxCore/            # tmux session management
│           ├── JiraCore/            # Jira/acli integration
│           ├── IPCCore/             # IPC request/response contracts + agent docs
│           ├── PersistenceCore/     # Settings/thread/cache persistence
│           ├── UtilityCore/         # Shared non-UI helper utilities
│           └── GhosttyBridge/       # SwiftPM wrapper around GhosttyKit
├── Magent/                          # Main app target
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   └── AppCoordinator.swift
│   ├── Services/
│   │   ├── ThreadManager.swift      # Thread lifecycle (create, archive, restore)
│   │   ├── IPCSocketServer.swift    # App-owned IPC socket server
│   │   └── UpdateService.swift      # App update flow + UI banners
│   ├── Views/
│   │   ├── ThreadList/
│   │   ├── Terminal/
│   │   ├── Settings/
│   │   └── Configuration/          # First-run setup wizard
│   └── Resources/
├── Project.swift
├── Tuist/
│   └── Package.swift
└── Libraries/
    └── GhosttyKit.xcframework       # Local Ghostty terminal binary
```

Module boundary rules:
- `MagentCore` is the facade imported by the app target and re-exports the internal package modules needed by the app.
- `MagentModels` holds shared non-UI models and CLI-facing DTOs.
- `ShellInfra` holds shell execution primitives that other package targets can depend on without pulling in higher-level services.
- `GitCore`, `TmuxCore`, and `JiraCore` isolate subsystem-specific services behind narrower dependency edges.
- `IPCCore` isolates CLI/IPC-facing request-response models and agent guidance text from the rest of the shared domain layer.
- `PersistenceCore` owns JSON/file-backed persistence for threads, settings, and caches.
- `UtilityCore` holds remaining cross-cutting non-UI helpers that do not justify their own subsystem target yet.
- `GhosttyBridge` wraps `GhosttyKit.xcframework` and is consumed as a local package product.
- The app target keeps AppKit controllers/views plus resource-backed code that depends on generated asset and string-catalog symbols.
- Extract new pure logic into package modules first; do not move resource-heavy AppKit code into SwiftPM targets until theme/localization wrappers exist.

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
When parsing combined rename payloads, treat only the first `SLUG:` line as the slug field before checking for the `EMPTY` sentinel. Multi-line model replies also include `DESC:` and `TYPE:` lines; checking the whole tail can incorrectly sanitize `SLUG: EMPTY` into the literal branch name `empty`.
Generated descriptions should stay semantically aligned with the slug and read like concrete task labels in the sidebar, not abstract nouns unless the prompt is explicitly about that concept.

### 4.3 Prompt TOC Source of Truth

Prompt TOC content is confirmation-driven, not raw-keystroke-driven. Persist per-session TOC-confirmed prompt history only after pane evidence shows the prompt is no longer just active bottom composer text.
The parser must exclude the active bottom input cluster (prompt line plus pinned status/helper rows such as model/usage lines) so draft text like `Implement {feature}` and pinned chrome like `gpt-5.4 high · ...` never enter confirmed history.
Use `tmux capture-pane -e` for TOC parsing so placeholder/draft composer text can be rejected by style as well as text: Codex placeholders are dim/grey while real submitted prompt text is normal foreground after the input marker.
Do not assume dim text always means placeholder content across agents: current Claude Code can render real submitted prompt text as dim white and gives those submitted rows a distinct non-default background, so Claude prompt filtering should treat that background as a positive signal and must not rely on dimness alone.
Treat a submitted prompt as a block, not only the marker line: include directly wrapped continuation lines that belong to the same user input, then require later non-composer pane output after that full block before the prompt becomes TOC-eligible.
When session names are renamed/migrated, re-key this confirmed prompt history together with other session-scoped maps; when sessions are removed, prune it.

### 4.4 Prompt TOC Layout + Interaction Persistence

Prompt TOC geometry is session-scoped UI state:
- Persist panel position and size per `(threadID, sessionName)` in `UserDefaults`.
- Restore size first, then restore position, and clamp both against current terminal container bounds.
- Keep minimum size fixed at `320x250` (the original default panel dimensions).

Prompt TOC visibility is shared app-scoped UI state:
- Persist a single show/hide preference in `UserDefaults`, not per controller or per session.
- When one `ThreadDetailViewController` toggles TOC visibility, broadcast that change so other open thread panels apply the same state immediately instead of waiting for relaunch/reselection.

Prompt row interaction/visual rules:
- Row hit target is the full row (not only text), so clicking anywhere in the row triggers navigation.
- Row labels can wrap up to 3 lines and then truncate.
- Apply subtle alternating row backgrounds to improve scanability without dominating the terminal UI.
- Keep the TOC drag header visually distinct from the body; a slightly darker top band helps communicate that the header is the draggable region without making the whole panel heavier.
- If the TOC was pinned to the bottom before a same-session append refresh, restore it to the bottom after repopulating rows; do not force-scroll when the user was reading older entries.
- Keep the TOC overlay frontmost in the AppKit subview order whenever terminal surfaces are attached/switched/refreshed; layer `zPosition` alone is not sufficient for mouse hit-testing against embedded Ghostty views.

Navigation behavior:
- TOC selection uses tmux copy-mode positioning (`scrollHistoryLineToTop`) so the selected prompt line is anchored at the top of the viewport whenever enough lines exist below it.
- Terminal scrollback fallback controls in the terminal panel must route through tmux copy-mode commands (`page-up`, `page-down-and-cancel`, cancel-to-bottom) instead of relying on Ghostty wheel events, because in-agent wheel handling can be captured by the running tool.
- Scroll-to-bottom FAB visibility must not depend only on Ghostty scrollbar callbacks; refresh it from tmux `#{scroll_position}` as the source of truth so the button still appears after real upward scrolls when Ghostty's scrollbar notifications lag or go missing.
- Keep tmux pane scrollbars in `modal` mode so users get a visible history indicator while using those fallback controls.

### 4.5 Project Local File Sync Paths

Projects can define repo-relative local sync paths (files or directories).

- On thread creation, configured paths are copied from repo root into the new worktree and snapshotted onto the thread.
- On thread archive, local-sync merge-back is limited to paths currently configured in project `Local Sync Paths`, and only those eligible paths are merged back from worktree to repo root (unless archive local-sync is disabled via global setting or CLI `--skip-local-sync` override).
- Merge-back is additive/safe: do not delete destination files that are missing in worktree.
- If a copy would overwrite an existing destination (including file-vs-directory collisions at intermediate paths), require explicit user choice in UI archive flows:
  - `Override`
  - `Override All`
  - `Ignore`
  - `Cancel Archive`
- CLI/non-interactive archive paths should avoid destructive overwrite prompts and skip conflicting targets by default.
- Force archive is allowed for local sync failures: continue archiving with a warning, but still keep sync non-destructive.

### 4.6 Sidebar Split View Stability

The main window's sidebar/detail `NSSplitView` structure should remain stable while switching threads.

- Create the sidebar split item and the detail/content split item once at startup.
- When the selected thread changes, swap the child view controller inside a persistent content container instead of removing/re-adding split view items.
- Recreating split view items during selection can make AppKit renegotiate divider positions, which causes visible sidebar width jumps and sidebar row reflow (for example task descriptions toggling between one and two lines).
- Restore the saved sidebar width before launch-time thread selection/detail installation begins. If startup content swaps run first, they can preserve the default width and force the sidebar to reflow a second time when the persisted width is finally applied.
- Even with a stable container, AppKit can still push the divider when a newly-installed child view's constraints resolve. Wrap each `setContent(...)` call with `preserveSidebarWidthDuringContentChange`: capture the current divider position, swap content, then call `splitView.setPosition(_:ofDividerAt:)` synchronously and once more on the next run-loop tick via `DispatchQueue.main.async`.
- While `preserveSidebarWidthDuringContentChange` is enforcing a width, do not treat `splitViewDidResizeSubviews` callbacks as user-driven resizes. AppKit can emit transient divider moves during selection/content swaps, and persisting those values will ratchet the saved sidebar width smaller over time.
- All thread rows should reserve the same description-style height, measured from the sidebar cell's typography/layout rather than hardcoded compact-vs-multiline constants, and description rows should keep a stable semibold font so selection-side effects (like unread state clearing) cannot rewrap rows between one and two lines.
- Keep trailing marker layout width-stable by reserving a fixed status slot and keeping pin as the rightmost marker. Marker visibility changes must not change available description width.
- Refit the sidebar outline from the scroll view's visible clip width when sidebar width changes; `NSOutlineView` can retain a stale frame width across startup restores, which leaves trailing controls misaligned until a manual resize. Still avoid forcing `noteHeightOfRows(...)` on every layout pass; that introduced visible lag/flicker during divider drags.

### 4.7 Release-Gated Local Features

Some features need to stay in the codebase before they are ready to ship. Those features are release-gated with dedicated `FEATURE_*` active compilation conditions in `Project.swift`.

- Add the flag only to the configurations that should expose the feature.
- Keep the availability check centralized in an app-level helper so AppKit/UI code can use one source of truth.
- Release builds should hide the related UI and skip the related background automation instead of showing dead controls.
- If a feature is visible in debug-only Settings surfaces, annotate it with `Debug builds only` so developers can see immediately that it is not part of release builds.
- `FEATURE_JIRA` is the current example: Debug builds expose Jira settings/actions, while Release builds hide them and stub out Jira-specific UI/runtime hooks.

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

## Review Button Agent Selection

- The top-right Review button reuses the same active-agent menu model as `+` buttons so the available agents stay aligned with `AppSettings.activeAgents`.
- Unlike `+`, the Review button must not offer `Terminal`; every review launch should open an agent tab with the configured review prompt.
- Option-click on Review should bypass the menu and launch immediately with the resolved default agent for the thread's project, matching the quick-create behavior used by project and tab `+` controls.

## Session Reopen / Recovery

- `ThreadDetailViewController` always calls `ThreadManager.recreateSessionIfNeeded(...)` before attaching a tab so reopened views can reuse a live tmux session or recover a missing/mismatched one.
- Keep the fast path cheap: if the tmux session already exists and matches the expected thread/worktree context, return before doing slower resume bookkeeping such as agent conversation-ID refresh.
- The loading overlay's secondary detail line is reserved for non-routine recovery actions reported by session recreation. Normal agent startup should continue to show only `Starting agent...`.

## tmux Session Ownership

Each tmux session created by Magent is tagged with `MAGENT_THREAD_ID` (the owning thread's UUID) via `tmux set-environment`. This tag is set in:
- `ThreadManager+ThreadLifecycle.swift` — initial thread creation (both regular and main threads)
- `ThreadManager+TabManagement.swift` — new tab creation
- `ThreadManager+SessionRecreation.swift` — session recreation/recovery

**Why this matters**: Worktree names are reused when a thread is archived and a new thread is opened on the same branch/worktree name. Without ownership tracking, the old stale tmux session would be adopted by the new thread, restoring the previous agent session. The fix in `isValidExistingSession(...)` checks `MAGENT_THREAD_ID` first; if absent (old sessions), it falls back to comparing `session_created` timestamp against `thread.createdAt` — sessions older than the thread are rejected.
## Platform Scope

- **macOS**: Full experience — sidebar + terminal + tabs, keyboard-driven
