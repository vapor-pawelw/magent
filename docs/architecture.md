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
- `PersistenceCore` owns JSON/file-backed persistence for threads, settings, and caches. `loadSettings()` uses an in-memory cache (invalidated on every `saveSettings()` call) to avoid repeated disk reads — it is called dozens of times per polling cycle. `debouncedSaveActiveThreads(_:)` coalesces rapid thread-state saves within a 300 ms window for non-critical state changes (dirty flags, completion markers); critical saves (archive, rename, thread creation) still use the synchronous `saveActiveThreads(_:)`.
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

Both thread rename and tab rename change tmux session names, which requires rekeying all session-name-keyed state at two levels:
- **ThreadManager**: `knownGoodSessionContexts` (session-validation cache), transient session state, bell pipes (`forceSetupBellPipe` to replace old-name pipes).
- **ThreadDetailViewController**: `preparedSessions`, `sessionPreparationTasks`/`sessionPreparationTaskTokens` (in-flight tasks are cancelled since their old-name completion path would fail), `loadingOverlaySessionName`, `startupOverlayRequiredSessions`. This is centralised in `rekeySessionState(_:)`.
- **recreateSessionIfNeeded** guards against stale session names by checking `tmuxSessionNames.contains(sessionName)` both at entry and again immediately before `tmux.createSession`, so a rename landing mid-preparation cannot resurrect an orphan session.

### 4.2 Prompt-Based Rename Reuse

Manual `Rename...` from the non-main thread context menu reuses the same model payload path as first-prompt auto-rename so branch slug generation, task description generation, and icon suggestion stay behaviorally aligned.
This manual path intentionally skips first-prompt eligibility gates (for example "already auto-renamed") so users can explicitly request a regenerated name/description/icon at any time.
When parsing combined rename payloads, treat only the first `SLUG:` line as the slug field before checking for the `EMPTY` sentinel. Multi-line model replies also include `DESC:` and `TYPE:` lines; checking the whole tail can incorrectly sanitize `SLUG: EMPTY` into the literal branch name `empty`.
Generated descriptions should stay semantically aligned with the slug and read like concrete task labels in the sidebar, not abstract nouns unless the prompt is explicitly about that concept.

**Multi-agent fallback for all prompt-rename paths:** Both `autoRenameThreadAfterFirstPromptIfNeeded` (auto/first-prompt) and `renameThreadFromPrompt` (manual TOC rename, context-menu rename) use `slugGenerationAgentOrder` to try the preferred agent first and fall back to other active trackable agents (Claude/Codex) in order. If the preferred agent is rate-limited or unavailable, the next candidate is tried automatically. The cache key is shared across agents, so a successful result from any fallback agent is reused on subsequent calls with the same prompt. `.claude` is always appended as a final fallback entry in `slugGenerationAgentOrder` even when no built-in agent is marked active — since Claude is a prerequisite for the app, this guarantees at least one attempt regardless of which agent is configured as default.

**Rename-in-progress visual feedback:** `renameThreadFromPrompt` adds the thread to `autoRenameInProgress` before the AI call and removes it (via `defer`) on exit. This drives the sidebar pulse animation so users can see a rename is in flight, matching the visual feedback from the auto-rename path. Without this, explicit "Rename from this prompt" context menu actions showed no progress indicator for up to 30 seconds.

**Rename payload cache (`promptRenameResultCache`):** Every non-failed AI rename result (slug+description or "question" classification) is cached in `ThreadManager.promptRenameResultCache` keyed by `(threadId, normalizedPrompt)`. Both the TOC-triggered path and the sheet-triggered path check this cache before calling the agent. This means repeated renames or a right-click rename on a previously used prompt resolve instantly without a second agent call. The cache is cleared on thread archive and delete.

**Force-generate for explicit renames:** `renameThreadFromPrompt` (TOC right-click, thread context menu) and CLI `rename-thread` always pass `forceGenerate: true` to the AI layer. This strips the `SLUG: EMPTY` option from the prompt entirely, so context-setting statements like "You're working on branch X" — which auto-rename would classify as questions — still produce a name. The cache behavior differs: cached slug results are reused as normal, but cached QUESTION results are bypassed so the AI is re-called with the forced prompt. `auto-rename-thread` (automatic first-prompt path) keeps `forceGenerate: false` to preserve the question-skip behavior.

