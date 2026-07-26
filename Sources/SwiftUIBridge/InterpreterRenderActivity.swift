import Foundation
import SwiftInterpreter

/// A value snapshot of SwiftUI body work performed for one interpreted render
/// session. Capture harnesses can compare revisions without consulting the
/// process-global compatibility counter on `InterpretedView`.
public struct InterpreterRenderActivity: Sendable, Equatable {
    public let bodyEvaluationCount: UInt64
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
