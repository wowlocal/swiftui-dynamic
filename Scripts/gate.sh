#!/bin/zsh
# The closing gate: one build followed by bounded process-level test and eval
# shards. See Docs/ParallelVerification.md before changing worker allocation.
#
# Usage: Scripts/gate.sh
# Tuning: GATE_JOBS, GATE_TEST_WORKERS, GATE_PARITY_TEST_WORKERS,
#         GATE_EVAL_WORKERS, GATE_LIVE_WORKERS, GATE_*_TIMEOUT_SECONDS,
#         GATE_TERMINATION_GRACE_SECONDS, GATE_KEEP_LOGS, GATE_RECEIPT_PATH,
#         GATE_CONTINUE_AFTER_FAILURE, GATE_LOCK_DIRECTORY,
#         GATE_CLAIMS_PATH, GATE_INTEGRATION_BASE,
#         GATE_EXPECTED_TOOLCHAIN_FINGERPRINT,
#         GATE_CAPABILITY_{INVENTORY,STATUS}_INPUT_PATH (negative controls)
set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2
integer gate_started=$SECONDS
gate_started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir \
    2>/dev/null || true)
if [[ -z "$git_common_dir" ]]; then git_common_dir="$PWD/.git"; fi
gate_lock_directory="${GATE_LOCK_DIRECTORY:-$git_common_dir/dynamic-swiftui-closing-gate.lock}"
typeset gate_lock_owned=false gate_lock_conflict=""

is_positive_integer() {
    [[ "$1" == <-> ]] && (( $1 > 0 ))
}

positive_integer_value() {
    local name="$1"
    local fallback="$2"
    local value="${(P)name:-$fallback}"
    if ! is_positive_integer "$value"; then
        echo "$name must be a positive integer, got '$value'" >&2
        return 2
    fi
    echo "$value"
}

write_gate_lock_owner() {
    print -r -- "$$" > "$gate_lock_directory/pid" \
        && print -r -- "$PWD" > "$gate_lock_directory/worktree" \
        && print -r -- "$gate_started_at" > "$gate_lock_directory/started-at"
}

acquire_gate_lock() {
    local owner_pid owner_worktree owner_started stale_lock
    if mkdir "$gate_lock_directory" 2>/dev/null; then
        gate_lock_owned=true
        if write_gate_lock_owner; then return 0; fi
        gate_lock_conflict="could not write owner metadata at $gate_lock_directory"
        rm -rf "$gate_lock_directory"
        gate_lock_owned=false
        return 2
    fi

    owner_pid=$(/bin/cat "$gate_lock_directory/pid" 2>/dev/null || true)
    owner_worktree=$(/bin/cat "$gate_lock_directory/worktree" 2>/dev/null \
        || echo unknown)
    owner_started=$(/bin/cat "$gate_lock_directory/started-at" 2>/dev/null \
        || echo unknown)
    if [[ "$owner_pid" == <-> ]] && kill -0 "$owner_pid" 2>/dev/null; then
        gate_lock_conflict="pid=$owner_pid worktree=$owner_worktree started=$owner_started"
        return 1
    fi
    if [[ "$owner_pid" != <-> ]]; then
        gate_lock_conflict="owner metadata is incomplete at $gate_lock_directory"
        return 1
    fi

    stale_lock="$gate_lock_directory.stale.$$"
    if ! mv "$gate_lock_directory" "$stale_lock" 2>/dev/null; then
        gate_lock_conflict="lock ownership changed while inspecting $gate_lock_directory"
        return 1
    fi
    rm -rf "$stale_lock"
    if ! mkdir "$gate_lock_directory" 2>/dev/null; then
        gate_lock_conflict="another gate acquired $gate_lock_directory"
        return 1
    fi
    gate_lock_owned=true
    if write_gate_lock_owner; then return 0; fi
    gate_lock_conflict="could not write owner metadata at $gate_lock_directory"
    rm -rf "$gate_lock_directory"
    gate_lock_owned=false
    return 2
}

release_gate_lock() {
    local owner_pid
    if [[ "$gate_lock_owned" != true ]]; then return; fi
    owner_pid=$(/bin/cat "$gate_lock_directory/pid" 2>/dev/null || true)
    if [[ "$owner_pid" == "$$" ]]; then rm -rf "$gate_lock_directory"; fi
    gate_lock_owned=false
}

compute_worktree_fingerprint() {
    {
        git --no-pager diff --no-ext-diff --no-textconv --binary HEAD \
            2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null \
            | while IFS= read -r file; do
                echo "$file"
                shasum -a 256 "$file" 2>/dev/null || true
            done
    } | shasum -a 256 | awk '{print $1}'
}

