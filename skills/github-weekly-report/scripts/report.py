#!/usr/bin/env python3
"""GitHub Weekly Report Generator"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta
from collections import defaultdict

def run_gh(args):
    cmd = ['gh'] + args
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            print(f"Warning: gh command failed: {' '.join(cmd)}\n  {result.stderr.strip()}", file=sys.stderr)
            return []
        return json.loads(result.stdout) if result.stdout else []
    except subprocess.TimeoutExpired:
        print(f"Warning: gh command timed out: {' '.join(cmd)}", file=sys.stderr)
        return []
    except json.JSONDecodeError as e:
        print(f"Warning: failed to parse gh output: {e}", file=sys.stderr)
        return []
    except FileNotFoundError:
        print("Error: 'gh' CLI not found. Install it from https://cli.github.com/", file=sys.stderr)
        sys.exit(1)

def get_repos(org):
    return [{'owner': org, 'name': r['name']} for r in
            run_gh(['repo', 'list', org, '--limit', '100', '--json', 'name'])]

def normalize_repo_args(repo_args, org):
    """Turn --repos values into {owner, name} dicts.

    The RepoMan enrolled set can span multiple owners, so entries are expected
    owner-qualified ('rossoctl/operator' -> {'owner': 'rossoctl', 'name': 'operator'}).
    A bare name ('operator') is still accepted for backward compatibility, but only
    when --org is supplied to supply the owner; without --org a bare name is
    ambiguous and rejected. Each repo is fetched against its own owner, so entries
    from different owners coexist in one report. Order and duplicates are preserved.
    """
    out = []
    for item in repo_args:
        item = item.strip()
        if not item:
            continue
        parts = item.split('/')
        if len(parts) == 1:
            if not org:
                sys.exit(
                    f"--repos entry '{item}' is a bare name but no --org was given. "
                    f"Use '<owner>/<repo>' or pass --org."
                )
            out.append({'owner': org, 'name': parts[0]})
        elif len(parts) == 2 and parts[0] and parts[1]:
            out.append({'owner': parts[0], 'name': parts[1]})
        else:
            sys.exit(f"--repos entry '{item}' is malformed; expected '<repo>' or '<owner>/<repo>'.")
    return out

def get_merged_prs(org, repo, since, until):
    return run_gh(['pr', 'list', '-R', f'{org}/{repo}', '--search', f'merged:{since}..{until}', '--state', 'merged', '--limit', '500', '--json', 'number,title,author,mergedAt'])
def get_open_prs(org, repo):
    return run_gh(['pr', 'list', '-R', f'{org}/{repo}', '--state', 'open', '--limit', '500', '--json', 'number,title,author,createdAt,isDraft,reviewDecision,labels,body'])
def get_new_issues(org, repo, since, until):
    return run_gh(['issue', 'list', '-R', f'{org}/{repo}', '--search', f'created:{since}..{until}', '--limit', '500', '--json', 'number,title,author,createdAt'])
def get_open_issues_count(org, repo):
    try:
        result = subprocess.run(['gh', 'issue', 'list', '-R', f'{org}/{repo}', '--state', 'open', '--limit', '1000', '--json', 'number'], capture_output=True, text=True, timeout=30)
        return len(json.loads(result.stdout)) if result.returncode == 0 else 0
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return 0
def get_workflow_runs(org, repo):
    return run_gh(['run', 'list', '-R', f'{org}/{repo}', '--limit', '30', '--json', 'name,conclusion,createdAt'])

def analyze_ci(runs):
    if not runs:
        return {'passed': 0, 'total': 0, 'pass_rate': None, 'failures': [], 'by_workflow': {}}
    by_workflow = defaultdict(lambda: {'passed': 0, 'failed': 0, 'other': 0})
    for run in runs:
        name = run.get('name', 'unknown')
        conclusion = run.get('conclusion', '')
        if conclusion == 'success':
            by_workflow[name]['passed'] += 1
        elif conclusion == 'failure':
            by_workflow[name]['failed'] += 1
        else:
            by_workflow[name]['other'] += 1
    total = len(runs)
    passed = sum(r.get('conclusion') == 'success' for r in runs)
    failures = [
        {'name': name, 'failed': data['failed'], 'passed': data['passed']}
        for name, data in by_workflow.items() if data['failed'] > 0
    ]
    failures.sort(key=lambda x: x['failed'], reverse=True)
    return {
        'passed': passed,
        'total': total,
        'pass_rate': passed / total if total else None,
        'failures': failures,
        'by_workflow': dict(by_workflow),
    }

_SECURITY_PATTERNS = re.compile(
    r'\b(api[-_]?key|secret|credential|password|token|cve|exploit|vuln|leak|exposure)\b',
    re.IGNORECASE
)

def get_pr_notes(pr):
    notes = []
    text_to_scan = (pr.get('title') or '') + ' ' + (pr.get('body') or '')
    label_names = [l.get('name', '') for l in (pr.get('labels') or [])]
    label_text = ' '.join(label_names)
    if _SECURITY_PATTERNS.search(text_to_scan) or _SECURITY_PATTERNS.search(label_text):
        notes.append('SECURITY')
    days = days_since(pr.get('createdAt', ''))
    if days > 14 and not pr.get('isDraft'):
        notes.append(f'stale ({days}d)')
    blocked_match = re.search(r'blocked (?:on|by) (#\d+|\w+/\w+#\d+)', text_to_scan, re.IGNORECASE)
    if blocked_match:
        notes.append(f'blocked on {blocked_match.group(1)}')
    return ', '.join(notes)

def categorize_prs(prs):
    cats = {'ready': [], 'changes': [], 'review': [], 'draft': [], 'total': len(prs)}
    for pr in prs:
        if pr.get('isDraft'):
            cats['draft'].append(pr)
        elif pr.get('reviewDecision') == 'APPROVED':
            cats['ready'].append(pr)
        elif pr.get('reviewDecision') == 'CHANGES_REQUESTED':
            cats['changes'].append(pr)
        else:
            cats['review'].append(pr)
    return cats

def days_since(date_str):
    try:
        d = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
        return (datetime.now(d.tzinfo) - d).days
    except (ValueError, AttributeError, TypeError):
        return 0

def pct(value):
    return f"{round(value * 100)}%"

def pr_row_with_notes(pr, org, repo, show_days=True):
    t = pr['title'][:50] + '...' if len(pr['title']) > 53 else pr['title']
    a = pr.get('author', {}).get('login', '--')
    link = f"[#{pr['number']}](https://github.com/{org}/{repo}/pull/{pr['number']})"
    notes = get_pr_notes(pr)
    if show_days:
        days = days_since(pr.get('createdAt', ''))
        return f"| {link} | {t} | @{a} | {days} | {notes} |"
    return f"| {link} | {t} | @{a} | {notes} |"

def generate_action_items(repos_data):
    lines = ["## Action Items", ""]
    has_items = False
    for r in repos_data:
        if len(r['open']) > 5:
            lines.append(f"- **{r['name']}**: High PR load—{len(r['open'])} open PRs.")
            has_items = True
        if r['ci']['pass_rate'] is not None and r['ci']['pass_rate'] < 0.5:
            lines.append(f"- **{r['name']}**: CI failure rate high ({round(r['ci']['pass_rate']*100)}% pass rate).")
            has_items = True
    if not has_items:
        lines.append("- No urgent action items detected.")
    lines.append("")
    return lines

def run_epic_tracker(org, since, until, repos=None):
    """Run epic-tracker.py once and return its parsed JSON.

    Returns a dict on success, or a dict with an 'error' key describing why
    it could not run (so the caller can render a useful placeholder).
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    tracker = os.path.join(script_dir, 'epic-tracker.py')

    if not os.path.isfile(tracker):
        return {'error': 'Epic tracker not available.'}

    try:
        cmd = [sys.executable, tracker, '--since', since, '--until', until]
        if repos:
            # Pass owner-qualified so the tracker can span owners; no global --org.
            cmd += ['--repos', *[f"{r['owner']}/{r['name']}" for r in repos]]
        elif org:
            cmd += ['--org', org]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            if result.stderr:
                print(f"epic-tracker stderr: {result.stderr}", file=sys.stderr)
            return {'error': 'Epic tracker failed — see stderr.'}
        return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError) as e:
        return {'error': f'Epic tracker error: {e}'}

