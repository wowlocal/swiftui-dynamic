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
