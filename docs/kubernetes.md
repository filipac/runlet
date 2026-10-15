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

## Current Limits

Kubernetes targets run snippets, including application bootstrap, inspector output, and saved connections executed by that PHP. Interactive terminals, project commands, REPLs, and project tests aren't available yet. Kubernetes log following, kubectl through SSH, and port-forwarded database tunnels aren't included.

## For developers

[Kubernetes targets #33](https://github.com/filipac/runlet/issues/33) adds `RunletCore/Kubernetes.swift`, `RunletExecution/KubernetesCLI.swift` and `KubernetesExecAdapter.swift`, `AppModel+Kubernetes.swift`, and the profile and pod-choice views. The runner's `workingDirectory` request changes directory before project bootstrap without a shell. `KubernetesTests`, `KubernetesCLITests`, and `KubernetesRunTests` cover persistence, argument boundaries, resolution, rechecks, streaming, and Stop.

The fake CLI is `Tests/Fixtures/fake-kubectl/kubectl`. `KubernetesDebugSteps.swift` and `scripts/kubernetes-screenshots.py` drive the editor, pod list, ambiguous choice, and run with scratch data. The [testing guide](testing.md#kubernetes-fixtures) describes the opt-in local fixtures.

Follow-ups: [interactive terminals and commands #373](https://github.com/filipac/runlet/issues/373), [pod logs #374](https://github.com/filipac/runlet/issues/374). Remote kubeconfig over SSH and database forwarding remain outside this implementation.
