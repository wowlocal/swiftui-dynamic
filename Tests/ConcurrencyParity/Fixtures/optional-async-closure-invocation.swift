func optionalAsyncClosureIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

func optionalAsyncClosureArgumentTrap() -> Int {
    fatalError("nil optional closure evaluated its argument")
}

func optionalAsyncClosureInvocationProbe() async -> String {
    let callback: (@Sendable (Int) async -> String)? = { value in
        let before = optionalAsyncClosureIsolation()
        await Task.yield()
        let after = optionalAsyncClosureIsolation()
        return "live:\(value):\(before)|\(after)"
    }
    let live = await Task.detached {
        await callback?(7)
    }.value ?? "missing"

    let missing: (@Sendable (Int) async -> String)? = nil
    let nilResult = await Task.detached {
        await missing?(optionalAsyncClosureArgumentTrap())
    }.value ?? "nil"
    return "\(live)|\(nilResult)"
}

func parityNativeOutput() async throws -> String {
    await optionalAsyncClosureInvocationProbe()
}
