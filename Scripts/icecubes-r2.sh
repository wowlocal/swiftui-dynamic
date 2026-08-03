#!/bin/zsh
# Capture compiled Catalyst and interpreted IceCubes screens from the same
# recorded Mastodon bytes, then enforce each screen's exact per-pixel AE.
#
# Determinism contract: every scored screen is captured TWICE per side and the
# two passes must be pixel-identical (AE 0, no fuzz) before the board scores
# anything. A floor delta can then only mean interpreter fidelity moved —
# never spinner phase, settle timing, or machine load (the 2026-07-30 noise
# band was ~17-33k AE, larger than several committed ratchet ticks).
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
FIXTURES="$ROOT/Fixtures/mastodon-public-timeline"
# Worktree-local by default so concurrent lanes never clobber each other's
# captures; the per-screen stdout lines carry the concrete paths.
TWIN_DIR="${ICECUBES_R2_TWIN_DIR:-$ROOT/.build/icecubes-r2-captures/native-twin}"
INTERP_DIR="${ICECUBES_R2_INTERP_DIR:-$ROOT/.build/icecubes-r2-captures/interpreted}"
TWIN_REPEAT_DIR="$TWIN_DIR-repeat"
INTERP_REPEAT_DIR="$INTERP_DIR-repeat"
# 2026-07-16T12:00:00Z, immediately after the recorded fixture was captured.
FROZEN_NOW=1784203200
CLOCK_DIR="$ROOT/Examples/IceCubesNativeTwin/.build/frozen-clock"
INTERP_SCRATCH_PATH="${ICECUBES_R2_SCRATCH_PATH:-$ROOT/.build/icecubes-r2-product}"
INTERP_BUILD_DIR="$INTERP_SCRATCH_PATH/arm64-apple-ios-macabi/debug"
INTERP_BINARY="$INTERP_BUILD_DIR/IceCubesCheck"
INTERP_APP="$INTERP_BUILD_DIR/IceCubesCheck.app"
INTERP_EXECUTABLE="$INTERP_APP/Contents/MacOS/IceCubesCheck"
mkdir -p "$TWIN_DIR" "$INTERP_DIR" "$TWIN_REPEAT_DIR" "$INTERP_REPEAT_DIR"
for capture_dir in "$TWIN_DIR" "$TWIN_REPEAT_DIR"; do
  rm -f \
    "$capture_dir/timeline.png" \
    "$capture_dir/status-detail.png" \
    "$capture_dir/account-header.png" \
    "$capture_dir/media.png" \
    "$capture_dir/timeline.json"
done
for capture_dir in "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
  rm -f \
    "$capture_dir/timeline.png" \
    "$capture_dir/status-detail.png" \
    "$capture_dir/account-header.png" \
    "$capture_dir/timeline.json" \
    "$capture_dir/timeline.log" \
    "$capture_dir/status-detail.log" \
    "$capture_dir/account-header.log"
done

echo "── native IceCubes twin ──"
(
  cd Examples/IceCubesNativeTwin || exit 2
  ./build.sh
) || exit 2

run_twin_screen() {
  local screen="$1"
  local twin_out="$2"
  (
    cd Examples/IceCubesNativeTwin || exit 2
    ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
    DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
    .build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin.app/Contents/MacOS/IceCubesNativeTwin \
      --out "$twin_out" --fixtures "$FIXTURES" --screen "$screen" \
      -ApplePersistenceIgnoreState YES
  )
}

