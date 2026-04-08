# Sidebar Row Layout

Capsule-style sidebar with per-row rounded borders, dynamic heights, and badge overlays.

## User-Facing Behavior

- Every thread row is drawn inside a rounded-border capsule (`AlwaysEmphasizedRowView`).
  - **Selected**: accent-colored border and fill.
  - **Completion (unread)**: green border and fill.
  - **Waiting for input**: orange border and fill.
  - **Default**: subtle white border and fill.
- Status badges (pinned, rate-limit, keep-alive) are bare-icon badges sitting on the capsule's top border with a circular background on selected/completed rows.
- Duration badge is a pill on the capsule's bottom-right with a persistent border. The duration label tints with a color gradient based on thread age: light blue (<15 min), green (<8 hrs), yellow (<1 day), orange (<3 days), red (3+ days). This provides at-a-glance visual feedback on activity age.
- The `Main worktree` row shows a tinted accent bar at the leading edge (same inset as non-main thread icons).
- Regular thread rows use a three-line vertical stack:
  - line 1 (primary): task description when set; otherwise the branch name.
  - line 2 (secondary / `subtitleLabel`): branch · worktree when a description is shown; worktree only when no description and the worktree name differs from the branch; hidden otherwise.
  - line 3 (PR/ticket row): `jiraTicketLabel` + `jiraStatusBadge` + dot separator + `prNumberLabel` + `prStatusBadge`. Badges gated by `AppSettings.showJiraStatusBadges` / `showPRStatusBadges`. Ticket display gated by `AppSettings.jiraTicketDetectionEnabled`.
- Row heights are **dynamic** based on actual content (description lines, subtitle, PR row) with a minimum height matching 2 description lines + 2 metadata labels (1 line + 2 labels when `narrowThreads` is enabled).
- Sign emoji is rendered at the **row view** level (`AlwaysEmphasizedRowView`), centered on the capsule's leading edge (centerX = `capsuleLeadingInset`, centerY = row center). Not part of `ThreadCell`.
- Project repo names use system bold 20pt font.
- No separator divider between project groups; vertical gap (`projectHeaderInterProjectGap = 24pt`) handles spacing.
- The global "Add repository" button is a `SidebarAddRepoRow` at the top of the outline view's root items. It scrolls with the rest of the content — there is no sticky toolbar.
- **Sticky headers**: When the user scrolls past a project or section header, a floating overlay (`StickyHeaderOverlayView`) pins the project name (and current section, if applicable) at the top of the sidebar. A 12pt fade gradient softens the transition into scrolling content. Clicking a sticky header smoothly scrolls the sidebar to reveal the actual header row.
- The archive icon (`archivebox.fill`) appears in the trailing area. Clicking it must not select the row — `SidebarOutlineView.mouseDown` intercepts clicks on the archive button directly.

## Implementation Notes

- Capsule geometry is defined in `AlwaysEmphasizedRowView`:
  - `capsuleLeadingInset` / `capsuleTrailingInset` — inset from row edges to capsule border.
  - `capsuleVerticalInset` — vertical inset.
  - `capsuleBorderWidth` / `capsuleBorderInset` — border stroke width and half-width.
  - `capsuleContentHPadding` / `capsuleContentVPadding` — padding from capsule inner edge to content (12pt each).
  - `capsuleCornerRadius` — 8pt.
- Shared constants in `ThreadListViewController`:
  - `sidebarHorizontalInset` = capsuleLeadingInset + borderInset + contentHPadding — leading content rail.
  - `sidebarTrailingInset` — trailing content rail (same derivation from trailing side).
  - `capsuleAlignedLeading` / `capsuleAlignedTrailing` — non-thread row alignment (project/section headers).
  - `addRepoRowHeight` — height for the `SidebarAddRepoRow`.
