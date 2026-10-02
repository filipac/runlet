# Sandbox auto-run

Implemented under [#30](https://github.com/filipac/runlet/issues/30).

In a **Laravel Sandbox** tab, click **Auto-run** in the toolbar to opt in for that tab. The button shows **AUTO** while enabled; click it again to turn it off. Enabling does not run the code already in the editor. The next editor edit starts an 800 ms debounce. Each subsequent edit restarts that delay, then Runlet evaluates the entire tab, regardless of the selection or the Run-prefers-selection setting.

An edit during an active run waits for it to finish before evaluating the latest code; automatic runs never overlap. **Stop** cancels pending automatic execution as well as stopping the current run. Explicit **Run** and **Run Selection** cancel pending automatic execution and retain their normal selection behavior. Empty code does not run. Errors appear in the normal output pane; another edit can run the corrected code.

Auto-run is off by default and belongs to one tab. New, duplicated, reopened, session-restored, and workspace-imported tabs start with it off. Loading code from history, snippets, imports, or disk turns it off. Switching targets also turns it off, including switching back to the sandbox. It is unavailable on local projects, Docker profiles, SSH profiles, or production targets. The sandbox itself keeps its usual choice of local PHP or a dedicated sandbox Docker runtime; opting in does not connect to a project or server.

Only editor edits after explicit opt-in trigger execution. Opening, importing, restoring, selecting, or enabling a tab does not execute it. Sandbox PHP can still have side effects: review the code before opting in.

## Validation

Native acceptance evidence is recorded here after the focused tests run. The tests use scratch `RUNLET_DATA_DIR` storage, real editor events, and PHP marker files rather than inferring execution from the toolbar alone.

## Implementation

`TabModel` keeps opt-in and debounce tasks outside `TabState`; `EditorController` marks programmatic loads separately from editor edits; `AppModel` cancels pending work on execution/close and checks eligibility again across asynchronous preparation. The delay uses Swift's cancellable [Task.sleep](https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:)).
