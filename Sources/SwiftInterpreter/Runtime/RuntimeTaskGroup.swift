/// Source-facing capability for one active nonthrowing task-group scope.
/// Swift prevents this value from escaping through `inout`; runtime checks
/// retain the same lifetime boundary for dynamically invoked source.
final class RuntimeTaskGroup {
    let record: RuntimeTaskGroupRecord
    private(set) var childHandles: [RuntimeTaskHandle] = []
    private(set) var isClosed = false
    private(set) var isCancellationRequested = false

    init(record: RuntimeTaskGroupRecord) {
        self.record = record
    }

    var id: RuntimeTaskGroupID { record.id }
    var ownerTaskID: RuntimeTaskID { record.ownerTaskID }

    func requireActive(ownerTaskID: RuntimeTaskID?) throws {
        guard !isClosed else {
            throw RuntimeError(message: "task group escaped its source scope")
        }
        guard ownerTaskID == record.ownerTaskID else {
            throw RuntimeError(message:
                "task group can only be used by its owning task")
        }
    }

    func append(_ handle: RuntimeTaskHandle) {
        precondition(!isClosed, "cannot add a child to a closed task group")
        childHandles.append(handle)
    }

    func requestCancellation() {
        precondition(!isClosed, "cannot cancel a closed task group")
        isCancellationRequested = true
    }

    func close() {
        precondition(!isClosed, "task group closed twice")
        isClosed = true
        childHandles.removeAll(keepingCapacity: false)
    }
}
