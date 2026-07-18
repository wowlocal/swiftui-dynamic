import SwiftInterpreter

nonisolated func executorNeutralDescriptors() -> String {
    let session = RuntimeSessionID(rawValue: 7)
    let task = RuntimeTaskID(rawValue: 11)
    let deadline = RuntimeInstant.zero.advanced(by: .milliseconds(3))
    return "\(session)|\(task)|\(deadline.nanoseconds)"
}