def render_active_epics_section(data):
    """Render the Active Epics markdown section from epic-tracker output."""
    lines = ["## Active Epics", ""]

    if data.get('error'):
        lines.append(f"*{data['error']}*")
        return lines

    epics = data.get('epics', [])
    if not epics:
        lines.append("*No active epics with activity this period.*")
        return lines

    if data.get('fallback_mode'):
        lines.append("*Note: Projects v2 status unavailable; the Status column is derived from sub-issue state.*")
        lines.append("")

    lines.append("| Epic | Lead | Key Result | This Week |")
    lines.append("|------|------|------------|-----------|")
    for e in epics:
        ref = f"[{e['org']}/{e['repo']}#{e['number']}](https://github.com/{e['org']}/{e['repo']}/issues/{e['number']})"
        title_clean = re.sub(r'^epic:\s*', '', e['title'], flags=re.IGNORECASE)
        title_short = title_clean[:50] + '...' if len(title_clean) > 53 else title_clean
        lead = f"@{e['lead']}" if e['lead'] else "unassigned"
        kr = e.get('key_result', '') or "—"
        # Sub-issue activity is the primary signal; PRs merged is supplementary.
        sub = e.get('sub_issues', {})
        act = e.get('activity_this_week', {})
        parts = []
        if sub.get('closed_recent'):
            n = sub['closed_recent']
            parts.append(f"{n} sub-issue{'s' if n != 1 else ''} closed")
        if sub.get('open'):
            parts.append(f"{sub['open']} open")
        if act.get('prs_merged'):
            parts.append(f"{act['prs_merged']} PR{'s' if act['prs_merged'] != 1 else ''} merged")
        if act.get('issues_closed'):
            parts.append(f"{act['issues_closed']} issue{'s' if act['issues_closed'] != 1 else ''} closed")
        week_summary = ', '.join(parts) if parts else "no activity"
        lines.append(f"| {ref} {title_short} | {lead} | {kr} | {week_summary} |")

    lines.append("")
    return lines

