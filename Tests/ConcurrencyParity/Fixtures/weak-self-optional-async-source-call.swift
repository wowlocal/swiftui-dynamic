func weakSelfOptionalAsyncIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

func weakSelfOptionalAsyncArgumentTrap() -> Int {
    fatalError("nil optional chaining evaluated its argument")
}

final class WeakSelfOptionalAsyncSourceCallProbe: @unchecked Sendable {
    func update() async -> String {
        let before = weakSelfOptionalAsyncIsolation()
        await Task.yield()
        let after = weakSelfOptionalAsyncIsolation()
        return "alive:\(before)|\(after)"
    }

    func update(_ value: Int) async -> String {
        await Task.yield()
        return "unexpected:\(value)"
    }

    func retainedResult() async -> String {
        await Task.detached { [weak self] in
            await self?.update()
        }.value ?? "missing"
    }
}

func weakSelfOptionalAsyncSourceCallProbe() async -> String {
    let retained = WeakSelfOptionalAsyncSourceCallProbe()
    let alive = await retained.retainedResult()
    let missing: WeakSelfOptionalAsyncSourceCallProbe? = nil
    let nilResult = await Task.detached {
        await missing?.update(weakSelfOptionalAsyncArgumentTrap())
    }.value ?? "nil"
    return "\(alive)|\(nilResult)"
}

func parityNativeOutput() async throws -> String {
    await weakSelfOptionalAsyncSourceCallProbe()
}
