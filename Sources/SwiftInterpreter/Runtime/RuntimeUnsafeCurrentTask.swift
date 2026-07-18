/// Source-facing capability passed to `withUnsafeCurrentTask` operations.
///
/// It deliberately stores logical runtime identity instead of borrowing a
/// `RuntimeTaskHandle`: root and host-callback tasks need not have a source
/// handle, and creating one here would add an ownership edge. The runtime is
/// weak because Swift guarantees the capability only for the dynamic extent
/// of the operation.
@MainActor
final class RuntimeUnsafeCurrentTaskLease {
    private(set) var isValid = true

    func invalidate() { isValid = false }
}

@MainActor
final class RuntimeUnsafeCurrentTask: HostValueSemantic,
    HostRuntimeEquatable, @preconcurrency CustomStringConvertible {
    private weak var runtime: CooperativeConcurrencyRuntime?
    private let runtimeIdentity: ObjectIdentifier
    private let lease: RuntimeUnsafeCurrentTaskLease
    let taskID: RuntimeTaskID

    init(
        runtime: CooperativeConcurrencyRuntime,
        taskID: RuntimeTaskID,
        lease: RuntimeUnsafeCurrentTaskLease
    ) {
        self.runtime = runtime
        runtimeIdentity = ObjectIdentifier(runtime)
        self.taskID = taskID
        self.lease = lease
    }

    private init(
        runtime: CooperativeConcurrencyRuntime?,
        runtimeIdentity: ObjectIdentifier,
        taskID: RuntimeTaskID,
        lease: RuntimeUnsafeCurrentTaskLease
    ) {
        self.runtime = runtime
        self.runtimeIdentity = runtimeIdentity
        self.taskID = taskID
        self.lease = lease
    }

    private func activeRecord() throws -> RuntimeTaskRecord {
        guard lease.isValid,
              let runtime, let record = runtime.records[taskID] else {
            throw RuntimeError(message:
                "UnsafeCurrentTask escaped the dynamic extent of its operation")
        }
        return record
    }

    func isCancelled() throws -> Bool {
        let record = try activeRecord()
        let isRequested = record.cancellation.isRequested
        if isRequested {
            runtime?.observeCancellation(
                taskID, inferredSource: .unsafeCurrentTask)
        }
        return isRequested
    }

    func priority() throws -> RuntimeTaskPriority {
        try activeRecord().effectivePriority
    }

    func basePriority() throws -> RuntimeTaskPriority {
        try activeRecord().basePriority
    }

    func cancel() throws {
        guard let runtime else {
            throw RuntimeError(message:
                "UnsafeCurrentTask escaped the dynamic extent of its operation")
        }
        let record = try activeRecord()
        runtime.requestCancellation(record, source: .unsafeCurrentTask)
    }

    func identityHashValue() throws -> Int {
        _ = try activeRecord()
        var hasher = Hasher()
        hasher.combine(runtimeIdentity)
        hasher.combine(taskID)
        return hasher.finalize()
    }

    func copiedHostValue() -> Any {
        RuntimeUnsafeCurrentTask(
            runtime: runtime,
            runtimeIdentity: runtimeIdentity,
            taskID: taskID,
            lease: lease)
    }

    func runtimeEquals(_ other: Any) -> Bool? {
        guard let other = other as? RuntimeUnsafeCurrentTask else {
            return false
        }
        guard lease.isValid, other.lease.isValid,
              GeneratedConcurrencySurface.nominalMemberIntrinsic(
                typeName: "UnsafeCurrentTask", memberName: "==")
                == .currentTaskIdentityEquals else { return nil }
        return runtimeIdentity == other.runtimeIdentity
            && taskID == other.taskID
    }

    var description: String { "UnsafeCurrentTask(\(taskID))" }
}
