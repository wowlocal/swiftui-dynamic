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
