# Contributing

Runlet is free and open source, and bug reports, ideas, documentation, and code are all welcome. Every change starts as a GitHub issue and lands through a pull request that the owner reviews and merges. This page is the workflow; [Building Runlet](building.md) gets you a working build first.

## Reporting a Bug or an Idea

Open an [issue](https://github.com/filipac/runlet/issues). Search first, including closed issues: someone may have reported it already, or it may be fixed in the next release.

A good bug report has:

- the Runlet version (**Runlet ▸ About Runlet**) and your macOS version;
- the kind of target: the sandbox, a local project, Docker, or SSH, and the framework;
- the steps that show the problem, what you expected, and what happened;
- for a crash, the crash log ([Reading a Crash Log](crash-logs.md)).

> [!WARNING]
> Leave out passwords, tokens, hostnames, and anything else private. Replace them with placeholders before you paste output or a screenshot.

## The Workflow

1. [Find or create the issue](#start-with-an-issue).
2. [Make a branch](#a-branch-per-issue) for it, in its own worktree if you work on several things at once.
3. [Open a draft pull request](#open-a-draft-pull-request-early) with your first commit, and label the issue `in progress`.
4. Push as you go: the code, a [changelog entry](#a-changelog-entry) (none for a documentation-only change), the [documentation](#documentation), and [screenshots](#screenshots) for UI changes.
5. [Run the tests](#tests), then [mark the pull request ready for review](#marking-it-ready).

The owner reviews and merges. Nobody else merges.

## Start With an Issue

Every change has an issue: a feature, a bug fix, a documentation task, and even a TODO you leave in the code. Look for one first, and reuse it when its scope matches:

```sh
gh issue list --repo filipac/runlet --state all --search "pinned tabs"
```

If there's none, create it. Describe the problem, the behavior you intend, the acceptance criteria, and the files or pages involved:

```sh
gh issue create --repo filipac/runlet
```

An issue has labels:

| Label | Values |
| --- | --- |
| Type | `bug`, `enhancement`, or `documentation` |
| Area | At least one `area:*` label, such as `area:editor`, `area:database`, or `area:website` |
| Priority | `priority:P1` (next release), `priority:P2` (the one after), or `priority:P3` (later) |
| Scope | `optional` for an idea that needs the owner's go-ahead; `deferred` for later work |

If you can't set labels on the repository, say which ones fit in the issue, and the owner adds them.

> [!NOTE]
> An issue labelled `optional` isn't a go-ahead to build it. Ask in the issue first.

Keep related work in one issue, and split work that can ship on its own into separate issues. A TODO you leave in the code names its issue number.

## A Branch per Issue

Work on each issue in its own branch, named after it. With push access, branch from `main`; otherwise, [fork the repository](https://github.com/filipac/runlet/fork) and branch in your fork:

```sh
git fetch origin
git switch -c issue-123-short-name origin/main
```

To work on several issues at once, give each one a worktree instead of switching branches:

```sh
git worktree add -b issue-123-short-name ../runlet-issue-123 origin/main
```

> [!TIP]
> A new worktree has none of the gitignored downloads and dependencies. Run the [one-time setup](building.md#one-time-setup) in it before you build or test. The test fixtures' containers and certificates are shared by every worktree.

## Open a Draft Pull Request Early

Open the pull request as a **draft** as soon as you have a first commit; don't wait until the end. Its description says `Closes #123` and has a short checklist of what's done and what remains:

```sh
git push -u origin issue-123-short-name
gh pr create --draft --title "Pinned tabs ask before closing (#123)" --body-file pr.md
```

```markdown
Closes #123

- [x] ⌘W on a pinned tab asks first
- [ ] Docs: tabs.md
- [ ] Changelog entry
- [ ] Screenshots
```

Then label the issue `in progress`, which means someone is working on it right now:

```sh
gh issue edit 123 --repo filipac/runlet --add-label "in progress"
```

Push commits to the pull request as you go, with the issue number in each subject (`Pinned tabs: ⌘W asks first (#123)`), and keep the checklist current. One pull request can have many commits.

## What a Pull Request Includes

### A Changelog Entry

A user-visible change gets a changelog entry. Don't edit `CHANGELOG.md`: write the entry in a file of its own, `changelog.d/<issue>.md`, and check it:

```sh
scripts/changelog.py new 123
scripts/changelog.py check
```

After the merge, a workflow moves it into the changelog. The format is in [Changelog Entries](changelog.md).

> [!NOTE]
> A pull request that only changes documentation (`docs/`, the docs site, or the readme) adds no changelog entry.

### Documentation

A change that users notice updates its page in `docs/` in the same pull request; a new page goes into the navigation. Changes to building, testing, or releasing Runlet update these Development pages. [Writing Docs](writing-docs.md) has the style guide.

### Screenshots

A pull request that changes the UI shows the new or changed parts in screenshots, in light and dark when the appearance matters. Take them from a Debug build with scratch data, so they contain no personal data: no names, paths, hosts, or containers. [Checking the App](testing.md#checking-the-app) shows how: a scratch `RUNLET_DATA_DIR`, `RUNLET_DEBUG_STEPS`, and `RUNLET_SNAPSHOT_DIR`.

Attach them to the pull request's description. When you replace a screenshot, give the new one a new file name: GitHub caches images by their address.

### Tests

Add tests with the change, and run the package tests while you work:

```sh
scripts/test.sh fast
```

Before the pull request is ready, run `scripts/test.sh full` with the fixtures. [Testing](testing.md) has the fixtures and the options.

## Marking It Ready

When the work is finished (the tests pass, and the docs and any changelog entry are written), mark the pull request ready for review, label it `ready to review`, and take `in progress` off the issue:

```sh
gh pr ready
gh pr edit --add-label "ready to review"
gh issue edit 123 --repo filipac/runlet --remove-label "in progress"
```

Take `in progress` off as soon as nobody works on the issue anymore, also when you stop or hand the work back. Issues you file for later don't get it.

When a pull request changes the docs or the changelog entries, its checks build the docs (with every link checked) and validate the entries. The owner reviews, and only the owner merges.

## Labels for Work in Progress

| Label | On | Means |
| --- | --- | --- |
| `in progress` | The issue | Someone is working on it in an open pull request. Removed when the pull request is ready for review, or when the work stops. |
| `ready to review` | The pull request | The work is finished: tests pass, and docs and any changelog entry are written. The owner reviews and merges. |

## For developers

AI coding agents follow [AGENTS.md](../AGENTS.md), the short rule list for agents, which links here for the details. Branches made by agents are named after the agent (`claude/issue-2-bundled-php`, `codex/issue-1-tab-titlebar`), and agents keep their worktrees in `.claude/worktrees/`, which is gitignored. Agents publish pull request screenshots on the `pr-screenshots` branch, under `issue-<N>/`, and link them as `https://raw.githubusercontent.com/filipac/runlet/pr-screenshots/issue-<N>/<name>.png`.

- Tracking work in GitHub first: [#3](https://github.com/filipac/runlet/issues/3). Pull requests: [#65](https://github.com/filipac/runlet/issues/65). The `in progress` label: [#125](https://github.com/filipac/runlet/issues/125). Changelog fragments: [#277](https://github.com/filipac/runlet/issues/277). Docs in the same pull request: [#287](https://github.com/filipac/runlet/issues/287). This page: [#293](https://github.com/filipac/runlet/issues/293).
- Before turning an old plan into issues, check `CHANGELOG.md`, the source, and the tests. Completed ideas move to [done-next-release-ideas.md](done-next-release-ideas.md) with their evidence; for partly done ideas, only the rest is tracked. Answered questions, reference inventories, and rejected ideas get no issue unless the owner asks.
- If GitHub is unavailable, report that instead of keeping an untracked local backlog.