def owners_label(repos):
    """Human-readable owner label for the report header. One owner -> that owner;
    several -> a comma-joined set (preserving first-seen order)."""
    seen = []
    for r in repos:
        o = r['owner']
        if o not in seen:
            seen.append(o)
    if len(seen) == 1:
        return f"[{seen[0]}](https://github.com/{seen[0]})"
    return ', '.join(f"[{o}](https://github.com/{o})" for o in seen)

def generate_report(org, since, until, enhanced=False, repos=None):
    repos = repos if repos is not None else get_repos(org)
    lines = [
        f"# Weekly Report: {since} -- {until}",
        "",
        f"*Generated for {owners_label(repos)} by the "
        "[github-weekly-report](https://github.com/rossoctl/agent-skills/tree/main/skills/github-weekly-report) "
        "skill.*",
        "",
    ]
    repos_data = []
    for repo in repos:
        owner = repo['owner']
        name = repo['name']
        merged = get_merged_prs(owner, name, since, until)
        open_prs = get_open_prs(owner, name)
        new_issues = get_new_issues(owner, name, since, until)
        open_count = get_open_issues_count(owner, name)
        workflow_runs = get_workflow_runs(owner, name)
        ci = analyze_ci(workflow_runs)
        repos_data.append({
            'owner': owner,
            'name': name,
            'merged': merged,
            'open': open_prs,
            'new': new_issues,
            'open_count': open_count,
            'cats': categorize_prs(open_prs),
            'ci': ci,
        })
    repos_data.sort(key=lambda x: len(x['merged']), reverse=True)

    # Summary table
    lines += ["## Org-Wide Summary", "", "| Repo | Merged PRs | Open PRs | Open Issues | New Issues | CI Pass Rate | Status |", "|------|-----------|----------|-------------|------------|--------------|--------|"]
    totals = {'m': 0, 'o': 0, 'i': 0, 'n': 0}
    for d in repos_data:
        m, o, n, i = len(d['merged']), len(d['open']), len(d['new']), d['open_count']
        totals['m'] += m; totals['o'] += o; totals['i'] += i; totals['n'] += n
        status = "active" if (m > 0 or o > 5) else "quiet"
        ci = d['ci']
        ci_display = f"{ci['passed']}/{ci['total']} ({pct(ci['pass_rate'])})" if ci['pass_rate'] is not None else "--"
        lines.append(f"| [{d['name']}](https://github.com/{d['owner']}/{d['name']}) | {m} | {o} | {i} | {n} | {ci_display} | {status} |")
    lines.append(f"| **TOTAL** | **{totals['m']}** | **{totals['o']}** | **{totals['i']}** | **{totals['n']}** | | |")
    lines.append("")

    # Cross-Repo Highlights
    lines += ["## Cross-Repo Highlights", ""]
    contrib_repos = defaultdict(set)
    contrib_counts = defaultdict(int)
    for d in repos_data:
        for pr in d['merged']:
            a = pr.get('author', {}).get('login')
            if a:
                contrib_repos[a].add(d['name'])
                contrib_counts[a] += 1
    multi = [(u, sorted(contrib_repos[u]), contrib_counts[u]) for u, r in contrib_repos.items() if len(r) > 1]
    multi.sort(key=lambda x: len(x[1]), reverse=True)
    if multi:
        for u, repos_list, pc in multi[:5]:
            lines.append(f"- **@{u}** contributed to {', '.join(repos_list)} — {pc} PRs merged")
        lines.append("")

    # CI concerns highlight
    ci_concern_repos = [d for d in repos_data if d['ci']['pass_rate'] is not None and d['ci']['pass_rate'] < 0.5 and d['ci']['total'] >= 5]
    if ci_concern_repos:
        for d in ci_concern_repos:
            ci = d['ci']
            failing_names = ', '.join(f['name'] for f in ci['failures'][:2])
            lines.append(f"- **CI concern**: {d['name']} at {pct(ci['pass_rate'])} pass rate — failing: {failing_names or 'unknown'}")
        lines.append("")

    # Security-flagged PRs
    security_prs = []
    for d in repos_data:
        for pr in d['open']:
            notes = get_pr_notes(pr)
            if 'SECURITY' in notes:
                security_prs.append((d['owner'], d['name'], pr))
    if security_prs:
        lines.append("- **Security concern**: unreviewed security-related PRs:")
        for repo_owner, repo_name, pr in security_prs[:3]:
            lines.append(f"  - [{repo_owner}/{repo_name}#{pr['number']}](https://github.com/{repo_owner}/{repo_name}/pull/{pr['number']}) — {pr['title'][:80]}")
        lines.append("")

    # Dependabot wave
    dependabot_open = sum(
        sum(1 for pr in d['open'] if (pr.get('author') or {}).get('login', '') in ('dependabot[bot]', 'app/dependabot', 'dependabot'))
        for d in repos_data
    )
    if dependabot_open > 10:
        lines.append(f"- **Dependabot wave**: {dependabot_open} dependabot PRs awaiting review across the reported repos. Consider batching.")
        lines.append("")

    if repos_data and repos_data[0]['merged'] and len(repos_data[0]['merged']) > 20:
        lines.append(f"- **{repos_data[0]['name']}** saw massive activity ({len(repos_data[0]['merged'])} merged PRs)")
        lines.append("")

    # Active Epics — run the tracker once and reuse for both markdown and JSON
    epic_data = run_epic_tracker(org, since, until, repos=repos)
    lines += render_active_epics_section(epic_data)
    lines.append("")

    # Action Items
    lines += generate_action_items(repos_data)
    lines.append("")

    lines += ["---", ""]

    # Per-repo deep dives
    for d in repos_data:
        if not d['merged'] and not d['open'] and not d['new']:
            continue
        lines += [f"## {d['name']}", ""]

        # Merged PRs
        if d['merged']:
            lines.append(f"### Merged PRs ({len(d['merged'])})")
            cc = defaultdict(int)
            for pr in d['merged']:
                cc[pr.get('author', {}).get('login', 'unknown')] += 1
            top = sorted(cc.items(), key=lambda x: x[1], reverse=True)[:5]
            if top:
                lines.append(f"**Top contributors:** {', '.join(f'@{u} ({c})' for u, c in top)}")
                lines.append("")
            lines += ["| # | Title | Author | Merged |", "|---|-------|--------|--------|"]
            for pr in d['merged'][:15]:
                t = pr['title'][:57] + '...' if len(pr['title']) > 60 else pr['title']
                a = pr.get('author', {}).get('login', 'unknown')
                m = pr.get('mergedAt', '--')[:10]
                lines.append(f"| [#{pr['number']}](https://github.com/{d['owner']}/{d['name']}/pull/{pr['number']}) | {t} | @{a} | {m} |")
            if len(d['merged']) > 15:
                lines.append(f"| ... | +{len(d['merged'])-15} more | | |")
            lines.append("")

        # Open PRs
        if d['open']:
            c = d['cats']
            lines.append(f"### Open PRs ({len(d['open'])})")
            lines.append("")

            if c['ready']:
                lines.append(f"#### Ready to Merge ({len(c['ready'])})")
                lines += ["| # | Title | Author | Notes |", "|---|-------|--------|-------|"]
                for pr in c['ready'][:5]:
                    lines.append(pr_row_with_notes(pr, d['owner'], d['name'], show_days=False))
                lines.append("")
            if c['changes']:
                lines.append(f"#### Changes Requested ({len(c['changes'])})")
                lines += ["| # | Title | Author | Days | Notes |", "|---|-------|--------|------|-------|"]
                for pr in c['changes'][:5]:
                    lines.append(pr_row_with_notes(pr, d['owner'], d['name']))
                lines.append("")
            if c['review']:
                lines.append(f"#### Needs Review ({len(c['review'])})")
                lines += ["| # | Title | Author | Days | Notes |", "|---|-------|--------|------|-------|"]
                for pr in c['review'][:8]:
                    lines.append(pr_row_with_notes(pr, d['owner'], d['name']))
                if len(c['review']) > 8:
                    lines.append(f"| ... | +{len(c['review'])-8} more | | | |")
                lines.append("")
            if c['draft']:
                lines.append(f"#### Draft PRs ({len(c['draft'])})")
                if len(c['draft']) <= 5:
                    for pr in c['draft']:
                        lines.append(f"- [#{pr['number']}](https://github.com/{d['owner']}/{d['name']}/pull/{pr['number']}) — {pr['title']}")
                else:
                    authors = list(set(p.get('author', {}).get('login') for p in c['draft'] if p.get('author')))
                    lines.append(f"{len(c['draft'])} drafts from {', '.join(f'@{a}' for a in authors)}")
                lines.append("")

        # CI Health
        ci = d['ci']
        if ci['total'] > 0:
            lines.append("### CI Health")
            rate_str = f"{ci['passed']}/{ci['total']} ({pct(ci['pass_rate'])})"
            lines.append(f"- {rate_str} passed")
            for f in ci['failures'][:3]:
                lines.append(f"- **Failing**: \"{f['name']}\" — {f['failed']} failure(s)")
            lines.append("")

        # New Issues
        if d['new']:
            lines.append(f"### New Issues ({len(d['new'])})")
            lines += ["| # | Title | Created |", "|---|-------|---------|"]
            for issue in d['new']:
                t = issue['title'][:57] + '...' if len(issue['title']) > 60 else issue['title']
                created_date = issue.get('createdAt', '--')[:10]
                lines.append(f"| [#{issue['number']}](https://github.com/{d['owner']}/{d['name']}/issues/{issue['number']}) | {t} | {created_date} |")
            lines.append("")

    return '\n'.join(lines), repos_data, epic_data

