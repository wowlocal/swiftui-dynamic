import Testing

@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// The DELIVERY-vs-PRESENTATION boundary of capture readiness, distilled to the
/// readiness state machine alone — no app, no network, no pixels.
///
/// Surfaced by `hashtag-timeline` (Timeline/View/TimelineTagHeaderView.swift +
/// TimelineViewModel.fetchTag). That screen's pinned header renders only
/// `if let tag`, and `tag` is assigned by a SECOND request the view model
/// issues after the page lands:
///
///     let tag: Tag = try await client.get(endpoint: Tags.tag(id: id))
///     withAnimation { self.tag = tag }
///
/// The capture harness waited on two conditions ANDed together — the session is
/// ready, and the screen's own endpoints have been served — and sampled both in
/// the same instant. But `NetworkBridge` records a replayed resource in a
/// `defer` on the call that RETURNS its bytes, so "served" becomes true while
/// the app still has to decode them, assign the model and evaluate a body.
/// Readiness earned by the EARLIER settle of the rows is still standing in that
/// window, so the wait could exit inside it and capture a tree the response had
/// not reached — dropping the header entirely and shifting every row up by its
/// 84pt band.
///
/// Measured 2026-08-08: the same commit, binary, fixtures and source root
/// produced a header-less capture once and a correct one on every repeat, which
/// is what a race looks like and what a "the checkout path decides it" reading
/// of the same evidence missed.
@Suite
struct CaptureResponseArrivalReadinessTests {
    private static let quiescent = InterpreterRuntimeActivity(
        activeTaskCount: 0,
        scheduledTaskCount: 0,
        activeHostOperationCount: 0,
        activeContinuationCount: 0)
    private static let working = InterpreterRuntimeActivity(
        activeTaskCount: 1,
        scheduledTaskCount: 1,
        activeHostOperationCount: 0,
        activeContinuationCount: 1)

    private func observe(
        _ readiness: inout InterpreterCaptureReadiness,
        _ activity: InterpreterRuntimeActivity,
        revision: UInt64
    ) {
        readiness.observe(
            runtimeActivity: activity,
            renderActivity: InterpreterRenderActivity(
                bodyEvaluationCount: revision))
    }

    /// A settled session that is handed a gating response is NOT ready until a
    /// body has been evaluated after it.
    @Test
    func deliveredResponseWithdrawsReadinessUntilTheTreeEvaluatesPastIt() {
        var readiness = InterpreterCaptureReadiness(initialRenderRevision: 10)

        // The rows fetch, land and settle: the session earns readiness.
        observe(&readiness, Self.working, revision: 10)
        #expect(!readiness.isReadyForCapture)
        observe(&readiness, Self.quiescent, revision: 11)
        #expect(readiness.isReadyForCapture)

        // The header's own response is handed to the app at revision 11.
        // Nothing has decoded or rendered it yet.
        readiness.noteAwaitedResponse(atRenderRevision: 11)
        #expect(!readiness.isReadyForCapture)

        // The instant that used to end the wait: the bytes are served and the
        // runtime looks quiescent, because the continuation that decodes them
        // has not been resumed. Capturing here is the header-less frame.
        observe(&readiness, Self.quiescent, revision: 11)
        #expect(!readiness.isReadyForCapture)

        // Decode and assignment run.
        observe(&readiness, Self.working, revision: 11)
        #expect(!readiness.isReadyForCapture)

        // `self.tag = tag` re-evaluates the body: now the tree shows it.
        observe(&readiness, Self.quiescent, revision: 12)
        #expect(readiness.isReadyForCapture)
        #expect(readiness.readyRenderRevision == 12)
    }

    /// A second gating response raises the bar rather than lowering it — two
    /// endpoints in flight cannot let the earlier one's re-render satisfy the
    /// later one.
    @Test
    func aLaterResponseRaisesTheRevisionTheTreeMustPass() {
        var readiness = InterpreterCaptureReadiness(initialRenderRevision: 1)
        observe(&readiness, Self.working, revision: 1)
        observe(&readiness, Self.quiescent, revision: 2)
        #expect(readiness.isReadyForCapture)

        readiness.noteAwaitedResponse(atRenderRevision: 5)
        readiness.noteAwaitedResponse(atRenderRevision: 3)
        #expect(readiness.awaitedResponseRenderRevision == 5)

        observe(&readiness, Self.quiescent, revision: 5)
        #expect(!readiness.isReadyForCapture)
        observe(&readiness, Self.quiescent, revision: 6)
        #expect(readiness.isReadyForCapture)
    }

    /// A NON-WEDGE guard, not a second demonstration of the defect: this one
    /// passes with the fix removed too. It exists because the failure mode of
    /// this fix is the opposite of the bug — a barrier that never clears turns
    /// every capture into a readiness timeout — so it pins that a re-render
    /// after the response does clear it.
    @Test
    func aBusySessionPastTheResponseIsStillNotReady() {
        var readiness = InterpreterCaptureReadiness(initialRenderRevision: 0)
        observe(&readiness, Self.working, revision: 0)
        observe(&readiness, Self.quiescent, revision: 1)
        #expect(readiness.isReadyForCapture)

        readiness.noteAwaitedResponse(atRenderRevision: 1)
        for _ in 0..<20 {
            observe(&readiness, Self.working, revision: 2)
            #expect(!readiness.isReadyForCapture)
        }
        observe(&readiness, Self.quiescent, revision: 2)
        #expect(readiness.isReadyForCapture)
    }
}
