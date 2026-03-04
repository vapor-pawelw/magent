# Releasing

Use the interactive helper to run the full release flow:

```bash
./scripts/release-interactive.sh
```

It will:

1. Ask for the target version
2. Create and push the git tag
3. Watch the GitHub `Release` workflow until completion
4. Verify the release contains `Magent.zip`
5. Verify `homebrew-magent/Casks/magent.rb` was updated to the same version

If your tap repo is different, set:

```bash
MAGENT_HOMEBREW_TAP_REPO=<owner>/<repo> ./scripts/release-interactive.sh
```

Manual flow (equivalent) is tag-driven. To publish directly:

```bash
git tag v1.2.0
git push origin v1.2.0
```

This triggers a GitHub Actions workflow that:

1. Builds `Magent.app` (unsigned)
2. Creates a GitHub Release with the zipped app
3. Auto-updates the Homebrew cask formula with the new version and SHA

Commits on `main` without a tag do **not** produce a release.