def build_json_output(since, until, repos_data, epic_data=None):
    """Build structured JSON suitable for AI synthesis of highlights and action items.

    The owner set (and the back-compat single-owner 'org' field) is derived from
    repos_data, so no separate org argument is needed."""
    owners = []
    for d in repos_data:
        if d['owner'] not in owners:
            owners.append(d['owner'])
    result = {
        # 'org' is retained for backward compatibility: the single owner when the
        # report covers one, else null. 'owners' is the authoritative list.
        'org': owners[0] if len(owners) == 1 else None,
        'owners': owners,
        'period': {'since': since, 'until': until},
        'repos': [],
    }

    if epic_data and not epic_data.get('error'):
        result['active_epics'] = epic_data
    for d in repos_data:
        open_prs_enriched = []
        for pr in d['open']:
            open_prs_enriched.append({
                'number': pr['number'],
                'title': pr['title'],
                'author': (pr.get('author') or {}).get('login', 'unknown'),
                'days_open': days_since(pr.get('createdAt', '')),
                'status': ('draft' if pr.get('isDraft') else
                           pr.get('reviewDecision', 'REVIEW_REQUIRED') or 'REVIEW_REQUIRED'),
                'notes': get_pr_notes(pr),
                'labels': [l.get('name', '') for l in (pr.get('labels') or [])],
                'url': f"https://github.com/{d['owner']}/{d['name']}/pull/{pr['number']}",
            })
        result['repos'].append({
            'owner': d['owner'],
            'name': d['name'],
            'merged_prs': [
                {
                    'number': pr['number'],
                    'title': pr['title'],
                    'author': (pr.get('author') or {}).get('login', 'unknown'),
                    'merged_at': (pr.get('mergedAt') or '')[:10],
                }
                for pr in d['merged']
            ],
            'open_prs': open_prs_enriched,
            'open_prs_summary': {
                'ready': len(d['cats']['ready']),
                'changes_requested': len(d['cats']['changes']),
                'needs_review': len(d['cats']['review']),
                'draft': len(d['cats']['draft']),
                'total': len(d['open']),
            },
            'new_issues': [
                {
                    'number': i['number'],
                    'title': i['title'],
                    'created_at': (i.get('createdAt') or '')[:10],
                    'url': f"https://github.com/{d['owner']}/{d['name']}/issues/{i['number']}",
                }
                for i in d['new']
            ],
            'open_issues_count': d['open_count'],
            'ci': {
                'passed': d['ci']['passed'],
                'total': d['ci']['total'],
                'pass_rate': round(d['ci']['pass_rate'] * 100) if d['ci']['pass_rate'] is not None else None,
                'failing_workflows': [
                    {'name': f['name'], 'failures': f['failed']}
                    for f in d['ci']['failures']
                ],
            },
        })
    return result

