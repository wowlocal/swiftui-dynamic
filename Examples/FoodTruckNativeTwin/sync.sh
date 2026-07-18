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
# Harness frozen clock (R2/R3 determinism, LOOP.md): FOODTRUCK_FROZEN_NOW
# pins `Date.now` on BOTH sides. Shadowing is module-scoped, so the shim
# lands in each target; without the env var behavior is native-identical.
for target in Sources/FoodTruckKit Sources/FoodTruckNativeTwin; do
cat > "$target/HarnessFrozenClock.swift" << 'SHIM'
import Foundation

// HARNESS-GENERATED (sync.sh) — not app source. FOODTRUCK_FROZEN_NOW
// (epoch seconds) pins the model clock so twin and interpreter captures
// are comparable across runs; unset, this is exactly Foundation's now.
extension Date {
    static var now: Date {
        if let raw = ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"],
           let epoch = TimeInterval(raw) {
            return Date(timeIntervalSince1970: epoch)
        }
        return Date(timeIntervalSinceNow: 0)
    }
}

// Deterministic `.random` for harness runs — same doctrine as the
// frozen clock. Env-pinned runs draw from a shared LCG so twin and
// interpreter social-feed timestamps agree bit-exactly; unpinned
// (live) runs seed from the wall clock so launches still differ.
// The seeded `.random(in:using:)` spellings resolve past this shadow
// to the stdlib, exactly like native overload resolution.
nonisolated(unsafe) var __harnessRandomState = 0
extension Double {
    static func random(in range: ClosedRange<Double>) -> Double {
        if __harnessRandomState == 0 {
            if ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"] != nil {
                __harnessRandomState = 1
            } else {
                __harnessRandomState = Int(Date(timeIntervalSinceNow: 0).timeIntervalSince1970 * 1000) % 2147483647 + 1
            }
        }
        __harnessRandomState = (__harnessRandomState * 1103515245 + 12345) % 2147483648
        let unit = Double(__harnessRandomState) / 2147483648.0
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
SHIM
done
for target in Sources/FoodTruckKit Sources/FoodTruckNativeTwin; do
# TimelineView's animation clock is SwiftUI-internal WALL TIME even under
# the Date.now shadow — frozen runs captured a different map-camera phase
# every launch (proven: context.date ticks at ~120Hz of real now). The
# module-scoped shadow pins context.date to the shadowed Date.now under
# the env var and defers to the real TimelineView otherwise. BOTH
# targets: FoodTruckKit's BrandHeader animates on it too, and an
# app-only shadow left the twin Kit on wall time (orders rows drifted).
cat > "$target/HarnessFrozenTimeline.swift" << 'SHIM'
import SwiftUI

// HARNESS-GENERATED (sync.sh) — not app source. See sync.sh for why.
struct HarnessTimelineContext {
    var date: Date
}

struct HarnessTimelineSchedule {
    var paused: Bool

    static var animation: HarnessTimelineSchedule {
        HarnessTimelineSchedule(paused: false)
    }

    static func animation(paused: Bool) -> HarnessTimelineSchedule {
        HarnessTimelineSchedule(paused: paused)
    }
}

struct TimelineView<Content: View>: View {
    var schedule: HarnessTimelineSchedule
    var content: (HarnessTimelineContext) -> Content

    init(
        _ schedule: HarnessTimelineSchedule,
        @ViewBuilder content: @escaping (HarnessTimelineContext) -> Content
    ) {
        self.schedule = schedule
        self.content = content
    }

    var body: some View {
        if ProcessInfo.processInfo.environment["FOODTRUCK_FROZEN_NOW"] != nil {
            content(HarnessTimelineContext(date: Date.now))
        } else {
            SwiftUI.TimelineView(.animation(paused: schedule.paused)) { context in
                content(HarnessTimelineContext(date: context.date))
            }
        }
    }
}
SHIM
done
echo "synced kit=$(find Sources/FoodTruckKit -name '*.swift' | wc -l | tr -d ' ') app=$(find Sources/FoodTruckNativeTwin/App -name '*.swift' | wc -l | tr -d ' ')"
