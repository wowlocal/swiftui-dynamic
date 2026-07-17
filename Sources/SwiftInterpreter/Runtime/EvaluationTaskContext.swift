import Foundation
import SwiftSyntax

/// Mutable evaluator state owned by exactly one interpreted source task.
///
/// The interpreter remains MainActor-confined while the concurrency runtime
/// is cooperative, but native actor reentrancy means two source tasks can
/// interleave at any host suspension. Keeping their dynamic stacks in this
/// object makes that ownership explicit and removes the need to park shared
/// fields on `Interpreter` around every await.
final class EvaluationTaskContext {
    @TaskLocal static var current: EvaluationTaskContext?

    let id: UInt64
    let runtimeTaskID: RuntimeTaskID?
    let runtimeEntry: RuntimeEntry?
    let runtimeSessionID: RuntimeSessionID?
    let isAsyncSession: Bool
    var priority: RuntimeTaskPriority
    let taskLocals: RuntimeTaskLocalStorage
    weak var interpreter: Interpreter?
    let initialExecutor: RuntimeExecutorKind
    var currentExecutor: RuntimeExecutorKind

    var steps = 0
    var callDepth = 0
    var evaluationDepth = 0
    var resolveAnnotatedDepth = 0
    var synchronousTaskDepth = 0
    var asyncTemporarySerial = 0

    var activeExtensionFrames: Set<ExtensionFrame> = []
    var activeInitializers: Set<SyntaxIdentifier> = []
    var initializingInstances: Set<ObjectIdentifier> = []
    var activeFunctionBodies: Set<SyntaxIdentifier> = []
    var activeEqualityPairs: Set<Interpreter.InstanceEqualityPair> = []
    var activePropertyObservers: Set<Interpreter.ObserverKey> = []
    var activeCollisionProperties: Set<String> = []
    var dependencyInFlight: Set<String> = []

    var callStackNames: [String] = []
    var lexicalOwnerFrames: [AnyObject] = []
    /// Static executor context of the currently evaluated source declaration.
    /// A `nil` frame is intentional: a plain/nonisolated declaration may run
    /// dynamically on MainActor without making closures formed in its body
    /// MainActor-isolated.
    var lexicalExecutorFrames: [RuntimeExecutorKind?] = []
    var expectedAnnotationStack: [String] = []
    var enclosingReturnAnnotations: [String?] = []
    var viewIdentitySalts: [String] = []
    var structuredScopeFrames: [RuntimeStructuredScopeFrame] = []
    var deferredExtensionRetry = false

    init(
        id: UInt64,
        runtimeTaskID: RuntimeTaskID? = nil,
        runtimeEntry: RuntimeEntry? = nil,
        runtimeSessionID: RuntimeSessionID? = nil,
        isAsyncSession: Bool = false,
        priority: RuntimeTaskPriority = .medium,
        executor: RuntimeExecutorKind = .mainActor,
        taskLocals: RuntimeTaskLocalStorage = RuntimeTaskLocalStorage(),
        interpreter: Interpreter
    ) {
        precondition(
            runtimeEntry == nil || runtimeSessionID == nil
                || runtimeEntry?.id == runtimeSessionID,
            "evaluation context runtime entry and session ID must agree")
        self.id = id
        self.runtimeTaskID = runtimeTaskID
        self.runtimeEntry = runtimeEntry
        self.runtimeSessionID = runtimeEntry?.id ?? runtimeSessionID
        self.isAsyncSession = isAsyncSession
        self.priority = priority
        initialExecutor = executor
        currentExecutor = executor
        self.taskLocals = taskLocals
        self.interpreter = interpreter
    }

    var isDynamicallyEmpty: Bool {
        steps == 0
            && callDepth == 0
            && evaluationDepth == 0
            && resolveAnnotatedDepth == 0
            && synchronousTaskDepth == 0
            && asyncTemporarySerial == 0
            && activeExtensionFrames.isEmpty
            && activeInitializers.isEmpty
            && initializingInstances.isEmpty
            && activeFunctionBodies.isEmpty
            && activeEqualityPairs.isEmpty
            && activePropertyObservers.isEmpty
            && activeCollisionProperties.isEmpty
            && dependencyInFlight.isEmpty
            && callStackNames.isEmpty
            && lexicalOwnerFrames.isEmpty
            && lexicalExecutorFrames.isEmpty
            && expectedAnnotationStack.isEmpty
            && enclosingReturnAnnotations.isEmpty
            && viewIdentitySalts.isEmpty
            && structuredScopeFrames.isEmpty
            && taskLocals.isEmpty
            && currentExecutor == initialExecutor
            && !deferredExtensionRetry
    }

    /// Break task-owned capture graphs as soon as evaluation completes. The
    /// context object can temporarily outlive execution through a native Task
    /// handle or host callback capability, but completed frames must not.
    func removeAllDynamicState() {
        precondition(
            structuredScopeFrames.isEmpty,
            "task context completed with an active structured scope")
        steps = 0
        callDepth = 0
        evaluationDepth = 0
        resolveAnnotatedDepth = 0
        synchronousTaskDepth = 0
        asyncTemporarySerial = 0
        activeExtensionFrames.removeAll(keepingCapacity: false)
        activeInitializers.removeAll(keepingCapacity: false)
        initializingInstances.removeAll(keepingCapacity: false)
        activeFunctionBodies.removeAll(keepingCapacity: false)
        activeEqualityPairs.removeAll(keepingCapacity: false)
        activePropertyObservers.removeAll(keepingCapacity: false)
        activeCollisionProperties.removeAll(keepingCapacity: false)
        dependencyInFlight.removeAll(keepingCapacity: false)
        callStackNames.removeAll(keepingCapacity: false)
        lexicalOwnerFrames.removeAll(keepingCapacity: false)
        lexicalExecutorFrames.removeAll(keepingCapacity: false)
        expectedAnnotationStack.removeAll(keepingCapacity: false)
        enclosingReturnAnnotations.removeAll(keepingCapacity: false)
        viewIdentitySalts.removeAll(keepingCapacity: false)
        structuredScopeFrames.removeAll(keepingCapacity: false)
        taskLocals.removeAll()
        currentExecutor = initialExecutor
        deferredExtensionRetry = false
    }
}
