#!/bin/zsh
# The IceCubes R3 board: drive one app-model INTERACTION on both sides, then
# pixel-AE the POST-mutation captures against each other.
#
# What this measures that Scripts/icecubes-r2.sh cannot. R2 scores ten FIRST
# RENDERS. Every one of its floors can be at zero while the interpreted app
# absorbs every subsequent state change, because nothing on that board ever
# changes state after the frame is read. The rungs in Sources/IceCubesCheck
# do drive interactions, but eight of the nine compare the interpreter against
# recorded JSON — against a fixture, not against SwiftUI — and all nine compare
# STRINGS harvested from the interpreter's own trace, so a screen that lays the
# right words out wrongly passes. This board is the missing third thing: the
# expectation is the natively compiled twin's own post-interaction pixels, and
# it is produced by the twin, never written here.
#
# WHY ONLY TWO SCENARIOS. Two more were designed and REJECTED for this
# iteration, and the reasoning is kept because it is the admission standard:
#
#  - a ROW TAP on the timeline pushes a `NavigationStack` destination, so its
#    post-mutation capture is a different screen rather than the same screen
#    updated — the base screen it would be diffed against is not proven at AE 0
#    (`status-detail` needs `--native-fixtures`), and the changed-guard would
#    measure a navigation transition, whose settle rules this board does not
#    yet have;
#  - PAGINATION drives a fetch, so its expectation depends on the replay
#    transport serving a second page deterministically under two different
#    request orders. That is a statement about the frozen network, not about
#    interaction fidelity, and a red would be unattributable between them.
#
# Both are worth admitting later, each behind the missing precondition named
# above. Neither is admitted by widening this list without one.
#
# Discipline inherited from Scripts/icecubes-r2.sh, which is the stricter of
# the two existing boards and the one to copy:
#
#  - BOTH sides are built for arm64-apple-ios18.0-macabi. The twin rasterizes
#    Catalyst UIKit; a macOS host is a different separator, control and scroll
#    implementation, so scoring one against the other reports a platform gap as
#    interaction debt. `IceCubesCheck` refuses `--scenario` on its macOS path
#    for exactly this reason, so the mistake cannot be made silently.
#  - Every capture is taken TWICE per side and the pair must be pixel-identical
#    before anything is scored. A floor delta can then only mean interpreter
#    fidelity moved — never settle timing, spinner phase or machine load.
#  - A pair whose PNGs disagree on SIZE or COLOUR ENCODING is refused rather
#    than scored (Scripts/pixel-ae.swift exits 2), because that difference is a
#    finding about the harnesses and not about the app.
#  - Floors ratchet DOWN only, and only with the measurement in the comment.
#
# And three rules this board adds, which are the whole point of it:
#
#  - The CHANGED-GUARD. For each scenario the board also diffs the PRE-mutation
#    capture against the POST-mutation capture ON EACH SIDE. If the twin's
#    screen changed and the interpreter's did not, the scenario FAILS even at
#    AE 0 — because two identical captures of an unchanged screen score zero,
#    and an absorbed mutation is exactly that. If the TWIN's screen did not
#    change either, the scenario itself has stopped testing anything and the
#    board says so separately: that is a broken scenario, not a green one.
#  - The CHANGED-DELTA AGREEMENT. `interpΔ == 0` is a test for a TOTALLY
#    absorbed mutation, and this repository's recorded shape is the partial
#    one. Scenario 1 alone gates TWO independent regions on
#    `theme.followSystemColorScheme` — the theme section's conditional footer,
#    and the four `ColorPicker`s' `.disabled`/`.opacity` — so an interpreter
#    that moves the footer and never undims the pickers produces a NONZERO
#    `interpΔ` and sails through a zero test. So `|twinΔ − interpΔ|` is scored
#    as its own ratcheted quantity, one per scenario, converging to 0 exactly
#    when the interpreted screen changed by as much as the native one did. The
#    zero test is KEPT alongside it, because "absorbed entirely" deserves its
#    own message; the magnitude relation is what catches everything short of
#    that.
#  - The REVISION-ADVANCE PRECONDITION. See the block above the metadata
#    assertions: a scenario whose interpreted body-evaluation revision did not
#    advance across the mutation is REFUSED rather than scored.
#
# Determinism inputs are the same three R2 pins, for the same reasons: the
# frozen clock (via the DYLD interposer AND both the epoch and the drift
# assertions below — one frozen source of wall time is not a frozen clock, and
# an epoch check alone cannot see `timeIntervalSinceNow` leaking), the frozen
# network (ReplayURLProtocol over the checked-in recordings), and the pinned
# @AppStorage persistent domain. The third one matters more here than anywhere
# else on either board: every scenario MUTATES an @AppStorage-backed singleton,
# so a second scenario running in the same process would start from the first
# one's writes. Both binaries therefore refuse `--scenario all`, and this board
# runs one process per scenario.
#
# KNOWN GAP, stated here until it lands (it is not fixable from this file).
# R2's floors are policed by two things outside `Scripts/icecubes-r2.sh`:
# `Scripts/validate-icecubes-close-policy.rb` parses `R2_FLOORS` as the
# open-debt stall series, and `Scripts/validate-anti-drift.sh` cross-checks
# `R2_SCREENS` against the gate's own count. NEITHER KNOWS THIS FILE EXISTS.
# Until they parse `R3_FLOORS`/`R3_SCENARIOS` the same way — treating
# `unmeasured` as UNREADABLE-AND-FAIL rather than as zero, which is the one
# way this table can lie to a stall detector — an R3 floor can sit still or be
# pasted without either instrument noticing. Do not read a green R3 stage as
# an R3 floor that anything is watching.
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
FIXTURES="$ROOT/Fixtures/mastodon-public-timeline"
# Worktree-local by default so concurrent lanes never clobber each other's
# captures; the per-scenario stdout lines carry the concrete paths.
TWIN_DIR="${ICECUBES_R3_TWIN_DIR:-$ROOT/.build/icecubes-r3-captures/native-twin}"
INTERP_DIR="${ICECUBES_R3_INTERP_DIR:-$ROOT/.build/icecubes-r3-captures/interpreted}"
TWIN_REPEAT_DIR="$TWIN_DIR-repeat"
INTERP_REPEAT_DIR="$INTERP_DIR-repeat"
# 2026-07-16T12:00:00Z, immediately after the recorded fixture was captured.
# The same instant R2 pins, so the two boards cannot disagree about "now".
FROZEN_NOW=1784203200
CLOCK_DIR="$ROOT/Examples/IceCubesNativeTwin/.build/frozen-clock"
# DELIBERATELY THE R2 PRODUCT PATH, AND DELIBERATELY THE R2 OVERRIDE. This
# board builds the SAME product with the SAME flags as Scripts/icecubes-r2.sh,
# so a second scratch path would buy nothing except a duplicate multi-minute
# macabi build on every gate. Sharing it makes this stage's build step a no-op
# whenever R2 already ran, and still correct standalone.
#
# The override CHAINS through `ICECUBES_R2_SCRATCH_PATH` because the sharing is
# the point: a lane that redirects R2's scratch path to isolate its build and
# leaves this one on the default would make the two stages build into different
# trees — which is not merely wasteful, it reintroduces the
# rebuild-during-a-prebuilt-test-run trap from the other direction, with each
# stage relinking a product the other is executing.
INTERP_SCRATCH_PATH="${ICECUBES_R3_SCRATCH_PATH:-${ICECUBES_R2_SCRATCH_PATH:-$ROOT/.build/icecubes-r2-product}}"
INTERP_BUILD_DIR="$INTERP_SCRATCH_PATH/arm64-apple-ios-macabi/debug"
INTERP_BINARY="$INTERP_BUILD_DIR/IceCubesCheck"
INTERP_APP="$INTERP_BUILD_DIR/IceCubesCheck.app"
INTERP_EXECUTABLE="$INTERP_APP/Contents/MacOS/IceCubesCheck"