detected_jobs=$(sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
if ! is_positive_integer "$detected_jobs"; then detected_jobs=4; fi
# Eight is an intentionally conservative default budget. Check processes keep
# independent interpreter/bridge heaps, so logical CPU count alone is not a
# safe memory limit. Every allocation remains explicitly overridable.
if (( detected_jobs > 8 )); then detected_jobs=8; fi
if ! gate_jobs=$(positive_integer_value GATE_JOBS "$detected_jobs"); then exit 2; fi

# Runtime parity now owns thousands of fresh-process repetitions, while the
# ordinary suite finishes much earlier. Give the long lane three quarters of
# the fixed test-stage budget. Both required pools retain a one-worker floor;
# for budgets of two or more their sum remains exactly gate_jobs.
default_test_workers=$(( gate_jobs / 4 ))
if (( default_test_workers < 1 )); then default_test_workers=1; fi
default_parity_workers=$(( gate_jobs - default_test_workers ))
if (( default_parity_workers < 1 )); then default_parity_workers=1; fi
default_eval_workers=$(( gate_jobs / 2 ))
if (( default_eval_workers < 1 )); then default_eval_workers=1; fi
default_live_workers=$gate_jobs
if (( default_live_workers > 4 )); then default_live_workers=4; fi

if ! test_workers=$(positive_integer_value GATE_TEST_WORKERS "$default_test_workers"); then exit 2; fi
if ! parity_test_workers=$(positive_integer_value GATE_PARITY_TEST_WORKERS "$default_parity_workers"); then exit 2; fi
if ! eval_workers=$(positive_integer_value GATE_EVAL_WORKERS "$default_eval_workers"); then exit 2; fi
if ! live_workers=$(positive_integer_value GATE_LIVE_WORKERS "$default_live_workers"); then exit 2; fi

# Deadlines are deliberately generous relative to the reference timings, but
# finite on every machine. A local or CI run can tighten/relax one stage without
# weakening the others.
if ! build_timeout=$(positive_integer_value GATE_BUILD_TIMEOUT_SECONDS 1800); then exit 2; fi
if ! test_timeout=$(positive_integer_value GATE_TEST_TIMEOUT_SECONDS 1800); then exit 2; fi
if ! eval_timeout=$(positive_integer_value GATE_EVAL_TIMEOUT_SECONDS 1800); then exit 2; fi
if ! live_timeout=$(positive_integer_value GATE_LIVE_TIMEOUT_SECONDS 1800); then exit 2; fi
# The R2 stage is the one deadline that GROWS with the board, so a fixed number
# here turns admitting a screen into a gate RED that says "timeout" and names no
# screen. `Scripts/icecubes-r2.sh` captures every screen FOUR times — twin,
# twin-repeat, interpreted, interpreted-repeat — strictly serially, because
# parallel capture windows perturb each other through the window server. Measured
# 2026-08-08 on the 11-screen board: ~43s per capture, so ~172s per screen. The
# per-screen budget below is that with a margin for a loaded machine, and the
# fixed part covers the two product builds plus scoring. Admitting screen 12
# raises the deadline by itself.
integer r2_screen_count=$(
    sed -n '/^R2_SCREENS=(/,/)/p' Scripts/icecubes-r2.sh \
        | tr '\n' ' ' | sed 's/.*R2_SCREENS=(//; s/).*//' \
        | tr -s ' ' '\n' | grep -cE '^[a-z][a-z-]*$' || true)
# A miscount is silent and one-directional — it can only shorten the deadline —
# so require it to agree with the floor table the board itself scores against.
integer r2_floor_count=$(
    sed -n '/^R2_FLOORS=(/,/^)/p' Scripts/icecubes-r2.sh \
        | grep -cE '^ *[a-z][a-z-]+ [0-9]+ *$' || true)
if (( r2_screen_count != r2_floor_count )); then
    echo "R2 screen count $r2_screen_count disagrees with floor count" \
        "$r2_floor_count in Scripts/icecubes-r2.sh" >&2
    exit 2
fi
if (( r2_screen_count < 1 )); then
    echo "could not read R2_SCREENS from Scripts/icecubes-r2.sh" >&2
    exit 2
fi
integer r2_timeout_default=$(( 900 + r2_screen_count * 240 ))
if ! r2_timeout=$(positive_integer_value GATE_R2_TIMEOUT_SECONDS "$r2_timeout_default"); then exit 2; fi
# The north-star rung ladder holds itself to a three-minute contract; the
# deadline is that contract with room for a loaded gate machine.
if ! icecubes_timeout=$(positive_integer_value \
    GATE_ICECUBES_TIMEOUT_SECONDS 900); then exit 2; fi
if ! child_timeout=$(positive_integer_value GATE_CHILD_TIMEOUT_SECONDS 1500); then exit 2; fi
if ! termination_grace=$(positive_integer_value GATE_TERMINATION_GRACE_SECONDS 5); then exit 2; fi
continue_after_failure="${GATE_CONTINUE_AFTER_FAILURE:-0}"
if [[ "$continue_after_failure" != 0 && "$continue_after_failure" != 1 ]]; then
    echo "GATE_CONTINUE_AFTER_FAILURE must be 0 or 1, got '$continue_after_failure'" >&2
    exit 2
fi

out=$(mktemp -d)
typeset -a active_pids
receipt_path="${GATE_RECEIPT_PATH:-$PWD/.build/gate-receipt.json}"
typeset build_stage_status="not-run" test_stage_status="not-run"
typeset eval_stage_status="not-run" live_stage_status="not-run"
typeset r2_stage_status="not-run" icecubes_stage_status="not-run"
integer build_stage_seconds=0 test_stage_seconds=0
integer eval_stage_seconds=0 live_stage_seconds=0
integer r2_stage_seconds=0 icecubes_stage_seconds=0
typeset suite_summary="" corpus_summary="" parity_summary="" live_summary=""
typeset r2_summary="" icecubes_summary=""
typeset parity_shard_validation="not-run"
typeset parity_shard_receipt_json='{"version":1,"status":"not-run"}'
typeset close_policy_json='{"version":1,"status":"not-run","errors":[]}'
typeset anti_drift_json='{"version":1,"status":"not-run","violations":-1}'
typeset gate_diagnostics="" test_worker_statuses=""
typeset current_stage="initialization"
typeset source_end_captured=false source_drift_detected=false
typeset source_drift_reported=false git_commit_at_end=""
typeset git_dirty_at_end=false worktree_fingerprint_at_end=""
integer test_count=0
integer build_status=-1 test_discovery_status=-1
integer corpus_status=-1 parity_status=-1 live_status=-1
integer close_policy_status=-1 r2_status=-1 icecubes_status=-1

claims_path="${GATE_CLAIMS_PATH:-${git_common_dir:h}/.claude/claims.md}"
integration_base="${GATE_INTEGRATION_BASE:-origin/main}"

git_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
git_status_at_start=$(git status --porcelain --untracked-files=normal 2>/dev/null || true)
if [[ -n "$git_status_at_start" ]]; then git_dirty_at_start=true; else git_dirty_at_start=false; fi
worktree_fingerprint=$(compute_worktree_fingerprint)
manifest_path="$PWD/Tests/ConcurrencyParity/Manifests/parity-cases.json"
manifest_sha256=$(shasum -a 256 "$manifest_path" 2>/dev/null | awk '{print $1}')
manifest_case_count=$(/usr/bin/ruby -rjson -e \
    'puts JSON.parse(File.read(ARGV.fetch(0))).length' "$manifest_path" 2>/dev/null \
    || echo 0)
manifest_runtime_case_count=$(/usr/bin/ruby -rjson -e \
    'puts JSON.parse(File.read(ARGV.fetch(0))).count { |item| item["mode"] == "runtime" }' \
    "$manifest_path" 2>/dev/null || echo 0)
acceptance_path="$PWD/Tests/ConcurrencyParity/Manifests/milestone-acceptance.json"
acceptance_sha256=$(shasum -a 256 "$acceptance_path" 2>/dev/null | awk '{print $1}')
acceptance_schema_version=$(/usr/bin/ruby -rjson -e \
    'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("schemaVersion")' \
    "$acceptance_path" 2>/dev/null || echo 0)
capability_inventory_relative_path="Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json"
capability_status_relative_path="Tests/ConcurrencyParity/Manifests/concurrency-capability-status.json"
capability_inventory_path="${GATE_CAPABILITY_INVENTORY_INPUT_PATH:-$PWD/$capability_inventory_relative_path}"
capability_status_path="${GATE_CAPABILITY_STATUS_INPUT_PATH:-$PWD/$capability_status_relative_path}"
capability_gaps_path="$PWD/Tests/ConcurrencyParity/Manifests/open-gaps.json"
capability_accounting_status=0
capability_accounting_json=$(/usr/bin/ruby \
    Scripts/validate-concurrency-capability-accounting.rb \
    "$capability_inventory_path" "$capability_status_path" "$acceptance_path" \
    "$capability_gaps_path" "$manifest_path" \
    "$capability_inventory_relative_path" "$capability_status_relative_path" \
    2> "$out/capability-accounting.error") || capability_accounting_status=$?
swiftc_path=$(xcrun --find swiftc 2>/dev/null || echo unavailable)
if [[ "$swiftc_path" == "unavailable" ]]; then
    swift_version=unavailable
    target_info='{}'
else
    swift_version=$("$swiftc_path" --version 2>/dev/null || echo unavailable)
    target_info=$("$swiftc_path" -print-target-info 2>/dev/null || echo '{}')
fi
# Build, discovery, prebuilt runner lookup, and native oracles must all come
# from the same Xcode selected by xcrun. An ambient Swiftly/Homebrew driver can
# otherwise build one runtime while xcrun compiles the native parity twin with
# another, producing timing-dependent worker failures instead of a valid gate.
swift_driver_path=$(xcrun --find swift 2>/dev/null || echo unavailable)
if [[ "$swift_driver_path" == "unavailable" ]]; then
    swift_driver_version=unavailable
    swift_driver_target_info='{}'
else
    swift_driver_version=$("$swift_driver_path" --version 2>/dev/null \
        || echo unavailable)
    swift_driver_target_info=$("$swift_driver_path" -print-target-info 2>/dev/null \
        || echo '{}')
fi
sdk_path=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo unavailable)
sdk_version=$(xcrun --show-sdk-version --sdk macosx 2>/dev/null || echo unavailable)
target_triple=$(printf '%s' "$target_info" \
    | plutil -extract target.triple raw -o - - 2>/dev/null || echo unavailable)
swift_driver_target_triple=$(printf '%s' "$swift_driver_target_info" \
    | plutil -extract target.triple raw -o - - 2>/dev/null || echo unavailable)
swift_driver_runtime_resource=$(printf '%s' "$swift_driver_target_info" \
    | plutil -extract paths.runtimeResourcePath raw -o - - 2>/dev/null \
    || echo unavailable)
toolchain_fingerprint=$(printf '%s\n%s\n%s\n%s\n%s\n' \
    "$swiftc_path" "$swift_version" "$swift_driver_path" "$swift_driver_version" \
    "$sdk_path $sdk_version $target_triple $swift_driver_target_triple" \
    | shasum -a 256 | awk '{print $1}')
expected_toolchain_fingerprint="${GATE_EXPECTED_TOOLCHAIN_FINGERPRINT:-}"
toolchain_identity_error=""
if [[ "$swiftc_path" == "unavailable" \
      || "$swift_driver_path" == "unavailable" ]]; then
    toolchain_identity_error="xcrun could not resolve both swift and swiftc"
elif [[ "${swiftc_path:h}" != "${swift_driver_path:h}" ]]; then
    toolchain_identity_error="xcrun resolved swift and swiftc from different toolchain directories"
elif [[ "$target_triple" == "unavailable" \
        || "$swift_driver_target_triple" == "unavailable" \
        || "$target_triple" != "$swift_driver_target_triple" ]]; then
    toolchain_identity_error="xcrun swift and swiftc target triples do not match"
elif [[ "$swift_driver_runtime_resource" == "unavailable" ]]; then
    toolchain_identity_error="xcrun swift did not report a runtime resource path"
fi
if [[ -n "$expected_toolchain_fingerprint" ]]; then
    toolchain_policy=xcrun-and-fingerprint-pinned
