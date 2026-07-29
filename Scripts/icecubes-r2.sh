#!/bin/zsh
# Capture compiled Catalyst and interpreted IceCubes screens from the same
# recorded Mastodon bytes, then enforce each screen's exact per-pixel AE.
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
FIXTURES="$ROOT/Fixtures/mastodon-public-timeline"
TWIN_DIR=/tmp/icecubes-native-twin
INTERP_DIR=/tmp/icecubes-interpreted
# 2026-07-16T12:00:00Z, immediately after the recorded fixture was captured.
FROZEN_NOW=1784203200
CLOCK_DIR="$ROOT/Examples/IceCubesNativeTwin/.build/frozen-clock"
INTERP_SCRATCH_PATH="${ICECUBES_R2_SCRATCH_PATH:-$ROOT/.build/icecubes-r2-product}"
INTERP_BUILD_DIR="$INTERP_SCRATCH_PATH/arm64-apple-ios-macabi/debug"
INTERP_BINARY="$INTERP_BUILD_DIR/IceCubesCheck"
INTERP_APP="$INTERP_BUILD_DIR/IceCubesCheck.app"
INTERP_EXECUTABLE="$INTERP_APP/Contents/MacOS/IceCubesCheck"
mkdir -p "$TWIN_DIR" "$INTERP_DIR"
rm -f \
  "$TWIN_DIR/timeline.png" \
  "$TWIN_DIR/status-detail.png" \
  "$TWIN_DIR/account-header.png" \
  "$TWIN_DIR/media.png" \
  "$TWIN_DIR/timeline.json" \
  "$INTERP_DIR/timeline.png" \
  "$INTERP_DIR/status-detail.png" \
  "$INTERP_DIR/account-header.png" \
  "$INTERP_DIR/timeline.json" \
  "$INTERP_DIR/timeline.log" \
  "$INTERP_DIR/status-detail.log" \
  "$INTERP_DIR/account-header.log"

echo "── native IceCubes twin ──"
(
  cd Examples/IceCubesNativeTwin || exit 2
  ./build.sh || exit 2
  ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
  DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
  .build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin.app/Contents/MacOS/IceCubesNativeTwin \
    --out "$TWIN_DIR" --fixtures "$FIXTURES"
) || exit 2

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
  local native_args=()
  if [[ "$screen" != timeline ]]; then
    native_args=(--native-fixtures "$TWIN_DIR")
  fi
  ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
  SWIFT_DETERMINISTIC_HASHING=1 \
  DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
  "$INTERP_EXECUTABLE" --capture "$INTERP_DIR" --screen "$screen" \
    "${native_args[@]}" > "$INTERP_DIR/$screen.log" 2>&1
}

capture_pids=()
for screen in timeline status-detail account-header; do
  capture_interpreted_screen "$screen" &
  capture_pids+=($!)
done
capture_status=0
for capture_pid in "${capture_pids[@]}"; do
  wait "$capture_pid" || capture_status=$?
done
for screen in timeline status-detail account-header; do
  cat "$INTERP_DIR/$screen.log"
done
if (( capture_status != 0 )); then
  echo "interpreted screen capture failed with status $capture_status" >&2
  exit 2
fi

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
  status-detail 100041
  account-header 399329
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
