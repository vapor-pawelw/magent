# Sidebar Row Layout

Capsule-style sidebar with per-row rounded borders, dynamic heights, and badge overlays.

## User-Facing Behavior

- Every thread row is drawn inside a rounded-border capsule (`AlwaysEmphasizedRowView`).
  - **Selected**: accent-colored border and fill.
  - **Completion (unread)**: green border and fill.
  - **Waiting for input**: orange border and fill.
  - **Default**: subtle white border and fill.
- Status badges (favorite, pinned, Jira-sync, keep-alive, rate-limit) are bare-icon badges sitting on the capsule's top border with a circular background on selected/completed rows. The Jira-sync badge uses the colored `JiraIcon` brand asset (not template-tinted) and appears whenever the thread has the per-thread "Sync description and priority from Jira" toggle enabled.
- Rate-limit top-border badges can show a tiny 2pt red corner dot to indicate a directly-detected local source (non-propagated marker) for that agent on this thread.
- Duration badge is a pill on the capsule's bottom-right with a persistent border. The duration label tints with a color gradient based on thread age: light blue (<15 min), green (<8 hrs), yellow (<1 day), orange (<3 days), red (3+ days). This provides at-a-glance visual feedback on activity age.
- **Priority capsule**: Optional pill sitting immediately to the left of the duration badge on the capsule's bottom-right. Shown only when the thread has an explicit 1–5 priority. Renders cumulative dots (`●○○○○` through `●●●●●`) in a monospaced 9pt font so the string width is stable across levels. Dot color tints by level: 1 blue, 2 green, 3 yellow, 4 orange, 5 red. The capsule is filled with `windowBackgroundColor` (matches the sidebar background behind the row capsules) and uses the same `TopBorderBadge`-style border treatment as the duration pill so both badges read as a matched pair. 2pt inner padding on all sides.
- The `Main worktree` row shows a tinted accent bar at the leading edge (same inset as non-main thread icons).
- Regular thread rows use a three-line vertical stack:
  - line 1 (primary): task description when set; otherwise the branch name.
  - line 2 (secondary / `subtitleLabel`): branch · worktree when a description is shown; worktree only when no description and the worktree name differs from the branch; hidden otherwise.
  - line 3 (PR/ticket row): `jiraTicketLabel` + `jiraStatusBadge` + dot separator + `prNumberLabel` + `prStatusBadge`. Badges gated by `AppSettings.showJiraStatusBadges` / `showPRStatusBadges`. Ticket display gated by `AppSettings.jiraTicketDetectionEnabled`.
