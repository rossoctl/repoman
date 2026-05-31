# Issue Templates -- Dep Bump Scanner

## Issue Title Format

```
[dep-bump] Stale <severity> bump: <package> in <repo>
```

Examples:
- `[dep-bump] Stale high bump: uuid in adk`
- `[dep-bump] Stale routine bump: k8s.io/client-go in kagenti-operator`
- `[dep-bump] Stale critical bump: cryptography in kagenti`

## Issue Body Structure

```markdown
## Describe the bug

Stale Dependabot PR detected by automated dependency bump scan.

**Repo:** kagenti/<repo>
**PR:** #<number>
**Package:** <package-name>
**Version:** <from> -> <to>
**Ecosystem:** <pip|npm|gomod|docker|github-actions|cargo>
**Severity:** <critical|high|medium|routine|major>
**SLA:** <N> days
**Age:** <M> days (overdue by <M-N> days)
**CI Status:** <passing|failing|pending>
**First detected:** YYYY-MM-DD
**Scan ID:** <scan_id>

## Steps To Reproduce

1. View PR: https://github.com/kagenti/<repo>/pull/<number>
2. Note PR age (<M> days) exceeds SLA threshold (<N> days)

## Expected Behavior

Dependabot PRs should be reviewed and merged within the SLA window.

## Additional Context

Category: <security|routine|major>
Detected by: OpenClaw Dep Bump Scanner (scan <scan_id>)
```

## Field Extraction (for fixer)

```bash
repo=$(echo "$body" | sed -nE 's/\*\*Repo:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ')
pr_number=$(echo "$body" | sed -nE 's/\*\*PR:\*\*[[:space:]]*#([0-9]+)/\1/p' | head -1)
package=$(echo "$body" | sed -nE 's/\*\*Package:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ')
ecosystem=$(echo "$body" | sed -nE 's/\*\*Ecosystem:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ')
severity=$(echo "$body" | sed -nE 's/\*\*Severity:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ')
ci_status=$(echo "$body" | sed -nE 's/\*\*CI Status:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ')
```

## Labels

- `kind/bug` -- standard bug label
- `dep-bump/stale` -- identifies dep-bump scanner issues
