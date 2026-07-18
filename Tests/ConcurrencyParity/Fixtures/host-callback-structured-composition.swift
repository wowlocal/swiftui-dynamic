@MainActor
final class HostCallbackStructuredCompositionProbe {
    var phase = "idle"
    var worker: Task<Void, Never>?

    func makeCallback() -> () -> Void {
        {
            self.phase = "started"
            self.worker = Task.detached {
                async let left = self.value(2)
                async let right = self.value(3)
                let asyncLetTotal = await left + right

                let shared = Task.detached {
                    await withTaskGroup(of: Int.self) { group in
                        for value in 1...4 {
                            group.addTask { value }
                        }
                        var total = 0
                        for _ in 1...4 {
                            total += await group.next() ?? 0
                        }
                        return total
                    }
                }
                let observerOne = Task { await shared.value }
                let observerTwo = Task { await shared.value }
                let firstSharedValue = await observerOne.value
                let secondSharedValue = await observerTwo.value

                let cancellable = Task.detached {
                    await withTaskCancellationHandler(operation: {
                        do {
                            try await Task.sleep(for: .milliseconds(200))
                            return "completed"
                        } catch {
                            return Task.isCancelled ? "cancelled" : "failed"
                        }
                    }, onCancel: {})
                }
                cancellable.cancel()
                let cancellation = await cancellable.value

                await self.finish(
                    asyncLetTotal: asyncLetTotal,
                    firstSharedValue: firstSharedValue,
                    secondSharedValue: secondSharedValue,
                    cancellation: cancellation
                )
            }
        }
    }

    @concurrent
    nonisolated func value(_ value: Int) async -> Int {
        await Task.yield()
        return value
    }

    func finish(
        asyncLetTotal: Int,
        firstSharedValue: Int,
        secondSharedValue: Int,
        cancellation: String
    ) {
        phase = "async:\(asyncLetTotal)"
            + "|shared:\(firstSharedValue):\(secondSharedValue)"
            + "|\(cancellation)"
    }
}

@MainActor
let parityHostCallbackStructuredCompositionProbe =
    HostCallbackStructuredCompositionProbe()

@MainActor
func parityInterpreterHostCallbackStructuredComposition() -> () -> Void {
    parityHostCallbackStructuredCompositionProbe.makeCallback()
}

@MainActor
func parityNativeOutput() async throws -> String {
    let callback = parityInterpreterHostCallbackStructuredComposition()
    callback()
    let immediate = parityHostCallbackStructuredCompositionProbe.phase
    await parityHostCallbackStructuredCompositionProbe.worker?.value
    return immediate + ","
        + parityHostCallbackStructuredCompositionProbe.phase
}
