import Testing
@testable import SwiftUIBridge

/// Capture readiness was bounded by TOTAL elapsed time — a deliberately
/// non-configurable 30s in both `IceCubesCheck` capture loops — so a screen
/// that is still working is failed by the same instrument that fails a screen
/// that is wedged. The two are opposite conditions with opposite fixes, and a
/// total budget cannot tell them apart: it measures interpreted throughput.
///
/// The IceCubes `trending-timeline` screen is the case that proves it. With the
/// deadline raised as a diagnostic it captures CLEAN — quiescent, zero active
/// tasks, all 12 continuations resumed, 605 body evaluations, exit 0 — at 269s
/// of real work. Nothing about that frame is unsettled; the clock expires
/// mid-computation, and the screen stays off the R2 board for it.
///
/// These pins assert the STRUCTURE of the bound over a synthetic timeline —
/// no wall clock, no sleeping — so machine load cannot turn them red. The
/// RED demonstration is the first test: under a total-time bound a session
/// making progress on every single tick expires anyway.
@Suite("Capture readiness budget")
struct CaptureReadinessBudgetTests {
    private let start = ContinuousClock.now

    /// THE CLASS, demonstrated as a CONTRAST rather than as an assertion that
    /// is green because its subject is new. The identical session — 269s of
    /// steady progress, which is `trending-timeline` — is run under both
    /// rules. The old rule is not described here, it is INSTANTIATED: a
    /// 30s total bound with no no-progress bound is exactly the deadline both
    /// capture loops carried, so its verdict on this session is the RED.
    @Test func advancingCaptureOutlivesTheOldTotalBudget() {
        // Stepped one observation per second rather than at the harness's
        // 50ms cadence: the same structure with a thousandth of the
        // arithmetic, and the bound is a comparison on instants either way.
        func runAdvancingSession(
            _ budget: inout CaptureReadinessBudget
        ) -> (expiry: CaptureReadinessBudget.Expiry?, second: Int) {
            for second in 1...269 {
                if let expiry = budget.observe(
                    progressed: true,
                    at: start.advanced(by: .seconds(second)))
                {
                    return (expiry, second)
                }
            }
            return (nil, 269)
        }

        // THE OLD RULE. `totalLimit` 30s is the deadline being replaced; the
        // no-progress bound is put out of reach so this budget expresses the
        // total-time rule alone. It fails a session that never stopped
        // working, 239s before that session was done.
        var oldRule = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(3600),
            totalLimit: .seconds(30))
        let old = runAdvancingSession(&oldRule)
        #expect(old.expiry == .oscillating)
        #expect(old.second == 30)

        // THE NEW RULE. Same session, same instants, opposite verdict.
        var budget = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(900))
        let new = runAdvancingSession(&budget)

        #expect(new.expiry == nil)
        #expect(new.second == 269)
        #expect(budget.progressCount == 269)
        #expect(budget.longestObservedStall <= .seconds(1))
    }

    /// The other half, and the reason this is not simply a bigger number: a
    /// WEDGED capture now fails FASTER than the 30s it used to take.
    @Test func wedgedCaptureFailsSoonerThanTheOldTotalBudget() {
        var budget = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(900))

        // Work happens for 5s, then stops dead.
        for second in 1...5 {
            #expect(
                budget.observe(
                    progressed: true,
                    at: start.advanced(by: .seconds(second))) == nil)
        }

        var expiry: CaptureReadinessBudget.Expiry?
        var expiredAt = 0
        for second in 6...60 {
            expiry = budget.observe(
                progressed: false,
                at: start.advanced(by: .seconds(second)))
            if expiry != nil { expiredAt = second; break }
        }

        #expect(expiry == .noProgress)
        // 5s of work + a 20s stall — strictly inside the old 30s bound.
        #expect(expiredAt == 25)
    }

    /// A respawn loop makes progress forever, so the no-progress bound alone
    /// can never catch it. The total bound remains, as a liveness backstop
    /// rather than as the primary instrument.
    @Test func oscillatingCaptureStillTerminatesOnTheTotalBound() {
        var budget = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(100))

        var expiry: CaptureReadinessBudget.Expiry?
        var expiredAt = 0
        for second in 1...200 {
            expiry = budget.observe(
                progressed: true,
                at: start.advanced(by: .seconds(second)))
            if expiry != nil { expiredAt = second; break }
        }

        #expect(expiry == .oscillating)
        #expect(expiredAt == 100)
    }

    /// THE MECHANISM THE REAL SCREEN DEPENDS ON, pinned because it is
    /// load-bearing and reads like a bug otherwise: a gap far longer than
    /// `noProgressLimit` that ENDS IN PROGRESS must not expire the budget.
    ///
    /// This is measured `trending-timeline`, not a hypothetical — the harness
    /// reports `longestStall=181.087s progressObservations=6 expiry=none` on a
    /// healthy capture against a 20s limit. Both capture loops poll from the
    /// same main actor that runs interpreted body evaluation, so while the
    /// interpreter occupies it the loop cannot tick at all; the tick that
    /// lands afterwards sees a changed revision. A no-progress bound is
    /// therefore only ever evaluated when the main actor is FREE, which is
    /// exactly the condition under which "nothing changed" means wedged.
    ///
    /// If this pin is ever "fixed" by raising `noProgressLimit`, the wedged
    /// case regresses by the same amount. The bound is not a duration budget.
    @Test func aLongGapEndingInProgressDoesNotExpire() {
        var budget = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(900))

        #expect(
            budget.observe(
                progressed: true, at: start.advanced(by: .seconds(1))) == nil)
        // The 181s window: the loop is starved, so `observe` is not called
        // once inside it. The next call it makes reports progress.
        #expect(
            budget.observe(
                progressed: true, at: start.advanced(by: .seconds(182)))
                == nil)

        #expect(budget.longestObservedStall == .seconds(181))
        #expect(budget.progressCount == 2)

        // And the contrast that makes it meaningful: had the loop been free to
        // tick inside that window — main actor idle, nothing advancing — the
        // very first such tick past the limit expires it.
        var wedged = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(900))
        #expect(
            wedged.observe(
                progressed: true, at: start.advanced(by: .seconds(1))) == nil)
        #expect(
            wedged.observe(
                progressed: false, at: start.advanced(by: .seconds(21)))
                == .noProgress)
    }

    /// `longestObservedStall` is the instrument that made the row above
    /// legible: without it a 181s occupancy and a 181s hang are the same
    /// silence. It reports what the capture survived rather than assuming it.
    @Test func budgetReportsTheLongestStallItSurvived() {
        var budget = CaptureReadinessBudget(
            startedAt: start,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(900))

        budget.observe(progressed: true, at: start.advanced(by: .seconds(1)))
        // A 7s gap: quiet, but well inside the limit.
        budget.observe(progressed: false, at: start.advanced(by: .seconds(5)))
        budget.observe(progressed: true, at: start.advanced(by: .seconds(8)))
        budget.observe(progressed: true, at: start.advanced(by: .seconds(9)))

        #expect(budget.longestObservedStall == .seconds(7))
        #expect(budget.progressCount == 3)
    }
}
