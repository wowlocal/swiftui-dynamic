@MainActor
final class StoreMessagesProbe {
    func updatesLoop() async -> String {
        await Task.yield()
        return "member"
    }

    func run() async -> String {
        await Task.detached(priority: .background) {
            await self.updatesLoop()
        }.value
    }
}

func updatesLoop() async -> String {
    "global"
}

@MainActor
func detachedSourceMemberCallTargetProbe() async -> String {
    let probe = StoreMessagesProbe()
    return "target:\(await probe.run())"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await detachedSourceMemberCallTargetProbe()
}
