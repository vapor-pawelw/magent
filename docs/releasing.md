# Releasing

Before releasing, make sure `CHANGELOG.md` has user-facing notes under `## Unreleased`.
See [docs/changelog.md](./changelog.md) for the changelog workflow.

Use the interactive helper to run the full release flow:

```bash
./scripts/release-interactive.sh
```

It will:

1. Ask for the target version
2. Promote `CHANGELOG.md` `## Unreleased` notes into a versioned section
3. Commit and push the changelog update
4. Create and push an annotated git tag with changelog notes
5. Watch the GitHub `Release` workflow until completion
6. Verify the GitHub release on `vapor-pawelw/mAgent` contains `Magent.dmg` (plus compatibility `Magent.zip`)
7. Verify `homebrew-tap/Casks/magent.rb` was updated to the same version

If your tap repo is different, set:

```bash
MAGENT_HOMEBREW_TAP_REPO=<owner>/<repo> ./scripts/release-interactive.sh
```

Manual flow (equivalent) is also tag-driven, but should use an annotated tag body:

```bash
git tag -a v1.2.0 -m "<release notes from CHANGELOG.md>"
git push origin v1.2.0
```

This triggers a GitHub Actions workflow that:

1. Builds `Magent.app` (unsigned)
2. Publishes a GitHub Release to `vapor-pawelw/mAgent` with `Magent.dmg`, a compatibility `Magent.zip`, and release notes taken from the matching `CHANGELOG.md` version section (`## <version> - <date>`)
3. Auto-updates the Homebrew cask formula in `vapor-pawelw/homebrew-tap` with the new version, SHA, and the public release download URL for `Magent.dmg`

The release workflow also rebuilds `Libraries/GhosttyKit.xcframework` using `./scripts/bootstrap-ghosttykit.sh` (instead of relying on git-lfs artifacts).

Commits on `main` without a tag do **not** produce a release.

Release artifacts are published directly on the source repository `vapor-pawelw/mAgent`. The workflow uses `GITHUB_TOKEN` for creating releases on the same repo, and `HOMEBREW_TAP_TOKEN` for pushing cask updates to `vapor-pawelw/homebrew-tap`.

If previously published releases have incorrect notes, you can backfill them from `CHANGELOG.md`:

```bash
./scripts/sync-release-notes-from-changelog.sh --from-version 1.2.1
```

## Changelog Guidelines

When updating `CHANGELOG.md` for a release or pre-release notes:

1. Keep pending release notes under `## Unreleased`, then let `./scripts/release-interactive.sh` promote them into the versioned section.
2. Group notes by domain using `### <Domain>` headings (for example: `Thread`, `Sidebar`, `Settings`, `Agents`).
3. Omit empty domains; only keep headings that have at least one note.
4. Keep `Thread` as a single top-level domain by default; avoid permanent split domains like `Thread: Rename`.
5. Within each domain, split entries into `#### Features` and `#### Bug Fixes` when both exist, with bug fixes listed below features.
6. If one topic dominates in a domain for a specific release, use an optional temporary `##### <Topic>` subheading inside `#### Features`/`#### Bug Fixes` and drop it once no longer needed.
7. Include only:
   - New features
   - Bug fixes
   - Performance improvements
8. Omit implementation details, internal refactors, tooling-only changes, and infrastructure-only updates.
9. Within each subsection, order entries by user impact:
   - Put broad/high-impact items first and describe them at a higher level.
   - Keep niche or smaller items shorter and place them near the end.
10. Use user-facing wording focused on outcomes, not code internals.

## Feature Flags

For features that should stay in the codebase but not ship yet, add a dedicated `FEATURE_*` active compilation condition in `Project.swift`, gate behavior behind that flag, hide related UI in release builds, and annotate debug-only Settings surfaces with `Debug builds only`.