TWIN_SOURCE="$ROOT/Examples/IceCubesNativeTwin/Sources/IceCubesNativeTwin/IceCubesNativeTwin.swift"
INTERP_SOURCE="$ROOT/Sources/IceCubesCheck/IceCubesCheck.swift"

# The scored scenarios, in capture order. ONE list, for the reason R2 states
# about its screens: a scenario captured but never scored is indistinguishable
# from a scenario that converged.
#
# Each id is `<base screen>-<what the mutation does>`, and the base screen is
# ALWAYS one the R2 board already holds at AE 0 on both sides — that is what
# makes a red here a statement about the interaction rather than about the
# screen it starts from.
R3_SCENARIOS=(display-settings-system-color-off timeline-status-actions-hidden)

# The three scored quantities per scenario, as id suffixes. Named once so the
# floor table, the two consistency loops and the scoring loop cannot disagree
# about how many there are.
R3_SUFFIXES=("-base" "" "-changed-delta")

# ── THE SHARED-STATE LOCK ─────────────────────────────────────────────────────
# This stage shares three mutable paths with Scripts/icecubes-r2.sh: the macabi
# scratch path above (`INTERP_SCRATCH_PATH`, and the `.app` bundle rebuilt and
# re-codesigned inside it), `Examples/IceCubesNativeTwin/.build`, and the frozen
# clock dylib in `$CLOCK_DIR` that both stages inject into every capture
# process. Two of those are being WRITTEN while the other stage may be
# EXECUTING them, which is the rebuild-during-a-prebuilt-test-run trap; and
# even where nothing is rewritten, two capture processes racing through the
# window server is the measured 141k-AE nondeterminism this board's
# reproducibility gate exists to reject.
#
# So the precondition is enforced rather than documented. HONEST LIMIT: this
# only excludes another R3 run, because Scripts/icecubes-r2.sh does not take
# the lock yet — that is a one-line addition on that side, and until it lands a
# concurrent R2 stage is still invisible here. Check `ps ax | grep lane-gate`
# before running standalone.
#
# Taken AFTER the source-only check below, never before it: that check reads two
# `.swift` files and touches nothing shared, so making it queue behind a running
# capture would be pure obstruction — and worse, it would hold the lock against
# a capture that has real work to do.
SHARED_LOCK="${ICECUBES_CAPTURE_LOCK:-$ROOT/.build/icecubes-capture.lock}"
take_shared_capture_lock() {
  local lock_owner lock_pid
  mkdir -p "$(dirname "$SHARED_LOCK")"
  if mkdir "$SHARED_LOCK" 2>/dev/null; then
    print -r -- "pid=$$ started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      > "$SHARED_LOCK/owner"
    return 0
  fi
  lock_owner="$(cat "$SHARED_LOCK/owner" 2>/dev/null)"
  lock_pid="${lock_owner%% *}"
  lock_pid="${lock_pid#pid=}"
  # A lock whose owner is gone is a crash residue, not a running stage, and
  # leaving it would wedge every later run behind a process that no longer
  # exists. Reclaiming it is safe precisely because the owner is dead.
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "IceCubes R3: SHARED-CAPTURE-LOCK-HELD — $SHARED_LOCK is owned by" \
      "$lock_owner, which is still running. This stage rebuilds and" \
      "re-codesigns $INTERP_SCRATCH_PATH and injects" \
      "$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib, both of which the" \
      "holder may be executing; running anyway fakes a regression nobody can" \
      "reproduce. Wait for it, or point ICECUBES_R3_SCRATCH_PATH and" \
      "ICECUBES_CAPTURE_LOCK somewhere private." >&2
    exit 2
  fi
  echo "IceCubes R3: reclaiming stale $SHARED_LOCK (owner '$lock_owner' is" \
    "not running)" >&2
  rm -rf "$SHARED_LOCK"
  if ! mkdir "$SHARED_LOCK" 2>/dev/null; then
    echo "IceCubes R3: SHARED-CAPTURE-LOCK-HELD — could not take" \
      "$SHARED_LOCK after reclaiming it" >&2
    exit 2
  fi
  print -r -- "pid=$$ started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    > "$SHARED_LOCK/owner"
}