else
    toolchain_policy=xcrun-pinned
fi

append_gate_diagnostic() {
    local message="$1"
    if [[ -z "$gate_diagnostics" ]]; then
        gate_diagnostics="$message"
    else
        gate_diagnostics+=$'\n'$message
    fi
}
capture_source_at_end() {
    if [[ "$source_end_captured" == true ]]; then return; fi
    git_commit_at_end=$(git rev-parse HEAD 2>/dev/null || echo unknown)
    local git_status_at_end=$(git status --porcelain --untracked-files=normal \
        2>/dev/null || true)
    if [[ -n "$git_status_at_end" ]]; then
        git_dirty_at_end=true
    else
        git_dirty_at_end=false
    fi
    worktree_fingerprint_at_end=$(compute_worktree_fingerprint)
    source_end_captured=true
    if [[ "$git_commit_at_end" != "$git_commit" \
          || "$worktree_fingerprint_at_end" != "$worktree_fingerprint" ]]; then
        source_drift_detected=true
    fi
}
report_source_drift() {
    if [[ "$source_drift_detected" != true \
          || "$source_drift_reported" == true ]]; then return; fi
    source_drift_reported=true
    append_gate_diagnostic \
        "source drift detected: commit $git_commit -> $git_commit_at_end; worktree $worktree_fingerprint -> $worktree_fingerprint_at_end"
    echo "source/worktree changed while the gate was running" >&2
}
bounded_log_tail() {
    local file_path="$1"
    local lines="${2:-60}"
    if [[ -f "$file_path" ]]; then
        /usr/bin/tail -n "$lines" "$file_path" 2>/dev/null || true
    fi
}
combined_test_log_tail() {
    local file
    for file in "$out"/tests-*.log(N) "$out"/concurrency-parity-shards.log(N); do
        echo "══ ${file:t} ══"
        bounded_log_tail "$file" 30
    done
}
timeout_message() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        /bin/cat "$file_path" 2>/dev/null || true
    fi
}
mark_current_stage_interrupted() {
    case "$current_stage" in
        build)
            build_stage_status="interrupted"
            build_stage_seconds=$(( SECONDS - stage_started )) ;;
        tests)
            test_stage_status="interrupted"
            test_stage_seconds=$(( SECONDS - stage_started )) ;;
        evaluation)
            eval_stage_status="interrupted"
            eval_stage_seconds=$(( SECONDS - stage_started )) ;;
        live)
            live_stage_status="interrupted"
            live_stage_seconds=$(( SECONDS - stage_started )) ;;
        icecubes-r2)
            r2_stage_status="interrupted"
            r2_stage_seconds=$(( SECONDS - stage_started )) ;;
        icecubes-board)
            icecubes_stage_status="interrupted"
            icecubes_stage_seconds=$(( SECONDS - stage_started )) ;;
    esac
}
handle_gate_signal() {
    local signal_name="$1"
    local exit_code="$2"
    append_gate_diagnostic \
        "received SIG$signal_name during $current_stage; terminating active process trees"
    mark_current_stage_interrupted
    exit "$exit_code"
}

