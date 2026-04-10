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
│   │   ├── AgentModelsService.swift # Agent model/reasoning manifest (load, cache, remote refresh)
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
- `MagentModels` holds shared non-UI models and CLI-facing DTOs, including `AgentModelsManifest` (Codable types for the model/reasoning picker manifest).
- `ShellInfra` holds shell execution primitives that other package targets can depend on without pulling in higher-level services.
- `GitCore`, `TmuxCore`, and `JiraCore` isolate subsystem-specific services behind narrower dependency edges.
- `IPCCore` isolates CLI/IPC-facing request-response models and agent guidance text from the rest of the shared domain layer.
- `PersistenceCore` owns JSON/file-backed persistence for threads, settings, caches, and last-resort backup/restore support. `loadSettings()` uses an in-memory cache (invalidated on every `saveSettings()` call) to avoid repeated disk reads — it is called dozens of times per polling cycle. `debouncedSaveActiveThreads(_:)` coalesces rapid thread-state saves within a 300 ms window for non-critical state changes (dirty flags, completion markers); critical saves (archive, rename, thread creation) still use the synchronous `saveActiveThreads(_:)`.
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

### 4.1 Worktree Name Stability

Thread/worktree names are permanent — set once at creation time (auto-generated pokemon name or explicit CLI `--name`) and never changed. Rename operations (`auto-rename-thread`, `rename-branch`, context menu rename, first-prompt auto-rename) only change the **git branch name**; the thread name, worktree directory, and tmux session names are unaffected.

When a branch is renamed, stacked threads whose base-branch references the old name are automatically retargeted to the new branch name (both `thread.baseBranch` and `WorktreeMetadata.detectedBaseBranch`).

This simplifies the rename path: no tmux session renaming, no compatibility symlinks, no session-state re-keying in `ThreadManager` or `ThreadDetailViewController`. The thread's `.name` always matches the worktree directory basename.

Tab rename still changes tmux session names (tab-level, not thread-level), which requires rekeying session-name-keyed state:
- **ThreadDetailViewController**: `preparedSessions`, `sessionPreparationTasks`/`sessionPreparationTaskTokens`, `loadingOverlaySessionName`, `startupOverlayRequiredSessions`. Centralised in `rekeySessionState(_:)`.
- **recreateSessionIfNeeded** guards against stale session names by checking `tmuxSessionNames.contains(sessionName)` both at entry and again immediately before `tmux.createSession`.

### 4.2 Prompt-Based Rename Reuse

The "AI Rename…" sheet (⌘⇧R, also in thread context menu and TOC right-click) reuses the same model payload path as first-prompt auto-rename so branch slug generation, task description generation, and icon suggestion stay behaviorally aligned. The sheet provides a multi-line prompt input, a picker with the last 10 recent prompts, and checkboxes to selectively rename icon, description, and/or branch name (state persisted in `AppSettings.aiRenameIcon/aiRenameDescription/aiRenameBranch`).
This manual path intentionally skips first-prompt eligibility gates (for example "already auto-renamed") so users can explicitly request a regenerated name/description/icon at any time. It also force-overwrites the existing task description and icon (unless manually set), so the sidebar label always matches the new branch name.
When parsing combined rename payloads, treat only the first `SLUG:` line as the slug field. Multi-line model replies also include `DESC:` and `TYPE:` lines; only the first line after `SLUG:` is used for the slug.
Generated descriptions should stay semantically aligned with the slug and read like concrete task labels in the sidebar, not abstract nouns unless the prompt is explicitly about that concept.

**Multi-agent fallback for all prompt-rename paths:** `autoRenameThreadAfterFirstPromptIfNeeded` (session-based auto-rename), `autoRenameThreadFromDraftPromptIfNeeded` (draft auto-rename), and `renameThreadFromPrompt` (manual TOC rename, context-menu rename) all use `slugGenerationAgentOrder` to try the preferred agent first and fall back to other active trackable agents (Claude/Codex) in order. The session-based and draft variants share a private `performAutoRename` helper parameterized by `requireSession` (tmux session guard) and `prefixDraft` ("DRAFT: " description prefix). If the preferred agent is rate-limited or unavailable, the next candidate is tried automatically. The cache key is shared across agents, so a successful result from any fallback agent is reused on subsequent calls with the same prompt. `.claude` is always appended as a final fallback entry in `slugGenerationAgentOrder` even when no built-in agent is marked active — since Claude is a prerequisite for the app, this guarantees at least one attempt regardless of which agent is configured as default.

**Rename-in-progress visual feedback:** `renameThreadFromPrompt` adds the thread to `autoRenameInProgress` before the AI call and removes it (via `defer`) on exit. This drives the sidebar pulse animation so users can see a rename is in flight, matching the visual feedback from the auto-rename path. Without this, explicit "Rename from this prompt" context menu actions showed no progress indicator for up to 30 seconds.

**Rename payload cache (`promptRenameResultCache`):** Every non-failed AI rename result (slug+description) is cached in `ThreadManager.promptRenameResultCache` keyed by `(threadId, normalizedPrompt)`. Both the TOC-triggered path and the sheet-triggered path check this cache before calling the agent. This means repeated renames or a right-click rename on a previously used prompt resolve instantly without a second agent call. The cache is cleared on thread archive and delete.

