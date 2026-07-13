#!/bin/zsh
# The closing gate: one build followed by bounded process-level test and eval
# shards. See Docs/ParallelVerification.md before changing worker allocation.
#
# Usage: Scripts/gate.sh
# Tuning: GATE_JOBS, GATE_TEST_WORKERS, GATE_PARITY_TEST_WORKERS,
#         GATE_EVAL_WORKERS, GATE_LIVE_WORKERS, GATE_KEEP_LOGS
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2
integer gate_started=$SECONDS

is_positive_integer() {
    [[ "$1" == <-> ]] && (( $1 > 0 ))
}

worker_value() {
    local name="$1"
    local fallback="$2"
    local value="${(P)name:-$fallback}"
    if ! is_positive_integer "$value"; then
        echo "$name must be a positive integer, got '$value'" >&2
        return 2
    fi
    echo "$value"
}

detected_jobs=$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
if ! is_positive_integer "$detected_jobs"; then detected_jobs=4; fi
# Eight is an intentionally conservative default budget. Check processes keep
# independent interpreter/bridge heaps, so logical CPU count alone is not a
# safe memory limit. Every allocation remains explicitly overridable.
if (( detected_jobs > 8 )); then detected_jobs=8; fi
if ! gate_jobs=$(worker_value GATE_JOBS "$detected_jobs"); then exit 2; fi

default_parity_workers=$(( gate_jobs / 2 ))
if (( default_parity_workers < 1 )); then default_parity_workers=1; fi
default_test_workers=$(( gate_jobs - default_parity_workers ))
if (( default_test_workers < 1 )); then default_test_workers=1; fi
default_eval_workers=$(( gate_jobs / 2 ))
if (( default_eval_workers < 1 )); then default_eval_workers=1; fi
default_live_workers=$gate_jobs
if (( default_live_workers > 4 )); then default_live_workers=4; fi

if ! test_workers=$(worker_value GATE_TEST_WORKERS "$default_test_workers"); then exit 2; fi
if ! parity_test_workers=$(worker_value GATE_PARITY_TEST_WORKERS "$default_parity_workers"); then exit 2; fi
if ! eval_workers=$(worker_value GATE_EVAL_WORKERS "$default_eval_workers"); then exit 2; fi
if ! live_workers=$(worker_value GATE_LIVE_WORKERS "$default_live_workers"); then exit 2; fi

out=$(mktemp -d)
typeset -a active_pids
terminate_tree() {
    local parent="$1"
    local child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        terminate_tree "$child"
    done
    kill "$parent" 2>/dev/null || true
}
cleanup() {
    local pid
    for pid in $active_pids; do
        terminate_tree "$pid"
    done
    if [[ "${GATE_KEEP_LOGS:-0}" == "1" ]]; then
        echo "gate logs kept at $out"
    else
        rm -rf "$out"
    fi
}
remove_active_pid() {
    local completed="$1"
    local pid
    local -a remaining
    for pid in $active_pids; do
        if [[ "$pid" != "$completed" ]]; then remaining+=($pid); fi
    done
    active_pids=($remaining)
}
trap cleanup EXIT

echo "── build (once) ──"
integer stage_started=$SECONDS
if ! swift build --build-tests > "$out/build.log" 2>&1; then
    tail -80 "$out/build.log"
    echo "BUILD RED"
    exit 1
fi
grep -E "warning: .*deprecat" "$out/build.log" | head -5 || true
echo "build completed in $(( SECONDS - stage_started ))s"

test_count=$(swift test list --skip-build 2>/dev/null \
    | awk 'NF { count++ } END { print count + 0 }')
if ! is_positive_integer "$test_count"; then
    echo "could not count the prebuilt tests" >&2
    exit 1
fi
runtime_resource=$(swift -print-target-info \
    | plutil -extract paths.runtimeResourcePath raw -o - - 2>/dev/null)
test_helper="${runtime_resource%/lib/swift}/libexec/swift/pm/swiftpm-testing-helper"
test_bundle="$PWD/.build/debug/DynamicSwiftUIPackageTests.xctest/Contents/MacOS/DynamicSwiftUIPackageTests"
test_library_path="$runtime_resource/macosx/testing:$runtime_resource/macosx"
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    test_library_path="$test_library_path:$DYLD_LIBRARY_PATH"
fi
if [[ ! -x "$test_helper" || ! -f "$test_bundle" ]]; then
    echo "could not locate the active toolchain's prebuilt test runner" >&2
    exit 1
fi

echo "── tests ($test_workers Swift workers + $parity_test_workers parity shards) ──"
stage_started=$SECONDS
typeset -a test_pids test_names test_logs

env DYLD_LIBRARY_PATH="$test_library_path" \
    "$test_helper" --test-bundle-path "$test_bundle" --skip-build \
    --parallel --num-workers "$test_workers" \
    --skip 'ConcurrencyParityTests/runtimeFixturesMatchNativeGuarantees' \
    "$test_bundle" --testing-library swift-testing \
    > "$out/tests-main.log" 2>&1 &
