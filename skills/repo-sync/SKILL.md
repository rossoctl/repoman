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

- `bash` 3.2+ (the macOS system default works; the script avoids bash 4 features)
- `git`
- `jq` (the config and enrolled-set readers parse JSON with it)
- repoman config at `~/.repoman/config.json` (see Before Running for the keys)
- a readable `~/.repoman/repos.json` (the enrolled set)

### Requirements (machine-readable)

- pat_scopes: []
- labels_required: []
- labels_applied: []
- programs: [repo-sync]

## Before Running

### 1. Confirm the config

The repoman config lives at `~/.repoman/config.json`. Repo-sync reads `REPOS_DIR` from it (the root under which clones are namespaced), and repoman validates two required keys — `repos_dir` and `fork_owner` — even though repo-sync itself only uses `repos_dir`. A missing config or an empty required key fails the run loud.

```bash
cat ~/.repoman/config.json   # expects at least {"repos_dir": "...", "fork_owner": "..."}
```

The config and enrolled-set paths can be overridden for testing with the `REPOMAN_CONFIG_FILE` and `REPOMAN_REPOS_FILE` environment variables; unset, they default to `~/.repoman/config.json` and `~/.repoman/repos.json`.

### 2. Confirm the enrolled set

The source of truth is `~/.repoman/repos.json`, the enrolled repos. This is not `gh repo list <org>`, and there is no `$ORG` fallback. If the enrolled-repos file is missing, empty, or malformed JSON, the run fails loud — an unreadable enrolled set is never silently treated as "no repos."

```bash
cat ~/.repoman/repos.json
```

Each enrolled `owner/name` is cloned into `<REPOS_DIR>/<owner>/<name>/` (owner-namespaced) if missing, or fast-forward pulled if the clone already exists. An entry whose owner or name is not a single safe path segment (`[A-Za-z0-9._-]`, never `.`, `..`, or a slash) is rejected before any clone, so a crafted `repos.json` cannot escape the clone tree.

### 3. (optional) Confirm the agent-skills clone for the skills refresh

The skills refresh runs when you pass `--refresh-skills` **or** when `REPOMAN_SKILLS_DIR` is set (either trigger alone opts in; the flag wins if both are given). `REPOMAN_SKILLS_DIR` selects the clone path and defaults to `~/agent-skills`. Confirm that clone exists first — the refresh fast-forward pulls an existing clone and does not create one.

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

When any repo failed, a `failed repos:` list follows, naming each failed repo with the reason — a clone/pull entry carries git's one-line error; an entry rejected up front is labeled `invalid owner/name` or `mkdir failed`.

## Safety

- Read-only toward GitHub: clones and fast-forward pulls only, never pushes, opens PRs, resets, or deletes.
- Per-repo failures (clone, pull, directory creation, or an invalid owner/name) are logged and non-fatal; the run continues with the rest of the enrolled repos. As long as at least one repo succeeds, a partial sync still exits 0.
- Reading repoman config and the enrolled-repos file are prerequisites; if either fails, the whole run aborts non-zero.
- With `--refresh-skills`, a missing skills clone is a fatal error (non-zero exit); repo-sync does not bootstrap it.
- The run exits non-zero when a prerequisite read fails, when **every** enrolled repo fails (a total failure must not report success), or when a requested skills refresh fails. A *partial* per-repo failure does not change the exit code.
- Runs daily via a cron job named `repo-sync`.
