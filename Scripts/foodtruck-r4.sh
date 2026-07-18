#!/bin/zsh
# R4 live-window sweep: launch the REAL interactive demo window on the
# interpreted FoodTruck and drive sidebar navigation, verifying each click
# lands its panel. One PROCESS PER PANEL: offscreen layer rasterization is
# only trustworthy for the first re-render after initial compositing, so
# chaining navigations in one window under-measures later steps. This opens
# visible windows and briefly takes focus — it is a LIVE instrument,
# deliberately not part of the headless closing gate. Captures land in
# /tmp/foodtruck-r4-<step> for inspection.
set -u
cd "$(dirname "$0")/.." || exit 2
swift build > /dev/null 2>&1 || exit 2
typeset -a steps
steps=(orders socialfeed saleshistory donuts donuteditor topfive cupertino london truck)
red=0
for step in "${steps[@]}"; do
    out="/tmp/foodtruck-r4-$step"
    verdict=$(env DEMO_SWEEP_STEP="$step" timeout 90 .build/debug/DynamicSwiftUIDemo \
        --project Examples/FoodTruckBuildingASwiftUIMultiplatformApp \
        --platform macOS --sweep "$out" 2>/dev/null | grep -E "^SWEEP ($step|GREEN|RED)")
    print -r -- "$verdict"
    [[ "$verdict" == *"SWEEP GREEN"* ]] || red=1
done
if (( red )); then
    echo "═══ R4 board: RED ═══"
    exit 1
fi
echo "═══ R4 board: all sidebar navigations land ═══"