**Early auto-rename from launch sheet:** `createThread` fires `autoRenameThreadAfterFirstPromptIfNeeded` in an unstructured `Task` immediately after the tmux session is created, using the prompt captured from the launch sheet. This means the thread typically gets a meaningful name before the agent has finished loading. `didAutoRenameFromFirstPrompt` is the deduplication guard — when the early trigger runs first and sets this flag, the TOC-based trigger skips the same prompt later. If the early trigger loses the `autoRenameInProgress` race (another rename is already in flight), it exits gracefully; the TOC path will pick it up instead.

**Inject-only mode (`--no-submit` / `shouldSubmitInitialPrompt: false`):** `injectAfterStart` supports injecting prompt text into the agent input without pressing Enter. When `shouldSubmitInitialPrompt` is false but an `initialPrompt` is provided, the method waits for the actual agent prompt marker (not just generic TUI output), pastes the text via `sendText`, but skips `sendEnter`. This is used by `batch-create --no-submit` to pre-fill many threads' agent inputs without triggering concurrent agent runs. If the prompt marker never appears within the startup timeout, Magent keeps the pending prompt state and shows a per-tab recovery banner instead of pasting into an ambiguous shell/UI state.

**Batch thread creation (`batch-create`):** `IPCCommandHandler.batchCreateThreads` resolves all names/sections/validation upfront (Phase 1, sequential), then creates all threads concurrently via `withTaskGroup` (Phase 2). Each thread passes `skipAutoSelect: true` so the sidebar focus doesn't jump during batch creation. Task descriptions are set after the task group completes to avoid main-actor isolation issues inside child tasks.

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

On launch, `AppCoordinator.start()` calls `tryLoadSettings()` / `tryLoadThreads()` before showing the UI. If either file fails to decode (corruption, incompatible schema from a newer build, etc.):

1. Writes to the affected file are **blocked** so no save can overwrite it.
2. A modal alert explains which files failed and why.
3. The user can **Quit** (file stays untouched for manual recovery) or **Continue with Reset** (file is backed up as `<name>.corrupted.<timestamp>.json`, writes unblocked, app proceeds with defaults).

Non-critical caches (Jira, PR, rate-limit, etc.) keep silent fallback to empty — they are regenerated from APIs.

#### File layout

| File | Contents |
|------|----------|
| `threads.json` | Versioned envelope containing `[MagentThread]` (active + archived) |
| `settings.json` | Versioned envelope containing `AppSettings` (projects, sections, preferences) |
| `agent-launch-prompt-drafts.json` | Draft prompts for agent launch sheets |
| `agent-last-selections.json` | Last-used agent type per scope |
| `rate-limit-cache.json` | Fingerprint → resetAt cache (auto-pruned on load) |
| `ignored-rate-limit-fingerprints.json` | User-ignored rate-limit patterns per agent |
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

## Review Button Agent Selection

- The top-right Review button reuses the same active-agent menu model as `+` buttons so the available agents stay aligned with `AppSettings.activeAgents`.
- Unlike `+`, the Review button must not offer `Terminal`; every review launch should open an agent tab with the configured review prompt.
- Option-click on Review should bypass the menu and launch immediately with the resolved default agent for the thread's project, matching the quick-create behavior used by project and tab `+` controls.

## Session Reopen / Recovery