# ── THE TWO SIDES MUST DRIVE THE SAME CALL, CHECKED WITHOUT RUNNING ANYTHING ──
# The runtime check further down compares the two RECORDED statements, and that
# is only half an assertion: the interpreted side records the source text it
# actually executes, but the twin records a DESCRIPTION while `driveScenario`
# executes a separately written literal. Comparing those compares a description
# against real source, and the twin's two halves can drift apart with every
# capture, every AE and every exit code unchanged.
#
# This closes it statically. `driveScenario`'s per-case convention — enforced
# here, not merely hoped for — is that the mutation is the LAST statement of
# the case body and occupies ONE line. Under that convention the executed
# statement is extractable from the source, and it must equal both the twin's
# `mutationDescription` and the interpreted side's `mutationStatement`.
#
# Runnable on its own, no build, no capture:
#
#     Scripts/icecubes-r3.sh --check-scenarios
#
# A failure here is never a floor to move: it means the board is about to
# report a number about two different interactions.
scenario_string_table() {
  awk -v member="$2" -v kind="$3" '
    index($0, "var " member ": String {") { inblock = 1; next }
    inblock && /^    \}$/ { inblock = 0 }
    inblock && match($0, /case \.[A-Za-z0-9_]+:/) {
      name = substr($0, RSTART + 6, RLENGTH - 7); next
    }
    inblock && name != "" {
      line = $0
      sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      if (line == "" || line ~ /^\/\//) next
      if (line ~ /^".*"$/) {
        print kind "\t" name "\t" substr(line, 2, length(line) - 2)
        name = ""
      }
    }
  ' "$1"
}

