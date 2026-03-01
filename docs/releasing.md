# Releasing

Releases are driven by git tags. To publish a new version:

```bash
git tag v1.2.0
git push origin v1.2.0
```

This triggers a GitHub Actions workflow that:

1. Builds `Magent.app` (unsigned)
2. Creates a GitHub Release with the zipped app
3. Auto-updates the Homebrew cask formula with the new version and SHA

Commits on `main` without a tag do **not** produce a release.
