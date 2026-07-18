#!/bin/zsh
# Build the dedicated Thread Sanitizer cache when requested, then run only the
# checked physical-worker/source-kernel board from its prebuilt test bundle.
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2

usage() {
    echo "usage: Scripts/run-concurrency-tsan.sh [--jobs N] [--skip-build]" >&2
}

jobs=${CONCURRENCY_TSAN_JOBS:-4}
skip_build=0
while (( $# > 0 )); do
    case "$1" in
        --jobs)
            if (( $# < 2 )); then usage; exit 2; fi
            jobs="$2"
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
    echo "TSan jobs must be a positive integer, got '$jobs'" >&2
    exit 2
fi

run_with_deadline() {
    local timeout="$1"
    shift
    /usr/bin/perl -MPOSIX=setsid -e \
        'setsid() >= 0 or die "setsid failed: $!\n"; exec @ARGV or die "exec failed: $!\n"' \
        -- "$@" &
    local pid=$!
    integer deadline=$(( SECONDS + timeout ))
    while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            kill -TERM -- "-$pid" 2>/dev/null || true
            sleep 1
            kill -KILL -- "-$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            echo "TSan command exceeded its ${timeout}s deadline: $*" >&2
            return 124
        fi
        sleep 0.1
    done
    wait "$pid"
}

scratch_path=${CONCURRENCY_TSAN_SCRATCH_PATH:-.build-tsan}
bundle="$scratch_path/debug/DynamicSwiftUIPackageTests.xctest/Contents/MacOS/DynamicSwiftUIPackageTests"
integer started=$SECONDS
if (( skip_build == 0 )); then
    build_log=$(mktemp)
    if ! run_with_deadline 600 \
            swift build --build-tests --scratch-path "$scratch_path" \
            --sanitize thread --jobs "$jobs" >"$build_log" 2>&1; then
        echo "TSan test build failed" >&2
        tail -100 "$build_log" >&2
        rm -f "$build_log"
        exit 1
    fi
    rm -f "$build_log"
    echo "TSan test bundle built in $(( SECONDS - started ))s"
elif [[ ! -f "$bundle" ]]; then
    echo "TSan test bundle is missing under '$scratch_path'" >&2
    exit 2
fi

export TSAN_OPTIONS='halt_on_error=1:exitcode=66'
tsan_runtime=$(xcrun clang \
    --print-file-name=libclang_rt.tsan_osx_dynamic.dylib) || exit $?
if [[ ! -f "$tsan_runtime" ]]; then
    echo "could not locate the active toolchain's TSan runtime" >&2
    exit 2
fi
native_dir=$(mktemp -d)
trap 'rm -rf "$native_dir"' EXIT
xcrun swiftc \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -sanitize=thread \
    -parse-as-library \
    Tests/RuntimeIsolation/NativeDetachedOverlap.swift \
    -o "$native_dir/overlap" || exit $?
observation=$(run_with_deadline 60 "$native_dir/overlap" 20) || exit $?
if [[ "$observation" != 'overlap:2' ]]; then
    echo "native TSan stress returned '$observation'" >&2
    exit 1
fi
echo "native TSan overlap: 20/20 exact"

inserted_libraries="$tsan_runtime"
if [[ -n "${DYLD_INSERT_LIBRARIES:-}" ]]; then
    inserted_libraries="$inserted_libraries:$DYLD_INSERT_LIBRARIES"
fi
test_log=$(mktemp)
test_status=0
run_with_deadline 60 env \
    PREBUILT_TEST_DYLD_INSERT_LIBRARIES="$inserted_libraries" \
    PREBUILT_TEST_SCRATCH_PATH="$scratch_path" \
    Scripts/run-prebuilt-tests.sh \
        --parallel \
        --num-workers "$jobs" \
        --filter \
        '(RuntimePhysicalWorkerDriverTests|RuntimeParallelSourceKernelTests)' \
        >"$test_log" 2>&1 || test_status=$?
if (( test_status != 0 )) \
    || rg -q 'Interceptors are not working|interceptors not installed' "$test_log"; then
    echo "prebuilt TSan test board failed" >&2
    tail -100 "$test_log" >&2
    rm -f "$test_log"
    exit 1
fi
cat "$test_log"
rm -f "$test_log"
echo "concurrency TSan board completed in $(( SECONDS - started ))s"
