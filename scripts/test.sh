#!/usr/bin/env bash
# Runs the RunletKit package tests in parallel (#242).
#   scripts/test.sh fast             # everything except live-fixture tests (Docker, SSH, fixture databases)
#   scripts/test.sh full             # everything; needs the fixtures (docs/testing.md)
#   scripts/test.sh full --filter Mongo   # extra arguments go to `swift test`, in one invocation
#   scripts/test.sh fast -v          # -v/--verbose (or RUNLET_TEST_VERBOSE=1): list each test as it
#                                    # finishes (passed and its time, failed, skipped and why); #244
#
# Tests run in parallel. Tests that share a fixture say so with a trait (`.live(.sql)`,
# `.live(.ssh, exclusive: true)`, `.fixture(.wordpress)`, see
# Packages/RunletKit/Tests/RunletExecutionTests/LiveFixtures.swift), and only those that
# really conflict wait for each other. `fast` sets RUNLET_TEST_SKIP_LIVE=1, which cancels the
# live-fixture tests.
#
# At most RUNLET_TEST_WIDTH tests run at once (default: two thirds of the logical CPUs). Some
# tests block a Swift-concurrency thread while they wait for a process; with no limit they can
# take every thread and starve the runs that other tests time. The limit goes to Swift Testing
# as SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH (`swift test --num-workers` doesn't reach
# Swift Testing).
#
# A full run holds a lock while the execution tests run (or `swift test`, with arguments), so
# only one full run on this Mac uses the shared fixtures at a time, from whichever worktree; a
# second run waits (RUNLET_TEST_LOCK_WAIT seconds, default 1800) and says whose run it waits for.
#
# The full log is Packages/RunletKit/.build/runlet-tests/<mode>.log. Plain `swift test` still
# works, but runs with no width limit, and skips nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/RunletKit"

MODE="${1:-}"
case "$MODE" in
    fast|full) shift ;;
    *)
        echo "usage: scripts/test.sh fast|full [-v|--verbose] [swift test arguments]" >&2
        exit 2
        ;;
