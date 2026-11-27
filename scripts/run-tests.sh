#!/bin/bash
# Runs `swift test` and decides for itself whether the run passed, rather
# than taking the test process's exit status on its word: a run once
# ended early, without a summary, and exited 0 with failures printed and
# tests never run (code-review-notes.md, F2).
#
# A run passes only when the log holds Swift Testing's summary saying it
# passed, at least MIN_TESTS tests ran, and every suite in REQUIRED_SUITES
# finished without being skipped. A run in which no test finishes for
# STALL_SECONDS is taken for a hang: every test process's threads are
# sampled and its tasks listed before it is stopped (F4), so the hang can
# be diagnosed rather than only rerun. Only the processes this run started
# are sampled and stopped. A run with a test that legitimately takes long
# (a benchmark) wants a larger STALL_SECONDS. Everything is kept in LOG_DIR.
#
# Usage: scripts/run-tests.sh [swift test arguments…]
#   MIN_TESTS=2700 REQUIRED_SUITES="ProjectStoreTests,LoopBarInteractionTests" \
#   STALL_SECONDS=90 LOG_DIR=build/test-logs UI_EVENTS=1 scripts/run-tests.sh
# Without arguments it runs the suite as CI does, eight tests at a time.
set -u

cd "$(dirname "$0")/.."
min_tests="${MIN_TESTS:-1}"
required="${REQUIRED_SUITES:-}"
stall="${STALL_SECONDS:-120}"
log_dir="${LOG_DIR:-build/test-logs}"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
log="$log_dir/run-$stamp.log"
clean="$log_dir/run-$stamp.txt"

if [ "$#" -eq 0 ]; then
    set -- --experimental-maximum-parallelization-width 8
fi

echo "run-tests: swift test $* (log: $log)"
swift test "$@" > "$log" 2>&1 &
runner=$!

# Every process this run started, below its `swift test`: only these are
# sampled and stopped, never another session's or worktree's test run,
# which a match by name (`pkill -f swiftpm-testing-helper`) would take too.
descendants() {
    local pid
    for pid in $(pgrep -P "$1"); do
        echo "$pid"
        descendants "$pid"
    done
}

# The watchdog: progress is a test or suite finishing.
finished() { grep -cE '(Test|Suite) .* (passed|failed|skipped)' "$log" 2>/dev/null || echo 0; }
last_count=-1
quiet=0
hung=0
while kill -0 "$runner" 2>/dev/null; do
    sleep 5
    count=$(finished)
    if [ "$count" = "$last_count" ] && [ "$count" -gt 0 ]; then
        quiet=$((quiet + 5))
    else
        quiet=0
        last_count=$count
    fi
    if [ "$quiet" -ge "$stall" ]; then
        hung=1
        echo "run-tests: no test finished for ${stall} s; sampling before stopping it"
        own=$(descendants "$runner")
        for pid in $own; do
            ps -o pid,ppid,etime,%cpu,rss,state,command -p "$pid" >> "$log_dir/hang-$stamp-processes.txt"
            case "$(ps -o command= -p "$pid")" in
                *swiftpm-testing-helper*|*AnimationMeetsVideoTests*)
                    sample "$pid" 5 -file "$log_dir/hang-$stamp-$pid.sample.txt" >/dev/null 2>&1 ;;
            esac
        done
        # The tests started and never finished, for whoever reads the hang.
        sed 's/\x1b\[[0-9;]*m//g' "$log" > "$clean"
        comm -23 \
            <(grep -oE 'Test [A-Za-z0-9_]+\(\) started' "$clean" | awk '{print $2}' | sort -u) \
            <(grep -oE 'Test [A-Za-z0-9_]+\(\) (passed|failed|skipped)' "$clean" | awk '{print $2}' | sort -u) \
            > "$log_dir/hang-$stamp-unfinished.txt"
        # Deepest first, then the run itself; nothing outside this run.
        for pid in $(printf '%s\n' $own | sort -rn); do kill "$pid" 2>/dev/null; done
        kill "$runner" 2>/dev/null
        break
    fi
done
wait "$runner" 2>/dev/null
status=$?
sed 's/\x1b\[[0-9;]*m//g' "$log" > "$clean"

failures=()
summary="$(grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$clean" | tail -1)"
if [ "$hung" -eq 1 ]; then
    failures+=("the run hung; samples and unfinished tests are in $log_dir/hang-$stamp-*")
fi
if [ -z "$summary" ]; then
    failures+=("no summary: the test process ended without reporting (exit status $status)")
else
    tests="$(printf '%s' "$summary" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/')"
    case "$summary" in *" passed "*) ;; *) failures+=("the run failed: $summary");; esac
    if [ "$tests" -lt "$min_tests" ]; then
        failures+=("only $tests tests ran, fewer than MIN_TESTS=$min_tests")
    fi
fi
if [ -n "$required" ]; then
    IFS=',' read -ra suites <<< "$required"
    for suite in "${suites[@]}"; do
        if ! grep -qE "Suite $suite (passed|failed) after" "$clean"; then
            failures+=("required suite $suite didn't run (skipped or missing)")
        fi
    done
fi
grep -E 'recorded an issue' "$clean" | head -20

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'run-tests: FAILED\n' >&2
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
fi
echo "run-tests: passed — $summary"
