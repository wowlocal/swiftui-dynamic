#!/bin/bash
# FoodTruck R3 board (Scripts/foodtruck-r3-spec.md): run the model-API
# mutation scenarios on BOTH sides, then pixel-AE each post-mutation
# capture. Expectations are the twin's captures — never hand-written.
#
# Usage: Scripts/foodtruck-r3.sh [TWIN_DIR] [INTERP_DIR]
#   Reuses existing twin captures when present (delete the dir to refresh).
#
# Not yet enforced here (tracked in LOOP.md): the spec's pre!=post
# changed-guard against each side's R2 base captures.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Frozen clock (LOOP.md determinism): both sides pin Date.now so captures
# compare across runs. 1784228400 = 2026-07-16 19:00:00 UTC, arbitrary.
export FOODTRUCK_FROZEN_NOW=${FOODTRUCK_FROZEN_NOW:-1784228400}
TWIN=${1:-/tmp/foodtruck-twin-r3}
INTERP=${2:-/tmp/foodtruck-interp-r3}

if [ ! -f "$TWIN/donuts-after-rename.png" ]; then
  (cd "$ROOT/Examples/FoodTruckNativeTwin" && swift run FoodTruckNativeTwin --out "$TWIN" --scenario all)
fi
(cd "$ROOT" && swift build && .build/debug/FoodTruckCheck --capture "$INTERP" --scenario all)

echo "── R3 board (twin=$TWIN interp=$INTERP) ──"
for id in donuts-after-rename donut-view-after-rename orders-after-complete \
          orders-after-preparing orders-after-steps donuts-after-popularity \
          card-donuts-after-popularity detail-truck detail-orders detail-donuts; do
  if [ -f "$TWIN/$id.png" ] && [ -f "$INTERP/$id.png" ]; then
    ae=$(swift "$ROOT/Scripts/pixel-ae.swift" "$TWIN/$id.png" "$INTERP/$id.png" 2>/dev/null | tail -1)
    echo "$id: $ae"
  else
    echo "$id: MISSING capture"
  fi
done