- `ThreadDetailViewController` prepares the selected tab first during thread switch, then continues recreating remaining tabs in the background. Tabs that have not been prepared yet still call `ThreadManager.recreateSessionIfNeeded(...)` on first selection so they can reuse a live tmux session or recover a missing/mismatched one without blocking the whole thread switch.
- Background preparation is only a health snapshot, not a permanent guarantee. Tabs whose `TerminalSurfaceView` has not been attached yet must revalidate the tmux session again on first lazy selection, then rebuild that detached view so its attach-or-create command captures the latest resume metadata. Otherwise a session that died after background prep can still be recreated locally by Ghostty with stale state.
- Thread switching has two explicit fast paths for healthy sessions: `ThreadManager.recreateSessionIfNeeded(...)` keeps a short-lived "known good" session-context cache so recently validated sessions can skip redundant context checks, and `ThreadDetailViewController` may reuse a cached `TerminalSurfaceView` wrapper for a session instead of always rebuilding one from scratch.
- Keep the fast path cheap: if the tmux session already exists and matches the expected thread/worktree context, return before doing slower resume bookkeeping such as agent conversation-ID refresh.
- Persist the resolved agent type per tmux session (`sessionAgentTypes` plus `MAGENT_AGENT_TYPE`) and use that stored session-level value for recreation/resume logic. A same-worktree session with the wrong agent type is still stale and must be recreated; do not reinterpret an old tab from the project's current default agent.
- Thread switching must not run zero-grace stale-session cleanup. Only clean up tmux sessions that are genuinely orphaned from the thread model, and keep a grace period before killing them so rapid view switches or temporary model lag cannot erase a tab the user just left.
- The loading overlay must follow the actual selected session, not the first tab in the thread. Its secondary detail line is reserved for non-routine recovery actions reported by session recreation; normal agent startup should continue to show only `Starting agent...`.
- Keep startup-overlay retention tied to real startup work: after `ensureSessionPrepared(...)`, dismiss the overlay immediately when `recreateSessionIfNeeded(...)` reports that the session was already healthy. Only keep `Starting agent...` alive for sessions that were actually recreated/recovered, or for explicit new-start handoffs such as a freshly created thread/tab that seeds a one-shot startup-overlay token before selection.
- For already-live sessions, loading UI should prefer runtime process detection (`pane_current_command` + child args) over persisted configuration. If the pane is back at a shell, dismiss/skip the startup overlay rather than waiting for agent-ready markers that will never appear.
- **Two-phase new-tab creation**: `addTab()` immediately adds the tab item to the bar and shows a "Creating tab…" overlay before any async work starts. The `TerminalSurfaceView` is only created and appended to `terminalViews` after the tmux session is fully set up. The placeholder `TabSlot.terminal(sessionName: "")` is replaced with the real session name once the tmux session is ready. Once the session is ready, `selectTab(at:)` takes over and transitions the overlay to "Starting agent…" via the normal `startLoadingOverlayTracking` path.
- Terminal-view caching is wrapper reuse, not live Ghostty-surface preservation: removing a `TerminalSurfaceView` from the window still destroys its Ghostty surface, and reattaching it recreates that surface. Treat the cache as a way to avoid some controller/view churn around thread switches, not as proof that Ghostty startup was bypassed.

### TabSlot Indirection (Web Tab Support)

Display order is decoupled from content arrays via `tabSlots: [TabSlot]`, an enum array parallel to `tabItems`:

- `.terminal(sessionName:)` — content is in `terminalViews`, indexed by `thread.tmuxSessionNames`
- `.web(identifier:)` — content is in `webTabs`, keyed by identifier
- `.draft(identifier:)` — content is in `draftTabs`, keyed by identifier; persisted in `thread.persistedDraftTabs`

Key invariants:
- `tabItems.count == tabSlots.count` always
- `terminalViews` stays parallel to `thread.tmuxSessionNames`; both are reordered together by `persistTabOrder()` during drag/pin operations
- `webTabs` stays in creation order; never reordered by drag
- `draftTabs` stays in creation order; view controllers are created lazily on first selection
- `tabSlots` + `tabItems` change order during drag/pin operations; `persistTabOrder()` syncs `terminalViews` and `thread.tmuxSessionNames` to match
- Single unified `pinnedCount` covers all tab types
- Content lookup uses session name / identifier keys, not positional indices (via `terminalView(forSession:)`, `currentTerminalView()`, etc.)
- **Web-only threads**: When a thread is created with the "Web" type, it has a worktree and branch but zero tmux sessions (`tmuxSessionNames` is empty). `setupTabs` detects this (`sessions.isEmpty && !persistedWebTabs.isEmpty`) and skips fallback session creation, selecting the first web tab directly instead of going through terminal session preparation.

## tmux Session Ownership

Each tmux session created by Magent is tagged with `MAGENT_THREAD_ID` (the owning thread's UUID) via `tmux set-environment`. This tag is set in:
- `ThreadManager+ThreadLifecycle.swift` — initial thread creation (both regular and main threads)
- `ThreadManager+TabManagement.swift` — new tab creation
- `ThreadManager+SessionRecreation.swift` — session recreation/recovery

**Why this matters**: Worktree names are reused when a thread is archived and a new thread is opened on the same branch/worktree name. Without ownership tracking, the old stale tmux session would be adopted by the new thread, restoring the previous agent session. The fix in `isValidExistingSession(...)` checks `MAGENT_THREAD_ID` first; if absent (old sessions), it falls back to comparing `session_created` timestamp against `thread.createdAt` — sessions older than the thread are rejected.
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