# Only a PROVEN-REPRODUCIBLE capture may be scored: each side captures twice
# and the pair must match exactly. A bounded number of fresh pairs absorbs
# transient window-server perturbation from unrelated lane activity on the
# same machine (`drawHierarchy` snapshots through the compositor); persistent
# divergence — a live animation, a settle bug — fails every attempt and exits
# loudly. The retry lives HERE, capped: never loop the script itself until a
# red goes green, and never answer this red by moving a floor.
#
# A capture process that DIES is retried by the same bounded loop rather than
# aborting the board on first sight. Measured 2026-08-03: a full gate lost the
# interpreted account-header capture to a launch-time death that wrote a
# zero-byte log, while the same screen captured cleanly 8/8 at idle and in a
# solo board run on the same binary — a transient the window server loses, not
# a divergence. Retrying cannot weaken the metric: the pair still has to match
# at AE 0 before anything is scored, so a retried capture can only produce the
# same pixels or fail again. Persistent death exhausts the attempts and exits
# loudly with the real status.
twin_reproducible=0
twin_failure="diverged"
for attempt in 1 2 3; do
  twin_diverged=0
  for screen in timeline status-detail account-header; do
    run_twin_screen "$screen" "$TWIN_DIR"
    twin_status=$?
    if (( twin_status == 0 )); then
      run_twin_screen "$screen" "$TWIN_REPEAT_DIR"
      twin_status=$?
    fi
    if (( twin_status != 0 )); then
      echo "twin $screen capture failed with status $twin_status" \
        "(attempt $attempt)" >&2
      twin_diverged=1
      twin_failure="died"
      break
    fi
    determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
      "$TWIN_DIR/$screen.png" "$TWIN_REPEAT_DIR/$screen.png")"
    if (( $? != 0 )); then
      echo "twin $screen capture pair diverged (attempt $attempt: $determinism_line)"
      twin_diverged=1
      twin_failure="diverged"
      break
    fi
  done
  if (( twin_diverged == 0 )); then
    twin_reproducible=1
    break
  fi
done
if (( twin_reproducible == 0 )); then
  if [[ "$twin_failure" == died ]]; then
    echo "twin CAPTURE-DEATH: no capture survived 3 attempts —" \
      "fix the capture, not the floor" >&2
  else
    echo "twin CAPTURE-NONDETERMINISM: no reproducible capture pair in 3" \
      "attempts — fix the capture, not the floor" >&2
  fi
  exit 2
fi

