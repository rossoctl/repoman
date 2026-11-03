#!/usr/bin/env python3
"""Deterministic doc-drift checker (RepoMan).

Reads a pinned git ref only (never the working tree). Emits JSON findings.
Release metadata and merged PRs are passed in by the shell so this stays offline.
"""
from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

DEFAULT_TAG_PATTERN = r"^v\d+\.\d+\.\d+$"
CONFIG_PATH = ".repoman/doc-drift.yaml"
DOC_EXTS = (".md", ".rst", ".txt")
VERSION_FILES = (
    "marketplace.json",
    ".claude-plugin/marketplace.json",
    "plugin.json",
    "package.json",
    "pyproject.toml",
)

# Paths that look like URLs are not tree paths.
URLISH = re.compile(r"^[a-z][a-z0-9+.-]*://", re.I)
# Backtick path: scripts/foo.sh, skills/x/SKILL.md (no spaces)
BACKTICK_PATH = re.compile(r"`([A-Za-z0-9_./\-]+(?:\.[A-Za-z0-9]+)?)`")
# Markdown link target that is a relative path
MD_LINK_PATH = re.compile(r"\[[^\]]*\]\((?!https?://|#|mailto:)([A-Za-z0-9_./\-]+)\)")
# Flag / long option
FLAG_RE = re.compile(r"(?<![A-Za-z0-9_-])(--[A-Za-z0-9][A-Za-z0-9-]*)")
# Subcommand header on a line (same-line tokens optional; bullets may follow).
SUBCMD_HEADER_RE = re.compile(
    r"^(?P<pre>\s*(?:#\s*)?)(?:subcommands?|commands?)\s*:\s*(?P<rest>.*)$",
    re.I,
)
_SUBCMD_STOPWORDS = frozenset(
    {"subcommand", "subcommands", "commands", "command"}
)
# Keep a Changelog heading
CHANGELOG_HEADING = re.compile(
    r"^## \[([^\]]+)\](?: - (\d{4}-\d{2}-\d{2}))?\s*$", re.M
)
# Conventional commit / PR title prefix
CONV_PREFIX = re.compile(
    r"^(?P<type>feat|fix|refactor|perf|revert|remove|docs|chore|test|ci|style)"
    r"(?:\([^)]*\))?!?\s*:\s*",
    re.I,
)
# "not implemented in this skill" — basename may sit before or after the claim.
NOT_IMPLEMENTED_RE = re.compile(
    r"\bnot implemented\b.{0,60}?\bin this skill\b",
    re.I | re.S,
)
# "lives in the automation repo, not in this repo" (either order)
AUTOMATION_ONLY_RE = re.compile(
    r"(?:"
    r"(?:lives?|is)\s+in\s+the\s+automation\s+repo.{0,80}?\bnot\b.{0,40}?\bthis\s+repo\b"
    r"|"
    r"\bnot\b.{0,40}?\bthis\s+repo\b.{0,80}?(?:lives?|is)\s+in\s+the\s+automation\s+repo\b"
    r")",
    re.I | re.S,
)
META_FLAGS = {"--help", "--version", "-h", "-v"}
# A backtick or link is a path claim only with a repo-file extension or a
# trailing slash. Version numbers, model ids, and owner/repo names are not.
PATH_EXTS = frozenset({
    ".sh", ".py", ".md", ".rst", ".txt", ".yml", ".yaml", ".json", ".toml", ".env",
})
# Tokens that match a command shape but are prose on a Subcommands: line.
_PROSE_WORDS = frozenset({
    "a", "an", "the", "each", "writes", "write", "its", "own", "then", "and",
    "or", "see", "below", "with", "for", "from", "into", "this", "that",
    "your", "also", "exactly", "one",
})
# Subcommand dispatcher, not an inner case on some other variable.
_DISPATCH_CASE_RE = re.compile(
    r"""(?x)
    ^\s*case\s+
    (?:
        "\$\{?(?:1|cmd|command|subcommand)\}?(?::[^"]*)?"
        |\$\{?(?:1|cmd|command|subcommand)\}?(?::[^\s]*)?
    )
    \s+in\s*(?:\#.*)?$
    """
)
_SCRIPT_MENTION_RE = re.compile(
    r"(?<![A-Za-z0-9_./-])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:sh|py))\b"
)

OMIT_TYPES = {"docs", "chore", "test", "ci", "style"}
BUCKET = {
    "feat": "Added",
    "fix": "Fixed",
    "refactor": "Changed",
    "perf": "Changed",
    "revert": "Removed",
    "remove": "Removed",
}


@dataclass
class Finding:
    check: str
    kind: str  # correction | addition
    mechanical: bool
    doc_path: str
    doc_line: int
    code_path: str
    code_line: int
    claim: str
    evidence: str
    draft: str = ""
    replace_with: str = ""
    status: str = "open"
    reason: str = ""
    repo: str = ""

    def key(self) -> str:
        claim_n = re.sub(r"\s+", " ", self.claim.strip().lower())
        # doc_line keeps two hits of the same claim in one file (repeated
        # versions, flags, retired names) from collapsing to the first.
        return "|".join(
            [
                self.repo,
                self.check,
                self.doc_path,
                claim_n,
                self.code_path,
                str(self.doc_line),
            ]
        )

    def to_dict(self) -> Dict[str, Any]:
        d = asdict(self)
        d["key"] = self.key()
        return d


