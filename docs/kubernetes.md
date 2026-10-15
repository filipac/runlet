# Kubernetes

Run PHP snippets in an existing Kubernetes pod with the pod's own PHP and application. A saved profile names the context, namespace, label selector, and container. Runlet uses your installed `kubectl`; it never reads or copies kubeconfig credentials.

## Creating a Profile

Choose **Library ▸ New Kubernetes Profile…**, or add one in **Library ▸ Manage Profiles…**.

1. Give the profile a name. Leave **Kubeconfig** blank for kubectl's default, or choose a file with **Browse…**.
2. Click **Load Contexts** and choose a context. Enter a namespace, or use **Load Namespaces** and **Choose Namespace**.
3. Enter a **Label selector**, such as `app=shop`, to list matching pods. **List Pods** refreshes the results. Filter the results by pod or node name. The list shows readiness, age, and restarts.
4. Choose the **Container**, then set the application's **Working directory**, **PHP executable**, and writable **Temporary directory**.
5. Optionally set a **Local source** checkout for code completion and links to local files. Set the **Environment** and **Color**, then click **Save**.

The pod spec decides the execution user. Runlet has no user override. Containers need PHP 7.4 or later and `env`; running a snippet doesn't require a shell. Stop requires Linux process information and either PHP's POSIX signaling functions or a shell with `kill`.

If kubectl isn't on your PATH, set **Settings ▸ General ▸ Kubernetes ▸ kubectl executable**. Credential plugins use the tool PATH, including the usual Homebrew locations. Runlet leaves authentication to kubectl.

**Load Namespaces** requires permission to list namespaces. If you don't have that permission, type the namespace instead. Listing pods needs read permission there; running and stopping need permission to exec in the chosen container.

## Choosing a Pod

Select the profile from the target menu or Open Anything. **Resolve when opened** may list pods; it never runs code. Production profiles wait for an explicit action.

Runlet considers only Running pods that aren't being deleted and have the chosen container Ready:

- **No matching pods:** Run explains that no Running pod has the Ready container. Choose Pod shows the same error instead of an empty sheet.
- **One matching pod:** Run uses it.
- **Several matching pods:** Run asks you to choose one. The sheet shows the pod, node, age, and restarts. Choose one, then press Run again. Runlet remembers this choice for the tab until the pod is replaced or its container isn't Ready, the profile changes, or you change the tab's target. If the pod becomes unavailable, choose again; Runlet never follows it to a replacement, even when only one pod remains.
- **Replicas are interchangeable:** Run chooses the oldest eligible pod, with a stable name ordering for ties. Enable this only when any matching replica is suitable.

Use **Library ▸ Choose Pod…** to choose explicitly. **Pin this pod until I choose again** saves the pod's name and UID. If the pod is replaced, Runlet refuses to follow the pin to its replacement. Use **Choose Pod…** again, or **Unpin Pod** in the profile editor.

Workspace exports abbreviate a kubeconfig path under your home folder with `~`; importing expands it for the receiving user. Credentials are never included.

Every call names the context and namespace explicitly. Changing kubectl's current context doesn't redirect a profile. Just before launch, Runlet checks that the chosen pod still has the same UID and its container is Ready. If it changed, resolve again. The run label and Run Log identify the selected pod and container.

## Running and Stopping

Press <kbd>⌘</kbd><kbd>R</kbd>. Runlet streams the runner and snippet over stdin, sets the run ID and temporary directory with `env`, and changes directory inside PHP before booting the application. Nothing is written into the application by Runlet's transport. Your snippet and application can still write files or services normally.

Production targets use the same confirmation as other targets. Opening a profile, workspace, history entry, or snippet never runs its code. AI client requests use Runlet's existing approval rules.

**Stop** opens a second exec in the same pod and container. It checks the runner's PID and run ID, sends SIGTERM, escalates to SIGKILL if needed, and checks that the runner ended. The pod keeps running. If confirmation fails, Runlet says PHP may still be running; stopping the local kubectl client alone is not confirmation.

## Commands, Shells, REPLs, and Tests

Open **Library ▸ Show Project Commands** and click **Load Commands** to list the project's commands. Listing boots the application; Kubernetes profiles never list commands automatically when the panel opens or a session is restored.

- **Run a command** to open it in a terminal in the profile's working directory. Commands that need arguments are typed without pressing Return, so you can complete them.
- **Open REPL** starts the project's Tinker, PsySH, or PHP interactive shell, using the profile's PHP.
- **Tests** runs all tests, a relative file, or a filter. Tests stay disabled on production targets.
- **Shell in Pod**, in the terminal panel's **+** menu or **View ▸ Shell in Pod**, opens `bash` when available, otherwise `sh`. **New Shell** still opens a shell on this Mac.

