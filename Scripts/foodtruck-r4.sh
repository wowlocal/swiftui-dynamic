#!/bin/zsh
# R4 live-window sweep: launch the REAL interactive demo window on the
# interpreted FoodTruck and drive sidebar navigation, verifying each click
# lands its panel (SweepDriver prints SWEEP lines; exit code is the
# verdict). This opens a visible window and briefly takes focus — it is a
# LIVE instrument, deliberately not part of the headless closing gate.
# Captures land in /tmp/foodtruck-r4 for inspection.
set -u
cd "$(dirname "$0")/.." || exit 2
OUT=${1:-/tmp/foodtruck-r4}
swift build > /dev/null 2>&1 || exit 2
timeout 120 .build/debug/DynamicSwiftUIDemo \
    --project Examples/FoodTruckBuildingASwiftUIMultiplatformApp \
    --platform macOS --sweep "$OUT" 2>/dev/null | grep -E "^SWEEP"
exit ${pipestatus[1]}
