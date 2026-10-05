# Changelog Entries

A pull request doesn't edit `CHANGELOG.md`. It adds its entry as a file of its own, `changelog.d/<issue>.md`, and after the merge a workflow moves the entry into `## Unreleased`. Different files never conflict, so open pull requests don't conflict at the top of Unreleased.

## When a Pull Request Needs an Entry

Every user-visible change adds a `changelog.d` fragment. A pull request that only changes documentation (`docs/`, the docs site, or the readme) adds none. The checks never require a fragment, so this is up to you and the review.

## Writing an Entry

Create the file. It starts with the issue's title, which the script reads from GitHub with `gh`:

```sh
scripts/changelog.py new 273
```

That writes `changelog.d/273.md`. Write the entry as it will appear in `CHANGELOG.md`, without the date:

```markdown
### ⌘W closes the sheet or window in front ([#273](https://github.com/filipac/runlet/issues/273))

- **The bug:** Close Tab (⌘W) closed the active editor window's tab whatever had the keyboard.
- **What ⌘W acts on now:** …
```

Then check it:

```sh
scripts/changelog.py check
```

| Rule | Details |
| --- | --- |
| **File name** | The issue number: `273.md`. For a second fragment of the same issue, add a slug of lowercase letters, digits, and hyphens: `273-docs.md`, which `scripts/changelog.py new 273 --slug docs` writes. |
| **Headings** | Every entry starts with a `### ` heading that links its issue, and the file name's issue must be one of them. A fragment can hold several entries, and an entry can link several issues: `([#154](…), [#152](…))`. `####` subheadings are fine; `#` and `##` headings aren't. |
| **Title** | `--title` sets another title than the issue's. Without `gh`, the title is a placeholder to replace. |
| **Date** | Leave it out. The workflow adds the day the entry lands on `main` (UTC), and replaces a date you wrote. |

Pull requests run the check too.

## After the Merge

The **Changelog** workflow (`.github/workflows/changelog.yml`) runs on every push to `main` that touches `changelog.d/`:

1. It runs `scripts/changelog.py collect`: the fragments go to the top of `## Unreleased`, dated, newest merge first, and are deleted. `changelog.d/README.md` stays.
2. It commits the result as github-actions (`CHANGELOG: collect the entries of #273`) and pushes it to `main`.

Pull `main` after the merge if you need the collected `CHANGELOG.md` locally.

| Situation | What happens |
| --- | --- |
| **Merges close together** | Runs wait for each other (one concurrency group), and a queued run collects everything still there. A merge that lands while a run collects makes its push fail; the run then starts again from the new `main`, up to five times. |
| **Loops** | None: a push made with the workflow's token starts no other workflow, so the commit doesn't run the Changelog or Website workflows. |
| **By hand** | **Actions ▸ Changelog ▸ Run workflow** collects whatever is left. |

> [!NOTE]
> The job asks for `contents: write`. The repository's default workflow token is read-only, and `main` isn't protected. If `main` gets branch protection, github-actions must be allowed to push to it.

## On Pull Requests

The same workflow's `check` job runs when a pull request touches `changelog.d/`, `CHANGELOG.md`, or the collector:

- **Tests:** the collector's tests, `python3 -m unittest discover -s scripts/tests`.
- **Fragments:** `scripts/changelog.py check --base HEAD^1` validates them.
- **No direct entries:** it fails when the pull request adds a `### ` entry to Unreleased itself. Fixing an older entry, or the preamble, is fine. So is a release pull request: it adds a version section above the entries, and the entries of fragments it collected itself are allowed.

## Releases

`scripts/release.sh prepare` makes sure no entry is left behind:

1. **Before branching:** if `main` still has fragments, it waits up to two minutes for the workflow to collect them, so the release branch starts after that commit.
2. **In the release worktree:** fragments that are still there (the workflow is slow or failed) are collected there and go in with the release commit.

A stable release then puts its `## <version>` section above the entries, as before ([Releasing](releasing.md)). After a release, `changelog.d/` holds only its README.

## For developers

Changelog fragments are [#277](https://github.com/filipac/runlet/issues/277).

| Piece | Where |
| --- | --- |
| Collector: `new [--title] [--slug]`, `check [--base]`, `collect [--date] [--dry-run]` | `scripts/changelog.py` |
| Its tests | `scripts/tests/test_changelog.py` |
| Workflow: collect on `main`, check on pull requests | `.github/workflows/changelog.yml` |
| Release fallback | `scripts/release.sh` (`fragments_at`, `wait_for_collection`, the CHANGELOG step) |