scenario_executed_table() {
  awk '
    /private func driveScenario\(/ { infunc = 1 }
    infunc && /^        switch scenario \{$/ { insw = 1; next }
    insw && /^        \}$/ {
      if (name != "") print "executed\t" name "\t" last
      insw = 0; infunc = 0; name = ""
    }
    insw && /^        case \.[A-Za-z0-9_]+:$/ {
      if (name != "") print "executed\t" name "\t" last
      s = $0; sub(/^        case \./, "", s); sub(/:$/, "", s)
      name = s; last = ""; next
    }
    insw && name != "" {
      line = $0
      sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      if (line == "" || line ~ /^\/\//) next
      last = line
    }
  ' "$1"
}

scenario_raw_value_table() {
  awk -v ename="$2" -v kind="$3" '
    index($0, "enum " ename ": String") { inenum = 1; next }
    inenum && /^\}$/ { inenum = 0 }
    inenum && match($0, /^    case [A-Za-z0-9_]+ = ".*"$/) {
      s = $0; sub(/^    case /, "", s)
      split(s, part, " = ")
      id = part[2]; gsub(/"/, "", id)
      print kind "\t" part[1] "\t" id
    }
  ' "$1"
}

check_scenario_statements() {
  local verbose="${1:-quiet}"
  local -A twin_recorded twin_executed interp_recorded twin_raw interp_raw
  local kind name text case_name scenario_id
  while IFS=$'\t' read -r kind name text; do
    case "$kind" in
      twin-recorded) twin_recorded[$name]="$text" ;;
      executed) twin_executed[$name]="$text" ;;
      interp-recorded) interp_recorded[$name]="$text" ;;
      twin-raw) twin_raw[$name]="$text" ;;
      interp-raw) interp_raw[$name]="$text" ;;
    esac
  done < <(
    scenario_string_table "$TWIN_SOURCE" mutationDescription twin-recorded
    scenario_executed_table "$TWIN_SOURCE"
    scenario_string_table "$INTERP_SOURCE" mutationStatement interp-recorded
    scenario_raw_value_table "$TWIN_SOURCE" TwinCaptureScenario twin-raw
    scenario_raw_value_table "$INTERP_SOURCE" IceCubesCaptureScenario interp-raw
  )

  # An extractor that matched NOTHING would otherwise pass every equality
  # below by comparing empty sets, which is the exact way a static check
  # becomes decorative. Require each table to be non-empty first.
  local table
  for table in twin_recorded twin_executed interp_recorded twin_raw \
    interp_raw
  do
    if (( ${(P)#table} == 0 )); then
      echo "R3 board: the scenario source check extracted NOTHING for" \
        "'$table'. The Swift declarations moved; fix the extractor in" \
        "Scripts/icecubes-r3.sh rather than deleting the check — an empty" \
        "table makes every comparison below vacuously true." >&2
      return 2
    fi
  done

  # Every enum case, on both sides, in all four tables.
  local -a all_cases
  all_cases=("${(@k)twin_raw}" "${(@k)interp_raw}")
  all_cases=("${(@u)all_cases}")
  for case_name in "${(@)all_cases}"; do
    if [[ -z "${twin_raw[$case_name]+set}" \
      || -z "${interp_raw[$case_name]+set}" ]]; then
      echo "R3 board: scenario case '.$case_name' exists on only ONE side" \
        "(twin='${twin_raw[$case_name]-absent}'," \
        "interpreted='${interp_raw[$case_name]-absent}'). The two enums have" \
        "drifted apart." >&2
      return 2
    fi
    if [[ "${twin_raw[$case_name]}" != "${interp_raw[$case_name]}" ]]; then
      echo "R3 board: scenario case '.$case_name' has different ids —" \
        "twin '${twin_raw[$case_name]}' vs interpreted" \
        "'${interp_raw[$case_name]}'" >&2
      return 2
    fi
    if [[ -z "${twin_recorded[$case_name]+set}" \
      || -z "${twin_executed[$case_name]+set}" \
      || -z "${interp_recorded[$case_name]+set}" ]]; then
      echo "R3 board: scenario case '.$case_name' has no extractable" \
        "mutation statement (recorded='${twin_recorded[$case_name]-absent}'," \
        "executed='${twin_executed[$case_name]-absent}'," \
        "interpreted='${interp_recorded[$case_name]-absent}'). If the" \
        "mutation is no longer the LAST single-line statement of its" \
        "driveScenario case body, restore that shape — the check cannot" \
        "read a split statement and must not pretend to." >&2
      return 2
    fi
    if [[ "${twin_recorded[$case_name]}" \
      != "${twin_executed[$case_name]}" ]]; then
      echo "R3 board: the twin RECORDS a different statement than it" \
        "EXECUTES for '.$case_name' — mutationDescription" \
        "'${twin_recorded[$case_name]}' vs driveScenario" \
        "'${twin_executed[$case_name]}'. The board's runtime agreement check" \
        "compares recorded strings, so this drift would score two different" \
        "interactions and stay green." >&2
      return 2
    fi
    if [[ "${twin_recorded[$case_name]}" \
      != "${interp_recorded[$case_name]}" ]]; then
      echo "R3 board: '.$case_name' drives different statements on the two" \
        "sides — twin '${twin_recorded[$case_name]}' vs interpreted" \
        "'${interp_recorded[$case_name]}'" >&2
      return 2
    fi
    if [[ "$verbose" == verbose ]]; then
      print -r -- "${twin_raw[$case_name]}"$'\t'"${twin_recorded[$case_name]}"
    fi
  done

  # The scored list and the two enums must name the same scenarios: an id in
  # R3_SCENARIOS with no enum case fails at capture time anyway, but an enum
  # case with no scored id is a scenario that exists and is never measured.
  local -a enum_ids
  enum_ids=("${(@v)twin_raw}")
  for scenario_id in "${R3_SCENARIOS[@]}"; do
    if (( ${enum_ids[(Ie)$scenario_id]} == 0 )); then
      echo "R3 board: scored scenario '$scenario_id' is not declared by" \
        "TwinCaptureScenario/IceCubesCaptureScenario" >&2
      return 2
    fi
  done
  for scenario_id in "${enum_ids[@]}"; do
    if (( ${R3_SCENARIOS[(Ie)$scenario_id]} == 0 )); then
      echo "R3 board: scenario '$scenario_id' is declared by both binaries" \
        "but is never scored — an unscored scenario is indistinguishable" \
        "from a converged one" >&2
      return 2
    fi
  done
  return 0
}

if [[ "${1-}" == "--check-scenarios" ]]; then
  check_scenario_statements verbose || exit 2
  echo "R3 board: scenario statements agree (recorded == executed == emitted)"
  exit 0
fi
check_scenario_statements || exit 2

# The trap is installed HERE, at top level, and not inside
# `take_shared_capture_lock`: in zsh a `trap` set inside a function is scoped to
# that function and fires when it RETURNS, which would delete the lock
# immediately and silently.
take_shared_capture_lock
trap 'rm -rf "$SHARED_LOCK"' EXIT INT TERM

mkdir -p "$TWIN_DIR" "$INTERP_DIR" "$TWIN_REPEAT_DIR" "$INTERP_REPEAT_DIR"
for capture_dir in \
  "$TWIN_DIR" "$TWIN_REPEAT_DIR" "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
  for scenario in "${R3_SCENARIOS[@]}"; do
    # `.tree` is cleared with the rest, exactly as R2 does: a geometry dump
    # left over from an earlier run is indistinguishable from this run's, and a
    # stale one is read as evidence about the capture sitting next to it.
    rm -f "$capture_dir/$scenario.png" "$capture_dir/$scenario-base.png" \
      "$capture_dir/$scenario.json" "$capture_dir/$scenario.log" \
      "$capture_dir/$scenario.tree" "$capture_dir/$scenario-base.tree"
  done
done

echo "── native IceCubes twin ──"
(
  cd Examples/IceCubesNativeTwin || exit 2
  ./build.sh
) || exit 2

run_twin_scenario() {
  local scenario="$1"
  local twin_out="$2"
  (
    cd Examples/IceCubesNativeTwin || exit 2
    ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
    DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
    .build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin.app/Contents/MacOS/IceCubesNativeTwin \
      --out "$twin_out" --fixtures "$FIXTURES" --scenario "$scenario" \
      -ApplePersistenceIgnoreState YES
  )
}

echo "── interpreted IceCubes ──"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_FRAMEWORKS="$SDK/System/iOSSupport/System/Library/Frameworks"
IOS_LIBS="$SDK/System/iOSSupport/usr/lib"
xcrun swift build \
  --scratch-path "$INTERP_SCRATCH_PATH" \
  --product IceCubesCheck \
  --triple arm64-apple-ios18.0-macabi \
  -Xcc -target -Xcc arm64-apple-ios18.0-macabi \
  -Xswiftc -target -Xswiftc arm64-apple-ios18.0-macabi \
  -Xswiftc -F -Xswiftc "$IOS_FRAMEWORKS" \
  -Xswiftc -I -Xswiftc "$IOS_LIBS/swift" \
  -Xlinker -F -Xlinker "$IOS_FRAMEWORKS" \
  -Xlinker -L -Xlinker "$IOS_LIBS" || exit 2
mkdir -p "$INTERP_APP/Contents/MacOS"
cp "$INTERP_BINARY" "$INTERP_EXECUTABLE"
cp "$ROOT/Scripts/IceCubesCheck-Info.plist" \
  "$INTERP_APP/Contents/Info.plist"
codesign --force --sign - "$INTERP_APP" >/dev/null || exit 2

# No `--native-fixtures`: both base screens are built from the checked-in
# recordings (`timeline`) or from the environment alone (`display-settings`),
# so neither reads anything the twin prepares. Adding a scenario whose base
# screen DOES need them (`status-detail`, `account-header`) has to pass it,
# and `IceCubesCheck` fails loudly rather than capturing without.
capture_interpreted_scenario() {
  local scenario="$1"
  local out_dir="$2"
  ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
  SWIFT_DETERMINISTIC_HASHING=1 \
  DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
  "$INTERP_EXECUTABLE" --capture "$out_dir" --scenario "$scenario" \
    -ApplePersistenceIgnoreState YES \
    > "$out_dir/$scenario.log" 2>&1
}

# Captures run STRICTLY SERIALLY, for the reason measured on the R2 board:
# parallel capture processes contend for the window server, `drawHierarchy`
# takes a different snapshot path per run, and two passes of the same binary on
# the same fixtures differ by 141k+ AE. Do not add a `&`.
#
# Only a PROVEN-REPRODUCIBLE scenario may be scored, and here that means BOTH
# of its captures: a base that wobbles would make the changed-guard's delta
# meaningless just as surely as a post-mutation frame that does. A bounded
# number of fresh attempts absorbs transient window-server perturbation and a
# capture process that dies; persistent divergence fails every attempt and
# exits loudly. Retrying cannot weaken the metric — the pair still has to match
# at AE 0 — and the retry lives HERE, capped: never loop the script until a red
# goes green, and never answer this red by moving a floor.
capture_reproducible_scenario() {
  local side="$1"
  local scenario="$2"
  local primary_dir repeat_dir out_dir attempt capture_status name
  local failure="diverged" determinism_line compare_status
  local capture_died diverged
  case "$side" in
    twin) primary_dir="$TWIN_DIR"; repeat_dir="$TWIN_REPEAT_DIR" ;;
    interpreted) primary_dir="$INTERP_DIR"; repeat_dir="$INTERP_REPEAT_DIR" ;;
    *) echo "unknown capture side '$side'" >&2; exit 2 ;;
  esac
  for attempt in 1 2 3; do
    capture_died=0
    for out_dir in "$primary_dir" "$repeat_dir"; do
      if [[ "$side" == twin ]]; then
        run_twin_scenario "$scenario" "$out_dir"
      else
        capture_interpreted_scenario "$scenario" "$out_dir"
      fi
      capture_status=$?
      if (( capture_status != 0 )); then
        if [[ "$side" == interpreted ]]; then
          cat "$out_dir/$scenario.log"
        fi
        echo "$side $scenario capture failed with status" \
          "$capture_status (attempt $attempt)" >&2
        capture_died=1
        failure="died"
        break
      fi
    done
    if (( capture_died )); then
      continue
    fi
    diverged=0
    for name in "$scenario-base" "$scenario"; do
      determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
        "$primary_dir/$name.png" "$repeat_dir/$name.png")"
      compare_status=$?
      # Exit 2 is NOT divergence and must not be retried as if it were. It
      # means the two PNGs disagree on size or colour encoding, or one is
      # unreadable — a finding about the harness, mirroring `score_pair`. The
      # retry loop would otherwise burn two more capture passes and then
      # report CAPTURE-NONDETERMINISM, sending the reader to the settle logic
      # for a format mismatch that settling cannot touch.
      if (( compare_status == 2 )); then
        echo "$side $name R3 board: pixel comparison failed —" \
          "$determinism_line (size/format mismatch or unreadable capture," \
          "between two captures from the SAME binary; neither may be" \
          "normalized away)" >&2
        exit 2
      fi
      if (( compare_status != 0 )); then
        echo "$side $name capture pair diverged" \
          "(attempt $attempt: $determinism_line)"
        diverged=1
        failure="diverged"
        break
      fi
    done
    if (( diverged == 0 )); then
      return 0
    fi
  done
  if [[ "$failure" == died ]]; then
    echo "$side $scenario CAPTURE-DEATH: no capture survived 3 attempts —" \
      "fix the capture, not the floor" >&2
  else
    echo "$side $scenario CAPTURE-NONDETERMINISM: no reproducible capture" \
      "pair in 3 attempts — fix the capture, not the floor" >&2
  fi
  exit 2
}

