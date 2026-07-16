#!/bin/zsh
# Run one manifest-backed native/interpreter parity case with its repetitions
# divided across independent prebuilt test-bundle processes.
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2

usage() {
    echo "usage: Scripts/run-focused-parity.sh CASE_ID [--jobs N]" >&2
}

if (( $# < 1 )); then usage; exit 2; fi
case_id="$1"
shift
jobs=${FOCUSED_PARITY_JOBS:-4}
while (( $# > 0 )); do
    case "$1" in
        --jobs)
            if (( $# < 2 )); then usage; exit 2; fi
            jobs="$2"
            shift 2 ;;
        *)
            usage
            exit 2 ;;
    esac
done
if [[ "$jobs" != <-> ]] || (( jobs < 1 )); then
    echo "focused parity jobs must be a positive integer, got '$jobs'" >&2
    exit 2
fi

manifest="$PWD/Tests/ConcurrencyParity/Manifests/parity-cases.json"
case_info=$(/usr/bin/ruby -rjson -e '
  manifest = JSON.parse(File.read(ARGV.fetch(0)))
  runtime = manifest.select { |entry| entry.fetch("mode") == "runtime" }
  matches = runtime.each_index.select { |index| runtime[index].fetch("id") == ARGV.fetch(1) }
  abort "case must identify exactly one runtime fixture" unless matches.length == 1
  index = matches.first
  repetitions = [Integer(runtime[index].fetch("repetitions", 1)), 1].max
  puts [index, runtime.length, repetitions].join("\t")
' "$manifest" "$case_id") || exit 2
IFS=$'\t' read -r shard_index shard_count total_repetitions <<< "$case_info"

if (( jobs > total_repetitions )); then jobs=$total_repetitions; fi
while (( total_repetitions % jobs != 0 )); do jobs=$(( jobs - 1 )); done
integer started=$SECONDS
work_dir=$(mktemp -d)
typeset -a pids active_pids logs

cleanup() {
    if [[ "${FOCUSED_PARITY_KEEP_LOGS:-0}" == 1 ]]; then
        echo "focused parity logs: $work_dir"
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

integer base=$(( total_repetitions / jobs ))
integer worker repetitions worker_pid
for (( worker = 0; worker < jobs; worker++ )); do
    repetitions=$base
    log="$work_dir/worker-$worker.log"
    logs+=("$log")
    env DYNAMIC_SWIFT_PARITY_SHARD_INDEX="$shard_index" \
        DYNAMIC_SWIFT_PARITY_SHARD_COUNT="$shard_count" \
        DYNAMIC_SWIFT_PARITY_FOCUSED_REPETITIONS="$repetitions" \
        Scripts/run-prebuilt-tests.sh --no-parallel \
        --filter 'ConcurrencyParityTests/runtimeFixturesMatchNativeGuarantees' \
        > "$log" 2>&1 &
    worker_pid=$!
    pids+=($worker_pid)
    active_pids+=($worker_pid)
done

integer red=0 worker_status
for (( worker = 1; worker <= ${#pids}; worker++ )); do
    worker_status=0
    wait "${pids[$worker]}" || worker_status=$?
    active_pids=(${active_pids:#${pids[$worker]}})
    if (( worker_status != 0 )); then
        echo "focused parity worker $worker/$jobs exited with status $worker_status" >&2
        tail -80 "${logs[$worker]}" >&2
        red=1
    fi
done
if (( red != 0 )); then exit 1; fi

summary=$(/usr/bin/ruby Scripts/validate-focused-parity-summaries.rb \
    "$manifest" "$case_id" "${logs[@]}") || {
        for log in "${logs[@]}"; do tail -80 "$log" >&2; done
        exit 1
    }
echo "$summary"
echo "focused parity completed in $(( SECONDS - started ))s ($jobs workers)"
