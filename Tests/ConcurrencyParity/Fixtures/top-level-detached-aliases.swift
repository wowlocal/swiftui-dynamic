enum TopLevelDetachedAliasProbeError: Error {
    case asyncDetachedBoom
    case detachBoom
}

nonisolated func makeAsyncDetachedAliasSuccess() -> Task<String, Never> {
    asyncDetached(priority: .utility) {
        let name = Task.name ?? "nil"
        let priority = Int(Task.currentPriority.rawValue)
        let local = await parityReadTaskLocal()
        await parityRecordHostGatewayEvent("asyncDetached-started")
        await parityWaitTaskValueGate()
        return "asyncDetached:" + name + ":" + String(priority) + ":" + local
    }
}

nonisolated func makeDetachAliasSuccess() -> Task<String, Never> {
    detach(priority: .background) {
        let name = Task.name ?? "nil"
        let priority = Int(Task.currentPriority.rawValue)
        let local = await parityReadTaskLocal()
        await parityRecordHostGatewayEvent("detach-started")
        await parityWaitTaskValueGate()
        return "detach:" + name + ":" + String(priority) + ":" + local
    }
}

nonisolated func makeAsyncDetachedAliasFailure()
    -> Task<String, any Error>
{
    asyncDetached { () async throws -> String in
        await Task.yield()
        throw TopLevelDetachedAliasProbeError.asyncDetachedBoom
    }
}

nonisolated func makeDetachAliasFailure() -> Task<String, any Error> {
    detach { () async throws -> String in
        await Task.yield()
        throw TopLevelDetachedAliasProbeError.detachBoom
    }
}

@MainActor
func topLevelDetachedAliasesProbe() async -> String {
    await parityWithTaskLocalValue("parent") {
        let asyncSuccess = makeAsyncDetachedAliasSuccess()
        let detachSuccess = makeDetachAliasSuccess()
        let asyncFailure = makeAsyncDetachedAliasFailure()
        let detachFailure = makeDetachAliasFailure()

        while !parityHostGatewayEvents().contains("asyncDetached-started")
                || !parityHostGatewayEvents().contains("detach-started") {
            await Task.yield()
        }
        parityOpenTaskValueGate()

        let asyncValue = await asyncSuccess.value
        let detachValue = await detachSuccess.value

        let asyncFailureValue: String
        do {
            _ = try await asyncFailure.value
            asyncFailureValue = "asyncDetached-unexpected-success"
        } catch TopLevelDetachedAliasProbeError.asyncDetachedBoom {
            asyncFailureValue = "asyncDetached-boom"
        } catch {
            asyncFailureValue = "asyncDetached-unexpected-error"
        }

        let detachFailureValue: String
        do {
            _ = try await detachFailure.value
            detachFailureValue = "detach-unexpected-success"
        } catch TopLevelDetachedAliasProbeError.detachBoom {
            detachFailureValue = "detach-boom"
        } catch {
            detachFailureValue = "detach-unexpected-error"
        }

        return asyncValue + "|" + detachValue
            + "|" + asyncFailureValue + "|" + detachFailureValue
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await topLevelDetachedAliasesProbe()
}
