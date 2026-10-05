#!/usr/bin/env python3
"""CHANGELOG fragments (#277): each pull request writes its entry to changelog.d/<issue>.md
instead of editing CHANGELOG.md, so open pull requests don't conflict on the top of Unreleased.
After the merge, the Changelog workflow (.github/workflows/changelog.yml) runs `collect`.

  scripts/changelog.py new <issue> [--title T] [--slug S]   write changelog.d/<issue>[-S].md
  scripts/changelog.py check [--base <ref>]                 validate the fragments; with --base,
                                                            also refuse entries added straight to
                                                            CHANGELOG.md's Unreleased since <ref>
  scripts/changelog.py collect [--date YYYY-MM-DD] [--dry-run]
                                                            move the fragments to the top of
                                                            Unreleased, dated, and delete them

A fragment holds one or more entries in CHANGELOG.md's format, without the date, which `collect`
adds (the day it lands on main, UTC):

  ### Logs: a project driver's log files ([#271](https://github.com/filipac/runlet/issues/271))

  - **What changed:** …

docs/changelog.md explains the flow.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = "filipac/runlet"
FRAGMENTS = "changelog.d"
CHANGELOG = "CHANGELOG.md"
UNRELEASED = "## Unreleased"

NAME = re.compile(r"^(?P<issue>[1-9][0-9]*)(?:-[a-z0-9]+(?:-[a-z0-9]+)*)?\.md$")
ISSUE_LINK = re.compile(r"\[#(?P<n>[0-9]+)\]\(https://github\.com/" + re.escape(REPO) + r"/issues/(?P<m>[0-9]+)\)")
DATED = re.compile(r"^### (?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2}) — (?P<rest>.*)$")
CONFLICT = re.compile(r"^(<{7}|\|{7}|={7}|>{7})(\s|$)", re.M)


class FragmentError(Exception):
    pass


def issue_link(issue: int) -> str:
    return f"[#{issue}](https://github.com/{REPO}/issues/{issue})"


# ── Fragments ─────────────────────────────────────────────────────────────────────────────────

class Fragment:
    def __init__(self, path: Path):
        self.path = path
        self.name = path.name
        match = NAME.match(self.name)
        self.issue = int(match.group("issue")) if match else 0
        self.text = path.read_text(encoding="utf-8")

    def problems(self) -> list[str]:
        """What's wrong with it, empty when it can be collected."""
        found = []
        if not NAME.match(self.name):
            found.append("the name must be <issue>.md or <issue>-<slug>.md (lowercase letters, digits, hyphens)")
        if CONFLICT.search(self.text):
            found.append("it has a merge-conflict marker")
        lines = self.text.strip("\n").splitlines()
        if not lines or not lines[0].startswith("### "):
            found.append("it must start with a \"### Title ([#N](…))\" heading")
        headings = []
        for number, line in self.lines_outside_code(lines):
            if line.startswith("#") and not line.startswith("### ") and not line.startswith("#### "):
                found.append(f"line {number}: only ### entry headings (and #### inside them) belong in a fragment")
            elif line.startswith("### "):
                headings.append(line)
                links = list(ISSUE_LINK.finditer(line))
                if not links:
                    found.append(f"line {number}: the heading needs an issue link like {issue_link(self.issue or 1)}")
                for link in links:
                    if link.group("n") != link.group("m"):
                        found.append(f"line {number}: [#{link.group('n')}] links to issue {link.group('m')}")
        if self.issue and str(self.issue) not in {m.group("n") for h in headings for m in ISSUE_LINK.finditer(h)}:
            found.append(f"no heading links issue #{self.issue}, which the file is named after")
        return found

    @staticmethod
    def lines_outside_code(lines: list[str]):
        """(line number, line) for the lines outside fenced code blocks."""
        fenced = False
        for number, line in enumerate(lines, 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
            elif not fenced:
                yield number, line

    def entry(self, date: str) -> str:
        """The fragment as CHANGELOG.md text: every ### heading dated, trailing blank lines dropped."""
        lines = self.text.strip("\n").splitlines()
        headings = {number for number, line in self.lines_outside_code(lines) if line.startswith("### ")}
        out = []
        for number, line in enumerate(lines, 1):
            if number in headings:
                line = f"### {date} — {undated(line)}"
            out.append(line.rstrip())
        return "\n".join(out) + "\n"


def fragment_paths(root: Path) -> list[Path]:
    folder = root / FRAGMENTS
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.is_file() and p.suffix == ".md" and p.name != "README.md")


