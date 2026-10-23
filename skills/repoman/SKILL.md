---
name: repoman
description: >-
  The RepoMan entrypoint. Invoke for anything RepoMan-related: first-time
  setup, enabling or configuring a program, enrolling repos or an org, or
  running a program against named repos. A single intent-dispatching skill
  that infers setup-vs-activate from ~/.repoman/ state and asks only on
  genuine ambiguity, always with enumerated options.
license: Complete terms in LICENSE.txt
---

# RepoMan

RepoMan runs automated maintenance **programs** (PR review, link-health,
dependency bumps, weekly reports, repo sync) across a set of GitHub repos you
enroll once. It handles the capability checks and output wiring for you.

`/repoman` is a single **intent-dispatching** entrypoint, not a mode you
pre-select. It reads `~/.repoman/` state and the user's message, infers whether
this is first-time setup, activating a program, or running one, and asks only
when something is genuinely ambiguous — always with explicit, enumerated
options (the driver may be a mid/low-tier model, so never require free-form
reasoning to answer).

## HARD INVARIANT: never write `~/.repoman/` directly

**This is the single most important rule in this skill.** You (the skill
driver) MUST NOT create, edit, append to, or delete any file under
`~/.repoman/` with your own tools — not `config.json`, not `repos.json`, not
`programs/<name>.json` — not with Write, Edit, `echo >`, `jq > file`, `tee`, or
any other direct means.

**Every mutation of `~/.repoman/` goes through a `repoman-setup.sh` subcommand**
(`init-config`, `add-repo`, `enable-program`, `set-requirements`, `set-output`).
That writer is the sole owner of validation, schema shape, atomicity, and dedup.
A hand-written file bypasses `validate_repos_dir`, owner/name dedup, the
known-program allowlist, and CSV→array normalization — all of which you would
otherwise have to re-derive and would get subtly wrong.

You may **read** `~/.repoman/` freely (via the `org.sh` helpers and plain reads)
to infer state. You write it only by calling the setup writer.

## Where the scripts live

The entire engine is **bundled with this plugin** under
`${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/` — there is no separate automation
checkout to install or locate. Resolve that directory at runtime via
`${CLAUDE_PLUGIN_ROOT}` and point the orchestrator at it with
`REPOMAN_RUN_BIN="${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts"` (the existing
run-time override `repoman-run.sh` reads). The scripts are a flat set, so each one
sources its siblings (`program-lib.sh`, `org.sh`, …) from that same directory.

- **Read-state / reconcile helpers** (`org.sh`): the enrolled-set resolver and
  `repoman_match_name` (bare-name → enrolled owner lookup). Source these to read
  state and reconcile names.
- **The writer `repoman-setup.sh`, the capability gate `repoman-check.sh`, and
  the orchestrator `repoman-run.sh`** are **commands** — run them from the bundled
  scripts dir, `--help` first to see full usage. `repoman-requirements.sh` is
  **not** a command: it is a sourced library that exposes the function
  `repoman_parse_requirements`. You must **source it, then call the function** —
  `source "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/repoman-requirements.sh"`
  then `repoman_parse_requirements <skill-md>`. Never execute it directly (e.g.
  `repoman-requirements.sh <skill-md>`): a direct run does **not** emit the JSON
  — once rossoctl/automation#113 lands it fails loud with this same guidance,
  and before that it exits 0 with empty output (which, captured and parsed as
  `[]`, would silently write empty requirements). Either way, sourcing is the
  only correct path.

Program-name → agent-skills `SKILL.md` directory map (canonical allowlist name
on the left, skill dir on the right):

| Program (allowlist) | Skill directory |
|---------------------|-----------------|
| `link-health` | `skills/link-health-scanner/` |
| `dep-bump` | `skills/dep-bump-scanner/` |
| `pr-review` | `skills/github-pr-review/` |
| `automation-health` | `skills/automation-health-dashboard/` |
| `repo-sync` | `skills/repo-sync/` |

## State-inference decision tree