main_test_pid=$!
test_pids+=($main_test_pid)
test_names+=("main test suite")
test_logs+=("$out/tests-main.log")
active_pids+=($main_test_pid)

integer shard
for (( shard = 0; shard < parity_test_workers; shard++ )); do
    log="$out/tests-parity-$shard.log"
    env DYNAMIC_SWIFT_PARITY_SHARD_INDEX="$shard" \
        DYNAMIC_SWIFT_PARITY_SHARD_COUNT="$parity_test_workers" \
        DYLD_LIBRARY_PATH="$test_library_path" \
        "$test_helper" --test-bundle-path "$test_bundle" --skip-build --no-parallel \
        --filter 'ConcurrencyParityTests/runtimeFixturesMatchNativeGuarantees' \
        "$test_bundle" --testing-library swift-testing \
        > "$log" 2>&1 &
    parity_test_pid=$!
    test_pids+=($parity_test_pid)
    test_names+=("concurrency parity shard $(( shard + 1 ))/$parity_test_workers")
    test_logs+=("$log")
    active_pids+=($parity_test_pid)
done

test_red=0
integer job
for (( job = 1; job <= ${#test_pids}; job++ )); do
    if ! wait "${test_pids[$job]}"; then
        echo "${test_names[$job]} RED" >&2
        tail -60 "${test_logs[$job]}" >&2
        test_red=1
    fi
    remove_active_pid "${test_pids[$job]}"
done
echo "tests completed in $(( SECONDS - stage_started ))s"

if (( test_red == 0 )); then
    echo "Test run with $test_count tests passed ($parity_test_workers process shards)" > "$out/suite"
else
    echo "parallel test workers failed" > "$out/suite"
fi

echo "── corpus + API parity ($eval_workers workers each) ──"
stage_started=$SECONDS
env SWIFT_DETERMINISTIC_HASHING=1 \
    .build/debug/ProjectCheck --all --jobs "$eval_workers" > "$out/corpus.log" 2>&1 &
corpus_pid=$!
.build/debug/ParityCheck --jobs "$eval_workers" > "$out/parity.log" 2>&1 &
parity_pid=$!
active_pids=($corpus_pid $parity_pid)

corpus_status=0
parity_status=0
wait "$corpus_pid" || corpus_status=$?
remove_active_pid "$corpus_pid"
wait "$parity_pid" || parity_status=$?
remove_active_pid "$parity_pid"
echo "corpus + API parity completed in $(( SECONDS - stage_started ))s"

grep "═══" "$out/corpus.log" | tail -1 > "$out/corpus" || true
grep "═══" "$out/parity.log" | tail -1 > "$out/parity" || true
if (( corpus_status != 0 )); then
    echo "ProjectCheck RED" >&2
    tail -60 "$out/corpus.log" >&2
fi
if (( parity_status != 0 )); then
    echo "ParityCheck RED" >&2
    tail -60 "$out/parity.log" >&2
fi

# Live scenarios allocate the deepest render graphs. They get process-level
# parallelism, but remain isolated from the corpus stage to cap peak memory.
echo "── live ($live_workers memory-isolated workers) ──"
stage_started=$SECONDS
live_status=0
env SWIFT_DETERMINISTIC_HASHING=1 \
    .build/debug/LiveCheck --jobs "$live_workers" > "$out/live.log" 2>&1 &
live_pid=$!
active_pids=($live_pid)
wait "$live_pid" || live_status=$?
remove_active_pid "$live_pid"
grep "═══" "$out/live.log" | tail -1 > "$out/live" || true
if (( live_status != 0 )); then
    echo "LiveCheck RED" >&2
    tail -60 "$out/live.log" >&2
fi
echo "live completed in $(( SECONDS - stage_started ))s"

red=$test_red
for board in suite corpus live parity; do
    line=$(cat "$out/$board" 2>/dev/null)
    echo "$board: $line"
    case "$board:$line" in
        suite:*" tests passed"*) ;;
        corpus:*"projects pass"*)
            # Ledger floor: Widgets + Mythic are documented native-real
            # failures. 678/680 is the baseline and only ratchets upward.
            passed=$(echo "$line" | sed -E 's/.*═══ ([0-9]+)\/680.*/\1/')
            if ! is_positive_integer "$passed" || (( passed < 678 )); then red=1; fi ;;
        live:*"5/5 live-data scenarios pass"*) ;;
        parity:*"0 diverge / 0 interp-error"*) ;;
        *) red=1 ;;
    esac
done
if (( corpus_status != 0 || parity_status != 0 || live_status != 0 )); then red=1; fi
if (( red != 0 )); then echo "GATE RED"; exit 1; fi
echo "GATE GREEN in $(( SECONDS - gate_started ))s"