Each action resolves the pod using the same choice, pin, or interchangeable-replica rules as Run. If Choose Pod appears, choose one and trigger the action again. Commands, REPLs, and pod shells ask for confirmation on production before resolving or connecting.

The container needs `sh` and permission to exec. Runlet checks for a shell before opening the terminal and explains when it is missing; snippets still work without a shell. Commands and shells receive the profile's `TMPDIR`. If the working directory can't be opened, the terminal explains why and stops.

Just before opening the terminal, Runlet checks the pod's UID and readiness again. **Run Again** repeats resolution, the shell check, and any production confirmation, then opens a new terminal; the old output stays available. If the original editor tab was closed or changed targets, start the action again from the intended target.

> [!NOTE]
> kubectl addresses a pod by name, with no option to bind exec to a UID. A pod can still be replaced in the brief interval between the final check and exec, including a StatefulSet replacement with the same name.

Terminals aren't restored. Reopening Runlet with a Kubernetes tab and a visible terminal panel starts only a local shell and makes no cluster connection, even with **Resolve when opened** enabled.

## Following Logs

Open **View ▸ Logs**, choose the Kubernetes profile, and select **Container output** or a file. **Follow** lists eligible pods only when you click it. Runlet uses the pinned pod, the only eligible pod, or the oldest eligible pod when **Replicas are interchangeable** is on. Otherwise, choose a **Pod** in the Logs window, then click **Follow** again. The picker shows the name, age, and readiness. Its choice stays in memory for that source; it isn't saved. A current tab's pod choice can be preselected.

**Container output** reads the last 500 lines with `kubectl logs` and follows new output from the selected container. Files use `kubectl exec` and `tail -F`, including paths from the driver and **Other Path…**. **Find Logs** lists file names in that same pod; it uses the same choice and production confirmation rules. File following and discovery require `/bin/sh` in the container. Distroless containers without a shell can still show **Container output**.

Runlet rechecks the pod UID, Running state, and container readiness immediately before starting. Kubernetes accepts a pod name for logs and exec, so a small race remains if a pod is replaced between that check and the command starting, including a StatefulSet reusing a name. When the stream ends after deletion, a restart, or a connection failure, the window says to click **Follow** again. Runlet never reconnects automatically. A choice whose identity is gone asks you to choose again; a saved pin must be updated or removed.

**Stop**, closing the Logs window, or quitting ends the local kubectl process. For a file follow, closing its input also tells the shell inside the pod to stop `tail`. The [Connection Manager](connections.md#connection-manager) shows the pod and container, and **Close** stops the follow. Production profiles ask before following or finding files. The Logs window isn't restored, and reopening it never starts a remote follow.

The [Log Viewer](logs.md) describes parsing, filters, stack frames, and the 5,000-entry / 48 MB limit. Logs stay in the window and aren't saved or sent to AI clients.

## Current Limits

kubectl through SSH and port-forwarded database tunnels aren't included.

## For developers

[Kubernetes targets #33](https://github.com/filipac/runlet/issues/33) adds `RunletCore/Kubernetes.swift`, `RunletExecution/KubernetesCLI.swift` and `KubernetesExecAdapter.swift`, `AppModel+Kubernetes.swift`, and the profile and pod-choice views. The runner's `workingDirectory` request changes directory before project bootstrap without a shell. `KubernetesTests`, `KubernetesCLITests`, and `KubernetesRunTests` cover persistence, argument boundaries, resolution, rechecks, streaming, and Stop.

The fake CLI is `Tests/Fixtures/fake-kubectl/kubectl`. `KubernetesDebugSteps.swift` and `scripts/kubernetes-screenshots.py` drive the editor, pod list, ambiguous choice, and run with scratch data. The [testing guide](testing.md#kubernetes-fixtures) describes the opt-in local fixtures.

[Interactive terminals and commands #373](https://github.com/filipac/runlet/issues/373) adds `KubernetesTerminal`, the explicit shell command, preflight checks, and safe reruns. `KubernetesTerminalTests`, `KubernetesRunTests`, and `scripts/kubernetes-terminals-check.py` cover arguments, live refusal, restore, and production confirmation.


Log following is [#374](https://github.com/filipac/runlet/issues/374): `KubernetesLogFollow`, the shared `LogSource` list, and the Logs window's session-local pod picker. `KubernetesLogFollowTests`, `KubernetesLogSourceTests`, and `KubernetesLogLiveTests` cover arguments, selection, errors, parsing, Stop, and disposable-pod replacement. `scripts/logs-screenshots.py … kubernetes` checks opening without queries, ambiguity, following, finding, and close with the fake CLI.

Remote kubeconfig over SSH and database forwarding remain outside this implementation.
