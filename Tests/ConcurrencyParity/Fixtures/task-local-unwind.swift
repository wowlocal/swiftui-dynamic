enum ParityTaskLocalError: Error {
    case expected
    case wrongBinding
}

@MainActor
func taskLocalUnwindProbe() async -> String {
    await parityWithTaskLocalValue("parent") {
        let afterThrow: String
        do {
            _ = try await parityWithTaskLocalValue("throwing") {
                _ = await parityYield("inside-throwing-binding")
                guard await parityReadTaskLocal() == "throwing" else {
                    throw ParityTaskLocalError.wrongBinding
                }
                throw ParityTaskLocalError.expected
            }
            afterThrow = "missed-throw"
        } catch ParityTaskLocalError.expected {
            afterThrow = await parityReadTaskLocal()
        } catch {
            afterThrow = "wrong-error"
        }

        let cancelled = Task {
            do {
                _ = try await parityWithTaskLocalValue("cancelled") {
                    guard await parityReadTaskLocal() == "cancelled" else {
                        return "wrong-binding"
                    }
                    try await parityWaitForever()
                    return "missed-cancellation"
                }
                return "missed-cancellation"
            } catch is CancellationError {
                return await parityReadTaskLocal()
            } catch {
                return "wrong-error"
            }
        }
        await parityAwaitWaitStarted()
        cancelled.cancel()

        return afterThrow + "," + (await cancelled.value)
    }
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskLocalUnwindProbe()
}