Your **first action** is to read `~/.repoman/config.json` and classify. Let
`SETUP = config.json exists and parses`, and `INTENT = the message names a
program and/or a target to act on` — where a *target* is one or more
`owner/name` slugs, bare repo names, or an org. Distinguishing an org token from
a bare repo name is a reconciliation step (see "Org-vs-repo detection"), never a
free-form judgment.

```
read ~/.repoman/config.json
  |> SETUP?
      no  -> INTENT?
               no  -> show the WELCOME ORIENTATION (what RepoMan does, which
                      programs ship, that it is open source), THEN begin the
                      first-time setup conversation (five questions)
               yes -> AMBIGUOUS COLD START: ask the user (enumerated):
                        A. set up now, then run the named intent (one flow)
                        B. just set up now; re-invoke to run later
                      (never guess)
      yes -> INTENT present?
               no  -> no actionable intent: show the ORIENTATION tailored to an
                      existing user — summarize current setup, list ENABLED
                      programs, list what else is AVAILABLE to activate, and the
                      open-source invitation (read-only; no writes)
               yes -> INTENT names a program not yet enabled?
                        yes -> activate: enable-program + requirement wiring,
                               then (if INTENT also names a run) reconcile + hand off
                        no  -> classify each named target (org-vs-repo detection),
                               reconcile targets vs enrolled set, hand off
```

The only question this tree forces unprompted is the **cold-start conflict**
(SETUP absent, INTENT present) — the one case where "no setup" and "an explicit
run request" genuinely contradict, so the user decides. Everything else is
inference over state.

### Cold start with intent (the one forced question)

When invoked with an intent but no setup, the signals conflict: the request says
"run," the state says "nothing is configured." Surface this with two enumerated
options and do **not** pick for the user:

- **A — Fold the run into setup:** run the five-question conversation using the
  named repos/program as the defaults for Q2 (repos) and Q3 (program), then
  reconcile + hand off the requested run. One continuous conversation.
- **B — Setup only:** complete and confirm setup, then stop. The user
  re-invokes `/repoman` to run.

## Welcome orientation (new-user acquisition)

Whenever you reach a **no-intent branch** — a brand-new user with no setup, or a
returning user who invoked `/repoman` with no concrete ask — lead with a short,
plain-language orientation *before* any question or summary. A user who does not
yet know what RepoMan is cannot sensibly answer "which programs do you want to
run?"; onboarding is a first-class flow, not a side effect of setup.

Keep it a brief, enumerated briefing (not a wall of prose), inferred from live
state so it never lies about what is installed:

1. **What RepoMan does, in one or two sentences** — it runs automated
   maintenance programs across a set of GitHub repos you enroll once, handling
   capability checks and output wiring for you.
2. **Which programs ship and are ready to deploy** — present each with its
   **friendly display name** (see "Friendly program names" below), and its
   one-line description read from the program's `SKILL.md` (the same source the
   gate uses; use the program→skill-dir map above). The authoritative backend
   names remain the `KNOWN_PROGRAMS` allowlist in `repoman-setup.sh`
   (`link-health`, `dep-bump`, `pr-review`, `automation-health`, `repo-sync`) —
   show the friendly names to the user, resolve back to the canonical token
   before any writer call. The description in each `SKILL.md` frontmatter is
   usually a YAML **folded block scalar** (`description: >-` with the text on the
   following indented lines), not an inline value; read the folded block, not the
   literal `>-`. For a returning user, split into **enabled** (already active in
   `~/.repoman/programs/`) vs **available to activate**.
3. **What else can be activated** — the available-but-not-enabled set, so the
   path to "turn on one more program" is visible without the user guessing a
   name.
4. **Open invitation** — RepoMan is open source and welcomes new programs; point
   to the repo and the program-authoring path (`docs/program-template.md`).

For a **new user**, the orientation flows directly into the five-question setup
(they have now seen what they are enrolling into). For a **returning user** with
no intent, it ends read-only: a summary of their current setup plus the
enabled/available split, with no writes and no forced question — they say what
they want in a follow-up turn.

The orientation makes **no** `~/.repoman/` writes; it is pure presentation over
inferred state.

## Presentation (naming, pacing, and choice UI)

These rules shape every user-facing prompt. They never change what gets written
(the writer and its allowlist stay canonical); they shape only how you ask.

