import Foundation
import SwiftInterpreter

/// A value snapshot of SwiftUI body work performed for one interpreted render
/// session. Capture harnesses can compare revisions without consulting the
/// process-global compatibility counter on `InterpretedView`.
public struct InterpreterRenderActivity: Sendable, Equatable {
    public let bodyEvaluationCount: UInt64
}

/// Tracks whether a render session has reached a capture-safe presentation
/// boundary. A session with no observed asynchronous work is ready after its
/// caller-defined settle period. Once owned work appears, capture waits for
/// both runtime quiescence and a later SwiftUI body evaluation so it cannot
/// freeze the placeholder frame between delivery and presentation.
public struct InterpreterCaptureReadiness: Sendable, Equatable {
    public let initialRenderRevision: UInt64
    public private(set) var firstActiveRenderRevision: UInt64?
    public private(set) var lastActiveRenderRevision: UInt64?
    public private(set) var firstQuiescentRenderRevision: UInt64?
    public private(set) var readyRenderRevision: UInt64?
    /// The render revision at which a response this session's content is GATED
    /// ON was handed to the app. Readiness stays false until a body has been
    /// evaluated strictly after it. `nil` when no such response is outstanding.
    public private(set) var awaitedResponseRenderRevision: UInt64?

    public init(initialRenderRevision: UInt64) {
        self.initialRenderRevision = initialRenderRevision
    }

    public var isReadyForCapture: Bool {
        readyRenderRevision != nil
    }

    /// Record that a response the session's content depends on has just been
    /// DELIVERED, and that the tree has therefore not shown it yet.
    ///
    /// Delivering a response and presenting it are two different events, and a
    /// wait that ANDs "ready" with "the response arrived" samples both in the
    /// same instant, so it can exit between them. `NetworkBridge` records a
    /// replayed resource in a `defer` on the call that RETURNS its bytes, so
    /// the log entry lands before the app decodes them, assigns its model and
    /// evaluates a body — and readiness earned by an EARLIER settle is still
    /// standing at that moment. Measured 2026-08-08: `hashtag-timeline` drops
    /// `TimelineTagHeaderView` entirely when the capture lands in that window,
    /// because `TimelineViewModel.fetchTag` assigns `self.tag` only after the
    /// bytes it was already handed decode.
    ///
    /// This is the ARRIVAL half of readiness, not a longer wait: the session
    /// must still quiesce, and the caller's no-progress budget still bounds
    /// how long it may take. A response that never reaches the tree therefore
    /// fails the capture instead of freezing the frame before it.
    public mutating func noteAwaitedResponse(atRenderRevision revision: UInt64) {
        awaitedResponseRenderRevision =
            max(awaitedResponseRenderRevision ?? revision, revision)
        readyRenderRevision = nil
    }

    public mutating func observe(
        runtimeActivity: InterpreterRuntimeActivity,
        renderActivity: InterpreterRenderActivity
    ) {
        let revision = renderActivity.bodyEvaluationCount
        guard revision >= initialRenderRevision else {
            readyRenderRevision = nil
            return
        }
        guard runtimeActivity.isQuiescent else {
            firstActiveRenderRevision =
                firstActiveRenderRevision ?? revision
            lastActiveRenderRevision = revision
            firstQuiescentRenderRevision = nil
            readyRenderRevision = nil
            return
        }

        firstQuiescentRenderRevision =
            firstQuiescentRenderRevision ?? revision
        // Quiescent, but a response the content is gated on landed at a
        // revision the tree has not evaluated past — the app holds bytes it
        // has not presented. See `noteAwaitedResponse`.
        if let awaitedResponseRenderRevision,
           revision <= awaitedResponseRenderRevision
        {
            readyRenderRevision = nil
            return
        }
        guard let firstActiveRenderRevision else {
            readyRenderRevision = revision
            return
        }
        if revision > firstActiveRenderRevision {
            readyRenderRevision = revision
        }
    }
}

