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
6. Verify the release contains `Magent.zip`
7. Verify `homebrew-magent/Casks/magent.rb` was updated to the same version

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
2. Creates a GitHub Release with `Magent.zip` and tag-annotation release notes
3. Auto-updates the Homebrew cask formula with the new version, SHA, and private GitHub asset API URL

The release workflow also rebuilds `Libraries/GhosttyKit.xcframework` using `./scripts/bootstrap-ghosttykit.sh` (instead of relying on git-lfs artifacts).

Commits on `main` without a tag do **not** produce a release.

## Private Repo Homebrew Notes

`magent` release assets are private. Homebrew users need a GitHub token with access to `vapor-pawelw/magent`:

```bash
export HOMEBREW_GITHUB_API_TOKEN=ghp_xxx
```

The cask download strategy uses this token to fetch `Magent.zip` from the GitHub Releases API.

## Changelog Guidelines

When updating `CHANGELOG.md` for a release or pre-release notes:

1. Keep pending release notes under `## Unreleased`, then let `./scripts/release-interactive.sh` promote them into the versioned section.
2. Group notes by domain using `### <Domain>` headings (for example: `Thread`, `Sidebar`, `Settings`, `Agents`).
3. Omit empty domains; only keep headings that have at least one note.
4. Include only:
   - New features
   - Bug fixes
   - Performance improvements
5. Omit implementation details, internal refactors, tooling-only changes, and infrastructure-only updates.
6. Within each domain, order entries by user impact:
   - Put broad/high-impact features first and describe them at a higher level.
   - Keep niche or smaller items shorter and place them near the end.
7. Within each domain, keep user-facing additions/UX improvements above bug fixes and technical improvements.
8. Use user-facing wording focused on outcomes, not code internals.
