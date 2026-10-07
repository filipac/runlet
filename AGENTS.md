# Runlet agent instructions

These are the rules AI agents follow in this repository, whatever the model or tool. [Contributing](docs/contributing.md) explains the same workflow for people, step by step and with the commands; [Building Runlet](docs/building.md) and [Testing](docs/testing.md) cover the tools; [Interface Guidelines](docs/ui-guidelines.md) is how the app looks, reads, and behaves.

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
- The owner sometimes asks for a fix straight on `main` ("fix it on main directly"). Commit to `main` only when asked, do exactly what was asked (with or without tests or a `changelog.d` entry), and reference the issue when there is one.

## Work through pull requests

- Work on an issue in its own branch named after the agent and the issue (`claude/issue-2-bundled-php`, `codex/issue-1-tab-titlebar`), in its own git worktree under `.claude/worktrees/` (gitignored). A new worktree needs the [one-time setup](docs/building.md#one-time-setup) before it builds or tests.
- Start with an empty commit (`git commit --allow-empty -m "Start <topic> (#N)"`), push it, and open the pull request as a **draft** right away, before writing code. Its description references the issue (`Closes #N`) and has a short checklist of what is done and what remains.
- When you open that draft, add the **`in progress`** label to every issue it will close (`gh issue edit N --add-label "in progress"`). The label means an agent is working on the issue right now.
- Push commits to the pull request as you go, with the issue number in each subject (`Pinned tabs: ⌘W asks first (#279)`). One pull request can have many commits; keep the description's checklist current.
- Commits and pull requests carry no AI attribution lines ("Co-Authored-By", "Generated with …").
- Record a user-visible change in `changelog.d/<issue>.md` (`scripts/changelog.py new <issue>`), not in `CHANGELOG.md`; a pull request that only changes documentation (`docs/`, the docs site, the readme) adds none. The fragment is the entry in CHANGELOG format without its date. After the merge, the Changelog workflow moves it into `## Unreleased`, so open pull requests don't conflict there. See [docs/changelog.md](docs/changelog.md) ([#277](https://github.com/filipac/runlet/issues/277)).
- Pull requests that add UI (a new pane, sheet, popover, or layout) include screenshots of it. Take them from the app with the DEBUG snapshot steps (`RUNLET_DEBUG_STEPS`, `RUNLET_SNAPSHOT_DIR`) and a scratch `RUNLET_DATA_DIR`, so they contain no personal data such as names, paths, hosts, or containers ([docs/testing.md](docs/testing.md#checking-the-app)). Publish them on the `pr-screenshots` branch under `issue-<N>/`; a retaken screenshot gets a new file name, because GitHub caches images by address. Documentation-only pull requests and small behaviour changes to existing UI need none: say so in the description.
- A change users notice updates its page in `docs/` in the same pull request, in the voice of [docs/writing-docs.md](docs/writing-docs.md); a new page goes into the navigation in `docs/.vitepress/navigation.ts` (the docs build fails on an unclassified page). Changes to building, testing, or releasing Runlet update the Development pages (`docs/building.md`, `architecture.md`, `releasing.md`, …). GitHub Actions builds and deploys https://runletapp.dev/docs/; never commit its build output ([#287](https://github.com/filipac/runlet/issues/287)).
- When the work is finished (tests pass, docs are updated, and any `changelog.d` entry is written), mark the pull request ready for review and add the **`ready to review`** label. The description says what was tested, what wasn't (for example UI tests or checks that need the running app), and what the owner should try by hand. Only the owner merges.
- Remove the `in progress` label from the issue as soon as no agent works on it any more: when the pull request is marked ready for review, or earlier if the work stops, is abandoned, or is handed back. Issues you file for later work don't get the label.

The initial policy and documentation migration are tracked in [#3](https://github.com/filipac/runlet/issues/3); the pull request workflow in [#65](https://github.com/filipac/runlet/issues/65); the `in progress` label in [#125](https://github.com/filipac/runlet/issues/125); the conventions below in [#330](https://github.com/filipac/runlet/issues/330).

## Build the interface the way Runlet does

Read [Interface Guidelines](docs/ui-guidelines.md) before you add or change a view, and copy the closest existing one. The rules that differ most between agents:

- **Risky confirmations** (code on production, a run an AI client asks for, a write to a server) are sheets where <kbd>Return</kbd> alone **cancels** and <kbd>⌘</kbd><kbd>Return</kbd> confirms, with a destructive, red confirm button, `.onExitCommand` cancelling, and a "⌘↩ confirms" caption. Reuse `ProductionConfirmationSheet` and `DatabaseDangerSheet`.
- **Ordinary sheets:** `VStack(alignment: .leading, spacing: 12)`, `.padding(20)`, a fixed width (460–640), a `.headline` title, Cancel (`.cancelAction`) then the primary button (`.defaultAction`) at the bottom right. The pending value lives on the model, and the sheet belongs to one window.
- **Confirming a delete or close:** `NSAlert` from model code or `.confirmationDialog` from a view. The title is a sentence-case question ("Close pinned tab?"), the message says what is and isn't touched, and the buttons are a Title Case verb, then Cancel. Never OK or Yes.
- **Errors** go through `model.alert = AppAlert(title:message:)`. The title is a statement ("Couldn't save the output"), and the message says what to do next.
- **Popovers** have an explicit width, padding 8 to 14, and a headline. Read-only peeks close with <kbd>Esc</kbd> and offer a way to promote them (**Open in Terminal**).
- **Wording:** Title Case for buttons, menus, commands, and empty-state titles. Sentence case for labels, tooltips, captions, and messages. Use **…** (one character) when more UI follows, curly quotes around names (“Cache”), ▸ in menu paths, contractions, and no "Please".
- **Every control has an `.accessibilityIdentifier`** in kebab-case, `<feature>-<element>` (`production-confirm`). Debug steps, screenshot scripts, What's New tours, and tests depend on them, so never rename one that's in use.
- **Every action** the user can trigger is an `AppCommand` in `CommandCatalog` (`Runlet/App/Commands.swift`), so menus, Open Anything, and Settings ▸ Shortcuts all get it. Command ids never change.
- **A feature with UI adds its own debug steps** (`Runlet/App/<Feature>DebugSteps.swift`) so it can be checked and photographed without a keyboard.
- **Old code that breaks these rules** is listed in [What Not to Copy](docs/ui-guidelines.md#what-not-to-copy). Don't copy it; fix it only when your issue covers it.

## Code conventions

- **Pure logic goes in `Packages/RunletKit/Sources/RunletCore`** as types without UI, with tests in `Packages/RunletKit/Tests/RunletCoreTests/<Name>Tests.swift`. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest; XCTest is only for `RunletUITests`.
- **App features** are `Runlet/App/AppModel+<Feature>.swift` extensions and `Runlet/Features/<Thing>View(s)/Sheet/Panel.swift` views.
- **Doc comments explain behaviour, including what never happens, and cite the issue:** `/// Renaming a tab (#285), …`, `// #279: …`. Match the comment density of the file you're in.
- **State persists through `JSONDocumentStore`** in `<data root>/State/*.json`, never UserDefaults.
  - A new setting is a defaulted property of `AppSettings` with a doc comment naming its Settings path and issue. Its decoding must keep older files loading.
  - Experimental work goes behind a `FeatureFlag`.
  - An undocumented, experimental hook says so in its doc comment.
- **Never put names, hosts, paths, or code from the owner's private projects** into Runlet's code, docs, tests, issues, or screenshots. Use neutral examples (`shop`, `example.com`, Alice Example).

## Tests

- Run the package tests with `scripts/test.sh fast` (no live fixtures, under a minute) while working, and `scripts/test.sh full` (Docker, SSH, and fixture databases) before marking a pull request ready or tagging a release. Extra arguments go to `swift test` (`scripts/test.sh full --filter Mongo`). A test that uses a shared fixture declares it with a trait (`.live(…)`, `.fixture(.wordpress)`); see [docs/testing.md](docs/testing.md) ([#242](https://github.com/filipac/runlet/issues/242)).
- Check what you see in the window with the scripted debug steps of a hidden Debug build ([Checking the App](docs/testing.md#checking-the-app)), not with UI tests (see below).

## On the owner's Mac

Agents usually run on the owner's Mac while the owner uses Runlet. Their work, data, and focus come first:

- **Don't touch the owner's Runlet.** Never launch, drive, or quit the running Runlet or Runlet Dev. Don't run the `RunletUITests` XCUITests, which launch and quit the app and take over the keyboard, unless the owner says the machine is free. Package tests, builds, and `--self-test` are fine at any time.
- **Check the app with your own build.**
  - Build with the screenshot bundle id (`dev.runlet.Runlet.prshots`) and DerivedData under your worktree's `build/`.
  - Launch it hidden (`open -g -j`) with a scratch `RUNLET_DATA_DIR`. It must never take focus or become the key window.
  - When the owner should try a build, give them the path and the `open` command instead of launching it for them.
- **Stay out of the owner's data.** Don't read or write:
  - `~/Library/Application Support/Runlet` or `Runlet Dev`
  - `~/.ssh` or the Keychain
  - projects' `.env` files and other secrets
  
  Keep `SSH_AUTH_SOCK=` empty for anything that could use SSH, and never connect to real servers or databases.
- **Docker:** use only the `runlet-fixtures` Compose project ([docs/testing.md](docs/testing.md#only-runlets-containers)) and the fake Docker CLI in `Tests/Fixtures/fake-docker/`. Never `docker exec` into other containers, and never pull images without asking.
- **Screenshots** show only the app's own windows with scratch data: never the full screen, and never real projects, hosts, or containers.
- **Signing:** never generate, read, or use the update signing key. The owner runs the commands that need it ([docs/releasing.md](docs/releasing.md)).
- **Window managers:** a tiling window manager can resize the hidden windows. Use the rule in [Window Managers](docs/writing-docs.md#window-managers) and never change the owner's window manager config without asking.
- **The shell:** `ls` may be an alias for a tool that hangs in non-interactive shells. Use `command ls` or `find`.

## Alongside other agents

Several agents often work at once, from different models:

- **One writer per worktree.** Before you resume or restart work on an issue, check that no other agent is on it: the worktree's recently changed files, and the pull request's latest commits.
- **Temporary files** (pull request bodies, notes, logs) go in your worktree's `build/` with names that include the issue number, never in a shared temp folder. After `gh pr edit --body-file`, check that the body still says `Closes #N` for your own issue.
- **Don't use bare `git stash`/`git stash pop`.** The stash is shared by every worktree; set work aside with a WIP commit.
- **Check every conflict resolution:** `grep -nE '^(<<<<<<<|\|\|\|\|\|\|\||=======$|>>>>>>>)'` must find nothing. The repository uses diff3 markers, and a stray `|||||||` line once reached published release notes.
- **Stacked pull requests:** retarget them before deleting their base branch (`gh pr edit N --base main`). Deleting the base closes them.
- **Bound your loops.** Measuring, tuning, or polishing gets at most 3 rounds. Push at least every 30 minutes, and stop and report when a step balloons. Don't wait for CI in a loop: GitHub Actions can be down, so push and move on.

## Releases

- Releases follow [docs/releasing.md](docs/releasing.md); the owner runs them with `scripts/release.sh` ([#263](https://github.com/filipac/runlet/issues/263)). Before a pre-release or a release, add What's New entries for the release's important features to `Runlet/WhatsNew.json`, under the version and build the release commit sets in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`; each beta build gets its own entry). Give important features a Show Me tour with anchors on the real UI. See [docs/whats-new.md](docs/whats-new.md#adding-entries-for-a-release); `WhatsNewTests` check the entries, and `scripts/package.sh` warns when the packaged version has none ([#232](https://github.com/filipac/runlet/issues/232)).
- Every release also gets an appcast item, or installed apps never see it; the owner signs it with their own key ([Releasing](docs/releasing.md)).

## Native UI test input

- Insert complete editor fixtures in one operation: paste the whole snippet, or seed scratch session state before launch. Never use character-by-character `typeText` for long snippets, base64 images, or other large test input; it blocks the user's keyboard. Preserve and restore the clipboard when tests use it.
