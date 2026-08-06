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
    /// What each still-scheduled task is waiting on, as
    /// `kind:state[:suspension]`. A quiescence timeout otherwise reports only
    /// a COUNT, which cannot distinguish "waiting on a host response that
    /// never arrives" from "sleeping until a frozen clock advances" from "a
    /// steady-state respawn loop" — three failures with three different fixes.
    public var pendingTaskDescriptions: [String] {
        scheduledTasks
            .map { handle in
                "\(handle.kind):\(handle.state)"
                    + (handle.suspension.map { ":\($0)" } ?? "")
            }
            .sorted()
    }

    /// Each unresumed continuation as `id:state:function` — the `function`
    /// being the source function that suspended, which names the code that
    /// owes a `resume`.
    public var pendingContinuationDescriptions: [String] {
        concurrencyRuntime.continuations.values
            .map { record in
                "\(record.id):\(record.state)"
                    + ":\(record.sourceToken?.function ?? "released")"
            }
            .sorted()
    }

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
