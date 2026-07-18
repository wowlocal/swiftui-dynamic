#!/bin/bash
# FoodTruck R3 board (Scripts/foodtruck-r3-spec.md): run the model-API
# mutation scenarios on BOTH sides, then pixel-AE each post-mutation
# capture. Expectations are the twin's captures — never hand-written.
#
# Usage: Scripts/foodtruck-r3.sh [TWIN_DIR] [INTERP_DIR]
#   Reuses existing twin captures when present (delete the dir to refresh).
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Frozen clock (LOOP.md determinism): both sides pin Date.now so captures
# compare across runs. 1784228400 = 2026-07-16 19:00:00 UTC, arbitrary.
export FOODTRUCK_FROZEN_NOW=${FOODTRUCK_FROZEN_NOW:-1784228400}
TWIN=${1:-/tmp/foodtruck-twin-r3}
INTERP=${2:-/tmp/foodtruck-interp-r3}

# Twin captures reuse only WITHIN a calendar day: relative date text
# ("Yesterday" in the orders table) anchors to the system's REAL today,
# so a stale twin vs a fresh interpreter capture diffs on day rollover
# (phantom 3.567% on every orders row, 2026-07-18).
if [ ! -f "$TWIN/donuts-after-rename.png" ] \
   || [ "$(date -r "$TWIN/donuts-after-rename.png" +%Y-%m-%d)" != "$(date +%Y-%m-%d)" ]; then
  rm -rf "$TWIN"
  (cd "$ROOT/Examples/FoodTruckNativeTwin" && swift run FoodTruckNativeTwin --out "$TWIN" --scenario all)
fi
(cd "$ROOT" && swift build && .build/debug/FoodTruckCheck --capture "$INTERP" --scenario all)

percent() {
  swift "$ROOT/Scripts/pixel-ae.swift" "$1" "$2" 2>/dev/null | tail -1 \
    | sed -E 's/.*\(([0-9.]+)%\).*/\1/'
}

# Spec enforcement (Scripts/foodtruck-r3-spec.md):
#  - FLOOR: each post-mutation capture must diff within its screen's
#    ratcheted floor (below, from the 2026-07-17 board + headroom).
#  - CHANGED-GUARD: the mutation must VISIBLY change the screen on both
#    sides (pre != post) — absorbed no-op mutations fail loudly.
typeset -A floors bases
floors=(donuts-after-rename 2.0 donut-view-after-rename 0.5
        orders-after-complete 1.5 orders-after-preparing 1.5
        orders-after-steps 4.0 donuts-after-popularity 2.0
        card-donuts-after-popularity 0.5 detail-truck 3.0
        detail-orders 1.5 detail-donuts 2.0)
bases=(donuts-after-rename donuts donut-view-after-rename donut-view
       orders-after-complete orders orders-after-preparing orders
       orders-after-steps orders donuts-after-popularity donuts)

failures=0
echo "── R3 board (twin=$TWIN interp=$INTERP) ──"
for id in donuts-after-rename donut-view-after-rename orders-after-complete \
          orders-after-preparing orders-after-steps donuts-after-popularity \
          card-donuts-after-popularity detail-truck detail-orders detail-donuts; do
  if [ ! -f "$TWIN/$id.png" ] || [ ! -f "$INTERP/$id.png" ]; then
    echo "$id: MISSING capture"; failures=$((failures+1)); continue
  fi
  ae=$(percent "$TWIN/$id.png" "$INTERP/$id.png")
  floor=${floors[$id]:-}
  verdict="ok"
  if [ -n "$floor" ] && (( $(echo "$ae > $floor" | bc -l) )); then
    verdict="OVER FLOOR $floor"; failures=$((failures+1))
  fi
  guard=""
  base=${bases[$id]:-}
  if [ -n "$base" ] && [ -f "$TWIN/$base.png" ] && [ -f "$INTERP/$base.png" ]; then
    twinDelta=$(percent "$TWIN/$base.png" "$TWIN/$id.png")
    interpDelta=$(percent "$INTERP/$base.png" "$INTERP/$id.png")
    # DISAGREEMENT is the failure: one side re-renders the mutation and
    # the other does not (both-zero = the sides agree the screen is
    # unaffected — donut-view shows art, not the renamed label).
    twinChanged=$(echo "$twinDelta > 0" | bc -l)
    interpChanged=$(echo "$interpDelta > 0" | bc -l)
    if [ "$twinChanged" != "$interpChanged" ]; then
      guard=" CHANGED-GUARD FAILED (twinΔ=$twinDelta interpΔ=$interpDelta)"
      failures=$((failures+1))
    fi
  fi
  echo "$id: ${ae}% [$verdict]$guard"
done
if (( failures > 0 )); then
  echo "═══ R3 board: $failures FAILURE(S) ═══"; exit 1
fi
echo "═══ R3 board: all scenarios within floors, mutations visible ═══"