### Friendly program names

Present programs by a friendly display name, accept close/fuzzy input, and
resolve back to the canonical `KNOWN_PROGRAMS` token **before any writer call**.
The allowlist stays the single source of truth — `enable-program` and
`set-requirements` validate against the canonical token, so a friendly name that
does not resolve must never reach them.

| Friendly name (shown) | Canonical token (backend) |
|-----------------------|---------------------------|
| Link-Health-Manager | `link-health` |
| Dep-Bump-Manager | `dep-bump` |
| PR-Review-Manager | `pr-review` |
| Automation-Health-Manager | `automation-health` |
| Repo-Sync-Manager | `repo-sync` |

Match user input leniently against this list: "pr review", "pr-review-manager",
and "prmanager" all resolve to `pr-review`; "dep bump" → `dep-bump`. **Always**
present the choices as an enumerated list so a mid/low-tier driver resolves by
selection, never by free-form reasoning. If an input is ambiguous or matches
nothing, re-ask with the enumerated list — do not guess.

### Pacing (keep setup fast)

Setup should feel like it takes under five minutes. Follow a tight loop per
question: **what is missing → what to input (with a default) → what to expect
next.** Keep prompts terse and enumerated; one question at a time. Do **not**
narrate internals — script names, `--help` output, parse mechanics, subcommand
wiring — in user-facing prompts. Still *perform* those checks (run `--help`,
source libraries, verify state), but surface them only when something is
genuinely ambiguous or an error needs the user's attention.

### Choice UI

