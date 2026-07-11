#!/bin/zsh
# Regenerate the twin's Kit and App source copies from the canonical
# sample. Upstream is READ-ONLY; these copies exist only because SPM
# cannot reference sources outside the package root (and the Kit needs
# the cross-import overlay flag its own manifest predates). Kit assets +
# Resources sync too (Bundle.module). Excluded: App.swift (@main
# conflicts with the harness main.swift), Widgets/.
cd "$(dirname "$0")" || exit 1
SRC="../FoodTruckBuildingASwiftUIMultiplatformApp"
rm -rf Sources/FoodTruckKit Sources/FoodTruckNativeTwin/App
rsync -a --include='*/' --include='*.swift' --exclude='*' \
    "$SRC/FoodTruckKit/Sources/" Sources/FoodTruckKit/
rsync -a "$SRC/FoodTruckKit/Sources/Assets.xcassets" Sources/FoodTruckKit/
rsync -a "$SRC/FoodTruckKit/Sources/Resources" Sources/FoodTruckKit/
rsync -a --include='*/' --include='*.swift' --exclude='*' \
    "$SRC/App/" Sources/FoodTruckNativeTwin/App/
rm -f Sources/FoodTruckNativeTwin/App/App.swift
# SDK-drift modernization (the ONLY divergence from pristine upstream,
# and the same fix Xcode 26 needs): ActivityKit now EXISTS on macOS so
# `#if canImport(ActivityKit)` passes, but its types remain iOS-only —
# the sample's own gate no longer compiles for macOS. Narrow it to iOS.
sed -i '' 's/#if canImport(ActivityKit)/#if os(iOS)/' \
    Sources/FoodTruckNativeTwin/App/Orders/OrderDetailView.swift
echo "synced kit=$(find Sources/FoodTruckKit -name '*.swift' | wc -l | tr -d ' ') app=$(find Sources/FoodTruckNativeTwin/App -name '*.swift' | wc -l | tr -d ' ')"