**Early auto-rename from launch sheet:** `createThread` fires `autoRenameThreadAfterFirstPromptIfNeeded` in an unstructured `Task` immediately after the tmux session is created, using the prompt captured from the launch sheet. This means the thread typically gets a meaningful name before the agent has finished loading. `didAutoRenameFromFirstPrompt` is the deduplication guard — when the early trigger runs first and sets this flag, the TOC-based trigger skips the same prompt later. If the early trigger loses the `autoRenameInProgress` race (another rename is already in flight), it exits gracefully; the TOC path will pick it up instead.

**Accumulated-prompt context for deferred auto-rename:** When auto-rename is deferred (e.g. the first prompt was rate-limited and the rename model couldn't run), subsequent history-growth or TOC-refresh triggers pass ALL accumulated prompts joined with newlines — not just the newest prompt. This ensures the rename model sees the original task description even when the triggering prompt is a short follow-up like "continue" or "resume". The launch-sheet early path still passes the single initial prompt (which is the only one at that point). Manual `renameThreadFromPrompt` is unaffected — it always passes exactly the prompt the user selected.

**Draft auto-rename:** When a thread is created with the "Draft" checkbox checked, `ThreadListViewController+SidebarActions` awaits `autoRenameThreadFromDraftPromptIfNeeded` after adding the draft tab. This uses `performAutoRename` with `requireSession: nil` (no tmux session exists) and `prefixDraft: true`. The "DRAFT: " prefix on `taskDescription` is stripped by `stripDraftDescriptionPrefixIfNeeded` when the draft is consumed ("Start Agent") or discarded, provided no other draft tabs remain on the thread.

**Inject-only mode (`--no-submit` / `shouldSubmitInitialPrompt: false`):** `injectAfterStart` supports injecting prompt text into the agent input without pressing Enter. When `shouldSubmitInitialPrompt` is false but an `initialPrompt` is provided, the method waits for the actual agent prompt marker (not just generic TUI output), pastes the text via `sendText`, but skips `sendEnter`. This is used by `batch-create --no-submit` to pre-fill many threads' agent inputs without triggering concurrent agent runs. If the prompt marker never appears within the startup timeout, Magent keeps the pending prompt state and shows a per-tab recovery banner instead of pasting into an ambiguous shell/UI state.

**Pending thread phase 2 merge:** `createThread` registers a pending thread immediately (phase 1) and runs git/tmux setup in the background (phase 2). When phase 2 completes, it calls `mergePhase2Setup(from:)` to update only infrastructure fields (tmux sessions, agent types, base branch, submitted prompts, web tabs, draft tabs) while preserving all user-modifiable sidebar metadata (displayOrder, sectionId, icon, pin/hidden state, description, sign) that may have been changed during the background setup window.
Phase 2 must also seed `sessionLastVisitedAt` for the newly created tmux session immediately. The pending thread may already be selected before the session exists, so relying on `setActiveThread(...)` alone leaves the first session without a visit timestamp and makes idle eviction eligible too early once the user switches away.
For draft/web threads (non-terminal), phase 2 skips tmux setup and `injectAfterStart`, so the `threadSetupSentinel` added to `magentBusySessions` during phase 1 is never cleared by the normal tmux/inject flow. The phase 2 merge must explicitly remove the sentinel so the thread's busy spinner stops when phase 2 completes.

**Batch thread creation (`batch-create`):** `IPCCommandHandler.batchCreateThreads` resolves all names/sections/validation upfront (Phase 1, sequential), then creates all threads concurrently via `withTaskGroup` (Phase 2). Each thread passes `skipAutoSelect: true` so the sidebar focus doesn't jump during batch creation. Sidebar positioning (`placeThreadAfterSibling` or `bumpThreadToTopOfSection` when the from-thread is pinned) and task descriptions are applied in a deterministic post-pass (in request order) after the task group completes — passing `insertAfterThreadId` into concurrent creates would race when multiple specs target the same from-thread.

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
- Keep a distinction between row preview text and the submitted prompt payload: UI rows may show a wrapped/truncated preview, but prompt actions like `Copy prompt` and rename-from-prompt must operate on the full submitted prompt text.
- Apply subtle alternating row backgrounds to improve scanability without dominating the terminal UI.
- Keep the TOC drag header visually distinct from the body; a slightly darker top band helps communicate that the header is the draggable region without making the whole panel heavier.
- If the TOC was pinned to the bottom before a same-session append refresh, restore it to the bottom after repopulating rows; do not force-scroll when the user was reading older entries.
- Keep the TOC overlay frontmost in the AppKit subview order whenever terminal surfaces are attached/switched/refreshed; layer `zPosition` alone is not sufficient for mouse hit-testing against embedded Ghostty views.

Navigation behavior:
- TOC selection uses tmux copy-mode positioning (`scrollHistoryLineToTop`) so the selected prompt line is anchored at the top of the viewport whenever enough lines exist below it.
- Terminal scrollback fallback controls in the terminal panel must route through tmux copy-mode commands (`page-up`, `page-down-and-cancel`, cancel-to-bottom) instead of relying on Ghostty wheel events, because in-agent wheel handling can be captured by the running tool.
- Mouse-wheel scrolling in embedded terminals uses a two-layer approach: (1) Ghostty config sets `mouse-reporting = true` for both `magentDefaultScroll` and `allowAppsToCapture` so scroll events reach tmux as xterm mouse sequences; (2) `TmuxService.applyMouseWheelScrollSettings` enables `set -g mouse on` and configures `WheelUpPane`/`WheelDownPane` tmux key bindings — `magentDefaultScroll` forces every scroll-up into copy-mode (history-only, apps never receive the event), `allowAppsToCapture` removes those overrides to restore tmux default behavior. `inheritGhosttyGlobal` touches neither. Settings are applied at startup and on every settings change via `AppDelegate.applyAppAppearanceAndTerminalPreferences`. When the setting changes for already-open tabs, `TerminalSurfaceView` instances are recreated so the updated ghostty config takes effect immediately.
- App appearance is a single shared setting: it must drive both `NSApp.appearance` for AppKit chrome and Ghostty's light/dark color scheme so the sidebar/top bars/terminal never drift apart. In `System` mode, refresh Ghostty on app activation and when macOS broadcasts `AppleInterfaceThemeChangedNotification`.
- Scroll-to-bottom FAB visibility must not depend only on Ghostty scrollbar callbacks; refresh it from tmux `#{scroll_position}` as the source of truth so the button still appears after real upward scrolls when Ghostty's scrollbar notifications lag or go missing.
- Keep tmux pane scrollbars disabled in embedded terminals. The visible history indicator should come from Magent's own overlay/FAB affordances, not tmux's character-cell scrollbar, which reads as a Ghostty scrollbar regression in the embedder.

### 4.5 Project Local File Sync Paths

Projects can define repo-relative local sync entries (files or directories) with a mode of `Copy` or `Shared Link`.

- On thread creation, `Copy` entries seed from the resolved base-branch sync source while `Shared Link` entries create direct symlinks to the project repo root copy; the normalized entry list is snapshotted onto the thread.
- On thread archive, local-sync merge-back is limited to `Copy` entries currently configured in project `Local Sync Paths`, and only those eligible paths are merged back from worktree to repo root (unless archive local-sync is disabled via global setting or CLI `--skip-local-sync` override).
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

### 4.6.1 Main Window Space/Screen Behavior

- Display-topology callbacks (for example `applicationDidChangeScreenParameters`) must not call app-activation paths (`NSApp.activate`, `makeKeyAndOrderFront`) because those can pull the user to another macOS Space unexpectedly.
- Keep screen-change handling limited to non-focus side effects (for example off-screen frame recovery) so background monitor or display events never steal focus.
- Persist both the main-window frame autosave entry and the last display identifier on quit. At launch, restore frame first, then prefer the persisted display when available; only fall back to the active/mouse display if the saved display no longer exists.
- If a restored frame lands on a different display than the persisted preferred display, re-center on the preferred display before showing the window.

### 4.7 Release-Gated Local Features

Some features need to stay in the codebase before they are ready to ship. Those features are release-gated with dedicated `FEATURE_*` active compilation conditions in `Project.swift`.

- Add the flag only to the configurations that should expose the feature.
- Keep the availability check centralized in an app-level helper so AppKit/UI code can use one source of truth.
- Release builds should hide the related UI and skip the related background automation instead of showing dead controls.
- If a feature is visible in debug-only Settings surfaces, annotate it with `Debug builds only` so developers can see immediately that it is not part of release builds.
- `FEATURE_JIRA_SYNC` is the current example: Debug builds expose Jira sync settings/actions (board config, section sync, auto-thread creation), while Release builds hide them. Basic Jira ticket detection from branch names and "Open in Jira" actions work in all builds without the flag.
- All Jira features (detection, status badges, toolbar button, context menu) are gated at runtime by `AppSettings.jiraIntegrationEnabled`, a master toggle in Jira settings. The toggle is auto-disabled when acli is not installed or authenticated.
- Jira branch-ticket detection can be narrowed with `AppSettings.jiraTicketDetectionPrefixes`, a comma/semicolon-separated prefix allowlist normalized case-insensitively (for example: `IP, APPL, UT`). The filter applies only to branch-derived ticket detection; explicit synced `jiraTicketKey` values bypass it. Future Jira UI/cache code should resolve branch-based tickets through `MagentThread.effectiveJiraTicketKey(settings:)` so the allowlist is respected consistently.
- The Jira context menu submenu includes a "Change Status" flyout listing all project statuses (discovered via `JiraService.discoverProjectStatuses` and cached per-project in `ThreadManager._jiraProjectStatusesCache`, persisted to `jira-project-statuses-cache.json`). Status transitions use `acli jira workitem transition`. The cache is pre-populated during ticket verification, persisted to disk so status lists survive restarts, and invalidated on force-refresh.

### 4.8 Shell Startup and Reattach CWD Contract

Shell startup uses a managed `ZDOTDIR` wrapper so Magent can source the user's shell files and still land in the intended worktree/repo directory afterward.

- Terminal startup should flow through `terminalStartCommand(...)`, which launches a login shell with `MAGENT_START_CWD` and applies the final `cd` from the managed `.zshrc` after user shell config has loaded.
- Agent startup should flow through `agentStartCommand(...)`, which must use an interactive login zsh shell (`-il`) so `.zshrc` PATH setup is available before resolving agent binaries like `claude` or `codex`.
- Agent binary invocations must use the `command <agent>` shell built-in prefix (e.g. `command claude`, `command codex`) to bypass any shell function wrappers or aliases the user may have defined. The ZDOTDIR wrapper intentionally loads user shell config so PATH is set up correctly, but user-defined `claude`/`codex` functions can inject conflicting flags. `command` resolves only the binary, not functions.
- A one-time `cd` in user `.zshrc` is expected and should be overridden by `MAGENT_START_CWD` during session creation.
- Reattaching to an existing tmux session must not inject `cd` again. Existing terminal state is authoritative once the session is live; only fresh session creation should enforce the starting directory.

### 4.9 Context Transfer File Contract

`Continue in...` captures pane output into a transient markdown file and then passes that absolute path to the receiving agent in its initial prompt.

- Do not write that file into the repo/worktree root, because even short-lived untracked files dirty the thread and can be accidentally staged.
- Store handoff files under the project's worktrees base path in a hidden Magent-owned directory so they stay outside the repo but near the trusted worktree boundary.
- Use a unique filename per transfer (for example a UUID-based suffix) so multiple transfers can be created concurrently without clobbering each other.
- Treat these files as ephemeral cache entries: remove them after a bounded TTL and prune leftovers on app launch/shutdown.

### AppKit Picker Presentation Safety

`NSOpenPanel.beginSheetModal(for:)` requires a live host window. Setup/settings actions can run while a controller's view exists but is not attached to a window yet.

- Do not force-unwrap `view.window` when presenting file/folder pickers.
- Present as a sheet only when a host window exists; otherwise fall back to `runModal()`.
- This prevents intermittent launch/setup timing crashes in configuration and settings flows.

### 4.10 Tab Resume Duplication Contract

Agent-backed terminal tabs may expose a `Resume Agent Session in New Tab` context-menu item that opens a fresh tmux session but resumes the same agent conversation.

- Only show this action for agent types that support deterministic resume (`Claude` and `Codex`).
- Gate enablement on a non-empty persisted `sessionConversationIDs[sessionName]`; if no resume ID has been captured yet, the menu item should stay disabled and the action must not launch a best-effort fresh session under the guise of resume.
- Route resumed-duplicate tabs through the normal `addTab(...)` flow with an explicit `resumeSessionID` so startup, trust handling, overlay behavior, and persisted session metadata stay consistent with every other agent tab.
- Persist the copied resume ID onto the new tab's `sessionConversationIDs` entry immediately so later recreation/reopen flows preserve the resumed conversation even before a subsequent refresh discovers the same ID again.

The tab context menu now opens a single `Continue in...` sheet instead of a nested agent submenu. That sheet is agent-only, so it keeps the model picker, title field, model/reasoning controls, and an optional "Extra context" prompt field. The draft checkbox is hidden. When the user provides extra context, it is appended to the transfer prompt as priority instructions for the receiving agent; when left empty, the transfer prompt is unchanged. Tabs created through that flow should persist an explicit forwarded-session marker so the tab bar can show the same forward icon as the header `Continue in...` button even after reload, rename, or session recreation.

### 4.10 Persistence Backup + Restore Contract

Magent keeps two layers of backup protection for critical app-state files in Application Support:

- Rolling backups: before overwriting `threads.json`, `settings.json`, or `agent-launch-prompt-drafts.json`, keep the previous file as `<name>.bak.json`.
- Periodic snapshots: every 30 minutes while the app is running, copy the currently present critical files into `Application Support/Magent/backups/<timestamp>/`.
- Settings exposes a manual `Back Up Now` action that creates the same snapshot format on demand.

Restore is a coordinated app-state transition, not just a filesystem copy:

- The Settings restore action must stop background pollers/timers that can write state (`ThreadManager` session monitor, update polling, periodic backup timer).
- Cancel any pending debounced thread save before touching snapshot files.
- Block writes for every restorable critical file while the restore is in progress so UI or background code cannot immediately overwrite the restored snapshot.
- Restore only replaces files that are actually present in the chosen snapshot. If the snapshot is partial, any missing files stay on disk so a partial backup cannot destroy newer local state by omission alone.
- Every restore first creates a `pre-restore-<timestamp>` safety snapshot of the current state, and those safety snapshots must stay visible in the restore picker so the user can undo a bad restore.

### 5. Persistence Model

Thread state and settings are persisted as JSON in `~/Library/Application Support/Magent/`.

#### Schema versioning

Critical files (`threads.json`, `settings.json`) are wrapped in a **versioned envelope**:

```json
{
  "schemaVersion": 1,
  "data": [ /* array of MagentThread objects */ ]
}
```

Legacy files (no envelope, written by older builds) are decoded directly and upgraded to the envelope format on the next save. See `PersistenceValidation.swift` for the full versioning contract, including when to bump versions and how to register migrations.

#### Startup validation & recovery

On launch, `AppCoordinator.start()` calls `tryLoadSettings()` / `tryLoadThreads()` before showing the UI. Before surfacing any fatal startup error, persistence first attempts silent self-recovery for missing or corrupt `settings.json` / `threads.json` by loading the newest valid copy from the rolling `.bak` file or the periodic snapshot folders and restoring it back to the primary path.

If the primary file and all recovery candidates still fail to decode (or the file is from a newer incompatible schema):

1. Writes to the affected file are **blocked** so no save can overwrite it.
2. A modal alert explains which files failed and why.
3. The user can **Quit** (file stays untouched for manual recovery) or **Continue with Reset** (file is backed up as `<name>.corrupted.<timestamp>.json`, writes unblocked, app proceeds with defaults).

If threads load successfully but settings are missing or no longer cover the live project IDs, Magent scans every `settings.json` recovery candidate (rolling backup first, then periodic snapshots newest-first) and restores the candidate with the best project-ID coverage before falling back to onboarding/default settings. This keeps existing threads attached to their projects after a missing-settings failure, even if `settings.bak.json` is stale but a newer snapshot is still good.

If the loaded settings still do not contain a project for one or more active threads, `AppCoordinator` makes one last best-effort pass before declaring the file incomplete: it tries to rebind each orphaned thread to a single matching project by exact repo path, then by worktree base-path prefix. Any successful rebinding is written back to `threads.json` immediately so the current launch starts from a consistent project/thread map.

That rebind pass must also consolidate active duplicates by normalized worktree path inside the recovered project. If two persisted threads end up pointing at the same worktree (for example because `threads.json` carried duplicate project registrations before `settings.json` recovery), keep one canonical thread, merge terminal/web/draft tabs into it, and de-duplicate terminal tab titles instead of leaving multiple sidebar rows for the same worktree.

If no candidate fully repairs coverage, startup still treats the file as incomplete when active threads reference projects that the loaded settings do not cover. In that state, writes to `settings.json` stay blocked for the launch so onboarding or other defaults cannot silently strand those threads.

Settings UI controllers must not cache an `AppSettings` value for later whole-object saves. A pane can keep a local copy for rendering, but each save path must reload the latest settings from persistence immediately before mutating the relevant fields. Otherwise a stale Settings window opened during recovery/default-state startup can overwrite newer project registrations or restored settings with an old snapshot.

`saveSettings(_:)` rejects partial coverage as well as total loss of coverage: every active thread project ID must still exist in the candidate settings file, or the write is blocked. This prevents a settings pane from saving a project list that strands only some live threads.

Non-critical caches (Jira, PR, rate-limit, etc.) keep silent fallback to empty — they are regenerated from APIs.

#### File layout

| File | Contents |
|------|----------|
| `threads.json` | Versioned envelope containing `[MagentThread]` (active + archived) |
| `settings.json` | Versioned envelope containing `AppSettings` (projects, sections, preferences) |
| `agent-launch-prompt-drafts.json` | Draft prompts for agent launch sheets |
| `agent-last-selections.json` | Last-used agent type, model, and reasoning effort per scope (managed by `AgentLastSelectionStore`) |
| `agent-models.json` | Cached remote agent model/reasoning manifest (written by `AgentModelsService`; sourced from `config/agent-models.json` in the app bundle as a fallback) |
| `rate-limit-cache.json` | Fingerprint → resetAt cache (auto-pruned on load) |
| `ignored-rate-limit-fingerprints.json` | User-ignored rate-limit reset timestamps per agent |
| `jira-ticket-cache.json` | Verified Jira ticket details |
| `jira-project-statuses-cache.json` | Cached Jira project status lists for "Change Status" menu |
| `pr-cache.json` | Cached PR/MR info by branch name |
| `<worktrees-base>/.magent-cache.json` | Per-project worktree metadata |

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

## Agent Model / Reasoning Manifest

`AgentModelsService` (singleton in the app target) owns the model/reasoning picker data:

- **Load order**: App Support cache → bundled `config/agent-models.json` → hardcoded fallback.
- **Remote refresh**: Fetched from `vapor-pawelw/mAgent` on GitHub at launch (`refreshOnLaunch`) and throttled to once per 10 minutes when the launch sheet calls `refreshIfThrottled`.
- **Per-agent last selection**: `AgentLastSelectionStore` (in `PersistenceCore`) persists the last-chosen model and reasoning effort per agent type in `agent-last-selections.json`. Fast paths (Option+click, context menu, keyboard create) use these stored values.
- **Command injection**: `freshAgentCommand` validates the selection against the manifest before appending `--model`/`--effort` (Claude) or `-m`/`-c` (Codex) flags. Invalid or missing selections fall through without flags.
- **Crash recovery**: Pending initial prompts preserve model and reasoning alongside the prompt text so the correct flags are restored after an app crash.

## Review Button Agent Selection

- The top-right Review button reuses the same active-agent menu model as `+` buttons so the available agents stay aligned with `AppSettings.activeAgents`.
- Unlike `+`, the Review button must not offer `Terminal`; every review launch should open an agent tab with the configured review prompt.
- When the project/default review agent is enabled, list that agent first in the Review menu and label it `(<Agent> Default)` using the same `(Default)` suffix convention as the launch sheet; do not show a separate `Use Project Default` menu row.
- Review launches should override built-in agents to the flagship review models (`opus` for Claude, `gpt-5.4` for Codex) and pass elevated reasoning on startup (`high` by default; Option-held review menu uses `max` for Claude and `xhigh` for Codex).
- Review tab titles should be `Review` when only one agent is enabled, and `Review (Claude)` or `Review (Codex)` when multiple agents are enabled. The visible title must still go through the standard tab deduplication path so repeated review launches remain unique.
- Review should keep a dedicated menu instead of using the `+` fast-path shortcuts so users can always pick an agent. When Option is not held, show a disabled discoverability hint near the menu header explaining that holding Option switches the Review menu to max reasoning.

## Session Reopen / Recovery

- `ThreadDetailViewController` prepares the selected tab first during thread switch, then continues recreating remaining tabs in the background. Tabs that have not been prepared yet still call `ThreadManager.recreateSessionIfNeeded(...)` on first selection so they can reuse a live tmux session or recover a missing/mismatched one without blocking the whole thread switch.
- Background preparation is only a health snapshot, not a permanent guarantee. Tabs whose `TerminalSurfaceView` has not been attached yet must revalidate the tmux session again on first lazy selection, then rebuild that detached view so its attach-or-create command captures the latest resume metadata. Otherwise a session that died after background prep can still be recreated locally by Ghostty with stale state.
- Thread switching has two explicit fast paths for healthy sessions: `ThreadManager.recreateSessionIfNeeded(...)` keeps a short-lived "known good" session-context cache so recently validated sessions can skip redundant context checks, and `ThreadDetailViewController` may reuse a cached `TerminalSurfaceView` wrapper for a session instead of always rebuilding one from scratch.
- Fast-path eligibility must survive `ThreadDetailViewController` recreation: `ensureSessionPrepared(...)` should consult `ThreadManager.isSessionPreparedFastPath(...)` before issuing any tmux checks so quick A→B→A revisits do not re-run `tmux has-session` just because the new VC starts with an empty local `preparedSessions` set.
- Keep the fast path cheap: if the tmux session already exists and matches the expected thread/worktree context, return before doing slower resume bookkeeping such as agent conversation-ID refresh.
- Session-context validation should use one tmux subprocess call when possible. `TmuxService.sessionContextSnapshot(...)` batches `session_created`, pane command/path, and relevant `MAGENT_*` env fields via one `display-message -p` format instead of serial `show-environment`/`list-panes`/`display-message` probes.
- Persist the resolved agent type per tmux session (`sessionAgentTypes` plus `MAGENT_AGENT_TYPE`) and use that stored session-level value for recreation/resume logic. A same-worktree session with the wrong agent type is still stale and must be recreated; do not reinterpret an old tab from the project's current default agent.
- Thread switching must not run zero-grace stale-session cleanup. Only clean up tmux sessions that are genuinely orphaned from the thread model, and keep a grace period before killing them so rapid view switches or temporary model lag cannot erase a tab the user just left.
- The loading overlay must follow the actual selected session, not the first tab in the thread. Its secondary detail line is reserved for non-routine recovery actions reported by session recreation; normal agent startup should continue to show only `Starting agent...`.
- Startup overlay reveal should be debounced (currently ~250 ms) for routine tab/session switches, so fast healthy-path prep completes without flashing `Starting agent...`. Explicit long-running flows (thread creation / tab creation) should still reveal immediately.
- Keep startup-overlay retention tied to real startup work: after `ensureSessionPrepared(...)`, dismiss the overlay immediately when `recreateSessionIfNeeded(...)` reports that the session was already healthy. Only keep `Starting agent...` alive for sessions that were actually recreated/recovered, or for explicit new-start handoffs such as a freshly created thread/tab that seeds a one-shot startup-overlay token before selection.
- `startLoadingOverlayTracking(...)` must avoid recurring high-frequency tmux readiness polls for every switch. Use injection notifications plus at most a one-shot readiness probe and a long safety timeout instead of 500 ms `capture-pane` polling loops.
- For already-live sessions, loading UI should prefer runtime process detection (`pane_current_command` + child args) over persisted configuration. If the pane is back at a shell, dismiss/skip the startup overlay rather than waiting for agent-ready markers that will never appear.
- **Two-phase new-tab creation**: `addTab()` immediately adds the tab item to the bar and shows a "Creating tab…" overlay before any async work starts. The `TerminalSurfaceView` is only created and appended to `terminalViews` after the tmux session is fully set up. The placeholder `TabSlot.terminal(sessionName: "")` is replaced with the real session name once the tmux session is ready. Once the session is ready, `selectTab(at:)` takes over and transitions the overlay to "Starting agent…" via the normal `startLoadingOverlayTracking` path.
- Terminal-view caching is wrapper reuse, not live Ghostty-surface preservation: removing a `TerminalSurfaceView` from the window still destroys its Ghostty surface, and reattaching it recreates that surface. Treat the cache as a way to avoid some controller/view churn around thread switches, not as proof that Ghostty startup was bypassed.
- **Idle session eviction**: `ThreadManager+IdleEviction.swift` runs on the slow tick (~1 min) and kills tmux sessions when the number of idle sessions exceeds `AppSettings.maxIdleSessions` (defaults to 30). A session is idle if it hasn't been visited in 1+ hour and hasn't been busy in 10+ minutes. Sessions undergoing Magent setup/injection (`magentBusySessions`) and sessions with active rate limits (`rateLimitedSessions`) are also exempt from eviction. Evicted session names are tracked in `evictedIdleSessions` so `checkForDeadSessions` doesn't auto-recreate them. Evicted sessions are also marked in `deadSessions` and the delegate is notified so sidebar/tabs gray out immediately. State is only updated after a successful `tmux kill-session` — failed kills leave the session live and retryable. When the user selects an evicted tab, `selectTerminalTab` clears the eviction marker and removes it from `preparedSessions`, forcing the slow path through `ensureSessionPrepared` → recreation.
- **Manual session cleanup**: `ThreadManager+SessionCleanup.swift` provides bulk cleanup via the status bar session count popover and per-session/per-thread kill via context menus. Bulk cleanup shows a confirmation alert listing affected threads/tabs and kills all idle live sessions (not busy/waiting/rate-limited/visible/shielded/pinned/recently busy within 5 min). Context menus offer "Kill Session" on individual tabs (tab right-click) and "Kill All Sessions" on threads (thread right-click in sidebar). All paths use the same eviction model: evict Ghostty surfaces from `ReusableTerminalViewCache`, mark sessions in `evictedIdleSessions`, kill tmux, mark dead. Tab metadata is fully preserved — killed sessions are recreated on demand when the user selects the tab.
- **tmux health in the session popover**: the bottom-left session count control also surfaces the latest detected tmux zombie count and offers a manual `Restart tmux + Recover` action. That action must continue to route through `ThreadManager.restartTmuxAndRecoverSessions()` so it shares the same resume/recovery behavior as the warning banner path.
- **No per-click `run-shell` / `run-shell -b` tmux bindings**: Historically the `MouseDown1Pane` binding used `run-shell -b` to run a mouse-URL-capture script on every click, which was the dominant source of the tmux zombie buildup that the health recovery banner was designed to mop up (tmux's libevent SIGCHLD reaper can lag under a rapid-click SIGCHLD burst, leaving `<defunct>` `/bin/sh` children attached to the tmux server). `configureMouseOpenableURLTracking` now stores per-click mouse state directly in a tmux server option via `set-option -gqF @magent_last_mouse "..."` — no fork, no child, no zombie. Do not reintroduce `run-shell` (sync or `-b`) on any high-frequency tmux hook; prefer in-process tmux commands (`set-option`, `set-environment`) and read the stored value from Magent via `ShellExecutor` (which always `waitpid`s its children).
- **Dead session tracking**: `checkForDeadSessions` no longer eagerly recreates all dead sessions. It updates `thread.deadSessions` (transient set) and only auto-recreates the currently visible session — but not if it was intentionally evicted. Background dead sessions stay suspended until the user selects the tab. Sidebar thread rows dim when all sessions are dead; individual tabs dim via `TabItemView.isSessionDead`.
- **Agent completion detection**: Magent no longer relies on per-session tmux `pipe-pane` bell watchers by default. Claude completion attention comes from the Magent-injected Claude Stop hook; Codex completion attention is synthesized from the session monitor when a Codex session transitions from busy to an idle prompt. `TmuxService.legacyAgentBellPipeEnabled` preserves the old pipe-pane path as an emergency rollback switch, and `ensureBellPipes()` detaches legacy pipes from upgraded live sessions while that flag is off.
- **Keep Alive (shielding)**: Two independent levels of protection exist. **Thread-level**: `MagentThread.isKeepAlive` (persisted `Bool`) protects all sessions in the thread from eviction and cleanup; toggled via the thread context menu. A light-blue half-shield icon (`shield.righthalf.filled`) appears in the sidebar trailing indicators. When thread-level keep alive is active, per-tab shield icons and per-tab keep alive context menu items are hidden (redundant). **Tab-level**: Individual sessions can be marked via the tab context menu; protected session names are stored in `MagentThread.protectedTmuxSessions` (persisted `Set<String>`). Tab-level protection does not imply thread-level — it only shields that one session. When all tabs in a multi-tab thread are individually protected, a one-time promotion banner offers to convert to thread-level keep alive (`didOfferKeepAlivePromotion` gates the offer). Changes propagate to the open detail view via `.magentKeepAliveChanged` notification, which syncs `isKeepAlive`, `didOfferKeepAlivePromotion`, and `protectedTmuxSessions`. **Instant recovery**: Enabling keep alive (at either level, including promotion) immediately recovers any dead/evicted sessions in scope — `recoverDeadSessions` clears the eviction markers, re-fetches the thread from the live `threads` array to avoid stale-snapshot races, recreates tmux sessions via `recreateSessionIfNeeded`, and posts a `didUpdateThreads` delegate call so the UI reflects the recovery without waiting for the next monitor tick.
- **Pinned session protection**: When `AppSettings.protectPinnedFromEviction` is enabled (default: true), pinned threads and pinned tabs are automatically treated as protected — same as shielded sessions — and exempt from eviction and cleanup. When this setting is active, the sidebar hides the keep-alive shield icon on pinned threads to avoid visual redundancy (the actual protection is maintained).
- **Unsubmitted input protection**: `MagentThread.hasUnsubmittedInputSessions` (transient `Set<String>`) tracks agent sessions where the user has typed text at the prompt but not yet submitted it. Detected during `syncBusySessionsFromProcessState` via ANSI-aware pane capture (`capturePaneWithEscapes`) — dim/SGR-2 text is placeholder, non-dim text is real input. A two-phase check avoids extra tmux calls: the cached plain-text capture is checked first, and the ANSI capture only runs when text is present after the prompt marker. Sessions with unsubmitted input are protected from idle eviction, manual cleanup, and archive suggestion (`showArchiveSuggestion`). The flag is cleared when the agent becomes busy, completes, exits, or the session is removed/renamed.

### TabSlot Indirection (Web Tab Support)

Display order is decoupled from content arrays via `tabSlots: [TabSlot]`, an enum array parallel to `tabItems`:

- `.terminal(sessionName:)` — content is in `terminalViews`, indexed by `thread.tmuxSessionNames`
- `.web(identifier:)` — content is in `webTabs`, keyed by identifier
- `.draft(identifier:)` — content is in `draftTabs`, keyed by identifier; persisted in `thread.persistedDraftTabs` including agent type, prompt, and optional model/reasoning overrides used by later `Start Agent`

Key invariants:
- `tabItems.count == tabSlots.count` always
- `terminalViews` stays parallel to `thread.tmuxSessionNames`; both are reordered together by `persistTabOrder()` during drag/pin operations
- `webTabs` stays in creation order; never reordered by drag
- `draftTabs` stays in creation order; view controllers are created lazily on first selection
- `tabSlots` + `tabItems` change order during drag/pin operations; `persistTabOrder()` syncs `terminalViews` and `thread.tmuxSessionNames` to match
- Single unified `pinnedCount` covers all tab types
- Content lookup uses session name / identifier keys, not positional indices (via `terminalView(forSession:)`, `currentTerminalView()`, etc.)
- **Non-terminal threads**: Threads created with an initial web tab or an initial draft tab have a worktree and branch but zero tmux sessions (`tmuxSessionNames` is empty). `setupTabs` treats these as intentional non-terminal threads (`sessions.isEmpty && (!persistedWebTabs.isEmpty || !persistedDraftTabs.isEmpty)`) and skips fallback session creation, restoring the saved web/draft tab directly instead of inventing a terminal session name that could collide with stale tmux state.
- **Tab selection persistence**: `MagentThread.lastSelectedTabIdentifier` stores the identifier of the last-selected tab across all tab types (tmux session name for terminal tabs, web/draft identifier for non-terminal tabs). On thread switch, `resolveLastSelectedSlotIndex()` looks up the saved identifier against all `tabSlots` to restore the correct tab. When the last-selected tab is non-terminal, it is selected immediately while terminal sessions prepare in the background.

## tmux Session Ownership

Each tmux session created by Magent is tagged with `MAGENT_THREAD_ID` (the owning thread's UUID) via `tmux set-environment`. This tag is set in:
- `ThreadManager+ThreadLifecycle.swift` — initial thread creation (both regular and main threads)
- `ThreadManager+TabManagement.swift` — new tab creation
- `ThreadManager+SessionRecreation.swift` — session recreation/recovery

**Why this matters**: Worktree names are reused when a thread is archived and a new thread is opened on the same branch/worktree name. Without ownership tracking, the old stale tmux session would be adopted by the new thread, restoring the previous agent session. The fix in `isValidExistingSession(...)` checks `MAGENT_THREAD_ID` first; if absent (old sessions), it falls back to comparing `session_created` timestamp against `thread.createdAt` — sessions older than the thread are rejected.

Agent resume metadata needs the same freshness guard. Claude and Codex both key resumable conversations by worktree path/cwd, so a newly created thread that reuses an archived worktree name must not adopt a conversation whose last activity predates that thread's `createdAt`. Resume-ID refresh should therefore ignore historical conversations for the same path unless their timestamp is at or after the current thread creation window.
## ThreadManager Concurrency Contract

`ThreadManager` is a plain `final class` (not an actor). Its mutable `threads: [MagentThread]` array must only be mutated on the **MainActor** to avoid data races.

**The trap**: async methods that mutate `threads` are typically called from `@MainActor` tasks. As long as the mutation happens synchronously (before any `await`), it runs on MainActor and is safe. But once the method crosses an `await` (e.g. a shell command via `ShellExecutor`), the continuation may resume on the cooperative thread pool — **off** MainActor. If two callers both reach the mutation point concurrently, the `[MagentThread]` array is accessed from two threads simultaneously → crash.

**Rule**: any private helper that mutates `threads` after an `await` must be annotated `@MainActor`. Example: `removeTabBySessionName` in `ThreadManager+TabManagement.swift` — after `await tmux.killSession(...)`, all mutations are protected by `@MainActor`, which ensures the continuation is re-scheduled on the MainActor rather than running on the thread pool.

**Secondary guard**: after an `@MainActor` method resumes from an `await`, other MainActor work (from a different concurrent task) may have run. Always re-validate index bounds against the live `threads` array after an `await` before accessing `threads[index]`.

**Safe parallel read pattern (withTaskGroup)**: For background work that is read-only per thread (e.g. running `git status` for every thread concurrently), use `withTaskGroup` with two strict phases:
1. **Input phase** (before the group): snapshot all needed data from `threads` into value-type structs (`MagentThread` is a struct, strings, bools). Child tasks capture only these snapshots — they never access `self.threads`.
2. **Apply phase** (after `withTaskGroup` returns): collect all results into a local array, then mutate `self.threads` in a sequential loop. Because the group is fully awaited before this phase begins, no concurrent mutation happens.

This pattern lets `refreshDirtyStates`, `refreshBranchStates`, and `refreshDeliveredStates` run O(n) git subprocess calls in O(1) wall-clock time by parallelizing across the cooperative thread pool, while keeping all `threads` mutations safely serialized in the apply phase.

**Detached cleanup pattern (archive/delete)**: Post-archive and post-delete cleanup (tmux session kills, worktree removal, symlink sweeps, stale-session pruning) runs in `Task.detached` blocks. A plain `Task { }` inherits the caller's actor context, so when archive/delete is initiated from AppKit-driven UI flows the synchronous code between `await` points (file-system walks, JSON I/O, task-group coordination) can stay on the UI path. The detached task pre-captures everything it needs (services, active worktree names, referenced session names) so it never needs UI-bound state while running. The snapshots can go stale if threads are created between capture and execution, but the window is negligible and the cleanup operations are idempotent (killing a non-existent session is a no-op, pruning an already-pruned cache is harmless).

## Platform Scope

- **macOS**: Full experience — sidebar + terminal + tabs, keyboard-driven
