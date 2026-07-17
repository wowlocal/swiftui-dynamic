#!/bin/zsh
# Build once, then run one focused concurrency slice through independent
# prebuilt-test processes. Avoid concurrent `swift test` commands: SwiftPM
# serializes them on the shared .build lock even when --skip-build is passed.
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2

usage() {
    echo "usage: Scripts/run-concurrency-iteration.sh CASE_ID TEST_FILTER [--jobs N] [--methodology-filter REGEX] [--skip-build]" >&2
}

if (( $# < 2 )); then usage; exit 2; fi
case_id="$1"
test_filter="$2"
shift 2
jobs=${FOCUSED_PARITY_JOBS:-4}
methodology_filter=${CONCURRENCY_METHODOLOGY_FILTER:-ConcurrencyMethodologyTests}
skip_build=0
while (( $# > 0 )); do
    case "$1" in
        --jobs)
            if (( $# < 2 )); then usage; exit 2; fi
            jobs="$2"
            shift 2 ;;
        --methodology-filter)
            if (( $# < 2 )); then usage; exit 2; fi
            methodology_filter="$2"
            shift 2 ;;
        --skip-build)
            skip_build=1
            shift ;;
        *)
            usage
            exit 2 ;;
    esac
done
if [[ "$jobs" != <-> ]] || (( jobs < 1 )); then
    echo "iteration jobs must be a positive integer, got '$jobs'" >&2
    exit 2
fi
if [[ -z "$methodology_filter" ]]; then
    echo "methodology filter must not be empty" >&2
    exit 2
fi

integer started=$SECONDS
if (( skip_build == 0 )); then
    swift build --build-tests || exit $?
fi

work_dir=$(mktemp -d)
typeset -a labels logs pids active_pids

cleanup() {
    if [[ "${CONCURRENCY_ITERATION_KEEP_LOGS:-0}" == 1 ]]; then
        echo "concurrency iteration logs: $work_dir"
    else
        rm -rf "$work_dir"
    fi
}
terminate_workers() {
    local pid
    for pid in $active_pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in $active_pids; do
        wait "$pid" 2>/dev/null || true
    done
    active_pids=()
}
on_signal() {
    trap - HUP INT TERM
    terminate_workers
    exit 130
}
on_exit() {
    terminate_workers
    cleanup
}
trap on_exit EXIT
trap on_signal HUP INT TERM

launch() {
    local label="$1"
    local log="$2"
    shift 2
    labels+=("$label")
    logs+=("$log")
    "$@" > "$log" 2>&1 &
    local pid=$!
    pids+=($pid)
    active_pids+=($pid)
}

launch "targeted tests" "$work_dir/targeted.log" \
    Scripts/run-prebuilt-tests.sh --filter "$test_filter"
launch "methodology" "$work_dir/methodology.log" \
    Scripts/run-prebuilt-tests.sh --no-parallel \
        --filter "$methodology_filter"
launch "focused parity" "$work_dir/parity.log" \
    Scripts/run-focused-parity.sh "$case_id" --jobs "$jobs"

integer failed=0 index worker_status
for (( index = 1; index <= ${#pids}; index++ )); do
    worker_status=0
    wait "${pids[$index]}" || worker_status=$?
    active_pids=(${active_pids:#${pids[$index]}})
    if (( worker_status != 0 )); then
        echo "${labels[$index]} failed with status $worker_status" >&2
        tail -100 "${logs[$index]}" >&2
        failed=1
    fi
done
for index in 1 2; do
    if rg -q 'Test run with 0 tests' "${logs[$index]}"; then
        echo "${labels[$index]} matched no tests" >&2
        tail -20 "${logs[$index]}" >&2
        failed=1
    fi
done
if (( failed != 0 )); then exit 1; fi

for (( index = 1; index <= ${#logs}; index++ )); do
    echo "${labels[$index]}:"
    tail -5 "${logs[$index]}"
done
echo "concurrency iteration completed in $(( SECONDS - started ))s"
