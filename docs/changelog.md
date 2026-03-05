# Changelog Workflow

`CHANGELOG.md` is the source of truth for release notes.

## During normal work

For every user-visible change, add a short bullet under `## Unreleased` in `CHANGELOG.md`.

Before any agent-driven commit, run a changelog check on the pending diff and include any needed `## Unreleased` updates in that same commit.

Guidelines:

- Group notes by product domain using `### <Domain>` headings (for example: `Thread`, `Sidebar`, `Settings`, `Agents`).
- Hide empty domains; only include a domain heading when it has at least one note.
- Focus on behavior users can notice (new features, fixes, UX changes).
- Skip internal-only refactors unless they affect user outcomes.
- Keep bullets short and specific.
- Within each domain, order bullets by user impact (broad/high-impact first, niche/smaller later).
- Within each domain, keep user-facing additions/UX improvements above bug fixes and technical improvements.

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