for scenario in "${R3_SCENARIOS[@]}"; do
  capture_reproducible_scenario twin "$scenario"
  capture_reproducible_scenario interpreted "$scenario"
  cat "$INTERP_DIR/$scenario.log"
done

# THE TWO SIDES MUST HAVE DRIVEN THE SAME CALL. The static check at the top of
# this script proves the twin executes the statement it records; this proves
# the two RUNS agreed on which statement that was. Without it, the enums
# drifting apart still produces two captures, still scores an AE, and reports a
# number about two different interactions.
#
# THE REVISION-ADVANCE PRECONDITION, which is what makes the changed-guard an
# instrument rather than a coin flip. `InterpreterCaptureReadiness` becomes
# ready on its FIRST sample when the runtime is already quiescent, and it
# admits a revision EQUAL to the one it was initialized with — exactly the
# state a synchronous `callClosure` leaves behind. A post-mutation wait built
# only from it is therefore a fixed settle that asserts nothing about the
# interpreter having re-rendered, and both processes of the reproducibility
# pair run that same race under the same load, so they AGREE, the pair is
# certified, and the changed-guard prints "the mutation was ABSORBED" for a
# timing reason — the board reporting its headline defect when nothing is
# wrong. So the interpreted harness reads the body-evaluation revision
# immediately BEFORE the mutation, waits (bounded) for it to strictly exceed
# that value, and records BOTH numbers. If it never advanced, the pixels cannot
# distinguish "the interpreter absorbed the mutation" from "the harness read
# the frame before the interpreter got to it", so the scenario is REFUSED
# rather than scored.
#
# The clock assertions are the R2 doctrine restated so this stage can stand
# alone, and they are a PAIR because either one alone has been green over a
# real bug: the EPOCH check catches an unfrozen `Date()`, and the relative
# drift check catches `timeIntervalSinceNow` computing its own "now" inside
# Foundation — which it did for weeks with the epoch check green the whole
# time. `display-settings` draws a relative timestamp, so this board would
# inherit that bug. (The interpreted side also records `hostClockEpoch`; it is
# deliberately NOT asserted, because nothing has ever measured it and an
# invariant asserted before it is measured is a guess that reds a lane.)
for scenario in "${R3_SCENARIOS[@]}"; do
  twin_metadata="$TWIN_DIR/$scenario.json"
  interp_metadata="$INTERP_DIR/$scenario.json"
  for metadata in "$twin_metadata" "$interp_metadata"; do
    if [[ ! -f "$metadata" ]]; then
      echo "$scenario R3 board: missing scenario metadata $metadata — the" \
        "driver did not report what it drove" >&2
      exit 2
    fi
  done
  twin_epoch="$(jq -r '.clockEpoch' "$twin_metadata")"
  if [[ "$twin_epoch" != "$FROZEN_NOW" ]]; then
    echo "$scenario native frozen clock mismatch: wanted $FROZEN_NOW, got" \
      "$twin_epoch" >&2
    exit 2
  fi
  interp_epoch="$(jq -r '.interpretedClockEpoch' "$interp_metadata")"
  if [[ "$interp_epoch" != "$FROZEN_NOW" ]]; then
    echo "$scenario interpreted frozen clock mismatch: wanted $FROZEN_NOW," \
      "got $interp_epoch" >&2
    exit 2
  fi
  if ! jq -e '.relativeClockDrift == 0' "$twin_metadata" >/dev/null; then
    echo "$scenario native relative clock is not frozen:" \
      "$(jq -r '.relativeClockDrift' "$twin_metadata"), wanted exactly 0 —" \
      "a wall-clock source is leaking past the frozen instant" >&2
    exit 2
  fi
  if ! jq -e '.interpretedRelativeClockDrift == 0' "$interp_metadata" \
    >/dev/null; then
    echo "$scenario interpreted relative clock is not frozen:" \
      "$(jq -r '.interpretedRelativeClockDrift' "$interp_metadata")," \
      "wanted exactly 0 — a wall-clock source is leaking past the frozen" \
      "instant" >&2
    exit 2
  fi
  if ! jq -e '
    (.preMutationRenderRevision | type) == "number"
    and (.postMutationRenderRevision | type) == "number"
  ' "$interp_metadata" >/dev/null; then
    echo "$scenario R3 board: the interpreted metadata carries no render" \
      "revision pair — this stage cannot tell an absorbed mutation from a" \
      "frame read too early without it" >&2
    exit 2
  fi
  if ! jq -e '.postMutationRenderRevision > .preMutationRenderRevision' \
    "$interp_metadata" >/dev/null; then
    echo "$scenario R3 board: REVISION-STALLED — the interpreted body" \
      "evaluation count did not advance across the mutation" \
      "(pre=$(jq -r '.preMutationRenderRevision' "$interp_metadata")," \
      "post=$(jq -r '.postMutationRenderRevision' "$interp_metadata"))." \
      "The post-mutation capture is therefore a frame the interpreter never" \
      "re-rendered into, and its pixels cannot distinguish an ABSORBED" \
      "mutation from a capture taken too early. REFUSED, not scored: fix" \
      "the invalidation or the wait, never a floor." >&2
    exit 2
  fi
  twin_mutation="$(jq -r '.mutation' "$twin_metadata")"
  interp_mutation="$(jq -r '.mutation' "$interp_metadata")"
  if [[ "$twin_mutation" != "$interp_mutation" ]]; then
    echo "$scenario R3 board: the two sides drove DIFFERENT mutations —" \
      "twin '$twin_mutation' vs interpreted '$interp_mutation'. Fix the" \
      "scenario tables in IceCubesNativeTwin.swift and IceCubesCheck.swift" \
      "so they name one statement; the AE below would be a number about two" \
      "different interactions." >&2
    exit 2
  fi
  twin_base="$(jq -r '.baseScreen' "$twin_metadata")"
  interp_base="$(jq -r '.baseScreen' "$interp_metadata")"
  if [[ "$twin_base" != "$interp_base" ]]; then
    echo "$scenario R3 board: the two sides started from DIFFERENT base" \
      "screens — twin '$twin_base' vs interpreted '$interp_base'" >&2
    exit 2
  fi
