# changelog.d

Each pull request adds its CHANGELOG entry here as `<issue>.md`, instead of editing
`CHANGELOG.md` ([#277](https://github.com/filipac/runlet/issues/277)). After the merge, the
Changelog workflow moves it into `## Unreleased` and deletes it, so this folder is normally empty
apart from this file.

```sh
scripts/changelog.py new <issue>   # write changelog.d/<issue>.md from the issue's title
scripts/changelog.py check         # validate the fragments
```

The format and the workflow: [docs/changelog.md](../docs/changelog.md).
