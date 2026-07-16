#!/bin/zsh
# R2 orchestrator: capture BOTH sides and print the per-screen AE table.
# Convention (shared with FoodTruckCheck's R2 rungs):
#   twin captures   → /tmp/foodtruck-twin/<id>.png
#   interp captures → /tmp/foodtruck-interp/<id>.png
# Every id present on BOTH sides is diffed; the table is the R2 board.
# Ratchet: per-screen AE only ever decreases (LOOP.md R2 baseline note).
set -u
cd "$(dirname "$0")/.." || exit 2
# Frozen clock (LOOP.md determinism): both sides pin Date.now so captures
# compare across runs. 1784228400 = 2026-07-16 19:00:00 UTC, arbitrary.
export FOODTRUCK_FROZEN_NOW=${FOODTRUCK_FROZEN_NOW:-1784228400}
TWIN_DIR=/tmp/foodtruck-twin
INTERP_DIR=/tmp/foodtruck-interp
mkdir -p "$TWIN_DIR" "$INTERP_DIR"

echo "── native twin ──"
( cd Examples/FoodTruckNativeTwin && swift run -q FoodTruckNativeTwin --out "$TWIN_DIR" 2>/dev/null )

echo "── interpreter ──"
swift build > /dev/null 2>&1
# All ids via FoodTruckCheck's capture mode (same technique both sides).
.build/debug/FoodTruckCheck --capture "$INTERP_DIR" 2>/dev/null | tail -8

echo "── AE board ──"
total=0; compared=0
for twin_png in "$TWIN_DIR"/*.png; do
    id=$(basename "$twin_png" .png)
    interp_png="$INTERP_DIR/$id.png"
    if [ -f "$interp_png" ]; then
        line=$(swift Scripts/pixel-ae.swift "$twin_png" "$interp_png" 2>/dev/null)
        echo "$id: $line"
        compared=$((compared+1))
    else
        echo "$id: (no interp capture yet)"
    fi
    total=$((total+1))
done
echo "── $compared/$total screens compared ──"
