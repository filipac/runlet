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
- Push commits to the pull request as you go. One pull request can have many commits; keep the description's checklist current.
- Pull requests that change the UI include screenshots of the new or changed features. Take them from the app with the DEBUG snapshot steps (`RUNLET_DEBUG_STEPS`, `RUNLET_SNAPSHOT_DIR`) and a scratch `RUNLET_DATA_DIR`, so they contain no personal data such as names, paths, hosts, or containers.
- When the work is finished (tests pass, and docs and `CHANGELOG.md` are updated), mark the pull request ready for review and add the **`ready to review`** label. Only the owner merges.

The initial policy and documentation migration are tracked in [#3](https://github.com/filipac/runlet/issues/3); the pull request workflow in [#65](https://github.com/filipac/runlet/issues/65).
