import Foundation

enum UnsafeCurrentTaskProbeError: Error {
    case synchronous
    case asynchronous
}

func unsafeCurrentTaskProbe() async -> String {
    let synchronous = Task.detached(priority: .low) {
        withUnsafeCurrentTask { first in
            guard let first else { return "sync:nil" }
            let identityAndHash = withUnsafeCurrentTask { second in
                guard let second else { return "false:false" }
                return "\(second == first)"
                    + ":\(second.hashValue == first.hashValue)"
            }
            let priorityMatches = first.priority == Task.currentPriority
            let basePriority = Int(first.basePriority.rawValue)
            first.cancel()
            return "sync:\(identityAndHash):\(priorityMatches):\(basePriority)"
                + ":\(first.isCancelled):\(Task.isCancelled)"
        }
    }
    var output = await synchronous.value

    let synchronousFailure = Task.detached {
        try withUnsafeCurrentTask { _ in
            if !Task.isCancelled {
                throw UnsafeCurrentTaskProbeError.synchronous
            }
            return "sync-throw-wrong"
        }
    }
    do {
        output += "|" + (try await synchronousFailure.value)
    } catch UnsafeCurrentTaskProbeError.synchronous {
        output += "|sync-error"
    } catch {
        output += "|sync-wrong-error"
    }

    let asynchronous = Task.detached(priority: .background) {
        await withUnsafeCurrentTask { first in
            guard let first else { return "async:nil" }
            let before = first.isCancelled
            let sameBefore = await withUnsafeCurrentTask { second in
                guard let second else { return false }
                await Task.yield()
                return second == first
            }
            first.cancel()
            await Task.yield()
            let sameAfter = withUnsafeCurrentTask { second in
                guard let second else { return false }
                return second == first
            }
            let basePriority = Int(first.basePriority.rawValue)
            return "async:\(before):\(sameBefore):\(sameAfter)"
                + ":\(basePriority):\(first.isCancelled):\(Task.isCancelled)"
        }
    }
    output += "|" + (await asynchronous.value)

    let asynchronousFailure = Task.detached {
        try await withUnsafeCurrentTask { _ in
            await Task.yield()
            if !Task.isCancelled {
                throw UnsafeCurrentTaskProbeError.asynchronous
            }
            return "async-throw-wrong"
        }
    }
    do {
        output += "|" + (try await asynchronousFailure.value)
    } catch UnsafeCurrentTaskProbeError.asynchronous {
        output += "|async-error"
    } catch {
        output += "|async-wrong-error"
    }

    return output
}

@MainActor
func parityNativeOutput() async throws -> String {
    await unsafeCurrentTaskProbe()
}
