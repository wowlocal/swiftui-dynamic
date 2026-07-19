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

echo "── R2 AE board ──"
xcrun swift Scripts/pixel-ae.swift \
  "$TWIN_DIR/timeline.png" "$INTERP_DIR/timeline.png"