done

echo "── R3 AE board ──"
# Ratchet floors, THREE per scenario:
#
#  - `<scenario>-base` — the cross-side AE of the PRE-mutation capture. NOT
#    ratchetable and NOT `unmeasured`: it is pinned to the literal 0, because
#    the entire admissibility argument for a scenario is that its base screen
#    is already proven at AE 0 on both sides by the R2 board. If this reads
#    nonzero the premise is false — most likely because the merged program this
#    board builds differs from R2's — and the fix is to make it zero, never to
#    paste whatever it measured. A pasted base floor would silently convert a
#    base-screen regression into the interaction's budget.
#  - `<scenario>` — the cross-side AE of the POST-mutation capture. This is the
#    interaction fidelity number, and the one that ratchets.
#  - `<scenario>-changed-delta` — `|twinΔ − interpΔ|`, where each Δ is a side
#    diffed against ITSELF pre- vs post-mutation. Zero means the interpreted
#    screen changed by exactly as many pixels as the native one did; a nonzero
#    value is the PARTIALLY absorbed mutation that the `interpΔ == 0` guard
#    cannot see. Ratchets like any other floor.
#
# THE FOUR RATCHETABLE FLOORS BELOW (two scenarios × two ratcheting
# quantities) ARE ALL `unmeasured`, AND THAT IS DELIBERATE.
# Nothing in this tree has ever been run: this board was written under an
# explicit prohibition on building, running or capturing (a close gate was
# running on the machine, and competing load had already produced two false
# reds that day). A number here would therefore be a constant chosen to make
# the board green rather than a measurement — the AGENTS.md §4 payload
# violation exactly: "a constant calibrated by measuring the compiled target is
# the same violation as `case \"someAPI\"`", and a constant calibrated by
# measuring NOTHING is worse, because it also cannot be reproduced. The board
# refuses to score an `unmeasured` pair and exits 2 printing the measurement it
# just took, so the only way a floor can appear here is by pasting a number the
# board itself produced.
#
# TO ADMIT THESE SCENARIOS, on an otherwise IDLE machine (no gate running —
# check `ps ax | grep lane-gate` first, and see the in-flight-gate trap: a
# concurrent R2 stage races these captures through the window server):
#
#     Scripts/icecubes-r3.sh
#
# then paste each printed "first measurement is N" into the table below, in ONE
# commit, with a comment saying what the number is made of — the way every
# screen in `R2_FLOORS` was admitted. A scenario entering at a large number is
# not a failure to hide; it is the honest first measurement of a surface that
# had none, and the comment is where its decomposition goes. The `-base` rows
# are NOT part of that admission: they are pinned at 0 and enforced below.
typeset -A R3_FLOORS
R3_FLOORS=(
  # `DisplaySettingsView`'s own theme toggle, driven as
  # `Theme.shared.followSystemColorScheme = false` — the model write its
  # `Toggle("settings.display.theme.systemColor", isOn:
  # $theme.followSystemColorScheme)` performs.
  #
  # Why it is admissible: the mutation is the app's own model API on both
  # sides; it is a pure function of the environment, so it needs no network, no
  # auth and no clock beyond the pins already in place; and it VISIBLY changes
  # the captured viewport in two independent places — the theme section's
  # footer is `if theme.followSystemColorScheme { Text(…) }`, so a row leaves a
  # grouped `Form` and everything below it shifts, and the four `ColorPicker`s
  # are `.disabled(theme.followSystemColorScheme)` +
  # `.opacity(theme.followSystemColorScheme ? 0.5 : 1.0)`, so they undim. Both
  # are inside the 900x700 capture: they are the exact pixels the
  # `display-settings` screen was admitted to the R2 board to score.
  #
  # TWO independent regions is also why this scenario needs the
  # `-changed-delta` floor: an interpreter that shifts the footer and never
  # undims the pickers produces a nonzero `interpΔ` and passes a zero test.
  display-settings-system-color-off unmeasured
  # PINNED TO 0, NOT RATCHETABLE. The base capture is the `display-settings`
  # screen, which the R2 board holds at AE 0. Anything else is a base
  # regression to fix.
  display-settings-system-color-off-base 0
  display-settings-system-color-off-changed-delta unmeasured
  # The display-settings action-buttons picker, driven as
  # `Theme.shared.statusActionsDisplay = Theme.StatusActionsDisplay.none` — the
  # model write `Picker("settings.display.status.action-buttons", selection:
  # $theme.statusActionsDisplay)` performs — but OBSERVED ON THE TIMELINE.
  #
  # Why it is worth its capture time even though the mutation looks like the
  # one above: it is the only comparison on either board where a change to an
  # `@Observable` singleton has to invalidate a `List` of rows that never
  # mention the screen the control lives on. `StatusRowView` reads
  # `theme.statusActionsDisplay` directly (StatusKit/Row/StatusRowView.swift:107),
  # so selecting `.none` drops the action bar out of every non-focused row and
  # the whole list re-lays out — a large, unambiguous pixel change on the
  # highest-value base screen the board has.
  timeline-status-actions-hidden unmeasured
  # PINNED TO 0, NOT RATCHETABLE. The base capture is the `timeline` screen,
  # the LOOP's headline R2 metric, which sits at AE 0. Same reading as above.
  timeline-status-actions-hidden-base 0
  timeline-status-actions-hidden-changed-delta unmeasured
)
# A pair captured but unscored is indistinguishable from a pair that converged,
# so the two tables must name exactly the same quantities — in both directions.
for scenario in "${R3_SCENARIOS[@]}"; do
  for suffix in "${R3_SUFFIXES[@]}"; do
    name="$scenario$suffix"
    if [[ -z "${R3_FLOORS[$name]+set}" ]]; then
      echo "R3 board: '$name' is captured but carries no floor" >&2
      exit 2
    fi
  done
  # The base floor is a PREMISE, not a budget. Enforced so that the obvious
  # wrong move — pasting the first measurement here the way the two ratcheting
  # floors are admitted — fails loudly instead of turning a base-screen
  # regression into headroom for the interaction.
  if [[ "${R3_FLOORS[$scenario-base]}" != 0 ]]; then
    echo "R3 board: the '$scenario-base' floor is" \
      "'${R3_FLOORS[$scenario-base]}', not 0. The base screen is the R2" \
      "screen this scenario starts from and R2 holds it at AE 0; a nonzero" \
      "base is a regression to fix, never a floor to paste." >&2
    exit 2
  fi