process_tree() {
    local parent="$1"
    local child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        process_tree "$child"
    done
    echo "$parent"
}
process_identity() {
    local pid="$1"
    local description=$(ps -p "$pid" -o lstart= 2>/dev/null \
        | awk '{$1=$1; print}')
    if [[ -z "$description" ]]; then return 1; fi
    local token=$(printf '%s' "$description" \
        | shasum -a 256 | awk '{print $1}')
    printf '%s\t%s\n' "$pid" "$token"
}
identity_pid() {
    printf '%s' "${1%%$'\t'*}"
}
identity_is_current() {
    local identity="$1"
    local pid=$(identity_pid "$identity")
    local state=$(ps -p "$pid" -o state= 2>/dev/null \
        | awk '{$1=$1; print}')
    if [[ -z "$state" || "$state" == Z* ]]; then return 1; fi
    local current=$(process_identity "$pid" 2>/dev/null || true)
    [[ -n "$current" && "$current" == "$identity" ]]
}
signal_identity() {
    local signal_name="$1"
    local identity="$2"
    if identity_is_current "$identity"; then
        kill "-$signal_name" "$(identity_pid "$identity")" 2>/dev/null || true
    fi
}
snapshot_identity_tree() {
    local root_identity="$1"
    if ! identity_is_current "$root_identity"; then return; fi
    local root=$(identity_pid "$root_identity")
    local pid identity
    local -a pids=("${(@f)$(process_tree "$root")}")
    # If the root changed while its tree was being enumerated, discard the
    # snapshot rather than risk signaling a reused PID's unrelated children.
    if ! identity_is_current "$root_identity"; then return; fi
    for pid in $pids; do
        if [[ "$pid" == "$root" ]]; then
            echo "$root_identity"
        else
            identity=$(process_identity "$pid" 2>/dev/null || true)
            if [[ -n "$identity" ]]; then echo "$identity"; fi
        fi
    done
}
terminate_captured_identities() {
    local -a identities=("$@")
    if (( ${#identities} == 0 )); then return; fi

    # Trees are captured descendants-first. Signal in reverse order so roots
    # stop spawning work first, while retaining every pre-TERM descendant
    # identity for safe escalation after it is reparented.
    integer index
    for (( index = ${#identities}; index >= 1; index-- )); do
        signal_identity TERM "${identities[$index]}"
    done
    integer deadline=$(( SECONDS + termination_grace ))
    integer any_running
    while (( SECONDS < deadline )); do
        any_running=0
        local identity
        for identity in "${identities[@]}"; do
            if identity_is_current "$identity"; then any_running=1; break; fi
        done
        if (( any_running == 0 )); then break; fi
        sleep 1
    done
    for identity in "${identities[@]}"; do
        signal_identity KILL "$identity"
    done
}
terminate_identity_trees() {
    local root_identity snapshot
    local -a identities
    for root_identity in "$@"; do
        snapshot=$(snapshot_identity_tree "$root_identity")
        if [[ -n "$snapshot" ]]; then identities+=("${(@f)snapshot}"); fi
    done
    terminate_captured_identities "${identities[@]}"
}
terminate_processes() {
    local root identity
    local -a root_identities
    for root in "$@"; do
        identity=$(process_identity "$root" 2>/dev/null || true)
        if [[ -n "$identity" ]]; then root_identities+=("$identity"); fi
    done
    terminate_identity_trees "${root_identities[@]}"
}
start_stage_watchdog() {
    local stage_name="$1"
    local timeout="$2"
    local marker="$3"
    shift 3
    local -a watched=("$@")
    local pid identity
    local -a watched_identities
    for pid in $watched; do
        identity=$(process_identity "$pid" 2>/dev/null || true)
        if [[ -n "$identity" ]]; then watched_identities+=("$identity"); fi
    done
    (
        sleep "$timeout"
        local -a running
        for identity in "${watched_identities[@]}"; do
            if identity_is_current "$identity"; then running+=("$identity"); fi
        done
        if (( ${#running} > 0 )); then
            echo "$stage_name exceeded its ${timeout}s deadline" > "$marker"
            echo "$stage_name TIMEOUT after ${timeout}s" >&2
            terminate_identity_trees "${running[@]}"
        fi
    ) &
    stage_watchdog_pid=$!
    active_pids+=($stage_watchdog_pid)
}
stop_stage_watchdog() {
    local pid="$1"
    local marker="$2"
    if kill -0 "$pid" 2>/dev/null; then
        if [[ -f "$marker" ]]; then
            # A fired watchdog owns escalation for the stage tree.
            wait "$pid" 2>/dev/null || true
        else
            # A cancelled watchdog contains only its cooperative sleep. Avoid
            # charging the normal success path the failure grace period.
            local watchdog_identity=$(process_identity "$pid" 2>/dev/null || true)
            local watchdog_snapshot=""
            local -a watchdog_tree
            if [[ -n "$watchdog_identity" ]]; then
                watchdog_snapshot=$(snapshot_identity_tree "$watchdog_identity")
                if [[ -n "$watchdog_snapshot" ]]; then
                    watchdog_tree=("${(@f)watchdog_snapshot}")
                fi
            fi
            integer index
            for (( index = ${#watchdog_tree}; index >= 1; index-- )); do
                signal_identity TERM "${watchdog_tree[$index]}"
            done
        fi
    fi
    wait "$pid" 2>/dev/null || true
    remove_active_pid "$pid"
}
cleanup() {
    local original_exit_status=$?
    local exit_status=$original_exit_status
    local pid
    local receipt_failed=0
    trap - INT TERM HUP
    if (( ${#active_pids} > 0 )); then terminate_processes $active_pids; fi
    capture_source_at_end
    report_source_drift
    if (( exit_status == 0 )) && [[ "$source_drift_detected" == true ]]; then
        exit_status=1
    fi
    write_receipt "$exit_status" || receipt_failed=1
    # A RED gate must keep the evidence that names its own failure. The
    # receipt's log tails are bounded and a parallel worker's summary JSON can
    # fill them, so deleting the per-worker logs on a red run leaves the
    # closing check reporting only THAT something failed — costing a second
    # full gate to find out what.
    if [[ "${GATE_KEEP_LOGS:-0}" == "1" ]] || (( receipt_failed != 0 )) \
       || (( exit_status != 0 )); then
        echo "gate logs kept at $out"
    else
        rm -rf "$out"
    fi
    release_gate_lock
    if (( original_exit_status == 0 \
          && (exit_status != 0 || receipt_failed != 0) )); then
        if (( receipt_failed != 0 )); then echo "GATE RECEIPT RED" >&2; fi
        trap - EXIT
        exit 1
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
write_receipt() {
    local exit_status="$1"
    local result=RED
    if (( exit_status == 0 )); then result=GREEN; fi
    local plist="$out/gate-receipt.plist"
    local receipt_tmp="${receipt_path}.tmp.$$"
    local finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local logs_sha256=$(
        find "$out" -type f 2>/dev/null | LC_ALL=C sort \
            | while IFS= read -r file; do shasum -a 256 "$file"; done \
            | shasum -a 256 | awk '{print $1}'
    )

    if ! /usr/bin/plutil -create xml1 "$plist" 2>/dev/null; then
        echo "could not create gate receipt" >&2
        return 1
    fi
    receipt_string() {
        /usr/bin/plutil -insert "$1" -string "$2" "$plist" >/dev/null
    }
    receipt_integer() {
        /usr/bin/plutil -insert "$1" -integer "$2" "$plist" >/dev/null
    }
    receipt_bool() {
        /usr/bin/plutil -insert "$1" -bool "$2" "$plist" >/dev/null
    }
    receipt_stage() {
        local stage="$1"
        /usr/bin/plutil -insert "stages.$stage" -dictionary "$plist" >/dev/null
        receipt_string "stages.$stage.status" "$2"
        receipt_integer "stages.$stage.durationSeconds" "$3"
    }

    receipt_integer schemaVersion 4
    receipt_string result "$result"
    receipt_integer exitStatus "$exit_status"
    receipt_string startedAt "$gate_started_at"
    receipt_string finishedAt "$finished_at"
    receipt_integer durationSeconds "$(( SECONDS - gate_started ))"

    /usr/bin/plutil -insert source -dictionary "$plist" >/dev/null
    receipt_string source.commit "$git_commit"
    receipt_bool source.dirtyAtStart "$git_dirty_at_start"
    receipt_string source.worktreeFingerprint "$worktree_fingerprint"
    receipt_string source.parityManifestSHA256 "$manifest_sha256"
    receipt_integer source.parityManifestCaseCount "$manifest_case_count"
    receipt_integer source.parityManifestRuntimeCaseCount "$manifest_runtime_case_count"
    receipt_string source.acceptanceManifestSHA256 "$acceptance_sha256"
    receipt_integer source.acceptanceManifestSchemaVersion \
        "$acceptance_schema_version"
    /usr/bin/plutil -insert source.concurrencyCapabilityAccounting -json \
        "$capability_accounting_json" "$plist" >/dev/null
    /usr/bin/plutil -insert source.iceCubesClosePolicy -json \
        "$close_policy_json" "$plist" >/dev/null
    /usr/bin/plutil -insert source.antiDrift -json \
        "$anti_drift_json" "$plist" >/dev/null
    receipt_string source.commitAtStart "$git_commit"
    receipt_string source.commitAtEnd "$git_commit_at_end"
    receipt_bool source.dirtyAtEnd "$git_dirty_at_end"
    receipt_string source.worktreeFingerprintAtEnd "$worktree_fingerprint_at_end"
    receipt_bool source.driftDetected "$source_drift_detected"

    /usr/bin/plutil -insert toolchain -dictionary "$plist" >/dev/null
    receipt_string toolchain.swiftVersion "$swift_version"
    receipt_string toolchain.swiftcPath "$swiftc_path"
    receipt_string toolchain.swiftDriverPath "$swift_driver_path"
    receipt_string toolchain.swiftDriverVersion "$swift_driver_version"
    receipt_string toolchain.swiftDriverTargetTriple "$swift_driver_target_triple"
    receipt_string toolchain.swiftDriverRuntimeResourcePath \
        "$swift_driver_runtime_resource"
    /usr/bin/plutil -insert toolchain.swiftDriverTargetInfo -json \
        "$swift_driver_target_info" "$plist" >/dev/null
    receipt_string toolchain.macOSSDKPath "$sdk_path"
    receipt_string toolchain.macOSSDKVersion "$sdk_version"
    receipt_string toolchain.targetTriple "$target_triple"
    /usr/bin/plutil -insert toolchain.targetInfo -json "$target_info" "$plist" >/dev/null
    receipt_string toolchain.fingerprint "$toolchain_fingerprint"
    receipt_string toolchain.policy "$toolchain_policy"
    receipt_string toolchain.expectedFingerprint "$expected_toolchain_fingerprint"

    /usr/bin/plutil -insert parity -dictionary "$plist" >/dev/null
    /usr/bin/plutil -insert parity.nativeCompileFlags -json \
        '["-swift-version","6","-strict-concurrency=complete","-parse-as-library"]' \
        "$plist" >/dev/null
    /usr/bin/plutil -insert parity.shardCoverage -json \
        "$parity_shard_receipt_json" "$plist" >/dev/null

    /usr/bin/plutil -insert configuration -dictionary "$plist" >/dev/null
    receipt_integer configuration.jobs "$gate_jobs"
    receipt_integer configuration.testWorkers "$test_workers"
    receipt_integer configuration.parityTestWorkers "$parity_test_workers"
    receipt_integer configuration.evalWorkers "$eval_workers"
    receipt_integer configuration.liveWorkers "$live_workers"
    receipt_string configuration.gateLockPolicy "exclusive-git-common-dir"
    receipt_string configuration.gateLockDirectory "$gate_lock_directory"
    receipt_integer configuration.buildTimeoutSeconds "$build_timeout"
    receipt_integer configuration.testTimeoutSeconds "$test_timeout"
    receipt_integer configuration.evalTimeoutSeconds "$eval_timeout"
    receipt_integer configuration.liveTimeoutSeconds "$live_timeout"
    receipt_integer configuration.r2TimeoutSeconds "$r2_timeout"
    receipt_integer configuration.iceCubesTimeoutSeconds "$icecubes_timeout"
    receipt_integer configuration.childTimeoutSeconds "$child_timeout"
    receipt_integer configuration.terminationGraceSeconds "$termination_grace"
    /usr/bin/plutil -insert configuration.effectiveEnvironment -dictionary \
        "$plist" >/dev/null
    receipt_string \
        configuration.effectiveEnvironment.DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS \
        "$child_timeout"
    receipt_string \
        configuration.effectiveEnvironment.DYNAMIC_SWIFT_PARITY_SHARD_COUNT \
        "$parity_test_workers"
    receipt_string \
        configuration.effectiveEnvironment.DYNAMIC_SWIFT_PARITY_SHARD_INDEX \
        "0..<$parity_test_workers (one value per shard)"
    receipt_string \
        configuration.effectiveEnvironment.SWIFT_DETERMINISTIC_HASHING "1"
    receipt_string \
        configuration.effectiveEnvironment.GATE_CONTINUE_AFTER_FAILURE \
        "$continue_after_failure"
    receipt_string \
        configuration.effectiveEnvironment.GATE_LOCK_DIRECTORY \
        "$gate_lock_directory"

    /usr/bin/plutil -insert stages -dictionary "$plist" >/dev/null
    receipt_stage build "$build_stage_status" "$build_stage_seconds"
    receipt_stage tests "$test_stage_status" "$test_stage_seconds"
    receipt_stage evaluation "$eval_stage_status" "$eval_stage_seconds"
    receipt_stage live "$live_stage_status" "$live_stage_seconds"
    receipt_stage iceCubesR2 "$r2_stage_status" "$r2_stage_seconds"
    receipt_stage iceCubesBoard "$icecubes_stage_status" \
        "$icecubes_stage_seconds"

    /usr/bin/plutil -insert boards -dictionary "$plist" >/dev/null
    receipt_integer boards.discoveredTestCount "$test_count"
    receipt_string boards.suite "$suite_summary"
    receipt_string boards.corpus "$corpus_summary"
    receipt_string boards.apiParity "$parity_summary"
    receipt_string boards.live "$live_summary"
    receipt_string boards.iceCubesR2 "$r2_summary"
    receipt_string boards.iceCubesBoard "$icecubes_summary"
    receipt_string boards.concurrencyParityShards "$parity_shard_validation"
    receipt_string evidenceLogsSHA256 "$logs_sha256"

    local build_log_tail="" test_logs_tail="" validator_log_tail=""
    local corpus_log_tail="" parity_log_tail="" live_log_tail=""
    local close_policy_log_tail="" r2_log_tail="" icecubes_log_tail=""
    if (( exit_status != 0 )); then
        build_log_tail=$(bounded_log_tail "$out/build.log" 80)
        test_logs_tail=$(combined_test_log_tail)
        validator_log_tail=$(bounded_log_tail \
            "$out/concurrency-parity-shards.log" 80)
        corpus_log_tail=$(bounded_log_tail "$out/corpus.log" 80)
        parity_log_tail=$(bounded_log_tail "$out/parity.log" 80)
        live_log_tail=$(bounded_log_tail "$out/live.log" 80)
        close_policy_log_tail=$(bounded_log_tail "$out/close-policy.log" 80)
        r2_log_tail=$(bounded_log_tail "$out/icecubes-r2.log" 80)
        icecubes_log_tail=$(bounded_log_tail "$out/icecubes-board.log" 80)
    fi
    /usr/bin/plutil -insert diagnostics -dictionary "$plist" >/dev/null
    receipt_integer diagnostics.exitStatus "$exit_status"
    receipt_string diagnostics.currentStage "$current_stage"
    receipt_string diagnostics.messages "$gate_diagnostics"
    receipt_string diagnostics.testWorkerStatuses "$test_worker_statuses"
    receipt_string diagnostics.buildLogTail "$build_log_tail"
    receipt_string diagnostics.testLogsTail "$test_logs_tail"
    receipt_string diagnostics.parityValidatorLogTail "$validator_log_tail"
    receipt_string diagnostics.corpusLogTail "$corpus_log_tail"
    receipt_string diagnostics.apiParityLogTail "$parity_log_tail"
    receipt_string diagnostics.liveLogTail "$live_log_tail"
    receipt_string diagnostics.closePolicyLogTail "$close_policy_log_tail"
    receipt_string diagnostics.iceCubesR2LogTail "$r2_log_tail"
    receipt_string diagnostics.iceCubesBoardLogTail "$icecubes_log_tail"
    /usr/bin/plutil -insert diagnostics.timeouts -dictionary "$plist" >/dev/null
    receipt_string diagnostics.timeouts.build \
        "$(timeout_message "$out/build.timeout")"
    receipt_string diagnostics.timeouts.tests \
        "$(timeout_message "$out/tests.timeout")"
    receipt_string diagnostics.timeouts.evaluation \
        "$(timeout_message "$out/evaluation.timeout")"
    receipt_string diagnostics.timeouts.live \
        "$(timeout_message "$out/live.timeout")"
    receipt_string diagnostics.timeouts.iceCubesR2 \
        "$(timeout_message "$out/icecubes-r2.timeout")"
    receipt_string diagnostics.timeouts.iceCubesBoard \
        "$(timeout_message "$out/icecubes-board.timeout")"
    /usr/bin/plutil -insert diagnostics.exitStatuses -dictionary \
        "$plist" >/dev/null
    receipt_integer diagnostics.exitStatuses.build "$build_status"
    receipt_integer diagnostics.exitStatuses.testDiscovery \
        "$test_discovery_status"
    receipt_integer diagnostics.exitStatuses.projectCheck "$corpus_status"
    receipt_integer diagnostics.exitStatuses.apiParity "$parity_status"
    receipt_integer diagnostics.exitStatuses.live "$live_status"
    receipt_integer diagnostics.exitStatuses.closePolicy \
        "$close_policy_status"
    receipt_integer diagnostics.exitStatuses.iceCubesR2 "$r2_status"
    receipt_integer diagnostics.exitStatuses.iceCubesBoard \
        "$icecubes_status"

    mkdir -p "${receipt_path:h}"
    if /usr/bin/plutil -convert json -r -o "$receipt_tmp" "$plist" 2>/dev/null \
        && /usr/bin/ruby -rjson -e '
            receipt = JSON.parse(File.read(ARGV.fetch(0)))
            paths = %w[
              schemaVersion result exitStatus startedAt finishedAt durationSeconds
              source.commit source.dirtyAtStart source.worktreeFingerprint
              source.parityManifestSHA256 source.parityManifestCaseCount
              source.parityManifestRuntimeCaseCount
              source.acceptanceManifestSHA256
              source.acceptanceManifestSchemaVersion
              source.concurrencyCapabilityAccounting.valid
              source.concurrencyCapabilityAccounting.errors
              source.concurrencyCapabilityAccounting.inventoryPath
              source.concurrencyCapabilityAccounting.inventoryInputPath
              source.concurrencyCapabilityAccounting.inventorySHA256
              source.concurrencyCapabilityAccounting.inventorySchemaVersion
              source.concurrencyCapabilityAccounting.inventoryScopeID
              source.concurrencyCapabilityAccounting.interfaceSHA256
              source.concurrencyCapabilityAccounting.declarationCount
              source.concurrencyCapabilityAccounting.declarationsByDomain
              source.concurrencyCapabilityAccounting.adapterRoutedDeclarationCount
              source.concurrencyCapabilityAccounting.adapterRouteIsSupportEvidence
              source.concurrencyCapabilityAccounting.scopeComplete
              source.concurrencyCapabilityAccounting.statusPath
              source.concurrencyCapabilityAccounting.statusInputPath
              source.concurrencyCapabilityAccounting.statusSHA256
              source.concurrencyCapabilityAccounting.statusSchemaVersion
              source.concurrencyCapabilityAccounting.pinnedInventorySHA256
              source.concurrencyCapabilityAccounting.pinMatches
              source.concurrencyCapabilityAccounting.interfaceOverrideCount
              source.concurrencyCapabilityAccounting.resolvedInterfaceClaimCount
              source.concurrencyCapabilityAccounting.reviewedInterfaceClaimCount
              source.concurrencyCapabilityAccounting.interfaceImplementationCounts
              source.concurrencyCapabilityAccounting.interfaceVerificationCounts
              source.concurrencyCapabilityAccounting.semanticCatalogID
              source.concurrencyCapabilityAccounting.semanticCatalogVersion
              source.concurrencyCapabilityAccounting.semanticCatalogCompleteForAcceptanceScope
              source.concurrencyCapabilityAccounting.semanticCapabilityCount
              source.concurrencyCapabilityAccounting.semanticImplementationCounts
              source.concurrencyCapabilityAccounting.semanticVerificationCounts
              source.iceCubesClosePolicy.version
              source.iceCubesClosePolicy.status
              source.iceCubesClosePolicy.errors
              source.commitAtStart source.commitAtEnd source.dirtyAtEnd
              source.worktreeFingerprintAtEnd source.driftDetected
              toolchain.swiftVersion toolchain.swiftcPath toolchain.macOSSDKPath
              toolchain.macOSSDKVersion toolchain.targetTriple toolchain.targetInfo
              toolchain.swiftDriverPath toolchain.swiftDriverVersion
              toolchain.swiftDriverTargetTriple
              toolchain.swiftDriverRuntimeResourcePath
              toolchain.swiftDriverTargetInfo
              toolchain.fingerprint toolchain.policy
              toolchain.expectedFingerprint
              parity.nativeCompileFlags parity.shardCoverage
              configuration.jobs configuration.testWorkers
              configuration.parityTestWorkers configuration.evalWorkers
              configuration.liveWorkers configuration.buildTimeoutSeconds
              configuration.testTimeoutSeconds configuration.evalTimeoutSeconds
              configuration.liveTimeoutSeconds configuration.r2TimeoutSeconds
              configuration.iceCubesTimeoutSeconds
              configuration.childTimeoutSeconds
              configuration.terminationGraceSeconds
              configuration.effectiveEnvironment
              stages.build.status stages.build.durationSeconds
              stages.tests.status stages.tests.durationSeconds
              stages.evaluation.status stages.evaluation.durationSeconds
              stages.live.status stages.live.durationSeconds
              stages.iceCubesR2.status stages.iceCubesR2.durationSeconds
              stages.iceCubesBoard.status
              stages.iceCubesBoard.durationSeconds
              boards.discoveredTestCount boards.suite boards.corpus
              boards.apiParity boards.live boards.iceCubesR2
              boards.iceCubesBoard
              boards.concurrencyParityShards
              evidenceLogsSHA256 diagnostics.exitStatus
              diagnostics.currentStage diagnostics.messages
              diagnostics.testWorkerStatuses diagnostics.buildLogTail
              diagnostics.testLogsTail diagnostics.parityValidatorLogTail
              diagnostics.corpusLogTail diagnostics.apiParityLogTail
              diagnostics.liveLogTail diagnostics.closePolicyLogTail
              diagnostics.iceCubesR2LogTail
              diagnostics.iceCubesBoardLogTail diagnostics.timeouts
              diagnostics.exitStatuses
            ]
            missing = paths.reject do |path|
              value = receipt
              present = true
              path.split(".").each do |key|
                unless value.is_a?(Hash) && value.key?(key)
                  present = false
                  break
                end
                value = value[key]
              end
              present
            end
            abort "missing receipt fields: #{missing.join(", ")}" unless missing.empty?
          ' "$receipt_tmp" 2>/dev/null
    then
        if ! mv -f "$receipt_tmp" "$receipt_path"; then
            rm -f "$receipt_tmp"
            echo "could not install gate receipt at $receipt_path" >&2
            return 1
        fi
        echo "gate receipt: $receipt_path"
        return 0
    else
        rm -f "$receipt_tmp"
        echo "could not write gate receipt to $receipt_path" >&2
        return 1
    fi
}
trap cleanup EXIT
trap 'handle_gate_signal INT 130' INT
trap 'handle_gate_signal TERM 143' TERM
trap 'handle_gate_signal HUP 129' HUP

if (( capability_accounting_status != 0 )); then
    build_stage_status="blocked-source-accounting"
    accounting_errors=$(/usr/bin/ruby -rjson -e '
        payload = JSON.parse(ARGV.fetch(0))
        puts payload.fetch("errors", []).join("; ")
    ' "$capability_accounting_json" 2>/dev/null || \
        /bin/cat "$out/capability-accounting.error" 2>/dev/null || true)
    append_gate_diagnostic \
        "concurrency capability accounting invalid: $accounting_errors"
    echo "concurrency capability accounting invalid" >&2
    echo "$accounting_errors" >&2
    exit 1
fi

if [[ -n "$toolchain_identity_error" ]]; then
    build_stage_status="blocked-toolchain"
    append_gate_diagnostic "$toolchain_identity_error"
    echo "toolchain identity invalid" >&2
    echo "$toolchain_identity_error" >&2
    exit 1
fi

if [[ -n "$expected_toolchain_fingerprint" \
      && "$toolchain_fingerprint" != "$expected_toolchain_fingerprint" ]]; then
    build_stage_status="blocked-toolchain"
    append_gate_diagnostic \
        "toolchain fingerprint mismatch: expected $expected_toolchain_fingerprint, actual $toolchain_fingerprint"
    echo "toolchain fingerprint mismatch" >&2
    echo "expected: $expected_toolchain_fingerprint" >&2
    echo "actual:   $toolchain_fingerprint" >&2
    exit 1
fi

acquire_gate_lock
gate_lock_status=$?
if (( gate_lock_status != 0 )); then
    build_stage_status="blocked-concurrent-gate"
    current_stage="completion"
    append_gate_diagnostic \
        "another closing gate is active: $gate_lock_conflict"
    echo "another closing gate is active" >&2
    echo "$gate_lock_conflict" >&2
    exit 75
fi

current_stage="disk-preflight"
# A gate needs its clean-detached checkout plus a full .build. When the volume is nearly full the
# failures do not say "disk": they arrive as a linker error, a truncated capture, or a corpus shard
# that dies with no log — hours of confusing RED. Fail here instead, with the reason and the fix.
# The scratch is created BY THE ITERATION (git worktree add), not by this script, so gate.sh cannot
# reap it; .claude/run-foodtruck-loop.sh reaps between iterations.
integer disk_free_gib=$(df -g . 2>/dev/null | tail -1 | awk '{print $4}')
integer disk_floor_gib=${GATE_DISK_FLOOR_GIB:-15}
if (( disk_free_gib < disk_floor_gib )); then
    build_stage_status="blocked-disk"
    append_gate_diagnostic \
        "only ${disk_free_gib}Gi free, below the ${disk_floor_gib}Gi floor a gate needs"
    print -u2 "GATE DISK RED — ${disk_free_gib}Gi free, floor ${disk_floor_gib}Gi."
    print -u2 "Stale clean-detached checkouts accumulate in /tmp/lane-gate-*; each is ~2.4G and" \
        "most are still REGISTERED git worktrees, so plain rm leaves the registration behind."
    print -u2 "Reap them with: Scripts/reap-gate-scratch.sh"
    exit 1
fi
echo "disk preflight GREEN (${disk_free_gib}Gi free, floor ${disk_floor_gib}Gi)"

current_stage="close-policy"
close_policy_status=0
/usr/bin/ruby Scripts/validate-icecubes-close-policy.rb \
    "$claims_path" "$integration_base" \
    > "$out/close-policy.log" 2>&1 || close_policy_status=$?
close_policy_marker=$(grep '^@@icecubes-close-policy ' \
    "$out/close-policy.log" | tail -1 || true)
if [[ -n "$close_policy_marker" ]]; then
    close_policy_json="${close_policy_marker#@@icecubes-close-policy }"
fi
if (( close_policy_status != 0 )); then
    build_stage_status="blocked-close-policy"
    append_gate_diagnostic \
        "IceCubes close policy rejected the candidate: $(bounded_log_tail "$out/close-policy.log" 20)"
    /bin/cat "$out/close-policy.log" >&2
    echo "ICECUBES CLOSE POLICY RED" >&2
    exit 1
fi
echo "IceCubes close policy GREEN"

current_stage="anti-drift"
# AGENTS.md's generality safeguards were binding prose for three weeks and did not fire once — the
# §5 ratchet was crossed inside the 2026-08-04..08-07 window and nothing noticed. Same treatment as
# the close policy: an exit code, before the expensive stages, so a drifting candidate is refused in
# seconds rather than after a 45-minute build.
anti_drift_status=0
./Scripts/validate-anti-drift.sh > "$out/anti-drift.log" 2>&1 || anti_drift_status=$?
anti_drift_marker=$(grep '^@@anti-drift ' "$out/anti-drift.log" | tail -1 || true)
if [[ -n "$anti_drift_marker" ]]; then
    anti_drift_json="${anti_drift_marker#@@anti-drift }"
fi
if (( anti_drift_status != 0 )); then
    build_stage_status="blocked-anti-drift"
    append_gate_diagnostic \
        "anti-drift rejected the candidate: $(bounded_log_tail "$out/anti-drift.log" 20)"
    /bin/cat "$out/anti-drift.log" >&2
    echo "ANTI-DRIFT RED" >&2
    exit 1
fi
/bin/cat "$out/anti-drift.log"

current_stage="build"
echo "── build (once) ──"
integer stage_started=$SECONDS
"$swift_driver_path" build --build-tests > "$out/build.log" 2>&1 &
build_pid=$!
active_pids+=($build_pid)
build_timeout_marker="$out/build.timeout"
start_stage_watchdog build "$build_timeout" "$build_timeout_marker" "$build_pid"
build_watchdog_pid=$stage_watchdog_pid
build_status=0
wait "$build_pid" || build_status=$?
remove_active_pid "$build_pid"
stop_stage_watchdog "$build_watchdog_pid" "$build_timeout_marker"
build_stage_seconds=$(( SECONDS - stage_started ))
if [[ -f "$build_timeout_marker" ]]; then
    build_stage_status="timeout"
elif (( build_status == 0 )); then
    build_stage_status="passed"
else
    build_stage_status="failed"
fi
if (( build_status != 0 )) || [[ -f "$build_timeout_marker" ]]; then
    if [[ -f "$build_timeout_marker" ]]; then
        append_gate_diagnostic "$(timeout_message "$build_timeout_marker")"
    else
        append_gate_diagnostic "build exited with status $build_status"
    fi
    tail -80 "$out/build.log"
    echo "BUILD RED"
    exit 1
fi
grep -E "warning: .*deprecat" "$out/build.log" | head -5 || true
echo "build completed in ${build_stage_seconds}s"

current_stage="tests"
stage_started=$SECONDS
test_timeout_marker="$out/tests.timeout"
"$swift_driver_path" test list --skip-build \
    > "$out/tests-list.out" 2> "$out/tests-list.log" &
test_discovery_pid=$!
active_pids+=($test_discovery_pid)
start_stage_watchdog "test discovery" "$test_timeout" \
    "$test_timeout_marker" "$test_discovery_pid"
test_discovery_watchdog_pid=$stage_watchdog_pid
test_discovery_status=0
wait "$test_discovery_pid" || test_discovery_status=$?
remove_active_pid "$test_discovery_pid"
stop_stage_watchdog "$test_discovery_watchdog_pid" "$test_timeout_marker"
test_count=$(awk 'NF { count++ } END { print count + 0 }' \
    "$out/tests-list.out")
if [[ -f "$test_timeout_marker" ]] || (( test_discovery_status != 0 )) \
    || ! is_positive_integer "$test_count"; then
    test_stage_seconds=$(( SECONDS - stage_started ))
    if [[ -f "$test_timeout_marker" ]]; then
        test_stage_status="timeout"
        append_gate_diagnostic "$(timeout_message "$test_timeout_marker")"
    else
        test_stage_status="failed-discovery"
        append_gate_diagnostic \
            "prebuilt test discovery exited with status $test_discovery_status and discovered $test_count tests: $(bounded_log_tail "$out/tests-list.log" 40)"
    fi
    echo "could not count the prebuilt tests" >&2
    exit 1
fi
runtime_resource="$swift_driver_runtime_resource"
test_helper="${runtime_resource%/lib/swift}/libexec/swift/pm/swiftpm-testing-helper"
test_bundle="$PWD/.build/debug/DynamicSwiftUIPackageTests.xctest/Contents/MacOS/DynamicSwiftUIPackageTests"
test_library_path="$runtime_resource/macosx/testing:$runtime_resource/macosx"
test_framework_path="$runtime_resource/macosx/testing:$runtime_resource/macosx"
sdk_platform_path=$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null \
    || true)
if [[ -n "$sdk_platform_path" ]]; then
    platform_frameworks="$sdk_platform_path/Developer/Library/Frameworks"
    if [[ -d "$platform_frameworks" ]]; then
        test_framework_path="$platform_frameworks:$test_framework_path"
    fi
fi
if [[ -n "${DYLD_LIBRARY_PATH:-}" ]]; then
    test_library_path="$test_library_path:$DYLD_LIBRARY_PATH"
fi
if [[ -n "${DYLD_FRAMEWORK_PATH:-}" ]]; then
    test_framework_path="$test_framework_path:$DYLD_FRAMEWORK_PATH"
fi
if [[ ! -x "$test_helper" || ! -f "$test_bundle" ]]; then
    test_stage_status="failed-runner-location"
    append_gate_diagnostic \
        "could not locate test helper '$test_helper' or bundle '$test_bundle'"
    echo "could not locate the active toolchain's prebuilt test runner" >&2
    exit 1
fi

test_remaining=$(( test_timeout - (SECONDS - stage_started) ))
if (( test_remaining < 1 )); then
    echo "tests exceeded their ${test_timeout}s deadline during setup" \
        > "$test_timeout_marker"
    test_stage_status="timeout"
    test_stage_seconds=$(( SECONDS - stage_started ))
    append_gate_diagnostic "$(timeout_message "$test_timeout_marker")"
    echo "test stage TIMEOUT during setup" >&2
    exit 1
fi

echo "── tests ($test_workers Swift workers + $parity_test_workers parity shards) ──"
typeset -a test_pids test_names test_logs parity_test_logs

env DYLD_LIBRARY_PATH="$test_library_path" \
    DYLD_FRAMEWORK_PATH="$test_framework_path" \
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
        DYLD_FRAMEWORK_PATH="$test_framework_path" \
        "$test_helper" --test-bundle-path "$test_bundle" --skip-build --no-parallel \
        --filter 'ConcurrencyParityTests/runtimeFixturesMatchNativeGuarantees' \
        "$test_bundle" --testing-library swift-testing \
        > "$log" 2>&1 &
    parity_test_pid=$!
    test_pids+=($parity_test_pid)
    test_names+=("concurrency parity shard $(( shard + 1 ))/$parity_test_workers")
    test_logs+=("$log")
    parity_test_logs+=("$log")
    active_pids+=($parity_test_pid)
done

start_stage_watchdog tests "$test_remaining" "$test_timeout_marker" $test_pids
test_watchdog_pid=$stage_watchdog_pid
test_red=0
integer job
for (( job = 1; job <= ${#test_pids}; job++ )); do
    worker_status=0
    wait "${test_pids[$job]}" || worker_status=$?
    if [[ -n "$test_worker_statuses" ]]; then test_worker_statuses+=", "; fi
    test_worker_statuses+="${test_names[$job]}=$worker_status"
    if (( worker_status != 0 )); then
        echo "${test_names[$job]} RED" >&2
        tail -60 "${test_logs[$job]}" >&2
        append_gate_diagnostic \
            "${test_names[$job]} exited with status $worker_status"
        test_red=1
    fi
    remove_active_pid "${test_pids[$job]}"
done
stop_stage_watchdog "$test_watchdog_pid" "$test_timeout_marker"
if [[ -f "$test_timeout_marker" ]]; then
    append_gate_diagnostic "$(timeout_message "$test_timeout_marker")"
    test_red=1
fi

parity_validation_log="$out/concurrency-parity-shards.log"
if /usr/bin/ruby Scripts/validate-concurrency-parity-summaries.rb \
    "$manifest_path" "${parity_test_logs[@]}" \
    > "$parity_validation_log" 2>&1; then
    parity_shard_validation=$(tail -1 "$parity_validation_log")
    parity_shard_receipt_json="${parity_shard_validation#@@concurrency-parity-gate-summary }"
else
    echo "concurrency parity shard coverage RED" >&2
    cat "$parity_validation_log" >&2
    append_gate_diagnostic \
        "concurrency parity shard validation failed: $(bounded_log_tail "$parity_validation_log" 20)"
    parity_shard_validation="failed"
    parity_shard_receipt_json='{"version":1,"status":"failed"}'
    test_red=1
fi

test_stage_seconds=$(( SECONDS - stage_started ))
if [[ -f "$test_timeout_marker" ]]; then
    test_stage_status="timeout"
elif (( test_red == 0 )); then
    test_stage_status="passed"
else
    test_stage_status="failed"
fi
if (( test_red != 0 )); then
    append_gate_diagnostic "test stage failed"
fi
echo "tests completed in ${test_stage_seconds}s"

if (( test_red == 0 )); then
    echo "Test run with $test_count tests passed ($parity_test_workers process shards)" > "$out/suite"
else
    echo "parallel test workers failed" > "$out/suite"
fi

# A failed test stage already makes the source-bound gate RED. Do not spend
# another ~10 minutes on memory-isolated live scenarios unless a diagnostic
# run explicitly asks for every board.
if (( test_red != 0 )) && [[ "$continue_after_failure" != 1 ]]; then
    suite_summary=$(cat "$out/suite")
    append_gate_diagnostic \
        "evaluation and live stages skipped after test failure"
    current_stage="completion"
    capture_source_at_end
    report_source_drift
    echo "suite: $suite_summary"
    echo "GATE RED (evaluation/live skipped after test failure)"
    exit 1
fi

current_stage="evaluation"
echo "── corpus + API parity ($eval_workers workers each) ──"
stage_started=$SECONDS
env SWIFT_DETERMINISTIC_HASHING=1 \
    DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS="$child_timeout" \
    .build/debug/ProjectCheck --all --jobs "$eval_workers" > "$out/corpus.log" 2>&1 &
corpus_pid=$!
env DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS="$child_timeout" \
    .build/debug/ParityCheck --jobs "$eval_workers" > "$out/parity.log" 2>&1 &
parity_pid=$!
active_pids=($corpus_pid $parity_pid)
eval_timeout_marker="$out/evaluation.timeout"
start_stage_watchdog evaluation "$eval_timeout" "$eval_timeout_marker" \
    "$corpus_pid" "$parity_pid"
eval_watchdog_pid=$stage_watchdog_pid

corpus_status=0
parity_status=0
wait "$corpus_pid" || corpus_status=$?
remove_active_pid "$corpus_pid"
wait "$parity_pid" || parity_status=$?
remove_active_pid "$parity_pid"
stop_stage_watchdog "$eval_watchdog_pid" "$eval_timeout_marker"
eval_stage_seconds=$(( SECONDS - stage_started ))
if [[ -f "$eval_timeout_marker" ]]; then
    eval_stage_status="timeout"
    append_gate_diagnostic "$(timeout_message "$eval_timeout_marker")"
elif (( corpus_status == 0 && parity_status == 0 )); then
    eval_stage_status="passed"
else
    eval_stage_status="failed"
fi
echo "corpus + API parity completed in ${eval_stage_seconds}s"

grep "═══" "$out/corpus.log" | tail -1 > "$out/corpus" || true
grep "═══" "$out/parity.log" | tail -1 > "$out/parity" || true
if (( corpus_status != 0 )); then
    append_gate_diagnostic "ProjectCheck exited with status $corpus_status"
    echo "ProjectCheck RED" >&2
    tail -60 "$out/corpus.log" >&2
fi
if (( parity_status != 0 )); then
    append_gate_diagnostic "ParityCheck exited with status $parity_status"
    echo "ParityCheck RED" >&2
    tail -60 "$out/parity.log" >&2
fi

# Live scenarios allocate the deepest render graphs. They get process-level
# parallelism, but remain isolated from the corpus stage to cap peak memory.
current_stage="live"
echo "── live ($live_workers memory-isolated workers) ──"
stage_started=$SECONDS
live_status=0
env SWIFT_DETERMINISTIC_HASHING=1 \
    DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS="$child_timeout" \
    .build/debug/LiveCheck --jobs "$live_workers" > "$out/live.log" 2>&1 &
live_pid=$!
active_pids=($live_pid)
live_timeout_marker="$out/live.timeout"
start_stage_watchdog live "$live_timeout" "$live_timeout_marker" "$live_pid"
live_watchdog_pid=$stage_watchdog_pid
wait "$live_pid" || live_status=$?
remove_active_pid "$live_pid"
stop_stage_watchdog "$live_watchdog_pid" "$live_timeout_marker"
grep "═══" "$out/live.log" | tail -1 > "$out/live" || true
if (( live_status != 0 )); then
    append_gate_diagnostic "LiveCheck exited with status $live_status"
    echo "LiveCheck RED" >&2
    tail -60 "$out/live.log" >&2
fi
live_stage_seconds=$(( SECONDS - stage_started ))
if [[ -f "$live_timeout_marker" ]]; then
    live_stage_status="timeout"
    append_gate_diagnostic "$(timeout_message "$live_timeout_marker")"
elif (( live_status == 0 )); then
    live_stage_status="passed"
else
    live_stage_status="failed"
fi
echo "live completed in ${live_stage_seconds}s"

current_stage="icecubes-r2"
echo "── IceCubes R2 ──"
stage_started=$SECONDS
r2_status=0
Scripts/icecubes-r2.sh > "$out/icecubes-r2.log" 2>&1 &
r2_pid=$!
active_pids=($r2_pid)
r2_timeout_marker="$out/icecubes-r2.timeout"
start_stage_watchdog icecubes-r2 "$r2_timeout" "$r2_timeout_marker" \
    "$r2_pid"
r2_watchdog_pid=$stage_watchdog_pid
wait "$r2_pid" || r2_status=$?
remove_active_pid "$r2_pid"
stop_stage_watchdog "$r2_watchdog_pid" "$r2_timeout_marker"
r2_stage_seconds=$(( SECONDS - stage_started ))
grep '^AE [0-9][0-9]* of 630000 ' "$out/icecubes-r2.log" \
    | tail -1 > "$out/r2" || true
if [[ -f "$r2_timeout_marker" ]]; then
    r2_stage_status="timeout"
    append_gate_diagnostic "$(timeout_message "$r2_timeout_marker")"
elif (( r2_status == 0 )); then
    r2_stage_status="passed"
else
    r2_stage_status="failed"
fi
if (( r2_status != 0 )); then
    append_gate_diagnostic "IceCubes R2 exited with status $r2_status"
    echo "IceCubes R2 RED" >&2
    tail -80 "$out/icecubes-r2.log" >&2
fi
echo "IceCubes R2 completed in ${r2_stage_seconds}s"

# The north star itself. R2 measures pixels against the twin; this ladder
# measures whether each screen and interaction reaches its rung at all, and
# nothing else in the gate can see a rung go red.
current_stage="icecubes-board"
echo "── IceCubes board ──"
stage_started=$SECONDS
icecubes_status=0
env SWIFT_DETERMINISTIC_HASHING=1 \
    DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS="$child_timeout" \
    .build/debug/IceCubesCheck > "$out/icecubes-board.log" 2>&1 &
icecubes_pid=$!
active_pids=($icecubes_pid)
icecubes_timeout_marker="$out/icecubes-board.timeout"
start_stage_watchdog icecubes-board "$icecubes_timeout" \
    "$icecubes_timeout_marker" "$icecubes_pid"
icecubes_watchdog_pid=$stage_watchdog_pid
wait "$icecubes_pid" || icecubes_status=$?
remove_active_pid "$icecubes_pid"
stop_stage_watchdog "$icecubes_watchdog_pid" "$icecubes_timeout_marker"
icecubes_stage_seconds=$(( SECONDS - stage_started ))
grep '═══ IceCubesCheck:' "$out/icecubes-board.log" | tail -1 \
    > "$out/icecubes" || true
if [[ -f "$icecubes_timeout_marker" ]]; then
    icecubes_stage_status="timeout"
    append_gate_diagnostic "$(timeout_message "$icecubes_timeout_marker")"
elif (( icecubes_status == 0 )); then
    icecubes_stage_status="passed"
else
    icecubes_stage_status="failed"
fi
if (( icecubes_status != 0 )); then
    append_gate_diagnostic "IceCubesCheck exited with status $icecubes_status"
    echo "IceCubesCheck RED" >&2
    tail -60 "$out/icecubes-board.log" >&2
fi
echo "IceCubes board completed in ${icecubes_stage_seconds}s"

red=$test_red
for board in suite corpus live parity r2 icecubes; do
    line=$(cat "$out/$board" 2>/dev/null)
    case "$board" in
        suite) suite_summary="$line" ;;
        corpus) corpus_summary="$line" ;;
        live) live_summary="$line" ;;
        parity) parity_summary="$line" ;;
        r2) r2_summary="$line" ;;
        icecubes) icecubes_summary="$line" ;;
    esac
    echo "$board: $line"
    case "$board:$line" in
        suite:*" tests passed"*) ;;
        # LOOP.md owns the current external-corpus census. Match the exact
        # denominator so a removed/missing project cannot silently weaken
        # the board. TWO sanctioned censuses (steward: reconcile): 586/586
        # is lane-concurrency's environment WITHOUT External/oss checked
        # out (94 projects); 678/680 is the FULL census with the two
        # long-documented pre-existing failures (oss:Mythic et al — the
        # LOOP.md "corpus backstop 678/680 (unchanged)" baseline).
        corpus:*"586/586 projects pass"*) ;;
        corpus:*"678/680 projects pass"*) ;;
        live:*"5/5 live-data scenarios pass"*) ;;
        parity:*"0 diverge / 0 interp-error"*) ;;
        r2:"AE "*" of 630000 "*) ;;
        # The RUNG COUNT is the north star, so match the exact denominator:
        # a rung that is deleted rather than fixed must not read as green.
        # Raise both numbers in the commit that adds a rung.
        icecubes:*"IceCubesCheck: 9/9 rungs"*) ;;
        *)
            append_gate_diagnostic \
                "$board board summary did not satisfy the gate contract: $line"
            red=1 ;;
    esac
done
if (( corpus_status != 0 || parity_status != 0 || live_status != 0 \
      || r2_status != 0 || icecubes_status != 0 )); then red=1; fi
if [[ -f "$eval_timeout_marker" || -f "$live_timeout_marker" \
      || -f "$r2_timeout_marker" || -f "$icecubes_timeout_marker" ]]; then
    red=1
fi
current_stage="completion"
capture_source_at_end
report_source_drift
if [[ "$source_drift_detected" == true ]]; then red=1; fi
if (( red != 0 )); then echo "GATE RED"; exit 1; fi
echo "GATE GREEN in $(( SECONDS - gate_started ))s"
