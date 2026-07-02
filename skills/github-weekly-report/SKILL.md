---
name: github-weekly-report
description: Generate comprehensive weekly activity reports for GitHub organizations showing merged PRs, open PR review status, new issues, CI health, active epics, and multi-repo contributor highlights with AI-synthesized Cross-Repo Highlights and Action Items. Use when the user wants a weekly summary, org activity report, "what happened this week" recap, or a GitHub org status update for a specific date range.
metadata: {"openclaw": {"requires": {"bins": ["gh", "python3"]}}}
---

# GitHub Weekly Report

Generate comprehensive weekly activity reports for GitHub organizations. Produces clean Markdown perfect for GitHub issues or documentation.

The report is produced in **two phases**:
1. **Phase 1 — Data collection** (`report.py`): fetches PRs, issues, CI runs, and active epics via the `gh` CLI and renders the mechanical sections.
2. **Phase 2 — AI synthesis** (you, the agent): reads the generated report and structured JSON, then writes the **Cross-Repo Highlights**, **Active Epics**, and **Action Items** sections using your own reasoning.

## Prerequisites

- **Python 3.8+**
- **GitHub CLI (`gh`)** — authenticated with access to the target org
- **Token scope**: `read:project` is optional — it only enriches the epic Status column from the Projects v2 board. Active-epic detection is sub-issue-based and works without it.

## Quick Start

```bash
# Report on current week (last 7 days) — also emit JSON for AI synthesis
python3 {baseDir}/scripts/report.py --org <org> --output report.md --json-output report-data.json

# Report on specific date range
python3 {baseDir}/scripts/report.py --org <org> --since 2026-03-23 --until 2026-03-30 --output report.md --json-output report-data.json

# Run epic tracker standalone (for debugging)
python3 {baseDir}/scripts/epic-tracker.py --org <org> --since 2026-03-23 --until 2026-03-30

# Post report to a GitHub issue
gh issue create -R <org>/<repo> --title "Weekly Report $(date +%Y-%m-%d)" --body-file report.md
```

## What the Report Includes

1. **Org-Wide Summary** — table with merged PRs, open PRs, open issues, new issues, CI pass rate, and status per repo
2. **Active Epics** — table of in-progress epics with leads, Key Results, and this-week activity
3. **Cross-Repo Highlights** — AI-synthesized narrative (see Phase 2 below)
4. **Per-Repo Deep Dives** — top contributors, merged PR table, open PRs by status (Ready to Merge / Changes Requested / Needs Review / Draft) with Notes flags, CI Health section, new issues
5. **Action Items** — AI-synthesized prioritized table (see Phase 2 below)

---

## Phase 2: AI Synthesis

After running `report.py`, read both the generated `report.md` and `report-data.json`. Use them to write three sections that require reasoning across the whole dataset.

### Active Epics

The script generates a baseline Active Epics table from `epic-tracker.py` output. Review it and enhance:

| Epic | Lead | Key Result | This Week |
|------|------|------------|-----------|
| [kagenti/kagenti#1789](https://github.com/kagenti/kagenti/issues/1789) OPA Authorization | @davidhadas | KR2: Zero-trust agent auth | 3 sub-issues closed, 4 open |
| [kagenti/kagenti-extensions#501](https://github.com/kagenti/kagenti-extensions/issues/501) Session Mgmt | @sahilsuneja1 | KR1: Stateful agent infra | 2 open, 1 PR merged |

Rules:
- Scan for the `epic` label across all repos in the org
- **Detection is sub-issue-based** (the primary signal): an epic is active if it has open sub-issues (backlog / in-progress) OR a sub-issue closed within the reporting window. This does not depend on the project board and needs no `read:project` scope. A merged-PR cross-reference in the window also counts.
- Board Status (Projects v2), when available, is **display-only enrichment** — it fills the status label but never gates inclusion. Teams often park active epics in an "Epics" column rather than "In Progress", so board status alone misses them.
- Lead = first assignee on the epic issue
- Epic reference = full `org/repo#N` with link to the source repo
- Key Result = extracted from epic body (`## Key Results` section) or inferred from title/labels
- "This Week" = brief summary of sub-issues closed / open, plus any PRs merged referencing this epic
- Cap the list (configurable via `--max-epics`, default 10); sort by recent activity (sub-issues closed this week, then open count) descending to keep the section a focused planning input
- If the script produced a fallback-mode table (no Projects v2 access), the status column is derived from sub-issue state — keep the section

### Cross-Repo Highlights

Replace the scaffold in `## Cross-Repo Highlights` with a rich narrative. Write bullet points covering **all** of the following that are relevant:

**Multi-repo contributors**
- For each person who merged PRs in more than one repo, describe *what* they worked on — not just a count. Name the repos and the themes.
- Call out the dominant contributor in the most active repo by name with a one-line summary of their impact.

**Org-wide CI narrative**
- State the overall org CI pass rate (compute as total passed / total runs across all repos).
- Call out which repos drag the average down and name the specific failing workflow(s).
- Highlight repos at 100% by name.

**Security concerns**
- List any open PRs flagged SECURITY that have been open >7 days without review. Link to the PR. Note the age.

**Dependabot accumulation**
- If the total open dependabot PRs across the org is significant (>10), call it out with a per-repo breakdown.

**Shared patterns / themes**
- Identify recurring themes across repos this week.

### Action Items

Append a `## Action Items` section at the end of the report. Produce a prioritized table of concrete actions.

**Priority criteria:**

| Priority | Criteria |
|----------|----------|
| **P0** | Security PRs unreviewed >7 days; CI broken on main for multiple consecutive days; active data/credential leak |
| **P1** | APPROVED PRs not yet merged; critical/regression bugs with no assignee; operator bugs causing pod restart loops |
| **P2** | PRs with CHANGES_REQUESTED where author has not responded >5 days; dependabot batch reviews; stale draft PRs blocking others |
| **P3** | Stale issues >30 days; ancient PRs >90 days with no review; quiet-repo triage; documentation gaps |

**Table format:**

```markdown
| # | Action | Repo | Owner | Priority |
|---|--------|------|-------|----------|
| 1 | Review and merge security fix #188 | agent-examples | @pdettori | P0 |
```

**Rules for Action Items:**
- Include only actionable items — skip things already in progress with healthy momentum
- Assign a named owner where obvious
- Limit to 15 items max, highest-priority first
- Reference GitHub issue/PR numbers with links

---

## Automation

The cron job runs weekly on Mondays at 05:01 UTC. The agent:
1. Runs `report.py` with `--json-output`
2. Reads the structured JSON and markdown
3. Enhances the Active Epics, Cross-Repo Highlights, and Action Items sections
4. Closes previous weekly report issues
5. Posts the final report as a new GitHub issue

## See Also

- GitHub CLI docs: https://cli.github.com/manual/
- Example report: https://github.com/kagenti/kagenti/issues/1110
