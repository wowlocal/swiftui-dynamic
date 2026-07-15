enum TaskGroupDeprecatedSpawnError: Error {
    case child
}

@MainActor
func taskGroupDeprecatedSpawnProbe() async -> String {
    let ordinary = await withTaskGroup(of: String.self) { group in
        group.spawn(priority: .high) {
            "ordinary-value"
        }
        return await group.next() ?? "ordinary-missing"
    }

    let throwing = await withThrowingTaskGroup(of: String.self) { group in
        group.spawn(priority: .high) {
            "throwing-value"
        }
        let success = (try? await group.next()) ?? "throwing-missing"

        group.spawn {
            throw TaskGroupDeprecatedSpawnError.child
        }
        do {
            _ = try await group.next()
            return success + ":failure-missing"
        } catch TaskGroupDeprecatedSpawnError.child {
            return success + ":failure-child"
        } catch {
            return success + ":failure-wrong"
        }
    }

    return ordinary + "|" + throwing
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupDeprecatedSpawnProbe()
}