done
for name in "${(@k)R3_FLOORS}"; do
  scored=0
  for scenario in "${R3_SCENARIOS[@]}"; do
    for suffix in "${R3_SUFFIXES[@]}"; do
      if [[ "$name" == "$scenario$suffix" ]]; then
        scored=1
      fi
    done
  done
  if (( scored == 0 )); then
    echo "R3 board: '$name' carries a floor but is never captured" >&2
    exit 2
  fi
done

# Scoring writes into these rather than returning, because a `$( )` subshell
# would swallow the `exit 2` a size/format mismatch has to produce.
AE_COUNT=""
AE_LINE=""
score_pair() {
  local left="$1" right="$2" label="$3" compare_status image
  for image in "$left" "$right"; do
    if [[ ! -f "$image" ]]; then
      echo "$label R3 board: missing capture $image" >&2
      exit 2
    fi
  done
  AE_LINE="$(xcrun swift Scripts/pixel-ae.swift "$left" "$right")"
  compare_status=$?
  if (( compare_status == 2 )); then
    echo "$label R3 board: pixel comparison failed — $AE_LINE (size/format" \
      "mismatch or unreadable capture; both are findings about the harnesses" \
      "and neither may be normalized away)" >&2
    exit 2
  fi
  AE_COUNT="$(print -r -- "$AE_LINE" | sed -E 's/^AE ([0-9]+) of .*/\1/')"
  if [[ ! "$AE_COUNT" == <-> ]]; then
    echo "$label R3 board: could not parse AE count from '$AE_LINE'" >&2
    exit 2
  fi
}