def main():
    p = argparse.ArgumentParser()
    # --org is optional: it supplies the owner for org-wide discovery (no --repos)
    # and the fallback owner for any bare --repos entry. An owner-qualified
    # --repos list needs no --org and may span multiple owners.
    p.add_argument('--org')
    p.add_argument('--since')
    p.add_argument('--until')
    p.add_argument('--output')
    p.add_argument('--json-output', metavar='PATH', help='Write structured JSON data for AI synthesis')
    p.add_argument('--enhanced', action='store_true', help='Include additional metrics (reserved for future use)')
    p.add_argument('--repos', nargs='+', metavar='OWNER/REPO',
                   help="Explicit repo list ('<owner>/<repo>', may span owners; a "
                        "bare '<repo>' is allowed only with --org to supply the "
                        "owner); when set, skips org-wide discovery")
    args = p.parse_args()
    if not args.repos and not args.org:
        p.error("one of --repos (owner-qualified) or --org (for org-wide discovery) is required")
    since = args.since or (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d')
    until = args.until or datetime.now().strftime('%Y-%m-%d')

    repos = normalize_repo_args(args.repos, args.org) if args.repos else None
    report, repos_data, epic_data = generate_report(args.org, since, until, args.enhanced, repos=repos)

    if args.output:
        with open(args.output, 'w') as f:
            f.write(report)
        print(f"Report written to: {args.output}")
    else:
        print(report)

    if args.json_output:
        data = build_json_output(since, until, repos_data, epic_data)
        with open(args.json_output, 'w') as f:
            json.dump(data, f, indent=2)
        print(f"JSON data written to: {args.json_output}", file=sys.stderr)

if __name__ == '__main__':
    main()
