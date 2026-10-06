# Docker

When your application runs in Docker, a Docker profile runs snippets inside its container, with the container's PHP, extensions, environment variables, and network. Laravel Sail, Docker Compose projects, and containers in OrbStack or Docker Desktop all work.

Runlet uses the Docker CLI's current context, so it sees the same containers as `docker ps` in your terminal. It runs code only in containers that are already running: it never starts, stops, or creates your containers.

## Creating a Docker Profile

Start your application first (for example, `sail up -d` or `docker compose up -d`). Then choose **Library ▸ New Docker Profile…** (<kbd>⇧</kbd><kbd>⌘</kbd><kbd>N</kbd>), also in the target menu.

The left side lists the running containers, with a search field for a name, an image, or a Compose project. Click your application's container: it becomes the profile's container, and the form fills in the name, execution user, working directory, and local source from it. Clicking another container replaces them, except the ones you changed yourself. Then check the form:

| Field | What to enter |
| --- | --- |
| **Name** | Shown in the target menu, tabs, and history, such as "Billing API". |
| **Working directory** | The application's folder inside the container, such as `/var/www/html`. The menu next to the field suggests the container's working directory and mounts; **Browse…** lists the container's folders. |
| **PHP executable** | `php`, or the path of another PHP inside the container. |
| **Execution user** | Optional: the user PHP runs as, such as `sail` or `1000:1000`. Empty uses the container's default user. |
| **Temporary directory** | A writable folder, exported as `TMPDIR` for each run, so `sys_get_temp_dir()` works in read-only containers. `/tmp` by default. |
| **Strict types**, **Mail** | As in a local project's [options](local-projects.md#project-options). |
| **Local source** | The same application's checkout on your Mac. See [Local Source](#local-source). |
| **PHP version** | The PHP version completion assumes. Empty reads it from `composer.json`. |
| **Environment** | Development, staging, or production, and a colour. See [Environments & Production](environments.md). |
| **Databases** | Database connections you save for this target, for [SQL tabs](connections.md#saved-connections). |

**Test Connection** runs a short, read-only PHP check inside the container (your snippet doesn't run). It shows the PHP version and binary, the user, whether the working directory exists and is readable, the framework, whether the temporary directory is writable, and how Stop can signal PHP. It also lists application folders it found, each with a **Use** button.

Two profiles may use the same container, for example with different users or working directories; the form says when another profile uses it.

Saving or opening a profile never runs code. To edit a profile later, choose **Edit Docker Profile…** in the target menu, or open **Library ▸ Manage Profiles…**, which shows every Docker and SSH profile side by side.

## How Runlet Finds the Container

Containers come and go: `docker compose up` after a change recreates the container with a new ID. So a profile remembers the container by its Compose project and service, or by its name when it has no Compose labels, never only by its ID.

Before each run, Runlet looks for the container again:

- **One running container matches:** the run uses it, even when it was recreated.
- **Several match** (replicas of one service): Runlet asks which one to use.
- **A container without Compose labels was replaced** by a new one with the same name: Runlet asks before it uses the new one.
- **None is running:** the run stops and says so. Start the container and run again.

Runlet never switches to another container silently. Right before PHP starts, it checks once more that the container still exists and is running.

**Resolve container when opening this profile** (in the profile's Connection section) looks for the container as soon as you switch a tab to the profile, so a stopped container shows up before you run. It never runs code.

## Local Source

The local source is the application's checkout on your Mac. It's optional, but it powers what Runlet reads from your Mac:

- **Completion and diagnostics** for your project's classes. Without it, only PHP's own functions and classes complete.
- **File links** in dumps, errors, and stack traces: paths inside the container map to the local source, and open in your editor.
- **Project snippets** in `.runlet/snippets/`, **host commands**, **Open Project in Editor**, and new terminal shells, which start in that folder.

When the profile has no local source and the container's working directory is mounted from a folder on your Mac, Runlet notices: a banner above the editor offers **Use for Completion**. It's never applied on its own.

## Commands and Shells

- **Project commands** from the Commands panel, and **Open REPL**, run inside the container, in a terminal tab: `docker exec -it`, in the working directory, as the execution user. See [Project Commands](project-commands.md).
- **Shell in … Container,** in the terminal's **+** menu, opens a shell in the container's working directory: `bash` when the container has it, else `sh`.
- **Host commands** that a project driver declares run on your Mac, in the local source folder, so `docker compose` or your own tools work even while the container is stopped.

## Stop

Stop ends the run's PHP process inside the container. Runlet checks that the process belongs to this run before it signals it, sends `SIGTERM`, and then `SIGKILL` if PHP doesn't end. The container keeps running: Runlet never uses `docker stop`.

> [!NOTE]
> Processes a snippet starts inside a container (with `exec()` or `proc_open()`) may keep running after Stop. Stop also needs Linux's `/proc`, and PHP's `posix_kill()` or a shell in the container; without them, Runlet reports the stop as unconfirmed.

## Settings

**Settings ▸ Docker** shows whether Docker is running and its version. Leave **CLI path** empty to find `docker` on your `PATH` and in the usual places (Docker Desktop, OrbStack, Rancher Desktop, Homebrew), or choose the binary yourself.

Docker is optional: Runlet needs it only for Docker profiles, and for the [Laravel Sandbox](laravel-sandbox.md#which-php-it-uses) when your Mac has no compatible PHP. A Docker container on a server is an [SSH profile](ssh.md#docker-on-the-server) with a container step.

## For developers

How Docker targets work, from [Architecture ▸ Docker targets](architecture.md#docker-targets):

- **CLI.** `ExecutableLocator` finds the Docker CLI; `AppSettings.dockerExecutable` overrides it. Running containers are listed with `docker ps -q --no-trunc` and `docker inspect --type container`, without Runlet's own containers (label `dev.runlet.owned`). A container can exit between `ps` and `inspect`; `docker inspect` then exits 1 but still prints the others, and Runlet skips the missing ones.
- **Profile.** `DockerProfile` (RunletCore) stores a `ContainerIdentity` (Compose project and service labels, the container name as a fallback, the last container ID and image), the working directory, the PHP executable, an optional user, the temporary directory, an optional local source and language PHP version, a strict-types and a mail override, the environment and colour, `autoResolve`, and a revision. `validate()` rejects relative paths, malformed users, and PHP values that start with `-`.
- **The editor's container list.** `DockerContainerSelection` (RunletExecution) holds the highlighted row and the fields the user set ([#318](https://github.com/filipac/runlet/issues/318)). A click highlights its row; `DockerProfileForm` applies it right after SwiftUI's view update, in one write, because the list's selection setter runs inside the update, where binding reads return the last drawn value. Listings only highlight the container the profile resolves to. `DockerContainerSelectionTests` cover the rules; the `docker-editor:…` DEBUG steps (`DockerEditorDebugSteps`) click rows in a hidden build.
- **Resolution.** `DockerProfileResolver`: a Compose identity with one running match resolves (flagged as recreated when the ID changed); several matches are ambiguous; no match is not running. Without Compose labels, the same ID resolves, and the same name with a new ID needs confirmation (`ContainerChoiceSheet`). Recording the new container ID isn't an edit.
- **Launch.** The snapshot's container ID is inspected again right before launch. The command is `docker exec -i --env RUNLET_RUN_ID=<id> --workdir <dir> [--env TMPDIR=<tmp>] [--user <user>] <containerId> <php> -d …`, with no TTY, keeping the container's environment. The runner arrives on stdin; nothing is written into the container.
- **Probe.** `DockerCLI.probe` uses only `php -r` inside the container, so no shell utilities are needed: PHP version and binary, user and uid, the working directory, framework, a writable temporary directory, the tokenizer, how Stop can signal (`posix`, `shell`, or `none`), and candidate application directories.
- **Facts.** `AppModel.detectFacts` reads the local source's files when there is one (and asks the container for its PHP version), else asks the container. A production profile's container is never asked: facts come from the local source or from runs. `noteSourceSuggestion` offers the host folder of the working directory's bind mount.
- **Stop.** `DockerExecAdapter` waits up to 2 s for the runner's PID, then runs `docker exec [--user U] <container> <php> -r <helper>`, which checks `/proc/<pid>/stat` and requires `RUNLET_RUN_ID=<runId>` in `/proc/<pid>/environ` before it signals (`posix_kill`, else `exec('kill …')`): `SIGTERM`, 1.5 s, `SIGKILL`, 3 s, then a signal-0 check. See [Architecture ▸ Cancellation](architecture.md#cancellation-stop) and the limitations in [compatibility.md](compatibility.md).
- **Shell.** `AppModel.openContainerShell`: `docker exec -it [--user] -w <dir> <container> sh -c 'command -v bash >/dev/null && exec bash || exec sh'`.
- This page was added under [#289](https://github.com/filipac/runlet/issues/289).
