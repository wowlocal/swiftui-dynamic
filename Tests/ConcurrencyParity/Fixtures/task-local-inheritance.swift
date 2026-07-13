@MainActor
func taskLocalInheritanceProbe() async -> String {
    await parityWithTaskLocalValue("parent") {
        let parent = await parityReadTaskLocal()
        let child = Task {
            let inherited = await parityReadTaskLocal()
            let nested = await parityWithTaskLocalValue("child") {
                _ = await parityYield("inside-binding")
                return await parityReadTaskLocal()
            }
            let restored = await parityReadTaskLocal()
            return inherited + ":" + nested + ":" + restored
        }
        let detached = Task.detached {
            await parityReadTaskLocal()
        }
        return parent + "," + (await child.value) + "," + (await detached.value)
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskLocalInheritanceProbe()
}