/// Bounds a capture-readiness wait by LACK OF OBSERVABLE PROGRESS rather than
/// by total elapsed time.
///
/// The fixed 30s total budget this replaces was deliberately non-configurable,
/// on the stated rationale that a "wait longer" knob turns a real settle
/// failure into a slow pass. That rationale held while readiness was weak
/// enough for time alone to satisfy it. It no longer describes this harness:
///
/// - `InterpreterCaptureReadiness` is a condition on OBSERVED STATE — runtime
///   quiescence AND a body evaluation later than the first active one — and
///   `CaptureGeometryDump.fingerprint` additionally requires the layout to stop
///   moving. More time cannot make any of those true of a wrong frame.
/// - `Scripts/icecubes-r2.sh` captures every screen TWICE per side and refuses
///   to score a pair that does not match at AE 0, so a frame read too early
///   surfaces as `CAPTURE-NONDETERMINISM` rather than as a quiet pass.
///
/// What a TOTAL budget actually measures is interpreted throughput, which is
/// why the IceCubes `trending-timeline` screen cannot be captured today: with
/// the deadline raised as a diagnostic it finishes clean — quiescent, zero
/// active tasks, all 12 continuations resumed, 605 body evaluations, exit 0 —
/// but it needs 269s of real work against a 30s clock. Nothing about that frame
/// is unsettled; the clock simply expires mid-computation.
///
/// Bounding no-progress instead is STRICTER where strictness is meaningful and
/// patient only where the session is demonstrably still working:
///
/// - a wedged capture fails after `noProgressLimit`, well before 30s;
/// - a slow but advancing capture is allowed to finish;
/// - a respawn loop — which keeps "progressing" forever and which a no-progress
///   bound alone can never catch — still terminates at `totalLimit`.
///
/// WHAT `progressed` CAN AND CANNOT SEE, stated because it is the assumption
/// the whole bound rests on. The caller's signal is
/// `InterpreterRuntimeActivity` — four LEVEL counters, not monotonic work
/// counters — plus `InterpreterRenderActivity.bodyEvaluationCount`, which
/// `InterpretedView.body` bumps on ENTRY (`InterpretedView.swift`), before the
/// interpreted work of that body runs. So the signal is flat for the duration
/// of a single long body evaluation with no task churn: a session burning CPU
/// productively inside one body is indistinguishable here from a wedged one.
///
/// That is survivable rather than fatal, and the reason is NOT that the
/// constant is generous — a healthy `trending-timeline` capture is measured at
/// a 181s stall against a 20s limit and passes. It is that the poll loop runs
/// on the SAME main actor as the work: while interpretation occupies it the
/// loop cannot tick, so `observe` is not called and no false failure can be
/// produced; the tick that eventually lands sees a CHANGED revision and reads
/// the whole gap as progress. See `captureHarness()` for the measurement and
/// the proof-by-exit-code.
///
/// The failure this bound can still produce is therefore narrow, and it is a
/// different shape than "one long body evaluation": interpreted work advancing
/// OFF the main actor while the main actor stays idle and no body evaluation
/// occurs, so the loop ticks freely against flat level counters. If a healthy
/// capture is ever failed that way, the signal is too weak and wants a
/// monotonic work counter — not a bigger constant, which would equally delay
/// the wedged case this exists to catch.
///
/// Deliberately driven by caller-supplied instants rather than reading a clock
/// itself, so its pins assert the STRUCTURE of the bound on a synthetic
/// timeline and machine load cannot turn them red.
public struct CaptureReadinessBudget: Sendable, Equatable {
    /// Which bound expired. Kept distinct because the two mean opposite things
    /// about the session and want opposite fixes: `noProgress` is work that
    /// stopped, `oscillating` is work that never stops.
    public enum Expiry: String, Sendable, Equatable {
        case noProgress
        case oscillating
    }

    public let startedAt: ContinuousClock.Instant
    public let noProgressLimit: Duration
    public let totalLimit: Duration
    public private(set) var lastProgressAt: ContinuousClock.Instant
    public private(set) var progressCount = 0
    /// The longest gap between observed progress so far. This is the number
    /// that CALIBRATES `noProgressLimit`: a limit is only defensible as a
    /// stated multiple of the largest stall a healthy capture actually shows,
    /// so the harness reports it rather than leaving the constant to taste.
    public private(set) var longestObservedStall: Duration = .zero

    public init(
        startedAt: ContinuousClock.Instant,
        noProgressLimit: Duration,
        totalLimit: Duration
    ) {
        self.startedAt = startedAt
        self.noProgressLimit = noProgressLimit
        self.totalLimit = totalLimit
        self.lastProgressAt = startedAt
    }

    /// Records one poll of the capture loop and reports the bound that has
    /// expired, if any. `progressed` is whatever the caller can observe moving
    /// — concurrency counts and the body-evaluation revision for this harness.
    @discardableResult
    public mutating func observe(
        progressed: Bool, at now: ContinuousClock.Instant
    ) -> Expiry? {
        let stall = lastProgressAt.duration(to: now)
        if stall > longestObservedStall { longestObservedStall = stall }
        if progressed {
            progressCount += 1
            lastProgressAt = now
            // A tick that made progress cannot be a no-progress expiry even if
            // it arrived late, but it is still subject to the total bound: an
            // oscillating session makes progress on every single tick.
            return startedAt.duration(to: now) >= totalLimit
                ? .oscillating : nil
        }
        if stall >= noProgressLimit { return .noProgress }
        return startedAt.duration(to: now) >= totalLimit ? .oscillating : nil
    }
}

