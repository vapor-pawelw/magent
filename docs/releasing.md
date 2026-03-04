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
3. Auto-updates the Homebrew cask formula with the new version and SHA

Commits on `main` without a tag do **not** produce a release.

## Changelog Guidelines

When updating `CHANGELOG.md` for a release or pre-release notes:

1. Keep pending release notes under `## Unreleased`, then let `./scripts/release-interactive.sh` promote them into the versioned section.
2. Include only:
   - New features
   - Bug fixes
   - Performance improvements
3. Omit implementation details, internal refactors, tooling-only changes, and infrastructure-only updates.
4. Order entries by user impact:
   - Put broad/high-impact features first and describe them at a higher level.
   - Keep niche or smaller items shorter and place them near the end.
5. Use user-facing wording focused on outcomes, not code internals.
