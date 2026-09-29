---
name: repo-sync
description: >-
  Keep local clones of the enrolled repos current by cloning missing ones
  and fast-forward pulling the rest, read-only toward GitHub. Use when the
  local working copies that the scanner, fixer, and report programs read
  need to be up to date, or when the daily repo-sync cron job runs.
license: Complete terms in LICENSE.txt
---

# Repo Sync

Keep local clones of the enrolled repos current so the scanner, fixer, and report programs operate on up-to-date working copies. The script only clones and fast-forward pulls. It never pushes, opens PRs, resets, or deletes.

**Run scripts with `--help` first** to see full usage and options. The script lives in the automation repo, not in this repo, so run it from an automation checkout.

## Prerequisites

- `bash` 4+ (macOS ships 3.2; use `brew install bash` for 4+)
- `git`
- a readable `~/.repoman/repos.json` (the enrolled set)
- repoman config providing `REPOS_DIR`

### Requirements (machine-readable)

- pat_scopes: []
- labels_required: []
- labels_applied: []
- programs: [repo-sync]

## Before Running

### 1. Confirm the enrolled set

The source of truth is `~/.repoman/repos.json`, the enrolled repos. This is not `gh repo list <org>`, and there is no `$ORG` fallback. If the enrolled-repos file cannot be read, the run fails loud.

```bash
cat ~/.repoman/repos.json
```

### 2. Confirm REPOS_DIR

`REPOS_DIR` comes from repoman config. Each enrolled `owner/name` is cloned into `<REPOS_DIR>/<owner>/<name>/` (owner-namespaced) if missing, or fast-forward pulled if the clone already exists.

### 3. (optional) Confirm the agent-skills clone for `--refresh-skills`

If you plan to pass `--refresh-skills`, confirm a local agent-skills clone exists at `REPOMAN_SKILLS_DIR` (default `~/agent-skills`). The flag refreshes an existing clone; it does not create one.

## Running Repo Sync

Plain run, from an automation checkout:

```bash
bash scripts/repo-sync.sh
```

With the optional skills refresh, which also fast-forward pulls the local agent-skills clone after syncing repos:

```bash
bash scripts/repo-sync.sh --refresh-skills
```

`--help` prints usage and exits 0. An unknown argument exits 2.

## Interpreting Output

The run ends with a summary line:

```
repo-sync: pulled N cloned N failed N
```

When any repo failed, a `failed repos:` list follows, naming each failed repo with its one-line git error.

## Safety

- Read-only toward GitHub: clones and fast-forward pulls only, never pushes, opens PRs, resets, or deletes.
- Per-repo failures (clone, pull, or directory creation) are logged and non-fatal; the run continues with the rest of the enrolled repos.
- Reading repoman config and the enrolled-repos file are prerequisites; if either fails, the whole run aborts non-zero.
- With `--refresh-skills`, a missing skills clone is a fatal error (non-zero exit); repo-sync does not bootstrap it.
- The script's overall exit code comes only from the skills-refresh step. Per-repo sync failures never change the exit code.
- Runs daily via a cron job named `repo-sync`.
