# Changelog Workflow

`CHANGELOG.md` is the source of truth for release notes.

## During normal work

For every user-visible change, add a short bullet under `## Unreleased` in `CHANGELOG.md`.

Guidelines:

- Focus on behavior users can notice (new features, fixes, UX changes).
- Skip internal-only refactors unless they affect user outcomes.
- Keep bullets short and specific.
- Order bullets by user impact (broad/high-impact first, niche/smaller later).

## During release

Run:

```bash
./scripts/release-interactive.sh
```

The script will:

1. Read notes from `CHANGELOG.md` under `## Unreleased`
2. Move them to a versioned section (`## <version> - <YYYY-MM-DD>`)
3. Commit and push the changelog update
4. Create an annotated tag containing those notes
5. Push the tag and verify release/homebrew automation

GitHub Releases use the tag annotation body, so release notes match the changelog.