def added_at(root: Path, path: Path) -> float:
    """When git history added the fragment; files git doesn't have yet count as newest."""
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%ct", "--diff-filter=A", "--", str(path.relative_to(root))],
                             cwd=root, capture_output=True, text=True, check=True).stdout.strip()
        return float(out) if out else float("inf")
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return float("inf")


def load(root: Path) -> list[Fragment]:
    fragments = [Fragment(p) for p in fragment_paths(root)]
    problems = [f"{FRAGMENTS}/{f.name}: {p}" for f in fragments for p in f.problems()]
    if problems:
        raise FragmentError("\n".join(problems))
    return fragments


# ── CHANGELOG.md ──────────────────────────────────────────────────────────────────────────────

def unreleased_bounds(text: str) -> tuple[int, int]:
    """Where Unreleased's body starts and ends in CHANGELOG.md's text."""
    lines = text.splitlines(keepends=True)
    heading = [i for i, line in enumerate(lines) if line.rstrip("\n") == UNRELEASED]
    if len(heading) != 1:
        raise FragmentError(f"{CHANGELOG} must have one \"{UNRELEASED}\" heading (it has {len(heading)})")
    start = heading[0] + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    offset = sum(len(line) for line in lines[:start])
    return offset, offset + sum(len(line) for line in lines[start:end])


def unreleased_headings(text: str) -> list[str]:
    start, end = unreleased_bounds(text)
    return [line for line in text[start:end].splitlines() if line.startswith("### ")]


def insert_entries(text: str, entries: list[str]) -> str:
    """CHANGELOG.md's text with the entries at the top of Unreleased, in the given order."""
    start, end = unreleased_bounds(text)
    body = text[start:end].strip("\n")
    parts = [e.strip("\n") for e in entries] + ([body] if body else [])
    return text[:start] + "\n" + "\n\n".join(parts) + "\n\n" + text[end:]


# ── Commands ──────────────────────────────────────────────────────────────────────────────────