def run_git(clone: str, *args: str) -> str:
    r = subprocess.run(
        ["git", "-C", clone, *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        return ""
    return r.stdout


def git_show(clone: str, ref: str, path: str) -> Optional[str]:
    r = subprocess.run(
        ["git", "-C", clone, "show", f"{ref}:{path}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        return None
    return r.stdout


def git_ls_tree(clone: str, ref: str) -> Set[str]:
    out = run_git(clone, "ls-tree", "-r", "--name-only", ref)
    return {line for line in out.splitlines() if line}


def git_basenames(tree: Set[str]) -> Dict[str, List[str]]:
    m: Dict[str, List[str]] = {}
    for p in tree:
        base = os.path.basename(p)
        m.setdefault(base, []).append(p)
    return m


def resolve_ref(clone: str, boundary: str, tag_pattern: str) -> Tuple[str, str]:
    """Return (sha, label). label is the tag name or 'HEAD'."""
    if boundary == "tags":
        try:
            tag_rx = re.compile(tag_pattern)
        except re.error:
            tag_rx = re.compile(DEFAULT_TAG_PATTERN)
        tags = [
            t
            for t in run_git(clone, "tag", "-l").splitlines()
            if t and tag_rx.search(t)
        ]
        if not tags:
            sha = run_git(clone, "rev-parse", "HEAD").strip()
            return sha, "HEAD"
        # Semver-ish sort: strip leading v, split numeric parts. Pre-releases
        # are already filtered by the stable pattern.
        def key(t: str) -> Tuple:
            body = t[1:] if t.startswith("v") else t
            parts = []
            for p in body.split("."):
                try:
                    parts.append(int(p))
                except ValueError:
                    parts.append(0)
            return tuple(parts)

        newest = sorted(tags, key=key)[-1]
        sha = run_git(clone, "rev-parse", newest).strip()
        return sha, newest
    sha = run_git(clone, "rev-parse", "HEAD").strip()
    return sha, "HEAD"


# ---------------------------------------------------------------------------
# Minimal YAML subset reader for .repoman/doc-drift.yaml
# ---------------------------------------------------------------------------

def _parse_scalar(s: str) -> Any:
    s = s.strip()
    if (s.startswith("'") and s.endswith("'")) or (
        s.startswith('"') and s.endswith('"')
    ):
        return s[1:-1]
    if s in ("true", "True"):
        return True
    if s in ("false", "False"):
        return False
    if s in ("null", "~", ""):
        return None
    return s


def _next_significant_line(lines: Sequence[str], start: int) -> Optional[str]:
    """Return the next non-blank, non-comment line at or after start, or None."""
    for j in range(start, len(lines)):
        cand = lines[j]
        if not cand.strip() or cand.lstrip().startswith("#"):
            continue
        return cand
    return None


def parse_simple_yaml(text: str) -> Dict[str, Any]:
    """Parse the narrow YAML subset used by doc-drift config.

    List-vs-map for a bare ``key:`` is decided structurally: if the next
    significant line is a ``- `` item at the same indent or deeper, the value
    is a list. That covers YAML's compact sequence form (``key:`` then
    ``- item`` in the same column). No hard-coded key names.
    """
    root: Dict[str, Any] = {}
    stack: List[Tuple[int, Any]] = [(-1, root)]
    lines = text.splitlines()

    for i, raw in enumerate(lines):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()

        # Dash items may sit in the same column as their key (compact
        # sequences). Popping on ``<=`` would discard the list just pushed
        # for that key. Other lines still close the block at ``<=``.
        if line.startswith("- "):
            while len(stack) > 1 and indent < stack[-1][0]:
                stack.pop()
        else:
            while len(stack) > 1 and indent <= stack[-1][0]:
                stack.pop()
        parent = stack[-1][1]

        if line.startswith("- "):
            item_text = line[2:].strip()
            if not isinstance(parent, list):
                continue
            if ":" in item_text and not item_text.startswith("{"):
                k, _, v = item_text.partition(":")
                obj: Dict[str, Any] = {k.strip(): _parse_scalar(v)}
                parent.append(obj)
                stack.append((indent, obj))
            elif item_text.startswith("{") and item_text.endswith("}"):
                parent.append(_parse_flow_map(item_text))
            else:
                parent.append(_parse_scalar(item_text))
            continue

        if ":" in line:
            k, _, v = line.partition(":")
            key = k.strip()
            val = v.strip()
            if not isinstance(parent, dict):
                continue
            if val == "":
                nxt = _next_significant_line(lines, i + 1)
                if nxt is not None:
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    if nxt_indent >= indent and nxt.lstrip().startswith("- "):
                        parent[key] = []
                        stack.append((indent, parent[key]))
                    else:
                        parent[key] = {}
                        stack.append((indent, parent[key]))
                else:
                    parent[key] = {}
            elif val.startswith("[") and val.endswith("]"):
                inner = val[1:-1].strip()
                if not inner:
                    parent[key] = []
                else:
                    parent[key] = [
                        _parse_scalar(x.strip()) for x in _split_flow(inner)
                    ]
            elif val.startswith("{") and val.endswith("}"):
                parent[key] = _parse_flow_map(val)
            else:
                parent[key] = _parse_scalar(val)
    return root


def _split_flow(inner: str) -> List[str]:
    parts, cur, in_q = [], [], None
    for ch in inner:
        if in_q:
            cur.append(ch)
            if ch == in_q:
                in_q = None
            continue
        if ch in ("'", '"'):
            in_q = ch
            cur.append(ch)
            continue
        if ch == ",":
            parts.append("".join(cur).strip())
            cur = []
            continue
        cur.append(ch)
    if cur:
        parts.append("".join(cur).strip())
    return parts


def _parse_flow_map(s: str) -> Dict[str, Any]:
    inner = s.strip()[1:-1]
    out: Dict[str, Any] = {}
    for part in _split_flow(inner):
        if ":" not in part:
            continue
        k, _, v = part.partition(":")
        out[k.strip()] = _parse_scalar(v)
    return out


def load_config(clone: str, ref: str) -> Dict[str, Any]:
    text = git_show(clone, ref, CONFIG_PATH)
    if text is None:
        return {
            "boundary": "main",
            "stable_tag_pattern": DEFAULT_TAG_PATTERN,
            "ignore_paths": ["CHANGELOG.md", "docs/history/**"],
            "sources_of_truth": [],
            "retired_names": [],
            "release": {"changelog": "CHANGELOG.md"},
        }
    cfg = parse_simple_yaml(text)
    cfg.setdefault("boundary", "main")
    cfg.setdefault("stable_tag_pattern", DEFAULT_TAG_PATTERN)
    # A failed list parse used to leave ``{}``, and setdefault would not
    # replace it — so CHANGELOG.md dropped out of the default ignore list.
    if not isinstance(cfg.get("ignore_paths"), list):
        cfg["ignore_paths"] = ["CHANGELOG.md", "docs/history/**"]
    if not isinstance(cfg.get("sources_of_truth"), list):
        cfg["sources_of_truth"] = []
    if not isinstance(cfg.get("retired_names"), list):
        cfg["retired_names"] = []
    rel = cfg.get("release") or {}
    if not isinstance(rel, dict):
        rel = {}
    rel.setdefault("changelog", "CHANGELOG.md")
    cfg["release"] = rel
    return cfg


def path_ignored(path: str, patterns: Sequence[str]) -> bool:
    for pat in patterns:
        if pat.endswith("/**"):
            prefix = pat[:-3]
            if path == prefix.rstrip("/") or path.startswith(prefix):
                return True
        elif "*" in pat:
            # simplistic glob: only trailing *
            if pat.endswith("*") and path.startswith(pat[:-1]):
                return True
        elif path == pat:
            return True
    return False


def line_of(text: str, needle: str) -> int:
    idx = text.find(needle)
    if idx < 0:
        return 1
    return text[:idx].count("\n") + 1


def line_of_re(text: str, m: re.Match) -> int:
    return text[: m.start()].count("\n") + 1


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def _is_path_claim(raw: str) -> bool:
    if not raw or raw in {".", ".."}:
        return False
    if raw.endswith("/"):
        body = raw.rstrip("/")
        return bool(body) and body not in {".", ".."}
    return os.path.splitext(raw)[1].lower() in PATH_EXTS


def _repo_relative(path: str) -> Optional[str]:
    """Normalize a path and drop anything that escapes the repo root."""
    norm = posixpath.normpath(path)
    if norm in {".", ""}:
        return ""
    if norm == ".." or norm.startswith("../"):
        return None
    return norm


def _in_tree(tree: Set[str], candidate: str) -> bool:
    candidate = candidate.rstrip("/")
    if not candidate:
        return True
    return any(p == candidate or p.startswith(candidate + "/") for p in tree)


def check_paths(
    clone: str,
    ref: str,
    tree: Set[str],
    basenames: Dict[str, List[str]],
    docs: List[Tuple[str, str]],
    repo: str,
    ignore: Sequence[str],
) -> List[Finding]:
    findings: List[Finding] = []
    top = {p.split("/", 1)[0] for p in tree}
    for doc_path, text in docs:
        if path_ignored(doc_path, ignore):
            continue
        doc_dir = os.path.dirname(doc_path)
        seen: Set[str] = set()
        for rx in (BACKTICK_PATH, MD_LINK_PATH):
            for m in rx.finditer(text):
                raw = m.group(1)
                if URLISH.match(raw) or raw.startswith("#"):
                    continue
                if not _is_path_claim(raw):
                    continue
                if raw in seen:
                    continue
                seen.add(raw)
                candidates: List[str] = []
                bare = "/" not in raw.strip("/")
                if raw.startswith("/"):
                    rel = _repo_relative(raw.lstrip("/"))
                    if rel is None:
                        continue
                    if rel:
                        candidates.append(rel)
                elif raw.startswith("./") or raw.startswith("../"):
                    # Resolve against the document. A link that climbs out of
                    # the repo is not an in-repo claim.
                    joined = f"{doc_dir}/{raw}" if doc_dir else raw
                    rel = _repo_relative(joined)
                    if rel is None:
                        continue
                    if rel:
                        candidates.append(rel)
                else:
                    rel = _repo_relative(raw)
                    if rel is None:
                        continue
                    if rel:
                        candidates.append(rel)
                if any(_in_tree(tree, c) for c in candidates):
                    continue
                # A bundled skill doc cites `scripts/org.sh` for the copy that
                # lives next to the doc (`skills/repoman/scripts/org.sh`).
                # That hit suppresses the finding; it does not create one.
                if (
                    doc_dir
                    and not raw.startswith(("/", "./", "../"))
                    and "/" in raw
                ):
                    bundled = _repo_relative(f"{doc_dir}/{raw}")
                    if bundled and _in_tree(tree, bundled):
                        continue
                # A bare filename exists when any tree path has that basename.
                if bare:
                    base = os.path.basename(raw.rstrip("/"))
                    if basenames.get(base):
                        continue
                    # A bare name that is not in the tree (`repos.json`,
                    # `SKILL.md` in another repo) does not name a location here.
                    continue
                # A slash path is a claim only when its first directory is in
                # this repo. `config/org.env` and `skills/foo/SKILL.md` are
                # host or other-repo paths.
                if not any("/" in c and c.split("/", 1)[0] in top for c in candidates):
                    continue
                findings.append(
                    Finding(
                        check="paths",
                        kind="correction",
                        mechanical=False,
                        doc_path=doc_path,
                        doc_line=line_of_re(text, m),
                        code_path="(tree)",
                        code_line=1,
                        claim=f"path `{raw}` exists",
                        evidence=f"`{raw}` not found at {ref}",
                        repo=repo,
                        replace_with="",
                    )
                )
    return findings


def _add_subcommand_token(subs: Set[str], tok: str) -> None:
    if tok and tok.lower() not in _SUBCMD_STOPWORDS:
        subs.add(tok)


def _list_command_tokens(text: str) -> List[str]:
    """Command names from a list, stopping where prose starts.

    ``init-config, add-repo, set-output. Each writes`` yields the three
    commands. ``Each writes a report`` yields nothing. Backtick tokens, when
    present, are the only ones taken.
    """
    ticks = re.findall(r"`([^`]+)`", text)
    if ticks:
        return [
            t
            for t in ticks
            if re.fullmatch(r"[a-z][a-z0-9-]*", t) and t not in _PROSE_WORDS
        ]
    out: List[str] = []
    for word in re.findall(r"[A-Za-z][A-Za-z0-9_-]*", text):
        if not re.fullmatch(r"[a-z][a-z0-9-]*", word) or word in _PROSE_WORDS:
            break
        out.append(word)
    return out


def extract_listed_subcommands(text: str) -> Set[str]:
    """Collect subcommand tokens from a Subcommands:/Commands: list.

    Same-line text contributes command tokens until prose starts. Following
    ``- item`` bullets and indented ``name --flag`` usage lines contribute
    their command, not the description after it.
    """
    subs: Set[str] = set()
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = SUBCMD_HEADER_RE.match(line)
        if not m:
            continue
        rest = (m.group("rest") or "").strip()
        if rest:
            for tok in _list_command_tokens(rest):
                _add_subcommand_token(subs, tok)
        base_indent = len(line) - len(line.lstrip(" "))
        for j in range(i + 1, len(lines)):
            nxt = lines[j]
            if not nxt.strip():
                continue
            nindent = len(nxt) - len(nxt.lstrip(" "))
            stripped = nxt.strip()
            # Markdown often puts "- item" at the same column as "Subcommands:".
            # Accept dash items at indent >= header; stop on other content at
            # indent <= header (a new section).
            if stripped.startswith("- "):
                if nindent < base_indent:
                    break
                item = stripped[2:].strip()
                toks = _list_command_tokens(item)
                if toks:
                    _add_subcommand_token(subs, toks[0])
                continue
            if nindent <= base_indent:
                break
            if stripped.startswith("#"):
                continue
            # "  foo --bar" style without a dash (must be indented past header)
            m2 = re.match(r"^([a-z][a-z0-9-]*)\s+--", stripped)
            if m2:
                _add_subcommand_token(subs, m2.group(1))
                continue
            break
    # Usage comment with a command-shaped token: "# init-config --repos-dir".
    # A prose comment such as "# explicit --live" or "# separate --repos" is not.
    for m in re.finditer(r"(?m)^#\s+([a-z][a-z0-9-]*)\s+--", text):
        tok = m.group(1)
        if "-" not in tok:
            continue
        _add_subcommand_token(subs, tok)
    return subs


def _header_subcommands(script_text: str) -> Set[str]:
    """Subcommands named in a leading comment / usage block."""
    return extract_listed_subcommands(script_text)


def _case_subcommands(script_text: str) -> Set[str]:
    """Arms of the subcommand dispatcher only.

    The dispatcher is ``case "$1"`` / ``$cmd`` / ``$command`` / ``$subcommand``.
    Arms of ``case "$mode"`` and other inner cases are not subcommands.
    """
    subs: Set[str] = set()
    lines = script_text.splitlines()
    i = 0
    n = len(lines)
    while i < n:
        if not _DISPATCH_CASE_RE.match(lines[i]):
            i += 1
            continue
        depth = 1
        i += 1
        while i < n and depth:
            line = lines[i]
            if re.match(r"^\s*case\b.*\bin\b", line):
                depth += 1
            elif re.match(r"^\s*esac\b", line):
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            elif depth == 1:
                arm_m = re.match(r"^\s*([A-Za-z0-9_|-]+)\)", line)
                if arm_m:
                    arm = arm_m.group(1)
                    if arm != "*" and not arm.startswith("$"):
                        for part in arm.split("|"):
                            part = part.strip()
                            if re.fullmatch(r"[a-z][a-z0-9-]*", part):
                                subs.add(part)
            i += 1
    return subs


def _scripts_by_basename(tree: Set[str]) -> Dict[str, List[str]]:
    by_base: Dict[str, List[str]] = {}
    for p in tree:
        if p.endswith(".sh") or p.endswith(".py"):
            by_base.setdefault(os.path.basename(p), []).append(p)
    for base in by_base:
        by_base[base] = sorted(by_base[base])
    return by_base


def _resolve_script_mention(token: str, by_base: Dict[str, List[str]]) -> Optional[str]:
    """Bind a doc citation to one script path.

    A path with a slash must match that location. A bare basename binds only
    when it is unique, so ``scripts/x.sh`` and ``skills/.../x.sh`` do not
    collapse onto whichever file was inserted last.
    """
    token = token.lstrip("./")
    base = os.path.basename(token)
    paths = by_base.get(base) or []
    if "/" in token:
        for p in paths:
            if p == token or p.endswith("/" + token):
                return p
        return None
    if len(paths) == 1:
        return paths[0]
    return None


def _sourced_shell_paths(script_text: str, by_base: Dict[str, List[str]]) -> List[str]:
    """Shell files named by a leading ``source`` or ``.`` line."""
    found: List[str] = []
    seen: Set[str] = set()
    for m in re.finditer(
        r"(?m)^[ \t]*(?:source|\.)[ \t]+[\"']?(\S+)",
        script_text,
    ):
        token = m.group(1).strip("'\"")
        base = token.rsplit("/", 1)[-1]
        if not base.endswith(".sh"):
            continue
        # $_LIB_DIR/core.sh is a basename. A concrete scripts/core.sh must match.
        if "/" in token and not token.startswith("$"):
            path = _resolve_script_mention(token.lstrip("./"), by_base)
        else:
            path = _resolve_script_mention(base, by_base)
        if not path or path in seen:
            continue
        seen.add(path)
        found.append(path)
    return found


def _accepted_flags(
    script_text: str,
    by_base: Dict[str, List[str]],
    show,
) -> Set[str]:
    """Long options in this script plus the libs it sources.

    ``program-lib.sh`` is followed one more level so flags defined in the
    modules it aggregates count for every program script.
    """
    flags = set(FLAG_RE.findall(script_text))
    queue = _sourced_shell_paths(script_text, by_base)
    seen: Set[str] = set()
    i = 0
    while i < len(queue):
        sp = queue[i]
        i += 1
        if sp in seen:
            continue
        seen.add(sp)
        text = show(sp)
        if not text:
            continue
        flags |= set(FLAG_RE.findall(text))
        if os.path.basename(sp) == "program-lib.sh":
            for child in _sourced_shell_paths(text, by_base):
                if child not in seen:
                    queue.append(child)
    return flags - META_FLAGS


def _doc_spans(text: str) -> List[Tuple[int, str]]:
    """Non-empty lines paired with their byte offset in ``text``.

    Fence markers are not spans. The offset is required because two identical
    lines must stay two findings; ``str.find`` would keep only the first.
    """
    spans: List[Tuple[int, str]] = []
    offset = 0
    for line in text.splitlines(keepends=True):
        body = line.splitlines()[0] if line.splitlines() else ""
        if body.strip() and not body.lstrip().startswith("```"):
            spans.append((offset, body))
        offset += len(line)
    return spans


def _line_at(text: str, offset: int) -> int:
    return text[:offset].count("\n") + 1


def _subcommand_after_mention(span: str, end: int) -> Optional[str]:
    """A usage token after a script, not the next word of a sentence.

    ``script.sh `set-output` `` and ``script.sh set-output --flag`` count.
    ``script.sh measures`` does not.
    """
    rest = span[end:]
    m = re.match(r"`?[ \t]+`([a-z][a-z0-9-]*)`", rest)
    if m and m.group(1) not in _PROSE_WORDS and m.group(1) not in _SUBCMD_STOPWORDS:
        return m.group(1)
    m = re.match(r"`?[ \t]+([a-z][a-z0-9-]*)\b[ \t]+--", rest)
    if m and "-" in m.group(1):
        return m.group(1)
    return None


def check_flags(
    clone: str,
    ref: str,
    tree: Set[str],
    docs: List[Tuple[str, str]],
    repo: str,
    ignore: Sequence[str],
) -> List[Finding]:
    findings: List[Finding] = []
    by_base = _scripts_by_basename(tree)
    shown: Dict[str, Optional[str]] = {}

    def show(path: str) -> Optional[str]:
        if path not in shown:
            shown[path] = git_show(clone, ref, path)
        return shown[path]

    # Intra-script: header list vs the dispatcher (the set-requirements case).
    for paths in by_base.values():
        for spath in paths:
            if spath.startswith("tests/") or "/tests/" in spath:
                continue
            if path_ignored(spath, ignore):
                continue
            script_text = show(spath)
            if script_text is None:
                continue
            header = _header_subcommands(script_text)
            cases = _case_subcommands(script_text)
            if not header:
                continue
            for sub in sorted(cases - header):
                findings.append(
                    Finding(
                        check="flags",
                        kind="addition",
                        mechanical=True,
                        doc_path=spath,
                        doc_line=1,
                        code_path=spath,
                        code_line=line_of(script_text, sub) if sub in script_text else 1,
                        claim=f"document subcommand `{sub}`",
                        evidence=f"`{sub}` in case arms of {spath} but absent from header list",
                        repo=repo,
                        draft=sub,
                    )
                )
            for sub in sorted(header - cases):
                findings.append(
                    Finding(
                        check="flags",
                        kind="correction",
                        mechanical=False,
                        doc_path=spath,
                        doc_line=line_of(script_text, sub),
                        code_path=spath,
                        code_line=1,
                        claim=f"{os.path.basename(spath)} implements `{sub}`",
                        evidence=f"`{sub}` listed in header but not in case arms of {spath}",
                        repo=repo,
                    )
                )

    for doc_path, text in docs:
        if path_ignored(doc_path, ignore):
            continue
        for offset, span in _doc_spans(text):
            mentions: List[Tuple[int, str]] = []
            for m in _SCRIPT_MENTION_RE.finditer(span):
                if re.search(r"https?://\S*$", span[: m.start()]):
                    continue
                spath = _resolve_script_mention(m.group(1), by_base)
                if not spath:
                    continue
                mentions.append((m.end(), spath))
            if not mentions:
                continue
            # A flag belongs to the nearest script named before it on this
            # line. ``alpha.sh and beta.sh --frobnicate`` is a claim about
            # beta only. A flag that appears first belongs to whatever command
            # preceded the script. `--flag` is the generic word, not an option.
            flag_at = []
            for m in FLAG_RE.finditer(span):
                if m.group(1) in META_FLAGS or m.group(1) == "--flag":
                    continue
                # "no --repos flag" is a denial, not a claim the script accepts it.
                prefix = span[max(0, m.start() - 40) : m.start()]
                if re.search(r"\b(?:no|not|without)\b", prefix, re.I):
                    continue
                flag_at.append(m)
            doc_line = _line_at(text, offset)
            for fm in flag_at:
                prior = [pair for pair in mentions if pair[0] <= fm.start()]
                if not prior:
                    continue
                _end, spath = max(prior, key=lambda pair: pair[0])
                script_text = show(spath)
                if script_text is None:
                    continue
                accepted = _accepted_flags(script_text, by_base, show)
                flag = fm.group(1)
                if flag in accepted:
                    continue
                findings.append(
                    Finding(
                        check="flags",
                        kind="correction",
                        mechanical=False,
                        doc_path=doc_path,
                        doc_line=doc_line,
                        code_path=spath,
                        code_line=1,
                        claim=f"{os.path.basename(spath)} accepts `{flag}`",
                        evidence=f"`{flag}` not found in parser of {spath}",
                        repo=repo,
                    )
                )
            for _end, spath in mentions:
                script_text = show(spath)
                if script_text is None:
                    continue
                sub = _subcommand_after_mention(span, _end)
                if sub and sub not in _case_subcommands(script_text):
                    findings.append(
                        Finding(
                            check="flags",
                            kind="correction",
                            mechanical=False,
                            doc_path=doc_path,
                            doc_line=doc_line,
                            code_path=spath,
                            code_line=1,
                            claim=f"{os.path.basename(spath)} implements `{sub}`",
                            evidence=f"`{sub}` listed in docs but not in parser of {spath}",
                            repo=repo,
                        )
                    )
    return findings


def check_enumerations(
    clone: str,
    ref: str,
    cfg: Dict[str, Any],
    docs_index: Dict[str, str],
    repo: str,
) -> List[Finding]:
    findings: List[Finding] = []
    for src in cfg.get("sources_of_truth") or []:
        if not isinstance(src, dict):
            continue
        code = src.get("code") or {}
        cfile = code.get("file", "")
        pattern = code.get("pattern", "")
        if not cfile or not pattern:
            continue
        code_text = git_show(clone, ref, cfile)
        if code_text is None:
            continue
        if len(pattern) > 256:
            findings.append(
                Finding(
                    check="config",
                    kind="correction",
                    mechanical=False,
                    doc_path=CONFIG_PATH,
                    doc_line=1,
                    code_path=cfile,
                    code_line=1,
                    claim="sources_of_truth pattern is a valid regex",
                    evidence=f"pattern longer than 256 characters in {CONFIG_PATH}",
                    repo=repo,
                )
            )
            continue
        try:
            compiled = re.compile(pattern)
        except re.error as exc:
            findings.append(
                Finding(
                    check="config",
                    kind="correction",
                    mechanical=False,
                    doc_path=CONFIG_PATH,
                    doc_line=1,
                    code_path=cfile,
                    code_line=1,
                    claim="sources_of_truth pattern is a valid regex",
                    evidence=f"invalid pattern {pattern!r}: {exc}",
                    repo=repo,
                )
            )
            continue
        m = compiled.search(code_text)
        if not m:
            continue
        captured = m.group(1) if m.lastindex else m.group(0)
        code_tokens = [t for t in re.split(r"[\s,]+", captured.strip()) if t]
        code_set = set(code_tokens)
        code_line = code_text[: m.start()].count("\n") + 1
        for dpath in src.get("docs") or []:
            dtext = docs_index.get(dpath) or git_show(clone, ref, dpath)
            if dtext is None:
                continue
            docs_index[dpath] = dtext
            # Tokens from the doc that look like the code tokens (same alphabet)
            doc_tokens = set()
            for tok in code_tokens:
                if re.search(rf"(?<![A-Za-z0-9_-]){re.escape(tok)}(?![A-Za-z0-9_-])", dtext):
                    doc_tokens.add(tok)
            # Also gather backtick tokens and table cells that match the style
            for bt in re.findall(r"`([a-z][a-z0-9-]*)`", dtext):
                if re.match(r"^[a-z]+(?:-[a-z0-9]+)*$", bt):
                    # Only consider if it's in the same namespace as code tokens
                    if any(bt.split("-")[0] == ct.split("-")[0] for ct in code_tokens) or bt in code_set:
                        doc_tokens.add(bt)
            for missing in sorted(code_set - doc_tokens):
                findings.append(
                    Finding(
                        check="enumerations",
                        kind="addition",
                        mechanical=True,
                        doc_path=dpath,
                        doc_line=1,
                        code_path=cfile,
                        code_line=code_line,
                        claim=f"document `{missing}` in {src.get('name', 'enum')}",
                        evidence=f"`{missing}` in {cfile} capture, absent from {dpath}",
                        repo=repo,
                        draft=missing,
                    )
                )
            for extra in sorted(doc_tokens - code_set):
                # Only flag extras that appear in an allowlist-like context
                if extra not in dtext:
                    continue
                findings.append(
                    Finding(
                        check="enumerations",
                        kind="correction",
                        mechanical=False,
                        doc_path=dpath,
                        doc_line=line_of(dtext, extra),
                        code_path=cfile,
                        code_line=code_line,
                        claim=f"`{extra}` is in {src.get('name', 'enum')}",
                        evidence=f"`{extra}` in {dpath} but not in {cfile} capture",
                        repo=repo,
                        replace_with="",
                    )
                )
    return findings


def check_retired_names(
    clone: str,
    ref: str,
    cfg: Dict[str, Any],
    files: List[Tuple[str, str]],
    repo: str,
) -> List[Finding]:
    findings: List[Finding] = []
    ignore = cfg.get("ignore_paths") or []
    retired = cfg.get("retired_names") or []
    names: List[Tuple[str, str]] = []
    for item in retired:
        if isinstance(item, str):
            names.append((item, ""))
        elif isinstance(item, dict):
            names.append((str(item.get("name", "")), str(item.get("replace_with", "") or "")))
    for name, repl in names:
        if not name:
            continue
        rx = re.compile(rf"(?i)(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])")
        for path, text in files:
            if path_ignored(path, ignore):
                continue
            for m in rx.finditer(text):
                findings.append(
                    Finding(
                        check="retired_names",
                        kind="correction",
                        mechanical=bool(repl),
                        doc_path=path,
                        doc_line=line_of_re(text, m),
                        code_path=CONFIG_PATH,
                        code_line=1,
                        claim=f"retired name `{name}` must not appear",
                        evidence=f"found `{m.group(0)}` in {path}",
                        repo=repo,
                        replace_with=repl,
                    )
                )
    return findings


def extract_versions_from_text(text: str) -> List[Tuple[str, int]]:
    """Versions named as the project's own version, not every semver.

    Dependency pins (``foo==1.2.3``) and changelog history headings are not
    matches: the line has to say "version" within a short gap of the number.
    """
    found = []
    for m in re.finditer(
        r"(?i)\bversion\b[^0-9\n]{0,40}?v?(\d+\.\d+\.\d+)\b",
        text,
    ):
        found.append((m.group(1), text[: m.start()].count("\n") + 1))
    return found


def _parse_iso(value: str) -> Optional[datetime]:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def pr_is_unreleased(pr: Dict[str, Any], releases: List[Dict[str, Any]]) -> bool:
    """True when the PR merged after the newest published stable release.

    Dates win over a caller-supplied ``unreleased`` flag. The flag is only
    a fallback for fixtures that do not pass ``mergedAt``.
    """
    published = [
        dt
        for dt in (_parse_iso(str(rel.get("publishedAt") or "")) for rel in releases)
        if dt is not None
    ]
    cutoff = max(published) if published else None
    merged = _parse_iso(str(pr.get("mergedAt") or ""))
    if cutoff is not None and merged is not None:
        return merged > cutoff
    return bool(pr.get("unreleased"))


def read_declared_versions(clone: str, ref: str, tree: Set[str]) -> Dict[str, Tuple[str, str, int]]:
    """Map source file -> (version, path, line)."""
    out: Dict[str, Tuple[str, str, int]] = {}
    for vf in VERSION_FILES:
        # marketplace may live under .claude-plugin/
        candidates = [vf]
        if vf == "marketplace.json":
            candidates.append(".claude-plugin/marketplace.json")
        for path in candidates:
            if path not in tree:
                continue
            text = git_show(clone, ref, path)
            if text is None:
                continue
            if path.endswith(".json"):
                try:
                    data = json.loads(text)
                except json.JSONDecodeError:
                    continue
                ver = None
                if isinstance(data, dict):
                    ver = data.get("version") or (data.get("metadata") or {}).get("version")
                if ver:
                    out[path] = (str(ver).lstrip("v"), path, line_of(text, str(ver)))
            elif path.endswith(".toml"):
                m = re.search(r'(?m)^version\s*=\s*["\']([^"\']+)["\']', text)
                if m:
                    out[path] = (m.group(1).lstrip("v"), path, line_of_re(text, m))
    return out


def check_versions(
    clone: str,
    ref: str,
    tree: Set[str],
    docs: List[Tuple[str, str]],
    boundary_label: str,
    repo: str,
    cfg: Dict[str, Any],
) -> List[Finding]:
    findings: List[Finding] = []
    declared = read_declared_versions(clone, ref, tree)
    if not declared:
        return findings
    # Prefer marketplace version as canonical when present. A stable tag
    # does not replace it: on main the declared version is often ahead of
    # the last tag, and rewriting docs back to the older tag is wrong.
    canon_ver, canon_path, canon_line = next(iter(declared.values()))
    for path, trip in declared.items():
        if "marketplace" in path:
            canon_ver, canon_path, canon_line = trip
            break
    if boundary_label.startswith("v") and re.match(r"^v\d+\.\d+\.\d+$", boundary_label):
        tag_ver = boundary_label[1:]
        if tag_ver != canon_ver:
            findings.append(
                Finding(
                    check="versions",
                    kind="correction",
                    mechanical=False,
                    doc_path=canon_path,
                    doc_line=canon_line,
                    code_path=f"tag:{boundary_label}",
                    code_line=1,
                    claim=f"declared version {canon_ver} matches tag {boundary_label}",
                    evidence=(
                        f"{canon_path} has {canon_ver}; tag {boundary_label} is {tag_ver}"
                    ),
                    repo=repo,
                    replace_with="",
                )
            )
    ignore = cfg.get("ignore_paths") or []
    for doc_path, text in docs:
        base = os.path.basename(doc_path).lower()
        if base == "changelog.md" or path_ignored(doc_path, ignore):
            continue
        # requirements.txt and other prose pins are not the project version.
        if doc_path.endswith(".txt"):
            continue
        for ver, line in extract_versions_from_text(text):
            if ver == canon_ver:
                continue
            findings.append(
                Finding(
                    check="versions",
                    kind="correction",
                    mechanical=True,
                    doc_path=doc_path,
                    doc_line=line,
                    code_path=canon_path,
                    code_line=canon_line,
                    claim=f"version is {canon_ver}",
                    evidence=f"doc has {ver}; {canon_path} has {canon_ver}",
                    repo=repo,
                    replace_with=canon_ver,
                )
            )
    return findings


def _nearby_script_names(text: str, start: int, end: int) -> List[str]:
    window = text[max(0, start - 240) : min(len(text), end + 240)]
    names = re.findall(r"`([^`]+)`", window)
    names += re.findall(r"\b([A-Za-z0-9_-]+\.sh)\b", window)
    return names


def check_absence_claims(
    clone: str,
    ref: str,
    tree: Set[str],
    basenames: Dict[str, List[str]],
    docs: List[Tuple[str, str]],
    repo: str,
) -> List[Finding]:
    findings: List[Finding] = []
    for doc_path, text in docs:
        for m in NOT_IMPLEMENTED_RE.finditer(text):
            for raw in _nearby_script_names(text, m.start(), m.end()):
                base = os.path.basename(raw)
                if base not in basenames:
                    continue
                code_path = basenames[base][0]
                findings.append(
                    Finding(
                        check="absence",
                        kind="correction",
                        mechanical=False,
                        doc_path=doc_path,
                        doc_line=line_of_re(text, m),
                        code_path=code_path,
                        code_line=1,
                        claim=f"`{base}` is not implemented in this skill",
                        evidence=f"`{code_path}` exists at {ref}",
                        repo=repo,
                    )
                )
        for m in AUTOMATION_ONLY_RE.finditer(text):
            for raw in _nearby_script_names(text, m.start(), m.end()):
                base = os.path.basename(raw)
                if base not in basenames:
                    continue
                code_path = basenames[base][0]
                findings.append(
                    Finding(
                        check="absence",
                        kind="correction",
                        mechanical=False,
                        doc_path=doc_path,
                        doc_line=line_of_re(text, m),
                        code_path=code_path,
                        code_line=1,
                        claim=f"`{base}` lives in the automation repo, not this repo",
                        evidence=f"`{code_path}` exists at {ref}",
                        repo=repo,
                    )
                )
    return findings


def changelog_sections(text: str) -> List[Tuple[str, Optional[str], int, int]]:
    """Return list of (version, date|None, start_offset, end_offset)."""
    matches = list(CHANGELOG_HEADING.finditer(text))
    sections = []
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        sections.append((m.group(1), m.group(2), m.start(), end))
    return sections


def bucket_for_pr(title: str, labels: Sequence[str]) -> Optional[str]:
    labs = {l.lower() for l in labels}
    if "security" in labs:
        return "Security"
    m = CONV_PREFIX.match(title.strip())
    if m:
        t = m.group("type").lower()
        if t in OMIT_TYPES:
            return None
        return BUCKET.get(t, "Uncategorized")
    return "Uncategorized"


def check_release(
    clone: str,
    ref: str,
    cfg: Dict[str, Any],
    releases: List[Dict[str, Any]],
    prs: List[Dict[str, Any]],
    repo: str,
) -> List[Finding]:
    findings: List[Finding] = []
    cl_path = (cfg.get("release") or {}).get("changelog", "CHANGELOG.md")
    text = git_show(clone, ref, cl_path)
    if text is None:
        return findings
    sections = changelog_sections(text)
    # Index releases by tag / version
    by_tag: Dict[str, Dict[str, Any]] = {}
    for rel in releases:
        tag = (rel.get("tagName") or "").lstrip()
        if not tag:
            continue
        by_tag[tag] = rel
        by_tag[tag.lstrip("v")] = rel

    for ver, date, start, end in sections:
        if ver.lower() == "unreleased":
            continue
        rel = by_tag.get(ver) or by_tag.get(f"v{ver}")
        if not rel:
            continue
        published = rel.get("publishedAt")
        if not published:
            continue  # draft — skip
        try:
            pub_dt = datetime.fromisoformat(published.replace("Z", "+00:00"))
        except ValueError:
            continue
        pub_date = pub_dt.astimezone(timezone.utc).strftime("%Y-%m-%d")
        heading_line = text[:start].count("\n") + 1
        if date and date != pub_date:
            body = rel.get("body") or ""
            evidence = f"CHANGELOG has {date}; GitHub publishedAt is {pub_date}"
            findings.append(
                Finding(
                    check="release_date",
                    kind="correction",
                    mechanical=True,
                    doc_path=cl_path,
                    doc_line=heading_line,
                    code_path=f"release:{rel.get('tagName', ver)}",
                    code_line=1,
                    claim=f"release {ver} date is {pub_date}",
                    evidence=evidence,
                    repo=repo,
                    replace_with=pub_date,
                    draft="",
                )
            )
            # Note stale release body heading when it repeats the changelog date
            if date in body and f"## [{ver}]" in body:
                findings[-1].evidence += f"; release body also has {date}"

    # Coverage / Unreleased drafts
    # Sort version sections newest-first for range bounds using tags when possible
    versioned = [(v, d, s, e) for (v, d, s, e) in sections if v.lower() != "unreleased"]
    # PRs not cited in their version section / unreleased
    unreleased_section = next(
        ((v, d, s, e) for (v, d, s, e) in sections if v.lower() == "unreleased"),
        None,
    )

    # Build cited PR numbers per section
    def cited_numbers(blob: str) -> Set[int]:
        nums = set()
        for m in re.finditer(r"#(\d+)\b", blob):
            nums.add(int(m.group(1)))
        for m in re.finditer(r"/pull/(\d+)", blob):
            nums.add(int(m.group(1)))
        return nums

    # PRs merged after the newest published release belong in Unreleased.
    newest_ver = versioned[0][0] if versioned else None

    unreleased_prs = []
    missing_by_section: Dict[str, List[Dict[str, Any]]] = {}

    for pr in prs:
        num = int(pr.get("number") or 0)
        if not num:
            continue
        title = pr.get("title") or ""
        labels = [
            (l.get("name") if isinstance(l, dict) else str(l))
            for l in (pr.get("labels") or [])
        ]
        bucket = bucket_for_pr(title, labels)
        if bucket is None:
            continue
        pr = {**pr, "_bucket": bucket}
        # If the PR number appears anywhere in the changelog, treat as covered
        if num in cited_numbers(text):
            continue
        if pr_is_unreleased(pr, releases):
            unreleased_prs.append(pr)
        elif newest_ver:
            missing_by_section.setdefault(newest_ver, []).append(pr)
        else:
            unreleased_prs.append(pr)

    def format_draft(prs_list: List[Dict[str, Any]], heading: str) -> str:
        groups: Dict[str, List[str]] = {}
        for pr in prs_list:
            b = pr["_bucket"]
            url = pr.get("url") or f"#{pr['number']}"
            title = pr.get("title") or ""
            # Strip conventional prefix for the bullet text
            clean = CONV_PREFIX.sub("", title).strip() or title
            groups.setdefault(b, []).append(f"- {clean} (#{pr['number']}: {url})")
        order = ["Added", "Changed", "Fixed", "Removed", "Security", "Uncategorized"]
        lines = [heading, ""]
        for b in order:
            if b not in groups:
                continue
            lines.append(f"### {b}")
            lines.append("")
            lines.extend(groups[b])
            lines.append("")
        return "\n".join(lines).rstrip() + "\n"

    if unreleased_prs:
        draft = format_draft(unreleased_prs, "## [Unreleased]")
        findings.append(
            Finding(
                check="release_draft",
                kind="addition",
                mechanical=True,
                doc_path=cl_path,
                doc_line=1,
                code_path="merged-prs",
                code_line=1,
                claim="document Unreleased merged PRs",
                evidence=f"{len(unreleased_prs)} merged PR(s) after newest tag not cited",
                repo=repo,
                draft=draft,
            )
        )

    for ver, prs_list in missing_by_section.items():
        if not prs_list:
            continue
        draft = format_draft(prs_list, f"## [{ver}] (additions)")
        # Find section line
        sec = next((s for s in sections if s[0] == ver), None)
        line = text[: sec[2]].count("\n") + 1 if sec else 1
        findings.append(
            Finding(
                check="release_coverage",
                kind="addition",
                mechanical=True,
                doc_path=cl_path,
                doc_line=line,
                code_path="merged-prs",
                code_line=1,
                claim=f"cite merged PRs in [{ver}]",
                evidence=f"{len(prs_list)} merged PR(s) not cited in [{ver}]",
                repo=repo,
                draft=draft,
            )
        )
    return findings


def collect_docs(clone: str, ref: str, tree: Set[str]) -> List[Tuple[str, str]]:
    docs = []
    for p in sorted(tree):
        if not p.endswith(DOC_EXTS):
            continue
        # Skip vendored / huge trees
        if p.startswith("node_modules/") or "/node_modules/" in p:
            continue
        text = git_show(clone, ref, p)
        if text is None:
            continue
        docs.append((p, text))
    return docs


def run_checks(
    clone: str,
    repo: str,
    releases: List[Dict[str, Any]],
    prs: List[Dict[str, Any]],
    ref_override: Optional[str] = None,
) -> Dict[str, Any]:
    # Load config at HEAD first to learn boundary mode, then resolve ref.
    head_sha = run_git(clone, "rev-parse", "HEAD").strip()
    preview_cfg = load_config(clone, head_sha)
    boundary = preview_cfg.get("boundary", "main")
    tag_pat = preview_cfg.get("stable_tag_pattern", DEFAULT_TAG_PATTERN)
    tag_pattern_error = ""
    try:
        re.compile(str(tag_pat))
    except re.error as exc:
        tag_pattern_error = str(exc)
        tag_pat = DEFAULT_TAG_PATTERN
    if ref_override:
        ref = ref_override
        label = ref_override
    else:
        ref, label = resolve_ref(clone, boundary, tag_pat)
    cfg = load_config(clone, ref)
    tree = git_ls_tree(clone, ref)
    basenames = git_basenames(tree)
    docs = collect_docs(clone, ref, tree)
    docs_index = {p: t for p, t in docs}
    # Text files scanned for retired names (docs + scripts/comments).
    scan_files: List[Tuple[str, str]] = list(docs)
    for p in sorted(tree):
        if not (p.endswith(".sh") or p.endswith(".py") or p.endswith(".md")):
            continue
        if any(existing == p for existing, _ in scan_files):
            continue
        text = git_show(clone, ref, p)
        if text is not None:
            scan_files.append((p, text))

    findings: List[Finding] = []
    if tag_pattern_error:
        findings.append(
            Finding(
                check="config",
                kind="correction",
                mechanical=False,
                doc_path=CONFIG_PATH,
                doc_line=1,
                code_path=CONFIG_PATH,
                code_line=1,
                claim="stable_tag_pattern is a valid regex",
                evidence=f"invalid stable_tag_pattern: {tag_pattern_error}",
                repo=repo,
            )
        )
    ignore = cfg.get("ignore_paths") or []
    findings += check_paths(clone, ref, tree, basenames, docs, repo, ignore)
    findings += check_flags(clone, ref, tree, docs, repo, ignore)
    findings += check_enumerations(clone, ref, cfg, docs_index, repo)
    findings += check_retired_names(clone, ref, cfg, scan_files, repo)
    findings += check_versions(clone, ref, tree, docs, label, repo, cfg)
    findings += check_absence_claims(clone, ref, tree, basenames, docs, repo)
    findings += check_release(clone, ref, cfg, releases, prs, repo)

    # Drop findings lacking both sides (plan rule)
    cleaned = []
    for f in findings:
        if not f.doc_path or not f.code_path or not f.claim or not f.evidence:
            continue
        if f.doc_line < 1 or f.code_line < 1:
            continue
        cleaned.append(f)

    # Dedupe by key
    seen: Set[str] = set()
    unique: List[Finding] = []
    for f in cleaned:
        k = f.key()
        if k in seen:
            continue
        seen.add(k)
        unique.append(f)

    return {
        "repo": repo,
        "ref": ref,
        "boundary_label": label,
        "config_path": CONFIG_PATH if git_show(clone, ref, CONFIG_PATH) is not None else None,
        "findings": [f.to_dict() for f in unique],
        "counts": {
            "corrections": sum(1 for f in unique if f.kind == "correction"),
            "additions": sum(1 for f in unique if f.kind == "addition"),
            "total": len(unique),
        },
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Deterministic doc-drift checker")
    ap.add_argument("--clone", required=True, help="Path to git clone")
    ap.add_argument("--repo", default="", help="owner/name")
    ap.add_argument("--ref", default="", help="Pin to this ref/SHA (skip boundary resolve)")
    ap.add_argument("--releases-json", default="", help="Path to releases JSON array")
    ap.add_argument("--prs-json", default="", help="Path to merged PRs JSON array")
    ap.add_argument("--releases", default="[]", help="Inline releases JSON")
    ap.add_argument("--prs", default="[]", help="Inline PRs JSON")
    args = ap.parse_args(argv)

    if not os.path.isdir(os.path.join(args.clone, ".git")):
        print(json.dumps({"error": f"not a git clone: {args.clone}"}))
        return 2

    releases: List[Dict[str, Any]] = []
    prs: List[Dict[str, Any]] = []
    if args.releases_json:
        with open(args.releases_json, encoding="utf-8") as f:
            releases = json.load(f)
    else:
        releases = json.loads(args.releases)
    if args.prs_json:
        with open(args.prs_json, encoding="utf-8") as f:
            prs = json.load(f)
    else:
        prs = json.loads(args.prs)

    repo = args.repo
    if not repo:
        # Best-effort from origin
        url = run_git(args.clone, "remote", "get-url", "origin")
        m = re.search(r"[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?$", url.strip())
        if m:
            repo = f"{m.group(1)}/{m.group(2)}"

    result = run_checks(
        args.clone,
        repo,
        releases,
        prs,
        ref_override=args.ref or None,
    )
    json.dump(result, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
