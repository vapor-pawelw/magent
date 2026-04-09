# Changelog Workflow

`CHANGELOG.md` is the source of truth for release notes.

## During normal work

For every user-visible change, add a short bullet under `## Unreleased` in `CHANGELOG.md`.

Before any agent-driven commit, run a changelog check on the pending diff and include any needed `## Unreleased` updates in that same commit.

Guidelines:

- Group notes by product domain using `### <Domain>` headings (for example: `Thread`, `Sidebar`, `Settings`, `Agents`).
- Hide empty domains; only include a domain heading when it has at least one note.
- Keep `Thread` as a single top-level domain by default. Do not split it into permanent domains like `Thread: Rename`.
- Within each domain, use `#### Features` and `#### Bug Fixes` subsections when both exist, with `#### Bug Fixes` listed below `#### Features`.
- If one topic inside a domain dominates a release, use an optional temporary `##### <Topic>` subheading inside `#### Features` or `#### Bug Fixes` (for example `##### Rename`) and remove it in later releases when no longer needed.
- Focus on behavior users can notice (new features, fixes, UX changes).
- Skip internal-only refactors unless they affect user outcomes.
- Keep bullets short and specific.
- Within each subsection, order bullets by user impact (broad/high-impact first, niche/smaller later).
- **Prune superseded entries within the same unreleased cycle**: if a change is introduced and then fully reverted before any release, remove the original entry rather than adding a "removed" or "reverted" note. If a change introduces a regression that is fixed before any release, update or remove the original bullet rather than adding a separate "fix" entry — users will never see the broken state, so the changelog should reflect only the net outcome.

## During release

Run:

```bash
./scripts/release-interactive.sh
```

The script will:

1. Read notes from `CHANGELOG.md` under `## Unreleased`
2. Move them to a versioned section (`## <version> - <YYYY-MM-DD>`)
3. Commit and push the changelog update
4. Create an annotated tag containing the new version section
5. Push the tag and verify release/homebrew automation

GitHub Releases read release notes from the matching `CHANGELOG.md` version section first, with annotated-tag fallback.
