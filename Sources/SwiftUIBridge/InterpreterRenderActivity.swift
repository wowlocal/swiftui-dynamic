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

    public init(initialRenderRevision: UInt64) {
        self.initialRenderRevision = initialRenderRevision
    }

    public var isReadyForCapture: Bool {
        readyRenderRevision != nil
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
        guard let firstActiveRenderRevision else {
            readyRenderRevision = revision
            return
        }
        if revision > firstActiveRenderRevision {
            readyRenderRevision = revision
        }
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
