# Runlet agent instructions

## Track work in GitHub first

- Before implementing a feature, fixing a bug, doing a documentation task, or adding a TODO, follow-up, or planned work item, find or create an issue in `filipac/runlet`. This also applies to work requested directly in chat.
- Use `gh issue list --repo filipac/runlet --state all` and inspect likely matches before creating an issue. Reuse an existing issue when its scope matches; do not duplicate tracked work.
- Create missing issues with `gh issue create --repo filipac/runlet`. Include the concrete problem, intended behavior, acceptance criteria, relevant source/documentation paths, and any known partial implementation. Preserve priority and optional/deferred status; an issue is not authorization to implement an optional idea.
- Every issue must have clear labels: a type (`bug`, `enhancement`, or `documentation`), at least one `area:*` label, and one `priority:P1`, `priority:P2`, or `priority:P3` label. Mark optional ideas with `optional` and later ideas with `deferred`. Reuse repository labels and create a missing label with a descriptive name and description.
- Do not begin changes until the issue exists. If GitHub is unavailable, report the blocker instead of creating an untracked local backlog or beginning implementation.
- Reference the issue number or URL in any TODO, backlog entry, implementation notes, and PR description. Keep GitHub as the source of truth for outstanding work; documentation may summarize and link issues.
- Before turning an old plan into issues, check `CHANGELOG.md`, source code, and existing tests. Move completed ideas to `docs/done-next-release-ideas.md` with evidence. For partially completed ideas, archive the completed scope and track only the remaining scope in the issue and active backlog.
- Do not create issues for reference inventories, answered questions, or explicitly rejected/out-of-scope ideas unless the user asks to pursue them.
- Read-only investigation and routine validation of an already tracked task do not require separate issues. Keep related changes under the same issue; split independently actionable work into separate issues.

## Work through pull requests

- Work on an issue in its own branch (for example `claude/issue-2-bundled-php` or `codex/issue-1-tab-titlebar`), in a separate git worktree when other agents may be using the main checkout.
- Open the pull request early as a **draft**, as soon as there is a first commit. Its description references the issue (`Closes #N`) and has a short checklist of what is done and what remains. Don't wait until the end to open it.
- When you open that draft, add the **`in progress`** label to every issue it will close (`gh issue edit N --add-label "in progress"`). The label means an agent is working on the issue right now.
- Push commits to the pull request as you go. One pull request can have many commits; keep the description's checklist current.
- Record the change in `changelog.d/<issue>.md` (`scripts/changelog.py new <issue>`), not in `CHANGELOG.md`: the entry in CHANGELOG format without its date. After the merge, the Changelog workflow moves it into `## Unreleased`, so open pull requests don't conflict there. See [docs/changelog.md](docs/changelog.md) ([#277](https://github.com/filipac/runlet/issues/277)).
- Pull requests that change the UI include screenshots of the new or changed features. Take them from the app with the DEBUG snapshot steps (`RUNLET_DEBUG_STEPS`, `RUNLET_SNAPSHOT_DIR`) and a scratch `RUNLET_DATA_DIR`, so they contain no personal data such as names, paths, hosts, or containers.
- When the work is finished (tests pass, docs are updated, and the `changelog.d` entry is written), mark the pull request ready for review and add the **`ready to review`** label. Only the owner merges.
- Remove the `in progress` label from the issue as soon as no agent works on it any more: when the pull request is marked ready for review, or earlier if the work stops, is abandoned, or is handed back. Issues you file for later work don't get the label.

The initial policy and documentation migration are tracked in [#3](https://github.com/filipac/runlet/issues/3); the pull request workflow in [#65](https://github.com/filipac/runlet/issues/65); the `in progress` label in [#125](https://github.com/filipac/runlet/issues/125).

## Tests

- Run the package tests with `scripts/test.sh fast` (no live fixtures, under a minute) while working, and `scripts/test.sh full` (Docker, SSH, and fixture databases) before marking a pull request ready or tagging a release. Extra arguments go to `swift test` (`scripts/test.sh full --filter Mongo`). A test that uses a shared fixture declares it with a trait (`.live(…)`, `.fixture(.wordpress)`); see [docs/validation.md](docs/validation.md) ([#242](https://github.com/filipac/runlet/issues/242)).

## Releases

- Releases follow [docs/releasing.md](docs/releasing.md); the owner runs them with `scripts/release.sh` ([#263](https://github.com/filipac/runlet/issues/263)). Before a pre-release or a release, add What's New entries for the release's important features to `Runlet/WhatsNew.json`, under the version and build the release commit sets in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`; each beta build gets its own entry). Give important features a Show Me tour with anchors on the real UI. See [docs/whats-new.md](docs/whats-new.md#adding-entries-for-a-release); `WhatsNewTests` check the entries, and `scripts/package.sh` warns when the packaged version has none ([#232](https://github.com/filipac/runlet/issues/232)).

## Native UI test input

- Insert complete editor fixtures in one operation: paste the whole snippet, or seed scratch session state before launch. Never use character-by-character `typeText` for long snippets, base64 images, or other large test input; it blocks the user's keyboard. Preserve and restore the clipboard when tests use it.