esac
# -v/--verbose right after the mode (#244); anything after it goes to `swift test`.
VERBOSE="${RUNLET_TEST_VERBOSE:-0}"
while (( $# > 0 )) && [[ "$1" == -v || "$1" == --verbose ]]; do
    VERBOSE=1
    shift
done

# Composer autoloaders the driver tests need. Without them dozens of tests fail with
# "Failed opening required …/vendor/autoload.php".
missing=()
for path in Resources/Sandbox/laravel/vendor/autoload.php Tests/Fixtures/composer/vendor/autoload.php \
    Tests/Fixtures/custom-driver/vendor/autoload.php Tests/Fixtures/laravel-app/vendor/autoload.php; do
    [[ -f "$ROOT/$path" ]] || missing+=("$path")
done
if (( ${#missing[@]} > 0 )); then
    echo "The test fixtures aren't set up (missing ${missing[*]})." >&2
    echo "From the repository root, run scripts/build-sandbox.sh, then scripts/setup-fixtures.sh." >&2
    exit 1
fi

if [[ "$MODE" == full ]]; then
    unset_variables=()
    for variable in RUNLET_TEST_MYSQL RUNLET_TEST_PGSQL RUNLET_TEST_REDIS RUNLET_TEST_REDIS_TLS \
        RUNLET_TEST_MONGODB RUNLET_TEST_MONGODB_TLS RUNLET_TEST_MONGODB_RS RUNLET_TEST_TLS; do
        [[ -n "${!variable:-}" ]] || unset_variables+=("$variable")
    done
    if (( ${#unset_variables[@]} > 0 )); then
        echo "warning: ${unset_variables[*]} not set: those live database tests will skip." >&2
        echo "         Run scripts/setup-fixtures.sh databases and export the lines it prints." >&2
    fi
    if command -v docker >/dev/null 2>&1; then
        if ! docker ps -q --filter label=com.docker.compose.project=runlet-fixtures 2>/dev/null | grep -q .; then
            echo "warning: no runlet-fixtures containers are running: Docker tests will skip or fail." >&2
            echo "         Run scripts/setup-fixtures.sh docker (and databases)." >&2
        fi
    fi
    export RUNLET_TEST_SKIP_LIVE=0
    # One full run at a time on this Mac: the fixture containers and databases are shared by every
    # worktree, and the trait locks only work inside one test process. The lock file sits in the
    # repository's common .git folder, which all worktrees share (like the fixtures' TLS files,
    # #186); lockf(1) holds it only while a test target runs, and the system drops it when the
    # process ends, so a killed run never leaves it behind.
    if [[ -z "${RUNLET_TEST_LOCK:-}" ]]; then
        common="$(cd "$ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)"
        if [[ -n "$common" ]]; then
            RUNLET_TEST_LOCK="$(cd "$ROOT" && cd "$common" && pwd)/runlet-fixtures/tests.lock"
        else
            RUNLET_TEST_LOCK="$PACKAGE/.build/runlet-tests/tests.lock"
        fi
    fi
    mkdir -p "$(dirname "$RUNLET_TEST_LOCK")"
else
    export RUNLET_TEST_SKIP_LIVE=1
fi
# How long a full run waits for another one to finish before giving up.
LOCK_WAIT="${RUNLET_TEST_LOCK_WAIT:-1800}"

# Tests never use the developer's SSH agent.
export SSH_AUTH_SOCK=
CPUS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
WIDTH="${RUNLET_TEST_WIDTH:-$(( CPUS * 2 / 3 > 4 ? CPUS * 2 / 3 : 4 ))}"
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$WIDTH"

LOGS="$PACKAGE/.build/runlet-tests"
mkdir -p "$LOGS"
LOG="$LOGS/$MODE.log"
: > "$LOG"
cd "$PACKAGE"

now() { perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }
elapsed() { perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$1" "$2"; }

echo "RunletKit tests, $MODE: up to $WIDTH at once$([[ "$MODE" == fast ]] && echo ", live-fixture tests skipped")$([[ "$VERBOSE" == 1 ]] && echo ", listing each test")"
start="$(now)"
build_start="$start"
if ! swift build --build-tests >>"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -20 >&2
    echo "The build failed; see $LOG" >&2
    exit 1
fi
build_time="$(elapsed "$build_start" "$(now)")"

summary=()
status=0
# Lines worth showing while the tests run: failures and each target's result.
# With -v, every test and suite as it finishes (not its "started" line, which parallel runs
# interleave): passed and its time, failed, skipped or cancelled and why, known issues.
show() {
    if [[ "$VERBOSE" == 1 ]]; then
        grep --line-buffered -E "(Test|Suite) .*( passed| failed| skipped| was cancelled)|recorded (an|a known) issue|Test run with|^error:|Fatal error|unexpected signal" || true
    else
        grep --line-buffered -E "recorded an issue|failed after|Test run with|^error:|Fatal error|unexpected signal" || true
    fi
}

# run <label> <lock|nolock> <swift test arguments…>: lock takes the fixture lock in a full run.
run() {
    local label="$1" lock="$2"
    shift 2
    local run_start offset
    run_start="$(now)"
    echo "== $label" >>"$LOG"
    offset="$(wc -l <"$LOG")"
    local locked=()
    if [[ "$MODE" == full && "$lock" == lock ]]; then
        if ! /usr/bin/lockf -s -t 0 "$RUNLET_TEST_LOCK" true; then
            echo "Waiting for the fixtures: another full test run is using them ($(cat "$RUNLET_TEST_LOCK.owner" 2>/dev/null || echo "owner unknown"))." | tee -a "$LOG"
        fi
        # The owner line is written once the lock is held, for the next run's message.
        locked=(/usr/bin/lockf -k -t "$LOCK_WAIT" "$RUNLET_TEST_LOCK"
            /bin/sh -c 'printf "%s, pid %s, since %s\n" "$1" "$$" "$(date +%H:%M:%S)" >"$2.owner"; shift 2; exec "$@"'
            sh "$ROOT" "$RUNLET_TEST_LOCK")
    fi
    set +e
    ${locked[@]+"${locked[@]}"} swift test --skip-build "$@" 2>&1 | tee -a "$LOG" | show
    local code="${PIPESTATUS[0]}"
    set -e
    if (( code == 75 )) && (( ${#locked[@]} > 0 )); then
        echo "Gave up after waiting ${LOCK_WAIT}s for another full test run ($(cat "$RUNLET_TEST_LOCK.owner" 2>/dev/null || echo "owner unknown"))." | tee -a "$LOG" >&2
    fi
    local seconds result
    seconds="$(elapsed "$run_start" "$(now)")"
    # One "Test run with …" line per test bundle that ran.
    result="$(tail -n +"$(( offset + 1 ))" "$LOG" | grep -E "Test run with" | sed -E 's/^[^T]*Test run with //' | paste -sd ';' - || true)"
    summary+=("$(printf '%-22s %7ss  %s' "$label" "$seconds" "${result:-no Swift Testing result (exit $code)}")")
    if (( code != 0 )); then status=1; fi
}

if (( $# > 0 )); then
    run "swift test $*" lock "$@"
else
    # Only the execution tests use the shared fixture containers and databases.
    run RunletLanguageTests nolock --filter "^RunletLanguageTests\\."
    run RunletCoreTests nolock --filter "^RunletCoreTests\\."
    run RunletExecutionTests lock --filter "^RunletExecutionTests\\."
fi

echo
echo "Summary ($MODE, width $WIDTH):"
printf '%-22s %7ss\n' "build" "$build_time"
for line in "${summary[@]}"; do echo "$line"; done
printf '%-22s %7ss\n' "total" "$(elapsed "$start" "$(now)")"
if (( status != 0 )); then
    echo "FAILED. The full log: $LOG"
else
    echo "Passed. The full log: $LOG"
fi
exit "$status"
