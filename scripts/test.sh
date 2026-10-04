#!/usr/bin/env bash
# Runs the RunletKit package tests in parallel (#242).
#   scripts/test.sh fast             # everything except live-fixture tests (Docker, SSH, fixture databases)
#   scripts/test.sh full             # everything; needs the fixtures (docs/validation.md)
#   scripts/test.sh full --filter Mongo   # extra arguments go to `swift test`, in one invocation
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
# The full log is Packages/RunletKit/.build/runlet-tests/<mode>.log. Plain `swift test` still
# works, but runs with no width limit, and skips nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Packages/RunletKit"

MODE="${1:-}"
case "$MODE" in
    fast|full) shift ;;
    *)
        echo "usage: scripts/test.sh fast|full [swift test arguments]" >&2
        exit 2
        ;;
esac

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
else
    export RUNLET_TEST_SKIP_LIVE=1
fi

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

echo "RunletKit tests, $MODE: up to $WIDTH at once$([[ "$MODE" == fast ]] && echo ", live-fixture tests skipped")"
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
show() { grep --line-buffered -E "recorded an issue|failed after|Test run with|^error:|Fatal error|crashed" || true; }

run() {
    local label="$1"
    shift
    local run_start offset
    run_start="$(now)"
    echo "== $label" >>"$LOG"
    offset="$(wc -l <"$LOG")"
    set +e
    swift test --skip-build "$@" 2>&1 | tee -a "$LOG" | show
    local code="${PIPESTATUS[0]}"
    set -e
    local seconds result
    seconds="$(elapsed "$run_start" "$(now)")"
    # One "Test run with …" line per test bundle that ran.
    result="$(tail -n +"$(( offset + 1 ))" "$LOG" | grep -E "Test run with" | sed -E 's/^[^T]*Test run with //' | paste -sd ';' - || true)"
    summary+=("$(printf '%-22s %7ss  %s' "$label" "$seconds" "${result:-no Swift Testing result (exit $code)}")")
    if (( code != 0 )); then status=1; fi
}

if (( $# > 0 )); then
    run "swift test $*" "$@"
else
    for target in RunletLanguageTests RunletCoreTests RunletExecutionTests; do
        run "$target" --filter "^$target\\."
    done
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