- Row heights are **dynamic** based on actual content (description lines, subtitle, PR row) with a minimum height matching 2 description lines + 2 metadata labels (1 line + 2 labels when `narrowThreads` is enabled).
- Sign emoji is rendered at the **row view** level (`AlwaysEmphasizedRowView`) inside a circular `SignEmojiBadgeView` anchored to the top-left corner of the row (2pt margin from leading and top edges). The badge self-sizes via `intrinsicContentSize` (text size + 4pt padding, high priority) with a required 1:1 width/height ratio to stay circular. Border color and width mirror the capsule's current state. Not part of `ThreadCell`.
- Project repo names use system bold 20pt font.
- No separator divider between project groups; vertical gap (`projectHeaderInterProjectGap = 24pt`) handles spacing.
- The global "Add repository" button is a `SidebarAddRepoRow` at the top of the outline view's root items. It scrolls with the rest of the content — there is no sticky toolbar.
- The add-repo row opens a 2-item menu: `Create New Repository…` and `Import Existing Repository…`.
- `Create New Repository…` selects/creates a target folder, initializes git, seeds an empty initial commit, then registers the project and creates the main thread.
- During create-repo flow, Magent shows a persistent spinner banner (`Creating repository: <name>`), then replaces it with explicit success (`Repository created: <name>`) or failure status (`Failed to create repository: <name>`) and an error alert.
- **Sticky headers**: When the user scrolls past a project or section header, a floating overlay (`StickyHeaderOverlayView`) pins the project name (and current section, if applicable) at the top of the sidebar. A 12pt fade gradient softens the transition into scrolling content. Clicking a sticky header smoothly scrolls the sidebar to reveal the actual header row.
- **Selected-thread jump capsule**: When the selected thread is outside the visible thread-list viewport, a floating capsule appears near the bottom of the thread list (inside the sidebar's thread area, not over the changes panel). It shows thread icon + title (prefer task description, fallback to worktree name) and a directional arrow (`up`/`down`) indicating where the row is relative to the viewport. Clicking the capsule centers the selected thread row. The capsule fades/slides in/out, and after scrolling completes the target row gets a brief pulse.
- The archive icon (`archivebox.fill`) appears in the trailing area. Clicking it must not select the row — `SidebarOutlineView.mouseDown` intercepts clicks on the archive button directly.

## Implementation Notes

- Capsule geometry is defined in `AlwaysEmphasizedRowView`:
  - `capsuleLeadingInset` / `capsuleTrailingInset` — inset from row edges to capsule border. The overlay vertical scroller floats over the trailing inset region, so the capsule itself is never visually clipped. To avoid capsule-width jitter when the scroller appears/disappears (e.g. on window deactivate/reactivate, or on mouse hover expanding the overlay scroller), `refitOutlineColumnIfNeeded` sizes the column from `scrollView.bounds.width` rather than `contentView.bounds.width`. The outline view's `columnAutoresizingStyle` is set to `.noColumnAutoresizing` and the column's `resizingMask` is `[]` — otherwise AppKit's own last-column autoresize shrinks the column whenever the clip view narrows transiently (overlay-scroller hover reserves a few pixels) and beats our manual refit to it.
  - `capsuleVerticalInset` — vertical inset.
  - `capsuleBorderWidth` / `capsuleBorderInset` — border stroke width and half-width.
  - `capsuleContentHPadding` / `capsuleContentVPadding` — padding from capsule inner edge to content (12pt each).
  - `capsuleCornerRadius` — 8pt.
- Shared constants in `ThreadListViewController`:
  - `sidebarHorizontalInset` = capsuleLeadingInset + borderInset + contentHPadding — leading content rail.
  - `sidebarTrailingInset` — trailing content rail (same derivation from trailing side).
  - `capsuleAlignedLeading` / `capsuleAlignedTrailing` — non-thread row alignment (project/section headers).
  - `addRepoRowHeight` — height for the `SidebarAddRepoRow`.
- Sidebar and changes-panel scroll views use `NonFlashingScrollView`. `flashScrollers()` is still gated by recent local `scrollWheel` input, but `reflectScrolledClipView(...)` is always forwarded to `super` so AppKit keeps tiling/geometry in sync during programmatic scroll restore and reload paths. Scroller visibility is still policy-driven (hidden without recent local input), which preserves anti-flicker behavior without risking stale layout.
- Bottom overlay spacing is reserved via a dedicated `SidebarBottomPadding` root item appended after projects. This keeps end-of-list scroll space deterministic regardless of changes-panel visibility.
- Outline view uses `indentationPerLevel = 0`. All indentation is managed via capsule-relative padding in `ThreadCell`.
- `AlwaysEmphasizedRowView.drawBackground(in:)` handles all selection/state drawing (not `drawSelection`). `selectionHighlightStyle = .none` on the outline view suppresses AppKit's own selection rect.
- `AlwaysEmphasizedRowView.isSelected.didSet` pushes `backgroundStyle` to child cell views and updates sign emoji selection color.
- `ThreadCell` owns the main-row accent bar, toggled via `configureAsMain(...)`.
- Dynamic row heights computed in `heightOfRowByItem` using `ThreadCell.estimatedDescriptionLineCount` (text width estimation) and `ThreadCell.sidebarRowHeight(descriptionLines:hasSubtitle:hasPRRow:narrowThreads:)`.
- The archiving overlay is owned by `AlwaysEmphasizedRowView`, covering the full row bounds.
- The priority capsule (`PriorityCapsuleView`) and duration badge (`TopBorderBadge`) are siblings inside a single horizontal `NSStackView` pinned to the trailing edge of `ThreadCell` (see `ensureDurationLabel()`). The stack uses `detachesHiddenViews = true` so either badge can collapse independently and the remaining one still sits flush against the trailing content inset. Both the stack and its arranged subviews keep `.required` horizontal hugging/compression so they never steal space from the text stack. `configurePriority(_:)` accepts `Int?` and hides the capsule for `nil`/out-of-range values. `priorityCapsule?.updateColors(...)` participates in the same `updateTopBorderBadgeColors()` appearance pass as the other border badges.
- Busy border animation is a rotating conic gradient (`CAGradientLayer` with `.conic` type) masked to the capsule border stroke via a `CAShapeLayer`. The gradient has a short bright accent-colored arc (~16% of the circumference) that blends into the subtle default border color. When the row is selected, the bright arc switches to white. Managed by `AlwaysEmphasizedRowView.startBusyBorderAnimation()`.
- All busy threads share a single animation epoch (`sharedAnimationEpoch`) set when the first thread becomes busy. Busy border rotation uses this epoch as its `beginTime`, so all busy threads animate in phase with each other. The epoch is never reset, so it persists across the app's lifetime.
- Spinner indicators were removed from `ThreadCell`'s trailing stack — the animated border replaces them.
- `StickyHeaderOverlayView` is a standalone view added as the topmost subview of `ThreadListViewController.view`. It mirrors project/section header styling (same fonts, insets, colors) without interactive controls (no disclosure/add buttons). The overlay height is managed by an external constraint updated by `updateStickyHeaders()`, which fires on every clip-view bounds change and after `reloadData()`. The overlay includes a `CAGradientLayer` fade below the opaque region. Click targets on the project/section regions fire `onProjectClicked`/`onSectionClicked` callbacks that animate-scroll the outline view to the actual header row (with the section offset by `projectRowHeight` so it sits below the sticky project header).

## Gotchas

- When displaying branch and worktree names together, check for equality first — if the same, show once.
- Keep the main-row accent bar at `sidebarHorizontalInset` so it aligns with non-main thread icons.
- `SidebarProjectMainSpacer` is skipped entirely when `projectHeaderToMainRowGap = 0` — inserting a 0-height spacer row crashes `NSOutlineView`.
- Do not rely on `NSScrollView.contentInsets` for overlay-aware bottom spacing in this sidebar. Effective behavior changes with sibling panel visibility; use explicit content padding rows (`SidebarBottomPadding`) instead.
- The PR/ticket row (`prRow`) contains `[jiraTicketTF, jiraBadge, dotSep, prNumTF, prBadge]` with `detachesHiddenViews = true`. Never merge branch/worktree and PR/ticket into one secondary line.
- CALayer colors from dynamic NSColor assets must be resolved inside `performAsCurrentDrawingAppearance`. `NSColor(resource:).withAlphaComponent(_:)` can snapshot the wrong drawing context at call time. Always create derived colors AND access `.cgColor` inside the `effectiveAppearance.performAsCurrentDrawingAppearance { }` block.
- The sticky header's `CAGradientLayer` uses non-flipped CALayer coordinates: `colors[0]` at `startPoint(y=0)` is the visual **bottom** of the layer. So the array must be `[transparent, opaque]` to fade from opaque (top, adjacent to headers) to transparent (bottom).
- Create-repo bootstrap must not depend on user-level git commit config. The seed commit path should pass transient `-c` overrides for identity and signing (`user.name`, `user.email`, `commit.gpgsign=false`) and skip local hooks (`--no-verify`) to avoid silent failures from machine-specific git config.
- Do not discard git stderr in create/import flows. Failure paths should surface the underlying git message to the user (alert/banner) so "does nothing" states are diagnosable.
- For sidebar/diff-panel scroller behavior, key-window checks are not sufficient in multi-Mac setups with Universal Control. Gate reveal on actual local scroll input instead of focus/hover state.

## Thread Row Naming/Description Contract

For non-main threads, render description on line 1 only when present; keep branch/worktree info on the branch-facing line with dot-separated segments (`branch · worktree · PR`). Keep dirty dot attached to the branch/worktree line, not the description line. Tooltip sections must skip missing fields/statuses. Generated task descriptions prefer 2-8 words and naturally cased text (do not force Title Case). Longer descriptions are allowed and should truncate with a trailing ellipsis when they exceed visible row lines.

## Auto Icon Assignment

AI-driven work-type icon assignment is allowed only when `AppSettings.autoSetThreadIconFromWorkType` is enabled and `MagentThread.isThreadIconManuallySet` is false. Any user-triggered icon change must mark `isThreadIconManuallySet = true`, including no-op re-selections of the current icon.