extension CaptureReadinessBudget {
    /// The capture harness's bounds, as ONE definition both capture loops read.
    /// Two copies of a bound is how one path silently keeps a different rule
    /// than the other — the same failure the R2 script's single screen list
    /// exists to prevent.
    ///
    /// `noProgressLimit` is calibrated against the longest stall a HEALTHY
    /// capture actually shows, which `longestObservedStall` reports; the
    /// harness prints it under `ICECUBES_TRACE_READINESS=1` so the constant
    /// stays answerable to a measurement rather than to taste.
    ///
    /// THE MEASUREMENT, 2026-08-06, macabi capture binary, reported by the
    /// harness itself under `ICECUBES_TRACE_READINESS=1`:
    ///
    ///     screen             longestStall  progressObservations  ready
    ///     timeline                  2.755s                    5   true
    ///     tags-list                 0.000s                    0   true
    ///     media                     0.000s                    0   true
    ///     media-browser             0.000s                    0   true
    ///     trending-timeline       181.087s                    6   true
    ///
    /// READ THAT LAST ROW BEFORE CHANGING THE CONSTANT. A HEALTHY capture —
    /// quiescent, ready, exit 0, PNG written — shows a stall NINE TIMES the
    /// 20s limit and is not failed by it. So `noProgressLimit` is emphatically
    /// NOT "a multiple of the worst observed stall"; that reading would demand
    /// ~500s here and would be wrong. What makes the bound well-formed is
    /// something else, and it is worth stating exactly:
    ///
    /// THE OBSERVER SHARES THE MAIN ACTOR WITH THE WORK IT OBSERVES. Both
    /// capture loops poll from the main actor (`Task.sleep` on the Catalyst
    /// path, `CFRunLoopRunInMode` on the other), and interpreted body
    /// evaluation runs there too. So:
    ///
    /// - a WEDGED capture leaves the main actor free, the loop ticks every
    ///   50ms, `progressed` is false every tick, and it fails at 20s — faster
    ///   than the 30s total budget this replaces;
    /// - a BUSY capture starves the loop, so `observe` is simply not called
    ///   during the stall. It cannot produce a false failure, because the code
    ///   that would produce it does not run.
    ///
    /// That is a proof by exit code on the row above, not an assumption. At a
    /// 50ms cadence a freely-running loop would have ticked ~3,670 times
    /// inside that 181s window, and ANY of those ticks — `progressed: false`,
    /// ≥20s since the last progress — returns `.noProgress`. The capture
    /// returned `expiry=none`, so no such tick happened: the loop ran about 6
    /// times in 183s. `longestObservedStall` therefore measures MAIN-ACTOR
    /// OCCUPANCY, not unresponsiveness, and a big value is evidence of work,
    /// not of risk.
    ///
    /// THE RESIDUAL, stated because it is the one shape this cannot see:
    /// interpreted work running OFF the main actor while the main actor is
    /// idle and no body evaluation occurs for more than `noProgressLimit`.
    /// Then the loop ticks freely against flat level counters and fails a
    /// healthy capture. None of the five screens above exhibits it — including
    /// `trending-timeline`, whose whole point is an actor-isolated fetch. If a
    /// screen ever does, the fix is a monotonic work counter that advances
    /// while the main actor is idle, NOT a bigger constant: a bigger constant
    /// would equally delay the wedged case this exists to catch.
    ///
    /// `totalLimit` is a liveness backstop for a respawn loop only — it is not
    /// a settle budget. The slowest screen measured uses 183.8s of it.
    public static func captureHarness(
        startedAt: ContinuousClock.Instant
    ) -> CaptureReadinessBudget {
        CaptureReadinessBudget(
            startedAt: startedAt,
            noProgressLimit: .seconds(20),
            totalLimit: .seconds(900))
    }
}

extension InterpreterRenderSession {
    /// Body evaluations owned by this session's exact interpreter.
    public var renderActivity: InterpreterRenderActivity {
        InterpreterRenderActivityStore.for(interpreter).snapshot
    }
}

/// Bridge-owned activity is keyed weakly by interpreter so successive renders
/// cannot share revisions and completed sessions leave no process-global
/// retained state.
final class InterpreterRenderActivityStore {
    private static let stores =
        NSMapTable<AnyObject, InterpreterRenderActivityStore>
            .weakToStrongObjects()

    static func `for`(_ interpreter: Interpreter)
        -> InterpreterRenderActivityStore
    {
        if let existing = stores.object(forKey: interpreter) {
            return existing
        }
        let fresh = InterpreterRenderActivityStore()
        stores.setObject(fresh, forKey: interpreter)
        return fresh
    }

    private var bodyEvaluationCount: UInt64 = 0

    var snapshot: InterpreterRenderActivity {
        InterpreterRenderActivity(
            bodyEvaluationCount: bodyEvaluationCount)
    }

    func recordBodyEvaluation() {
        bodyEvaluationCount &+= 1
    }
}
