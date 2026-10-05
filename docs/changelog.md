# Changelog entries

A pull request doesn't edit `CHANGELOG.md`. It adds its entry as a file of its own,
`changelog.d/<issue>.md`, and after the merge a workflow moves the entry into `## Unreleased`
([#277](https://github.com/filipac/runlet/issues/277)). Different files never conflict, so open
pull requests no longer conflict at the top of Unreleased.

## Writing an entry

```sh
scripts/changelog.py new 273    # writes changelog.d/273.md with the issue's title (from gh)
```

The file holds the entry as it appears in `CHANGELOG.md`, without the date:

```markdown
### ⌘W closes the sheet or window in front ([#273](https://github.com/filipac/runlet/issues/273))

- **The bug:** Close Tab (⌘W) closed the active editor window's tab whatever had the keyboard.
- **What ⌘W acts on now:** …
```

- **Name:** the issue number, `273.md`. If one issue needs a second fragment, add a slug:
  `273-docs.md` (lowercase letters, digits, and hyphens).
- **Headings:** every entry starts with a `### ` heading that links its issue, and the file name's
  issue must be one of them. A fragment can hold several entries, and an entry can link several
  issues (`([#154](…), [#152](…))`). `####` subheadings are fine; `#` and `##` headings aren't.
- **Date:** leave it out. The workflow adds the day the entry lands on `main` (UTC), and replaces
  a date you wrote.
- **Check:** `scripts/changelog.py check` validates the fragments. Pull requests run it too.

## After the merge

The **Changelog** workflow (`.github/workflows/changelog.yml`) runs on every push to `main` that
touches `changelog.d/`:

1. It runs `scripts/changelog.py collect`: the fragments go to the top of `## Unreleased`, dated,
   newest merge first, and are deleted. `changelog.d/README.md` stays.
2. It commits the result as github-actions (`CHANGELOG: collect the entries of #273`) and pushes
   it to `main`.

A few details:
- **Permission:** the job asks for `contents: write`. The repository's default workflow token is
  read-only, and `main` isn't protected. If `main` gets branch protection, github-actions must be
  allowed to push to it.
- **Merges close together:** runs wait for each other (one concurrency group), and a queued run
  collects everything still there. A merge that lands while a run collects makes its push fail;
  it then starts again from the new `main`, up to five times.
- **No loops:** a push made with the workflow's token starts no other workflow, so the commit
  doesn't run the Changelog or Website workflows.
- **By hand:** Actions ▸ Changelog ▸ Run workflow collects whatever is left.

Pull your branch's `main` after merging if you need the collected `CHANGELOG.md` locally.

## On pull requests

The same workflow's `check` job runs when a pull request touches `changelog.d/`, `CHANGELOG.md`, or
the collector:
- **Tests:** the collector's tests (`python3 -m unittest discover -s scripts/tests`).
- **Fragments:** `scripts/changelog.py check --base HEAD^1` validates them.
- **No direct entries:** it also fails when the pull request adds a `### ` entry to Unreleased
  itself. Fixing an older entry, or the preamble, is fine. So is a release pull request: it adds a
  version section above the entries, and the entries of fragments it collected itself are allowed.

## Releases

`scripts/release.sh prepare` makes sure no entry is left behind:

1. **Before branching:** if `main` still has fragments, it waits up to two minutes for the
   workflow to collect them, so the release branch starts after that commit.
2. **In the release worktree:** fragments that are still there (the workflow is slow or failed)
   are collected there and go in with the release commit.

A stable release then puts its `## <version>` section above the entries, as before
([releasing.md](releasing.md)). After a release, `changelog.d/` holds only its README.

## For developers

| Piece | Where |
| --- | --- |
| Collector: `new`, `check [--base]`, `collect [--date] [--dry-run]` | `scripts/changelog.py` |
| Its tests | `scripts/tests/test_changelog.py` |
| Workflow: collect on `main`, check on pull requests | `.github/workflows/changelog.yml` |
| Release fallback | `scripts/release.sh` (`fragments_at`, `wait_for_collection`, the CHANGELOG step) |
