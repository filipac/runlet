"""Tests for scripts/changelog.py (#277): python3 -m unittest discover -s scripts/tests"""
from __future__ import annotations

import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("changelog", Path(__file__).resolve().parent.parent / "changelog.py")
changelog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(changelog)

HEAD = """# Changelog

All notable changes to Runlet are recorded here. Dates use ISO format.

## Unreleased

"""
RELEASED = """## 0.4.5 — 2026-10-05

- A summary.

### 2026-10-05 — Older ([#271](https://github.com/filipac/runlet/issues/271))

- Old.
"""


def link(n: int) -> str:
    return f"[#{n}](https://github.com/filipac/runlet/issues/{n})"


class Repo:
    """A scratch repository with a CHANGELOG.md and changelog.d/."""

    def __init__(self, changelog_text: str = HEAD + RELEASED):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "changelog.d").mkdir()
        (self.root / "changelog.d" / "README.md").write_text("# Fragments\n")
        (self.root / "CHANGELOG.md").write_text(changelog_text)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.commit("start")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, capture_output=True, text=True, check=True).stdout

    def commit(self, message: str, date: str | None = None) -> None:
        env = {"GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date} if date else {}
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", message], cwd=self.root, check=True,
                       env={**os.environ, **env})

    def fragment(self, name: str, text: str) -> Path:
        path = self.root / "changelog.d" / name
        path.write_text(text)
        return path

    def run(self, *args: str, actions: bool = False) -> tuple[int, str, str]:
        """Runs a command; errors go to stderr, or to stdout as annotations with actions (in GitHub Actions)."""
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), \
                mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true" if actions else ""}):
            code = changelog.main(["--root", str(self.root), *args])
        return code, out.getvalue(), err.getvalue()

    @property
    def text(self) -> str:
        return (self.root / "CHANGELOG.md").read_text()

    def close(self) -> None:
        self.tmp.cleanup()


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.addCleanup(self.repo.close)

    def test_collect_puts_dated_entries_on_top_of_unreleased_and_deletes_them(self):
        self.repo.fragment("273.md", f"### ⌘W closes the window in front ({link(273)})\n\n- **The bug:** …\n\n\n")
        code, out, _ = self.repo.run("collect", "--date", "2026-10-06")
        self.assertEqual(code, 0)
        self.assertIn("changelog.d/273.md → ### 2026-10-06 — ⌘W closes", out)
        self.assertEqual(self.repo.text, HEAD + f"### 2026-10-06 — ⌘W closes the window in front ({link(273)})\n\n"
                         "- **The bug:** …\n\n" + RELEASED)
        self.assertFalse((self.repo.root / "changelog.d" / "273.md").exists())
        self.assertTrue((self.repo.root / "changelog.d" / "README.md").exists())
        # Nothing left: a second run changes nothing.
        before = self.repo.text
        self.assertEqual(self.repo.run("collect")[0], 0)
        self.assertEqual(self.repo.text, before)

    def test_entries_already_in_unreleased_stay_below_the_new_ones(self):
        self.repo.fragment("280.md", f"### First ({link(280)})\n\n- One.\n")
        self.repo.run("collect", "--date", "2026-10-06")
        self.repo.fragment("281.md", f"### Second ({link(281)})\n\n- Two.\n")
        self.repo.run("collect", "--date", "2026-10-07")
        unreleased = self.repo.text.split("## Unreleased\n\n", 1)[1].split("## 0.4.5", 1)[0]
        self.assertEqual(unreleased, f"### 2026-10-07 — Second ({link(281)})\n\n- Two.\n\n"
                                     f"### 2026-10-06 — First ({link(280)})\n\n- One.\n\n")

    def test_the_fragment_merged_last_goes_first(self):
        # The merge order wins over the issue numbers.
        self.repo.fragment("300.md", f"### Merged first ({link(300)})\n")
        self.repo.commit("a", "2026-10-06T09:00:00Z")
        self.repo.fragment("290.md", f"### Merged second ({link(290)})\n")
        self.repo.commit("b", "2026-10-06T10:00:00Z")
        # Not committed yet: newest.
        self.repo.fragment("100.md", f"### Uncommitted ({link(100)})\n")
        _, out, _ = self.repo.run("collect", "--dry-run")
        self.assertEqual([line.split(" → ")[0] for line in out.splitlines()],
                         ["changelog.d/100.md", "changelog.d/290.md", "changelog.d/300.md"])
        self.assertTrue((self.repo.root / "changelog.d" / "100.md").exists(), "a dry run deletes nothing")

    def test_several_entries_and_a_written_date(self):
        self.repo.fragment("154-sql.md", f"### 2026-01-01 — SQL ({link(154)}, {link(152)})\n\n- a\n\n"
                                         f"#### Detail\n\n```sh\n# a comment\n### not a heading\n```\n\n"
                                         f"### CSV ({link(152)})\n\n- b\n")
        self.assertEqual(self.repo.run("check")[0], 0)
        self.repo.run("collect", "--date", "2026-10-06")
        self.assertIn(f"### 2026-10-06 — SQL ({link(154)}, {link(152)})\n", self.repo.text)
        self.assertIn(f"### 2026-10-06 — CSV ({link(152)})\n", self.repo.text)
        self.assertIn("```sh\n# a comment\n### not a heading\n```", self.repo.text)
        self.assertNotIn("2026-01-01", self.repo.text)

    def test_empty_unreleased_at_the_end_of_the_file(self):
        repo = Repo(HEAD)
        self.addCleanup(repo.close)
        repo.fragment("1.md", f"### Only ({link(1)})\n\n- x\n")
        repo.run("collect", "--date", "2026-10-06")
        self.assertEqual(repo.text, HEAD + f"### 2026-10-06 — Only ({link(1)})\n\n- x\n\n")

    def test_malformed_fragments_are_refused_and_nothing_is_collected(self):
        cases = {
            "notes.md": f"### Title ({link(5)})\n",                      # no issue number in the name
            "6.md": "- a bullet without a heading\n",
            "7.md": "### No link\n",
            "8.md": f"## Release heading ({link(8)})\n",
            "9.md": f"### Title ([#9](https://github.com/filipac/runlet/issues/10))\n",
            "11.md": f"### Another issue ({link(12)})\n",
            "13.md": f"### Conflict ({link(13)})\n<<<<<<< HEAD\n- a\n=======\n- b\n>>>>>>> branch\n",
        }
        for name, text in cases.items():
            with self.subTest(name):
                path = self.repo.fragment(name, text)
                code, _, err = self.repo.run("check")
                self.assertEqual(code, 1, err)
                self.assertIn(f"changelog.d/{name}", err)
                before = self.repo.text
                self.assertEqual(self.repo.run("collect")[0], 1)
                self.assertEqual(self.repo.text, before)
                self.assertTrue(path.exists())
                path.unlink()

    def test_errors_are_annotations_in_github_actions(self):
        self.repo.fragment("7.md", "### No link\n")
        code, out, err = self.repo.run("check", actions=True)
        self.assertEqual((code, err), (1, ""))
        self.assertIn("::error file=changelog.d/7.md::changelog.d/7.md: line 1: the heading needs an issue link", out)

    def test_a_changelog_without_one_unreleased_heading_is_refused(self):
        for text in ["# Changelog\n\n## 0.1.0 — 2026-01-01\n", HEAD + "## Unreleased\n"]:
            with self.subTest(text):
                repo = Repo(text)
                self.addCleanup(repo.close)
                repo.fragment("1.md", f"### X ({link(1)})\n")
                code, _, err = repo.run("collect")
                self.assertEqual(code, 1)
                self.assertIn("Unreleased", err)
                self.assertEqual(repo.text, text)

    def test_check_base_refuses_entries_written_straight_into_unreleased(self):
        base = self.repo.git("rev-parse", "HEAD").strip()
        (self.repo.root / "CHANGELOG.md").write_text(
            HEAD + f"### 2026-10-06 — Direct ({link(282)})\n\n- x\n\n" + RELEASED)
        code, _, err = self.repo.run("check", "--base", base)
        self.assertEqual(code, 1)
        self.assertIn("changelog.d/282.md", err)
        # Also next to a collected fragment.
        repo = Repo()
        self.addCleanup(repo.close)
        repo.fragment("285.md", f"### Collected ({link(285)})\n")
        repo.commit("fragment")
        base = repo.git("rev-parse", "HEAD").strip()
        repo.run("collect", "--date", "2026-10-06")
        (repo.root / "CHANGELOG.md").write_text(repo.text.replace(
            "## Unreleased\n\n", f"## Unreleased\n\n### 2026-10-06 — Sneaked in ({link(286)})\n\n", 1))
        code, _, err = repo.run("check", "--base", base)
        self.assertEqual(code, 1)
        self.assertIn("Sneaked in", err)
        self.assertNotIn("Collected", err)

    def test_check_base_allows_release_sections_and_collected_entries(self):
        self.repo.fragment("283.md", f"### Entry ({link(283)})\n\n- x\n")
        self.repo.commit("fragment")
        base = self.repo.git("rev-parse", "HEAD").strip()
        # What a beta's release script does when the workflow hasn't collected a fragment yet.
        self.repo.run("collect", "--date", "2026-10-06")
        self.assertEqual(self.repo.run("check", "--base", base)[0], 0)
        # A stable one also puts a version section above the entries.
        text = self.repo.text.replace("## Unreleased\n\n", "## Unreleased\n\n## 0.4.6 — 2026-10-06\n\n- Summary.\n\n", 1)
        (self.repo.root / "CHANGELOG.md").write_text(text)
        self.assertEqual(self.repo.run("check", "--base", base)[0], 0)
        # A fix to an older entry is fine too.
        (self.repo.root / "CHANGELOG.md").write_text(text.replace("- Old.", "- Older."))
        self.assertEqual(self.repo.run("check", "--base", base)[0], 0)

    def test_new_writes_a_fragment_that_checks(self):
        code, out, _ = self.repo.run("new", "284", "--title", "Something new")
        self.assertEqual((code, out.strip()), (0, "changelog.d/284.md"))
        self.assertEqual((self.repo.root / "changelog.d" / "284.md").read_text(), f"### Something new ({link(284)})\n\n- \n")
        self.assertEqual(self.repo.run("check")[0], 0)
        self.assertEqual(self.repo.run("new", "284", "--title", "Again")[0], 1)
        self.assertEqual(self.repo.run("new", "284", "--title", "Second", "--slug", "docs")[0], 0)
        self.assertEqual(self.repo.run("new", "284", "--title", "Bad", "--slug", "Not OK")[0], 2)


if __name__ == "__main__":
    unittest.main()
