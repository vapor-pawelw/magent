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
5. Watch the GitHub `Release` workflow in the source repo until completion
6. Verify the public `vapor-pawelw/magent-releases` release contains `Magent.dmg` (plus compatibility `Magent.zip`)
7. Verify `homebrew-magent/Casks/magent.rb` was updated to the same version

If your tap repo is different, set:

```bash
MAGENT_HOMEBREW_TAP_REPO=<owner>/<repo> ./scripts/release-interactive.sh
```

If you ever need a non-default public release host, set:

```bash
MAGENT_RELEASE_REPO=<owner>/<repo> ./scripts/release-interactive.sh
```

Manual flow (equivalent) is also tag-driven, but should use an annotated tag body:

```bash
git tag -a v1.2.0 -m "<release notes from CHANGELOG.md>"
git push origin v1.2.0
```

This triggers a GitHub Actions workflow that:

1. Builds `Magent.app` (unsigned)
2. Publishes a GitHub Release to `vapor-pawelw/magent-releases` with `Magent.dmg`, a compatibility `Magent.zip`, and tag-annotation release notes
3. Auto-updates the Homebrew cask formula with the new version, SHA, and the public release download URL for `Magent.dmg`

The release workflow also rebuilds `Libraries/GhosttyKit.xcframework` using `./scripts/bootstrap-ghosttykit.sh` (instead of relying on git-lfs artifacts).

Commits on `main` without a tag do **not** produce a release.

Release artifacts are intentionally published to the public release-only repository `vapor-pawelw/magent-releases`. Keep source code out of that repo; it exists only to host releases and stable download URLs for in-app updates and Homebrew.

The workflow currently reuses the existing `HOMEBREW_TAP_TOKEN` secret for the cross-repo release publish step, so that token must keep write access to both `vapor-pawelw/magent-releases` and `vapor-pawelw/homebrew-magent`.

## Public Release Hosting

User-facing behavior:
- GitHub release downloads, in-app update checks, and Homebrew cask downloads all resolve against `vapor-pawelw/magent-releases`.
- The source repository remains the place where tags are pushed and where the `Release` workflow runs.

Implementation details:
- `scripts/release-interactive.sh` watches the source repo workflow, but verifies the final release in `vapor-pawelw/magent-releases`.
- `.github/workflows/release.yml` builds from the source repo, then publishes `Magent.dmg` and `Magent.zip` to the public release repo.
- The Homebrew cask is updated with the public `https://github.com/<owner>/<repo>/releases/download/<tag>/Magent.dmg` URL instead of a private GitHub API asset URL.

What changed in this thread:
- Created the dedicated public `vapor-pawelw/magent-releases` repository as a release-only host.
- Switched Magent's update-check endpoint and release automation defaults to that repo.
- Removed the previous documentation path that told users to rely on private-source-repo release access for installs and updates.

Gotchas for future agents:
- Do not add application source code to `vapor-pawelw/magent-releases`; keep it limited to releases and minimal repository metadata like `README.md`.
- If you change the release host repo, update all three surfaces together: `UpdateService`, `scripts/release-interactive.sh`, and `.github/workflows/release.yml`.
- The public release repo does not need to share git history with the source repo; release tags there exist only to anchor release pages and assets.

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
