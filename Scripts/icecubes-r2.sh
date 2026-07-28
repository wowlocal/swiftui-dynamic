#!/bin/zsh
# Capture the compiled Catalyst twin and interpreted IceCubes timeline from
# the same recorded Mastodon bytes, then print the exact per-pixel AE.
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
FIXTURES="$ROOT/Fixtures/mastodon-public-timeline"
TWIN_DIR=/tmp/icecubes-native-twin
INTERP_DIR=/tmp/icecubes-interpreted
# 2026-07-16T12:00:00Z, immediately after the recorded fixture was captured.
FROZEN_NOW=1784203200
CLOCK_DIR="$ROOT/Examples/IceCubesNativeTwin/.build/frozen-clock"
mkdir -p "$TWIN_DIR" "$INTERP_DIR"

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

echo "── interpreted IceCubes ──"
xcrun swift build --product IceCubesCheck || exit 2
ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macos.dylib" \
.build/arm64-apple-macosx/debug/IceCubesCheck --capture "$INTERP_DIR" || exit 2

INTERP_OBSERVED_CLOCK="$(jq -r '.interpretedClockEpoch' "$INTERP_DIR/timeline.json")"
if [[ "$INTERP_OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "interpreted frozen clock mismatch: wanted $FROZEN_NOW, got $INTERP_OBSERVED_CLOCK" >&2
  exit 2
fi

echo "── R2 AE board ──"
# Ratchet floor — enforced, committed baseline (AUDIT-2026-07-23-R2-stall.md rec #2,
# mirroring Scripts/foodtruck-r3.sh). Before this, the R2 floor lived only in commit
# prose and .gitignored .claude/claims.md and was measured out-of-band, which let
# 0b47a4db land at AE 158,178 on main (2.6x) before a post-hoc capture caught it.
# The board now FAILS on a regression above the floor and passes at/below it; the
# floor ratchets DOWN only — when a run measures below it, tighten this number in
# the same commit.
ICECUBES_R2_FLOOR=59598

ae_line="$(xcrun swift Scripts/pixel-ae.swift \
  "$TWIN_DIR/timeline.png" "$INTERP_DIR/timeline.png")"
ae_status=$?
print -r -- "$ae_line"
if (( ae_status == 2 )); then
  echo "R2 board: pixel comparison failed (size mismatch or unreadable capture)" >&2
  exit 2
fi
ae_count="$(print -r -- "$ae_line" | sed -E 's/^AE ([0-9]+) of .*/\1/')"
if [[ ! "$ae_count" == <-> ]]; then
  echo "R2 board: could not parse AE count from '$ae_line'" >&2
  exit 2
fi
if (( ae_count > ICECUBES_R2_FLOOR )); then
  echo "═══ R2 board: OVER FLOOR — AE $ae_count > floor $ICECUBES_R2_FLOOR (regression) ═══"
  exit 1
fi
if (( ae_count < ICECUBES_R2_FLOOR )); then
  echo "═══ R2 board: BELOW FLOOR — AE $ae_count < $ICECUBES_R2_FLOOR; ratchet ICECUBES_R2_FLOOR to $ae_count in this commit ═══"
  exit 0
fi
echo "═══ R2 board: AT FLOOR — AE $ae_count == $ICECUBES_R2_FLOOR ═══"
exit 0
