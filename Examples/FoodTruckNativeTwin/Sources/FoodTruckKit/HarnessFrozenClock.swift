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