If the host exposes a structured single/multi-select prompt (e.g. radio buttons
with a free-form "other" field), prefer it to render the enumerated options for
the program choice (Q3) and the nightly-sync choice (Q4): it demonstrates both
structured selection and natural free-form input in one widget. Fall back to a
numbered markdown list when no such tool is available. Either way the
enumerated-options contract holds. Note a host picker may cap the number of
options (Claude Code's caps at four); when there are more programs than slots,
show the most likely options and rely on the free-form "other" field for the
rest.

## Setup conversation (five questions)

Ask one question at a time; each offers a sensible default so a user can accept
the whole flow quickly. Every write goes through `repoman-setup.sh` — never
write `~/.repoman/` files directly. The questions follow the canonical five in
the architecture spec (§Setup flow), each mapping to one subcommand (or, for Q2
Option B and Q4, a step that resolves inputs *then* calls the writer).

| # | Question | Default | Subcommand / step |
|---|----------|---------|-------------------|
| Q1 | Where should repo clones live? Who is the fork owner? | `~/repoman/repos` (a subdir, so `validate_repos_dir` accepts it) + the user's `gh` login | `init-config --repos-dir <path> --fork-owner <owner>` |
| Q2 | Which repos to enroll? **Option A** — individual `owner/name` slugs or URLs (repeatable). **Option B** — enroll an entire org. | from the named intent if present, else prompt | A: `add-repo (--owner <o> --name <n>)...`. B: see "Org enrollment" (resolve the org's repo list, then `add-repo`). |
| Q3 | Which program(s) to enable now? | from the named intent if present, else none | `enable-program --program <name>` (per program) + requirement wiring (below) |
| Q4 | Set up nightly repo sync? (keeps clones fresh for scanners) | yes | `enable-program --program repo-sync` (deferred: user can add later) |
| Q5 | *(not asked at setup)* Output destination is asked the first time each program is invoked, not here. | — | — |

**Output mode is NOT a setup question.** The architecture spec defers it to the
first invocation of each program: "Same repo as the finding" (default) vs "one
central repo." That first-invocation prompt drives
`set-output --program <name> --mode same|central [--repo <owner/name>]`. It is
listed here only to make the five-question boundary explicit — setup does not ask
it, so a user is not forced to decide output routing before they have ever run
anything.

**Capability check** (`repoman-check.sh --program <name>
[--create-missing-labels]`) likewise runs at invocation time, not as a setup
question. You may offer to run it once at the end of setup as a convenience, but
it is not one of the five.

**Q1 path rejection.** `validate_repos_dir` (in `org.sh`) rejects empty values,
dangerous system paths, `$HOME` itself, and non-existent dirs. The last clause
matters on a fresh system: `~/repoman/repos` is a safe subdir path, but it does
not exist until something creates it, and `init-config` only `mkdir -p`s the
config file's parent under `~/.repoman/` — never `--repos-dir`. So before
calling `init-config`, `mkdir -p` the chosen repos dir. That directory is
outside `~/.repoman/`, so creating it does **not** violate the hard invariant
(which guards only `~/.repoman/` state). If a user-offered path is rejected for
any other reason, re-prompt with the specific reason the validator gave — do
**not** silently fall back to the default.

**Q3 requirement wiring.** For each program the user enables:

1. locate that program's `SKILL.md` (via the program→skill-dir map above, e.g.
   `skills/github-pr-review/SKILL.md`);
2. **source** the parser library once, then call the function:
   `source "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/repoman-requirements.sh"` →
   `repoman_parse_requirements <skill-md>` →
   `{"pat_scopes":[...],"labels_required":[...],"labels_applied":[...],"programs":[...]}`.
   Do **not** execute the script directly — it is a sourced library, not a
   command, and running it as a command does not emit the JSON (post
   rossoctl/automation#113 it fails loud; before that it exits silently empty).
   If you ever capture empty output here, you executed it instead of sourcing
   it; source it and retry (empty requirements would silently defeat the
   capability gate);
3. join each JSON array into a comma-separated string (empty array → empty CSV,
   which `set-requirements` normalizes back to `[]`);
4. call `set-requirements --program <name> --pat-scopes <csv>
   --labels-required <csv> --labels-applied <csv>`.

Parse `SKILL.md` **only** through `repoman_parse_requirements`; nothing else
reads that block.

**Q2 Option B — org enrollment.** The spec offers "enroll an entire org" as an
alternative to listing individual repos, and the same applies when a user's
*intent* names an org (e.g. "set up RepoMan for the `rossoctl` org"). First
confirm the token is an org via "Org-vs-repo detection" (below) — do **not**
assume a bare token is an org. The `add-repo` writer takes only explicit
`{owner, name}` pairs and does **not** expand an org, so once detection confirms
an org, expansion is a step you perform *before* calling the writer:

1. list the org's repos: `gh repo list <org> --json nameWithOwner,isArchived`;
2. filter out archived repos (and optionally forks/templates — ask, or default
   to excluding archived only);
3. present the resulting set for confirmation (count + the list, or a chance to
   deselect) — enrolling a large org is a big action;
4. enroll the confirmed set in one call by piping the JSON array of
   `{owner, name}` to `add-repo` on stdin (its documented array-on-stdin form),
   so the writer still owns dedup and validation.

The org-expansion `gh` call and filtering live here in the skill layer, never in
`add-repo` — the writer stays a pure writer with no `gh`. Enrolling an org is
still a set of `add-repo` entries on disk; there is no separate "org" record, so
later runs and reconciliation treat org-enrolled repos exactly like
individually-enrolled ones.

## Repo-selection reconciliation (activate / run)

Scanners resolve the enrolled set **internally** via `repoman_get_repos` (no
`--repos` flag exists anywhere; link-health/dep-bump drive from
`repoman_load_enrolled` + `enrolled_clone_dirs`, pr-review/weekly go straight to
GitHub). Reconciliation therefore lives **here, at the skill layer**; scanners
stay unchanged. Your job is to *narrow* the set when the user names repos, and to
catch names that cannot be run yet.

### Org-vs-repo detection (the single org-detection rule)

A bare token like `rossoctl` is lexically indistinguishable from a bare repo
name and a GitHub org slug, and you must **not** guess. This is the one place the
skill classifies a target as an org; both setup Q2 Option B and reconciliation
rule 6 route through it.

Given a bare token `T` (no `/`), classify in order:

1. **Enrolled bare name?** If `repoman_match_name T` emits any `owner/name`, `T`
   is a **repo name** (reconciliation rules 3–5 take over). An already-enrolled
   repo name wins — the user is almost certainly referring to a repo they
   enrolled, not an org of the same slug.
2. **Live org?** Otherwise probe once: `gh repo list T --limit 1`. Success
   (exit 0, non-empty) means `T` is a reachable org/user with repos → **org
   candidate**.
3. **Ambiguous or neither?** If the probe is inconclusive (e.g. `T` is both a
   plausible repo name the user has *not* enrolled and a reachable org), **ask**
   with enumerated options — "Did you mean the `T` org (enroll its repos), or a
   repo named `T` (which owner)?" — never guessing. If the probe fails outright
   (no such org, no enrolled match), fall through to rule 5 (not-enrolled bare
   name).

Once `T` is confirmed an org (step 2, or the org branch of step 3), expansion is
mechanical: `gh repo list T --json nameWithOwner,isArchived` → filter archived →
the `{owner, name}` pairs the primitives already consume. Detection is the only
hard part; after confirmation the existing `add-repo` array-on-stdin path and
`repoman_get_repos` reconciliation handle the rest.

### Reconciliation rules (per named token, setup already done)

1. **`owner/name` given, enrolled** → use it.
2. **`owner/name` given, not enrolled** → offer to enroll it now (via
   `add-repo`) and then run; if declined, drop it from the run.
3. **Bare `name`, exactly one enrolled owner** → resolve to that `owner/name`
   (via `repoman_match_name` — exactly one output line).
4. **Bare `name`, multiple enrolled owners** → ambiguous: surface the candidate
   `owner/name` list (`repoman_match_name` emits ≥2 lines) and ask which
   (enumerated options).
5. **Bare `name`, no enrolled owner** (`repoman_match_name` emits nothing) →
   treat as not-enrolled: offer to enroll (ask for the owner), else drop.
6. **An org named (no repo)**, e.g. "run pr-review on the `rossoctl` org" —
   classified as an org by "Org-vs-repo detection" (not guessed) → resolve to the
   set of that org's enrolled repos. If *some* of the org's live repos are not
   yet enrolled, offer to enroll the missing ones first (the Q2 Option B
   expansion flow), then run across the resolved org set.

When the user names **no** repos and **no** org → run across the whole enrolled
set (the current scanner default; hand off without a repo filter).

`repoman_match_name` output count maps directly onto the rules: **0 → rule 5,
1 → rule 3, ≥2 → rule 4.** Resolution happens here; the helper only answers the
lookup.

### Handoff to the run path (boundary only)

After reconciliation you hold a concrete, enrolled, unambiguous repo set (or the
whole set). The **run path** (capability-check → refresh clones → exec scanner →
write reports + `_index.json`) is a named follow-on — the "program invocation
wiring" half of [#107](https://github.com/rossoctl/automation/issues/107) (epic
[#72](https://github.com/rossoctl/automation/issues/72)) — and is **not
implemented in this skill**. Until it lands, complete reconciliation and
**report the resolved
`owner/name` set you *would* run** — do not attempt to exec a scanner yourself.
This keeps the setup/activate/reconcile flows fully usable on their own.

## Prerequisites

- `bash` 3.2+ (the macOS system default works; the bundled `org.sh` avoids bash
  4 features)
- `gh` (GitHub CLI, authenticated with org access) — for org detection/expansion
- `jq` (JSON processor)
- The RepoMan **engine**, bundled with this plugin at
  `${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/` (`repoman-setup.sh`,
  `repoman-check.sh`, `repoman-run.sh`, `repoman-requirements.sh`, and the
  program scanners). No separate checkout is required.

### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: []
- labels_applied: []
- programs: [entrypoint]

## The one new executable: `repoman_match_name`

Bundled in `scripts/org.sh`. Emits every enrolled `owner/name` whose name
component equals the given bare name, one per line; zero matches → no output,
return 0. Reads the enrolled set via `repoman_get_repos` (honoring
`REPOMAN_REPOS_FILE`) and propagates its fail-loud behavior on a
missing/empty/malformed `repos.json`. Whole-name match (substring-safe: `cort`
never matches `cortex`). bash 3.2-safe. The authoritative source and its unit
test (`tests/test-repoman-match-name.sh`) live in the automation repo; this is a
bundled copy.
