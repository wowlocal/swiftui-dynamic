/// A read-only value snapshot of asynchronous work currently owned by one
/// interpreter. Capture and test harnesses can observe this property without
/// reaching into mutable runtime records or guessing a framework-specific
/// completion delay.
///
/// Quiescence covers runtime-owned source tasks and their suspension
/// resources. It intentionally makes no claim about unsubmitted future timers
/// or host work that has not entered the interpreter runtime.
public nonisolated struct InterpreterRuntimeActivity:
    Sendable, Equatable
{
    public let activeTaskCount: Int
    public let scheduledTaskCount: Int
    public let activeHostOperationCount: Int
    public let activeContinuationCount: Int

    public var isQuiescent: Bool {
        activeTaskCount == 0
            && scheduledTaskCount == 0
            && activeHostOperationCount == 0
            && activeContinuationCount == 0
    }
}

extension Interpreter {
    public var runtimeActivity: InterpreterRuntimeActivity {
        InterpreterRuntimeActivity(
            activeTaskCount: concurrencyRuntime.activeRecordCount,
            scheduledTaskCount: scheduledTasks.count,
            activeHostOperationCount:
                concurrencyRuntime.activeHostOperationCount,
            activeContinuationCount:
                concurrencyRuntime.activeContinuationCount)
    }
}
