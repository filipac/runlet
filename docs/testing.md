# Testing

Runlet's tests are Swift Testing tests in the `Packages/RunletKit` package. Many of them run real PHP, Docker containers, a disposable SSH server, and database servers instead of mocks, so a few need fixtures. `scripts/test.sh` runs them in parallel. For the app itself, Debug builds take scripted steps and render their own windows to PNG, which checks a change end to end without driving your keyboard and mouse.

## Running the Tests

From the repository root:

```sh
scripts/test.sh fast
```

| Mode | Runs | Time |
| --- | --- | --- |
| `fast` | Everything except the tests that need live fixtures (Docker, the SSH fixture, the fixture database servers). Use it while you work. | About 45 seconds |
| `full` | Every test. It needs the [fixtures](#setting-up-the-fixtures) and warns when they're missing. Run it before a pull request is ready and before a release. | About 70 seconds |

The times are from an 18-core Mac. A fresh clone or worktree needs `scripts/build-sandbox.sh`, then `scripts/setup-fixtures.sh`, first ([Building Runlet](building.md#one-time-setup)). Without their Composer autoloaders, dozens of driver tests would fail with "Failed opening required …/vendor/autoload.php", so `scripts/test.sh` stops and says what to run instead.

### Options

Add `-v` (or `--verbose`) right after the mode to list each test as it finishes: passed with its time, failed, or skipped or cancelled and why. Everything after that goes to `swift test`, in one run:

```sh
scripts/test.sh fast --filter LaravelCompletion
scripts/test.sh fast -v --filter Redis
scripts/test.sh full --filter Mongo
```

Without extra arguments, the script builds once, then runs the three test targets one after another (`RunletLanguageTests`, `RunletCoreTests`, `RunletExecutionTests`) and prints each one's time.

| Variable | Effect |
| --- | --- |
| `RUNLET_TEST_VERBOSE=1` | The same as `-v`. |
| `RUNLET_TEST_WIDTH` | How many tests run at once. The default is two thirds of the logical CPUs (at least 4). |
| `RUNLET_TEST_LOCK_WAIT` | How many seconds a `full` run waits for [another one](#one-full-run-at-a-time). The default is 1800. |
| `RUNLET_TEST_LOCK` | Another lock file for `full` runs. |

### Reading the Results

While it runs, the script shows only failures and each target's result, then a summary with the build's and each target's time. The full log is `Packages/RunletKit/.build/runlet-tests/fast.log` or `full.log`.

Tests whose prerequisites are missing are **skipped, not failed**: host PHP, the Laravel fixture, Docker, or the PHPantom binary. A `fast` run reports the live-fixture tests as cancelled. So a green run on a Mac without Docker or PHP doesn't prove those paths: check the output for skipped tests, and only count `full` as proof for the live ones.

The script runs the tests with an empty `SSH_AUTH_SOCK`, so they never use your SSH agent.

## Setting Up the Fixtures

`scripts/setup-fixtures.sh` prepares disposable fixtures and never touches your own projects:

```sh
scripts/setup-fixtures.sh
```

It generates the Composer autoloaders of `Tests/Fixtures/*`, a Laravel fixture app copied from the sandbox, two Eloquent-without-Laravel apps, WordPress on SQLite, and a Symfony skeleton. The last three need the network the first time; when one can't be installed, its tests skip. Running it again reuses what's there.

### Docker Fixtures

The Docker tests use the `runlet-fixtures` Compose project: a Laravel container, a restricted one (non-root, read-only, PHP 7.4), two replicas of one service, a project-driver app, WordPress, an SSH host, and a PHP with the Excimer and SPX profilers. Start them, and pull the sandbox's image:

```sh
scripts/setup-fixtures.sh docker
docker pull php:8.4-cli
```

The SSH and profiler images are built from `Tests/Fixtures/docker` on first use, which needs the network once. The SSH tests start the `ssh` service themselves. It listens on `127.0.0.1:2222` only, and the tests reach it with a throwaway key, their own `ssh -F` config and `known_hosts`, and no agent. They never read `~/.ssh`.

Stop the containers when you're done:

```sh
docker compose -p runlet-fixtures down
```

### Database Fixtures

The live database tests need MariaDB 11, PostgreSQL 14, Redis, and MongoDB (plain, with TLS required, and a replica set). Start them:

```sh
scripts/setup-fixtures.sh databases
```

The script prints `export` lines for the variables the tests read. Export them in the shell that runs `scripts/test.sh full`, or let the shell do it:

```sh
eval "$(scripts/setup-fixtures.sh databases | grep '^export RUNLET_TEST_')"
```

| Variable | Server |
| --- | --- |
| `RUNLET_TEST_MYSQL` | MariaDB |
| `RUNLET_TEST_PGSQL` | PostgreSQL |
| `RUNLET_TEST_REDIS`, `RUNLET_TEST_REDIS_TLS` | Redis, plain and TLS |
| `RUNLET_TEST_MONGODB`, `RUNLET_TEST_MONGODB_TLS`, `RUNLET_TEST_MONGODB_RS` | MongoDB, plain, TLS, and the replica set `rs0` |
| `RUNLET_TEST_TLS` | The folder of the throwaway TLS certificates |

The servers listen on random ports on `127.0.0.1`, with throwaway credentials. Running the script again, from any worktree or the main checkout, reuses the running containers with the same ports and certificates.

The certificates live in one folder that every worktree shares: `runlet-fixtures/tls` in Git's common directory (the main checkout's `.git`, so it is never committed). The script hands it to Compose as `RUNLET_FIXTURE_TLS`, which you can also set to use another folder. If you run Compose yourself with the `databases` profile, set `RUNLET_FIXTURE_TLS` to that folder too; without it, Compose mounts `Tests/Fixtures/docker/tls` and recreates the containers. `COMPOSE_PROJECT_NAME` starts an isolated copy under another project name, on its own random ports.

To make new certificates, stop the databases, delete the folder, and run the script again:

```sh
docker compose -p runlet-fixtures --profile databases down
rm -rf "$(git rev-parse --path-format=absolute --git-common-dir)/runlet-fixtures/tls"
scripts/setup-fixtures.sh databases
```

### Only Runlet's Containers

Every test that runs Docker goes through a wrapper, `Tests/Fixtures/docker/fixtures-only-docker`, that lets through only the `runlet-fixtures` and `runlet-fixtures-recreate` Compose projects and Runlet's own sandbox containers. So the tests never list, inspect, or exec into your own containers, whatever `docker` is first on your `PATH`. There is no opt-out.

The tests find the real Docker CLI the way the app does: `PATH`, then the usual install folders. Set `RUNLET_REAL_DOCKER` to use another one:

```sh
cd Packages/RunletKit && RUNLET_REAL_DOCKER=/usr/local/bin/docker swift test
```

### When Docker Tests Fail

With Docker running but the fixture containers stopped:

- These tests fail and ask you to start the fixtures: `DockerRunTests`, `DockerDriverTests`, `DockerCommandsTests`, `ProjectREPLDockerTests`, `MagicCommentDockerTests`, `StrictTypesDockerTests`, the Docker test in `TargetInspectorTests`, and `WordPressMailDockerTests` (which skips when the WordPress fixture isn't generated).
- `ProfileRunDockerTests` is skipped.
- `SSHRunTests` and `MagicCommentSSHTests` start the `ssh` service themselves.
- The Docker sandbox, Compose recreation, and container listing suites don't use the fixture containers.

Without Docker, all of them are skipped, except `FixturesOnlyDockerTests`, where only the wrapper check needs Docker.

## Fixture Traits

Tests run in parallel. Most live tests keep to themselves: each uses its own tables (`p144_…`), Redis keys (`p190:…`), MongoDB databases, temporary folders, and SSH control sockets. A test or suite that uses a shared fixture declares it with a trait from `Tests/RunletExecutionTests/LiveFixtures.swift`:

```swift
@Suite(.serialized, .live(.sql), .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SQLRelationsLiveTests {
    // …
}
```

| Trait | Means |
| --- | --- |
| `.live(.sql)`, `.live(.redis)`, `.live(.mongo)`, `.live(.docker)`, `.live(.ssh)` | Uses that live fixture, shared with other live tests. A `fast` run cancels the test. |
| `.live(.ssh, exclusive: true)`, `.live(.sql, exclusive: true)` | Holds the fixture alone, because the test changes it for everyone (pauses the SSH server, replaces its `docker`) or reads what others change (the size of every table). |
| `.fixture(.wordpress)` | Holds `Tests/Fixtures/wordpress` alone: some tests add must-use plugins to it, and runs write to its SQLite database. Not live, so `fast` keeps it. |
| `.phpantom` (in `RunletLanguageTests`) | Takes one of two PHPantom slots, so not too many language servers index at once. |

A suite's trait covers its tests and nested suites. Each fixture has a readers-writer lock, first come first served: sharing tests run together, an exclusive one waits for them, and later ones wait behind it. Tests that need several fixtures take them in one fixed order, so they can't deadlock.

> [!IMPORTANT]
> A test that reaches a fixture without its trait fails: "… uses the sql fixture but has no .live(.sql) trait". Changes that need a fixture alone, such as pausing a container, can't be detected: give those tests `exclusive: true` yourself.

### One Full Run at a Time

Every worktree shares the same fixture containers and databases, and the traits only coordinate tests inside one test process. So a `full` run holds a lock while the execution tests run (or while `swift test` runs, when you pass arguments):

- **The lock** is `runlet-fixtures/tests.lock` in the repository's common `.git` folder, next to the certificates. It's a `lockf(1)` lock, so the system drops it when the run ends, even if the run is killed.
- **A second run waits.** It says "Waiting for the fixtures: another full test run is using them", with that run's worktree and start time.
- **It gives up** after 30 minutes (`RUNLET_TEST_LOCK_WAIT`), and says so.
- **Not locked:** `fast`, the language and core targets, and plain `swift test`.

### Plain `swift test`

`swift test` in `Packages/RunletKit` still works, but it runs with no limit on parallel tests, so a timing test can fail on a busy Mac, and it skips nothing. `RUNLET_TEST_SKIP_LIVE=1` skips the live tests as `fast` does, and `swift test --no-parallel` runs one test at a time. Without the fixtures, `FixtureSetupTests` says once what's missing.

## Checking the App

Package tests cover the model and the execution layer. For what you see in the window, Debug builds have scripted steps: the app replays them at launch, prints what it finds, renders its own windows to PNG, and quits. It needs no Screen Recording permission, and it never takes over your keyboard or mouse.

1. **Build a screenshot build.** With this bundle id, the app is named Runlet, without the DEV badge:

   ```sh
   xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Debug \
     -derivedDataPath build/DerivedData PRODUCT_BUNDLE_IDENTIFIER=dev.runlet.Runlet.prshots build
   ```

2. **Seed scratch data.** Point `RUNLET_DATA_DIR` at a folder in `build/`, and write the session, settings, and targets you need as `State/<name>.json` files, in the envelope the app writes: `{"schemaVersion": 1, "savedAt": 0, "data": …}`.
3. **Launch it with steps.** `ghost` makes the windows transparent and click-through, so the app doesn't cover your screen, and `shot:<name>` renders the main window into `RUNLET_SNAPSHOT_DIR`:

   ```sh
   open -g -j -n -W \
     --env RUNLET_DATA_DIR="$PWD/build/check-data" \
     --env RUNLET_SNAPSHOT_DIR="$PWD/build/check-shots" \
     --env RUNLET_DEBUG_STEPS="ghost,select:Scratch,run,wait-run,state,shot:after-run" \
     --stderr build/check.log build/DerivedData/Build/Products/Debug/Runlet.app
   ```

   `-g -j` starts the app hidden and in the background, so it never takes your keyboard. It still opens its main window, hidden, and `ghost` makes it visible but transparent. The steps start once that window is open. A launch that never gets one prints `RUNLET_DEBUG_STATE: no window: …` and `RUNLET_DEBUG_STEPS: done`, and quits without running any step.

4. **Read the result.** In the log, the app prints a `RUNLET_DEBUG_STATE:` line for each step that reports something, and `RUNLET_DEBUG_STEPS: done` when it has finished and quit.

The steps are comma-separated and run 1.5 seconds apart. The general ones are listed in `runDebugInspectorCheck` (`Runlet/App/RunletApp.swift`) and `Runlet/App/DebugSteps.swift`; features add their own in `Runlet/App/*DebugSteps.swift`. `scripts/*-screenshots.py` and `scripts/tab-rename-check.py` are complete examples that check a feature and take its pull request's screenshots.

> [!WARNING]
> Never show real projects, hosts, or containers in a check or a screenshot. Use scratch data and neutral names. For Docker, set `dockerExecutable` in the scratch settings to `Tests/Fixtures/fake-docker/docker`, or to `Tests/Fixtures/docker/fixtures-only-docker` to run code in the [fixture containers](#only-runlets-containers); for SSH, Debug builds read `RUNLET_SSH_CONFIG` instead of `~/.ssh/config` and `RUNLET_SSH_EXECUTABLE` instead of `/usr/bin/ssh` (`Tests/Fixtures/fake-ssh/ssh`). With `RUNLET_DEBUG_HOME` set to a scratch folder, a tab card shows a local project in it as `~/…`, not by your own folders.

### UI Tests

The `RunletUITests` target has XCUITests that launch the Debug app with a scratch `RUNLET_DATA_DIR` and drive it with real key events and clicks. They take over the Mac's keyboard and mouse while they run, so prefer the scripted steps above. To run them anyway:

```sh
xcodegen generate
TEST_RUNNER_RUNLET_DOCKER_FIXTURES=1 xcodebuild -project Runlet.xcodeproj -scheme Runlet \
  -configuration Debug -derivedDataPath build/DerivedData \
  -resultBundlePath build/uiall.xcresult -only-testing:RunletUITests test
```

`TEST_RUNNER_RUNLET_DOCKER_FIXTURES=1` tells the sandboxed test runner that the Docker fixtures are up; without it, the Docker scenarios are skipped. The scheme turns off automatic screenshots and screen recordings.

The opt-in screenshot tour renders Runlet's windows to PNG, with a fake Docker CLI so no real containers appear:

```sh
TEST_RUNNER_RUNLET_SNAPSHOT_DIR="$PWD/build/tour" xcodebuild -project Runlet.xcodeproj \
  -scheme Runlet -configuration Debug -derivedDataPath build/DerivedData \
  -only-testing:RunletUITests/VisualTourUITests test
```

> [!TIP]
> A UI test that needs a long snippet pastes it in one operation, or seeds it in the scratch session before launch. Typing it character by character blocks the keyboard. Save and restore the clipboard when a test uses it.

## Checking a Packaged App

`scripts/package.sh` builds the universal app, verifies it, and runs its headless self-test, which checks the bundled resources, the sandbox, PHPantom, Mago, and the updater. `RUNLET_SELFTEST_DOCKER=1` adds a Docker sandbox run:

```sh
RUNLET_SELFTEST_DOCKER=1 scripts/package.sh
```

Run the self-test again, natively and under Rosetta, each time with throwaway data:

```sh
RUNLET_DATA_DIR="$(mktemp -d)" dist/Runlet.app/Contents/MacOS/Runlet --self-test --docker
RUNLET_DATA_DIR="$(mktemp -d)" arch -x86_64 dist/Runlet.app/Contents/MacOS/Runlet --self-test --docker
```

In-app updates have an end-to-end test of their own, with local builds and feeds: see [Testing the Updater](releasing.md#testing-the-updater).

## Testing the Scripts

The changelog collector, `scripts/changelog.py`, has unit tests. Run them after changing it:

```sh
python3 -m unittest discover -s scripts/tests
```

Pull requests that touch `changelog.d/`, `CHANGELOG.md`, or the collector run them too ([Changelog Entries](changelog.md#on-pull-requests)).

## For developers

Parallel tests, the traits, and `scripts/test.sh` are [#242](https://github.com/filipac/runlet/issues/242); `-v` is [#244](https://github.com/filipac/runlet/issues/244). The shared certificates are [#176](https://github.com/filipac/runlet/issues/176), and the Docker wrapper [#80](https://github.com/filipac/runlet/issues/80). This page is [#293](https://github.com/filipac/runlet/issues/293).

- **Evidence.** Which test proves which requirement, the suites' prerequisites, and the packaged self-test's results are in [validation.md](validation.md), kept on GitHub.
- **Measured** on 2026-10-05 (Xcode 27, 18 logical CPUs, with PHPantom and Mago fetched): the old serial run, `swift test --no-parallel`, took 361 seconds (language 21, core 59, execution 281). `scripts/test.sh full` takes 69 seconds (language 11, core 14, execution 42), and `fast` 45 seconds (execution 18). Three full runs in a row passed.
- **Parallel width.** Some tests block a Swift-concurrency thread while they wait for a process. With no limit, a parallel run can take every thread, and runs that other tests time ("the first hit arrived … before the end") starve. The script passes the width to Swift Testing as `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`; `swift test --num-workers` doesn't reach Swift Testing.
- **The trait check.** The fixtures' accessors (`TestSupport.docker`, `SQLLiveDatabaseTests.servers`, `LiveServers`, `RedisFixture.server`, `SSHFixture.environment()`, `TestSupport.wordpressFixture`) fail a test without the trait; `LanguageTestSupport.session` does the same for `.phpantom`. `FixtureMarkingTests` checks that the fixture servers' variables are read only in `LiveFixtures.swift`, so a new test can't go around the accessors. Waiting for a fixture suspends a test without blocking a thread. Copies of the WordPress fixture (`TestSupport.cloneWordPressFixture`) leave out its must-use plugins and need no trait.
- **Who holds a fixture alone:** `SSHRunTests` (it pauses the server, kills its PHP processes, replaces its `docker`, and checks what runs as `runlet`), `SQLSavedConnectionSSHTests` (it empties `~runlet/.cache`), and `SQLServerPanelLiveTests.overviewAndSizes` (it reads the size of every table while other suites create and drop theirs). `.phpantom` exists because each PHPantom session indexes the Laravel fixture's `vendor/` on every core it gets; with about ten at once, a hover sent right after opening a document sometimes came back without its docblock.
- **The fake language server.** `Tests/Fixtures/fake-lsp/server.php` speaks LSP over stdin and stdout like PHPantom and records what Runlet sends: the capabilities, its answers to file-watcher registrations and progress tokens, and the `workspace/didChangeWatchedFiles` batches. `FileWatchingSessionTests` run it with host PHP, through a small shell launcher in a temporary folder ([#336](https://github.com/filipac/runlet/issues/336)).
- **The Docker wrapper's rules.** `ps` lists only the allowed containers, with one label-filtered `ps` per project or label. `inspect`, `exec`, `cp`, `pause`, `unpause`, `kill`, and `rm` take only those containers, by full ID, name, or ID prefix, and pass Docker their full IDs, so Docker never resolves an argument to another container. To `inspect`, any other container doesn't exist; the other commands refuse it, and the wrapper never asks Docker about it. `run` needs Runlet's sandbox label, and `compose` one of the allowed projects; everything else except `version`, `context`, and `image` is refused. The tests hand the real CLI to the wrapper through a small generated `docker` launcher. `FixturesOnlyDockerTests` proves the rules with a recording stand-in (`Tests/Fixtures/docker/recording-docker`) that has a fixture, a sandbox container, another Compose project's container, and one named like the fixture's short ID.
- **Profile Run in the app.** The Profile Run checks of [#41](https://github.com/filipac/runlet/issues/41) set `dockerExecutable` to the wrapper in a scratch `RUNLET_DATA_DIR`'s settings, with a Docker profile for the `profiler` service (Compose project `runlet-fixtures`, service `profiler`, `/var/www/html`, which mounts `Tests/Fixtures/laravel-app`). Start that service with `docker compose -p runlet-fixtures -f Tests/Fixtures/docker/compose.yml up -d profiler`.
- **Hidden launches.** Without `-ApplePersistenceIgnoreState YES`, AppKit opens no window for an app launched hidden (`open -j`); with it, AppKit opens SwiftUI's window, hidden. A Debug step run launched hidden opens the window itself when there is none, and counts a hidden window as open, because AppKit's `canBecomeMain` is false for any window that isn't visible (`AppDelegate.ensureMainWindow(countingHidden:)` in `Runlet/App/RunletApp.swift`). Before [#332](https://github.com/filipac/runlet/issues/332), such a launch had no window at all, and the check scripts dropped `-j`.
- **UI tests' hooks.** UI tests seed `State/*.json` envelopes instead of driving file pickers. `ScenarioUITests` seeds saved targets the same way. `VisualTourUITests` needs `TEST_RUNNER_RUNLET_SNAPSHOT_DIR` and points Runlet at `Tests/Fixtures/fake-docker/docker`.