OBSERVED_CLOCK="$(jq -r '.clockEpoch' "$TWIN_DIR/timeline.json")"
if [[ "$OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "native frozen clock mismatch: wanted $FROZEN_NOW, got $OBSERVED_CLOCK" >&2
  exit 2
fi
if ! jq -e '
  .screenFixtures
  | [
      .status,
      .statusContext,
      .account,
      .featuredTags,
      .accountStatuses,
      .familiarFollowers
    ]
  | length == 6 and all(.[]; type == "string" and length > 0)
' "$TWIN_DIR/timeline.json" >/dev/null; then
  echo "native screen fixture metadata is missing or malformed" >&2
  exit 2
fi
screen_fixture_names=(
  "${(@f)$(jq -r '
    .screenFixtures
    | [
        .status,
        .statusContext,
        .account,
        .featuredTags,
        .accountStatuses,
        .familiarFollowers
      ][]
  ' "$TWIN_DIR/timeline.json")}"
)
for fixture_name in "${screen_fixture_names[@]}"; do
  if [[ ! -f "$TWIN_DIR/$fixture_name" ]]; then
    echo "native screen fixture is missing: $fixture_name" >&2
    exit 2
  fi
done

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

capture_interpreted_screen() {
  local screen="$1"
  local out_dir="$2"
  local native_args=()
  if [[ "$screen" != timeline ]]; then
    native_args=(--native-fixtures "$TWIN_DIR")
  fi
  ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
  SWIFT_DETERMINISTIC_HASHING=1 \
  DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
  "$INTERP_EXECUTABLE" --capture "$out_dir" --screen "$screen" \
    "${native_args[@]}" -ApplePersistenceIgnoreState YES \
    > "$out_dir/$screen.log" 2>&1
}

# Captures run STRICTLY SERIALLY. Measured 2026-07-30: three parallel capture
# processes contend for the window server, `drawHierarchy` takes a different
# snapshot path per run, and two passes of the same binary on the same
# fixtures differ by 141k+ AE (±1-per-channel wobble plus spinner phase);
# serialized, four consecutive captures are pixel-exact. Do not restore the
# `&` fan-out without also proving the reproducibility gate below stays green.
capture_reproducible_interpreted_screen() {
  local screen="$1"
  local attempt determinism_line capture_status
  local failure="diverged"
  for attempt in 1 2 3; do
    local capture_died=0
    for interp_out in "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
      capture_interpreted_screen "$screen" "$interp_out"
      capture_status=$?
      if (( capture_status != 0 )); then
        cat "$interp_out/$screen.log"
        echo "interpreted $screen capture failed with status" \
          "$capture_status (attempt $attempt)" >&2
        capture_died=1
        failure="died"
        break
      fi
    done
    if (( capture_died )); then
      continue
    fi
    determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
      "$INTERP_DIR/$screen.png" "$INTERP_REPEAT_DIR/$screen.png")"
    if (( $? == 0 )); then
      return 0
    fi
    failure="diverged"
    echo "interpreted $screen capture pair diverged (attempt $attempt: $determinism_line)"
  done
  if [[ "$failure" == died ]]; then
    echo "interpreted $screen CAPTURE-DEATH: no capture survived 3" \
      "attempts — fix the capture, not the floor" >&2
  else
    echo "interpreted $screen CAPTURE-NONDETERMINISM: no reproducible capture" \
      "pair in 3 attempts — fix the capture, not the floor" >&2
  fi
  exit 2
}

for screen in timeline status-detail account-header; do
  capture_reproducible_interpreted_screen "$screen"
  cat "$INTERP_DIR/$screen.log"
done

INTERP_OBSERVED_CLOCK="$(jq -r '.interpretedClockEpoch' "$INTERP_DIR/timeline.json")"
if [[ "$INTERP_OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "interpreted frozen clock mismatch: wanted $FROZEN_NOW, got $INTERP_OBSERVED_CLOCK" >&2
  exit 2
fi

echo "── R2 AE board ──"
# Ratchet floors — enforced, committed baselines (AUDIT-2026-07-23-R2-stall.md
# rec #2, mirroring Scripts/foodtruck-r3.sh). The timeline remains the LOOP R2
# metric and exact at zero. Detail and account are independently measured so a
# green timeline cannot hide regressions or unmeasured screen gaps.
typeset -A R2_FLOORS
R2_FLOORS=(
  timeline 0
  status-detail 0
  account-header 35241
)
typeset -A R2_AE_LINES
board_red=0
board_below=0

for screen in timeline status-detail account-header; do
  ae_line="$(xcrun swift Scripts/pixel-ae.swift \
    "$TWIN_DIR/$screen.png" "$INTERP_DIR/$screen.png")"
  ae_status=$?
  if (( ae_status == 2 )); then
    echo "$screen R2 board: pixel comparison failed (size mismatch or unreadable capture)" >&2
    exit 2
  fi
  ae_count="$(print -r -- "$ae_line" | sed -E 's/^AE ([0-9]+) of .*/\1/')"
  if [[ ! "$ae_count" == <-> ]]; then
    echo "$screen R2 board: could not parse AE count from '$ae_line'" >&2
    exit 2
  fi
  R2_AE_LINES[$screen]="$ae_line"
  floor="${R2_FLOORS[$screen]}"
  print -r -- "$screen"$'\t'"$ae_line"$'\t'"floor=$floor"
  if (( ae_count > floor )); then
    echo "═══ $screen R2 board: OVER FLOOR — AE $ae_count > $floor (regression) ═══"
    board_red=1
  elif (( ae_count < floor )); then
    echo "═══ $screen R2 board: BELOW FLOOR — ratchet $floor to $ae_count in this commit ═══"
    board_below=1
  else
    echo "═══ $screen R2 board: AT FLOOR — AE $ae_count == $floor ═══"
  fi
done

# gate.sh deliberately consumes the last unlabelled AE line as the official
# timeline R2 metric.
print -r -- "${R2_AE_LINES[timeline]}"
if (( board_red != 0 )); then
  exit 1
fi
if (( board_below != 0 )); then
  echo "═══ R2 board: GREEN below at least one floor; commit the tighter floor ═══"
  exit 0
fi
echo "═══ R2 board: GREEN at all floors ═══"
exit 0