- Outline view uses `indentationPerLevel = 0`. All indentation is managed via capsule-relative padding in `ThreadCell`.
- `AlwaysEmphasizedRowView.drawBackground(in:)` handles all selection/state drawing (not `drawSelection`). `selectionHighlightStyle = .none` on the outline view suppresses AppKit's own selection rect.
- `AlwaysEmphasizedRowView.isSelected.didSet` pushes `backgroundStyle` to child cell views and updates sign emoji selection color.
- `ThreadCell` owns the main-row accent bar, toggled via `configureAsMain(...)`.
- Dynamic row heights computed in `heightOfRowByItem` using `ThreadCell.estimatedDescriptionLineCount` (text width estimation) and `ThreadCell.sidebarRowHeight(descriptionLines:hasSubtitle:hasPRRow:narrowThreads:)`.
- The archiving overlay is owned by `AlwaysEmphasizedRowView`, covering the full row bounds.
- Busy shimmer animation is a `CAGradientLayer` mask on the content view, managed by `AlwaysEmphasizedRowView`.
- Busy border animation is a rotating conic gradient (`CAGradientLayer` with `.conic` type) masked to the capsule border stroke via a `CAShapeLayer`. The gradient has a short bright accent-colored arc (~16% of the circumference) that blends into the subtle default border color. When the row is selected, the bright arc switches to white. Managed by `AlwaysEmphasizedRowView.startBusyBorderAnimation()`.
- All busy threads share a single animation epoch (`sharedAnimationEpoch`) set when the first thread becomes busy. Both shimmer sweep and border rotation use this epoch as their `beginTime`, so all busy threads animate in phase with each other. This creates a cohesive visual effect where multiple busy threads pulse/rotate together. The epoch is never reset, so it persists across the app's lifetime.
- Spinner indicators were removed from `ThreadCell`'s trailing stack — the animated border replaces them.
- `StickyHeaderOverlayView` is a standalone view added as the topmost subview of `ThreadListViewController.view`. It mirrors project/section header styling (same fonts, insets, colors) without interactive controls (no disclosure/add buttons). The overlay height is managed by an external constraint updated by `updateStickyHeaders()`, which fires on every clip-view bounds change and after `reloadData()`. The overlay includes a `CAGradientLayer` fade below the opaque region. Click targets on the project/section regions fire `onProjectClicked`/`onSectionClicked` callbacks that animate-scroll the outline view to the actual header row (with the section offset by `projectRowHeight` so it sits below the sticky project header).

## Gotchas

- When displaying branch and worktree names together, check for equality first — if the same, show once.
- Keep the main-row accent bar at `sidebarHorizontalInset` so it aligns with non-main thread icons.
- `SidebarProjectMainSpacer` is skipped entirely when `projectHeaderToMainRowGap = 0` — inserting a 0-height spacer row crashes `NSOutlineView`.
- The PR/ticket row (`prRow`) contains `[jiraTicketTF, jiraBadge, dotSep, prNumTF, prBadge]` with `detachesHiddenViews = true`. Never merge branch/worktree and PR/ticket into one secondary line.
- CALayer colors from dynamic NSColor assets must be resolved inside `performAsCurrentDrawingAppearance`. `NSColor(resource:).withAlphaComponent(_:)` can snapshot the wrong drawing context at call time. Always create derived colors AND access `.cgColor` inside the `effectiveAppearance.performAsCurrentDrawingAppearance { }` block.
- The sticky header's `CAGradientLayer` uses non-flipped CALayer coordinates: `colors[0]` at `startPoint(y=0)` is the visual **bottom** of the layer. So the array must be `[transparent, opaque]` to fade from opaque (top, adjacent to headers) to transparent (bottom).

## Thread Row Naming/Description Contract

For non-main threads, render description on line 1 only when present; keep branch/worktree info on the branch-facing line with dot-separated segments (`branch · worktree · PR`). Keep dirty dot attached to the branch/worktree line, not the description line. Tooltip sections must skip missing fields/statuses. Generated task descriptions are short (2-8 words) and naturally cased (do not force Title Case).

## Auto Icon Assignment

AI-driven work-type icon assignment is allowed only when `AppSettings.autoSetThreadIconFromWorkType` is enabled and `MagentThread.isThreadIconManuallySet` is false. Any user-triggered icon change must mark `isThreadIconManuallySet = true`, including no-op re-selections of the current icon.