integer board_red=0 board_below=0 board_unmeasured=0
integer board_guard=0 board_inert=0

# One verdict rule for all three scored quantities. Two copies of a ratchet
# rule is how one quantity silently keeps a different one than the others.
report_against_floor() {
  local name="$1" detail="$2"
  integer value="$3"
  local floor="${R3_FLOORS[$name]}"
  print -r -- "$name"$'\t'"$detail"$'\t'"floor=$floor"
  if [[ "$floor" == unmeasured ]]; then
    echo "═══ $name R3 board: UNMEASURED — first measurement is $value;" \
      "commit that number as this quantity's floor in" \
      "Scripts/icecubes-r3.sh, with what it is made of ═══"
    (( board_unmeasured += 1 ))
  elif (( value > floor )); then
    if [[ "$name" == *-base ]]; then
      echo "═══ $name R3 board: BASE REGRESSED — AE $value, and the base" \
        "screen is the R2 screen this scenario starts from, which R2 holds" \
        "at AE 0. The interaction number beside it is measuring the wrong" \
        "thing until this is 0. Do NOT paste this number as a floor ═══"
    else
      echo "═══ $name R3 board: OVER FLOOR — $value > $floor (regression) ═══"
    fi
    (( board_red += 1 ))
  elif (( value < floor )); then
    echo "═══ $name R3 board: BELOW FLOOR — ratchet $floor to $value in this" \
      "commit ═══"
    (( board_below += 1 ))
  else
    echo "═══ $name R3 board: AT FLOOR — $value == $floor ═══"
  fi
}

for scenario in "${R3_SCENARIOS[@]}"; do
  # The two cross-side comparisons: the base screen, then the interaction.
  for name in "$scenario-base" "$scenario"; do
    score_pair "$TWIN_DIR/$name.png" "$INTERP_DIR/$name.png" "$name"
    report_against_floor "$name" "$AE_LINE" "$AE_COUNT"
  done

  # THE CHANGED-GUARD. Each side is diffed against ITSELF, pre- against
  # post-mutation, and the two verdicts must agree.
  score_pair "$TWIN_DIR/$scenario-base.png" "$TWIN_DIR/$scenario.png" \
    "$scenario twin-delta"
  integer twin_delta=$AE_COUNT
  score_pair "$INTERP_DIR/$scenario-base.png" "$INTERP_DIR/$scenario.png" \
    "$scenario interp-delta"
  integer interp_delta=$AE_COUNT
  print -r -- "$scenario"$'\t'"twinΔ=$twin_delta"$'\t'"interpΔ=$interp_delta"
  driven_mutation="$(jq -r '.mutation' "$TWIN_DIR/$scenario.json")"
  if (( twin_delta == 0 )); then
    # The NATIVE app did not change. Nothing about the interpreter is being
    # tested any more, and the AE above is two unchanged screens agreeing —
    # which would read as a converged interaction forever. This is a broken
    # scenario, so it exits like a broken capture rather than like a fidelity
    # red: fix the scenario, do not move a floor.
    echo "═══ $scenario R3 board: SCENARIO-INERT — the twin's own screen is" \
      "byte-identical before and after '$driven_mutation'. The mutation no" \
      "longer changes the compiled app, so this scenario asserts nothing;" \
      "fix or retire it ═══"
    (( board_inert += 1 ))
  elif (( interp_delta == 0 )); then
    echo "═══ $scenario R3 board: CHANGED-GUARD FAILED — the twin's screen" \
      "changed by $twin_delta px and the interpreted screen did not change" \
      "at all. The mutation was ABSORBED: the interpreted capture is its own" \
      "base screen a second time, which is why the cross-side AE above can" \
      "look healthy. The interpreted body-evaluation revision DID advance" \
      "across the mutation (asserted above), so this is the interpreter" \
      "rendering the same pixels, not the harness reading too early ═══"
    (( board_guard += 1 ))
  fi
  # The magnitude relation, scored whether or not the zero test fired: at
  # perfect fidelity the interpreted screen changes by exactly as many pixels
  # as the native one, so this converges to 0 and every value above it is
  # mutation the interpreter did not fully apply. Computed as an absolute
  # difference because either direction is a defect — changing MORE than the
  # native app is not credit.
  integer changed_delta_skew=$(( twin_delta > interp_delta \
    ? twin_delta - interp_delta : interp_delta - twin_delta ))
  report_against_floor "$scenario-changed-delta" \
    "|twinΔ-interpΔ| $changed_delta_skew" "$changed_delta_skew"
done

# One machine-readable line for the gate receipt. `scenarios` is the
# DENOMINATOR and every must-be-zero counter is on it, so a scenario deleted
# rather than fixed cannot read as green. `below` is LAST and floats on
# purpose: pinning it would make the first genuine interpreter IMPROVEMENT red
# the gate contract while this script exits 0 — the ratchet-value-pinned-in-tests
# trap. Keep `below=` last, and keep the gate's pattern anchored on the fields
# before it.
print -r -- "@@icecubes-r3 scenarios=${#R3_SCENARIOS[@]}" \
  "red=$board_red unmeasured=$board_unmeasured inert=$board_inert" \
  "guard=$board_guard below=$board_below"

if (( board_inert != 0 )); then
  echo "═══ IceCubes R3 board: SCENARIO-INERT — a scenario stopped changing" \
    "the compiled app; fix the scenario, not the floor ═══"
  exit 2
fi
if (( board_unmeasured != 0 )); then
  echo "═══ IceCubes R3 board: UNMEASURED FLOORS — admit each quantity at" \
    "the measurement printed above, in one commit ═══"
  exit 2
fi
if (( board_red != 0 || board_guard != 0 )); then
  exit 1
fi
if (( board_below != 0 )); then
  echo "═══ IceCubes R3 board: GREEN below at least one floor; commit the" \
    "tighter floor ═══"
  exit 0
fi
echo "═══ IceCubes R3 board: GREEN at all floors, mutations visible on both" \
  "sides ═══"
exit 0