def annotate(message: str, file: str | None = None) -> None:
    """Prints an error, as a GitHub annotation inside Actions."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for line in message.splitlines():
            print(f"::error{' file=' + file if file else ''}::{line}")
    else:
        print(message, file=sys.stderr)


def git_show(root: Path, ref: str, path: str) -> str:
    return subprocess.run(["git", "show", f"{ref}:{path}"], cwd=root, capture_output=True, text=True, check=True).stdout


def removed_fragments(root: Path, base: str) -> list[str]:
    """The fragments at base that are gone now."""
    listed = subprocess.run(["git", "ls-tree", "--name-only", base, f"{FRAGMENTS}/"], cwd=root, capture_output=True,
                            text=True, check=True).stdout.splitlines()
    present = {p.name for p in fragment_paths(root)}
    return [Path(p).name for p in listed if NAME.match(Path(p).name) and Path(p).name not in present]


def undated(heading: str) -> str:
    dated = DATED.match(heading)
    return dated.group("rest") if dated else heading[4:]


def command_new(root: Path, issue: int, title: str | None, slug: str | None) -> int:
    if not title:
        try:
            title = json.loads(subprocess.run(["gh", "issue", "view", str(issue), "--repo", REPO, "--json", "title"],
                                              capture_output=True, text=True, check=True).stdout)["title"]
        except (subprocess.CalledProcessError, FileNotFoundError, KeyError, ValueError):
            title = "TITLE"
    name = f"{issue}-{slug}.md" if slug else f"{issue}.md"
    if not NAME.match(name):
        print(f"{name} isn't a fragment name: <issue>.md or <issue>-<slug>.md", file=sys.stderr)
        return 2
    path = root / FRAGMENTS / name
    if path.exists():
        print(f"{FRAGMENTS}/{name} already exists", file=sys.stderr)
        return 1
    path.parent.mkdir(exist_ok=True)
    path.write_text(f"### {title} ({issue_link(issue)})\n\n- \n", encoding="utf-8")
    print(f"{FRAGMENTS}/{name}")
    return 0


def command_check(root: Path, base: str | None) -> int:
    failed = False
    try:
        fragments = load(root)
    except FragmentError as error:
        for line in str(error).splitlines():
            annotate(line, line.split(":", 1)[0])
        failed = True
        fragments = []
    if base:
        try:
            before = git_show(root, base, CHANGELOG)
            # Entries of fragments this change collected (the release does when the workflow
            # hasn't yet) are no new entries.
            collected = {undated(line) for name in removed_fragments(root, base)
                         for line in git_show(root, base, f"{FRAGMENTS}/{name}").splitlines() if line.startswith("### ")}
            added = [h for h in unreleased_headings((root / CHANGELOG).read_text(encoding="utf-8"))
                     if h not in set(unreleased_headings(before)) and undated(h) not in collected]
        except subprocess.CalledProcessError as error:
            annotate(f"can't read {CHANGELOG} at {base}: {error.stderr.strip()}")
            return 1
        except FragmentError as error:
            annotate(str(error), CHANGELOG)
            return 1
        for heading in added:
            numbers = [m.group("n") for m in ISSUE_LINK.finditer(heading)]
            name = f"{numbers[0]}.md" if numbers else "<issue>.md"
            annotate(f"\"{heading[:80]}\" was added to {CHANGELOG}'s Unreleased; put it in {FRAGMENTS}/{name} "
                     f"instead (without the date, docs/changelog.md)", CHANGELOG)
            failed = True
    if not failed:
        print(f"{len(fragments)} fragment{'' if len(fragments) == 1 else 's'} ok" if fragments else "no fragments")
    return 1 if failed else 0


def command_collect(root: Path, date: str | None, dry_run: bool) -> int:
    try:
        fragments = load(root)
        changelog = root / CHANGELOG
        text = changelog.read_text(encoding="utf-8")
        unreleased_bounds(text)
    except FragmentError as error:
        annotate(str(error))
        return 1
    if not fragments:
        print("no fragments to collect")
        return 0
    date = date or datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    # Newest first, as CHANGELOG.md is: the fragment git added last goes on top.
    fragments.sort(key=lambda f: (added_at(root, f.path), f.issue, f.name), reverse=True)
    entries = [f.entry(date) for f in fragments]
    for fragment, entry in zip(fragments, entries):
        print(f"{FRAGMENTS}/{fragment.name} → {entry.splitlines()[0]}")
    if dry_run:
        return 0
    changelog.write_text(insert_entries(text, entries), encoding="utf-8")
    for fragment in fragments:
        fragment.path.unlink()
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="scripts/changelog.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    new = commands.add_parser("new", help="write a fragment for an issue")
    new.add_argument("issue", type=int)
    new.add_argument("--title", help="the entry's title (default: the issue's, from gh)")
    new.add_argument("--slug", help="a second fragment for the same issue: <issue>-<slug>.md")
    check = commands.add_parser("check", help="validate the fragments")
    check.add_argument("--base", help="also refuse entries added straight to Unreleased since this ref")
    collect = commands.add_parser("collect", help="move the fragments into Unreleased")
    collect.add_argument("--date", help="the entries' date (default: today, UTC)")
    collect.add_argument("--dry-run", action="store_true", help="only print what it would collect")
    args = parser.parse_args(argv)
    if args.command == "new":
        return command_new(args.root, args.issue, args.title, args.slug)
    if args.command == "check":
        return command_check(args.root, args.base)
    if args.date and not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    return command_collect(args.root, args.date, args.dry_run)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
