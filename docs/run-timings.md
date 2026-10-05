# Run Timings

Every run ends with a line that says how it went and how long it took: the total time, peak memory, and the run's queries, then how long the application took to boot and your code took to run.

```text
Completed · Total 412 ms · 38.5 MB peak · 7 queries (12.4 ms)
Bootstrap 180 ms · Execute 196 ms · Started 10:22:33
```

Hover the line, or the run's status at the bottom of the window, for every value, including the full date and time the run started. The same details are available to VoiceOver.

![The finished line of a run, with the total time, peak memory, queries, and the bootstrap and execute durations.](screenshots/run-timings-light.png#gh-light-mode-only)
![The finished line of a run, with the total time, peak memory, queries, and the bootstrap and execute durations.](screenshots/run-timings-dark.png#gh-dark-mode-only)

## What Each Value Means

| Value | Meaning |
| --- | --- |
| **Total** | The whole run as your Mac measured it: starting PHP, booting the application, running your code, and sending the output back. Over Docker or SSH, it includes the connection. |
| **Bootstrap** | How long the framework or project driver took to boot the application. |
| **Execute** | How long your code took, including finishing its output and the run inspector's records. |
| **Started** | When the run started, in your Mac's time zone. |
| **Peak memory** | PHP's peak memory during the run. |
| **Queries** | How many SQL statements the run sent, and their total time. Query time is part of Execute, not added on top. |

Bootstrap and Execute are measured by PHP, Total by Runlet, and each is rounded to the millisecond. So they don't add up exactly, especially over Docker or SSH. Measuring adds no extra connection or run.

When a value is missing, the details say **Unavailable**: PHP didn't report it. Runlet never guesses a missing value from the total, or carries one over from an earlier run.

- A run that ends with `exit()`, `dd()`, or a fatal error reports no Execute time.
- A run you stopped, or whose connection dropped, may have only its Bootstrap time.
- A run that fails while the application boots may have neither.

**Clear Output** (<kbd>⌘</kbd><kbd>K</kbd>) removes the output and the run's sections, but the status at the bottom keeps the query count and time until the next run starts.

> [!TIP]
> To time parts of your code, put `/*?.*/` between statements: each one shows the milliseconds since the previous one. To compare implementations, use [`\Runlet\bench()`](benchmarks.md).

## For developers

Added in [#9](https://github.com/filipac/runlet/issues/9).

| Metric | Source |
| --- | --- |
| Started | Wall-clock time on this Mac when the execution session began, before launching its process. Preparation before an execution session exists has no start time. |
| Bootstrap | The runner's reported framework/driver boot duration, in milliseconds. |
| Execute | The runner's reported execution phase, in milliseconds, including finishing its output and instrumentation. |
| Total | Host monotonic elapsed time for the execution session, including process launch, runner overhead, transport, and completion. |
| Peak memory | The PHP runner's reported peak memory. |
| Queries | Accepted query records and their recorded time. |

- The finished row is drawn in `Runlet/Features/OutputPane.swift`; the tooltip text is `TabModel.timingDetails(_:)`.
- The completion fields are optional. Older saved completion records and runner frames without timing fields remain readable; no protocol version or persistence schema change was needed.
- Loading, importing, or restoring code never executes it; explicit Run and production approvals keep their behavior, with the sandbox-only auto-run opt-in unchanged.

### Validation

Focused package checks cover old/new completion decoding; received zero/full/absent timings; cancellation, pre-launch failure, and incomplete transport; real PHP normal execution, runtime errors, `exit()`, and `dd()`; and the existing production guard (`RunTimingTests`). Native checks run an isolated Laravel sandbox with a query, compare the finished row and status details, clear output, then run a query-free error and early exit to verify that metrics do not leak across runs.

Executed checks at the time: 38 focused package tests passed (including the SSH CLI fixture) and 4 native UI tests passed. Three separate local-Laravel fixture checks were skipped because their fixture dependencies were absent; real Laravel query/timing behavior was exercised in the native sandbox test. PHP execution checks ran on host PHP 8.4.25 and PHP 7.4; screenshots used the sandbox on PHP 8.4.25. No live Docker or real SSH-server run was performed for this change.

Reproduce the screenshots with `python3 scripts/timing-screenshots.py /path/to/Runlet.app /path/to/output` against a Debug build. It uses a temporary `RUNLET_DATA_DIR` and the native `RUNLET_DEBUG_STEPS`/`RUNLET_SNAPSHOT_DIR` hooks, explicitly runs only the seeded sandbox code, then captures both appearances.
