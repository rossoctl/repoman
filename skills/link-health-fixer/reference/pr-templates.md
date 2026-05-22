# PR Format

The fixer creates fork-based PRs with the following structure.

## PR Title

```
docs: Fix <N> broken internal link(s) in <repo>
```

## PR Body

```markdown
Automated fix by Link Health Fixer.
Broken internal links updated to point to current file locations.

| File | Old Path | New Path |
|------|----------|----------|
| `docs/guide.md` | `src/old-module.md` | `src/new-module.md` |
```

## Branch Naming

```
fix/broken-links-<repo>-<YYYY-MM-DD>
```

## Commit Format

```
docs: Fix broken internal links in <repo>

Automated fix by Link Health Fixer (YYYY-MM-DD).

Signed-off-by: <author> <email>
```

## Fork Workflow

1. Fork is created under `--fork-owner` account if it doesn't exist
2. Branch is pushed to the fork
3. Cross-fork PR is opened against upstream `main`
4. Each fixed issue gets a comment linking to the PR

## Issue Comments

When a fix is submitted, the fixer comments on the original issue:

```
Fix submitted: <pr_url>. The broken link in `<file>` has been updated to point to `<new_path>`.
```

When a link cannot be fixed automatically:

```
Unable to find an automated fix: file `<path>` not found in `<repo>`
(searched for renames, filename matches, and extension variants).
This may require manual investigation.
```
