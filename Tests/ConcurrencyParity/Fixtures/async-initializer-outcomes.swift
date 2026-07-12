enum AsyncInitializerProbeError: Error {
    case rejected
}

struct ThrowingAsyncValue {
    let value: String

    init(value: String, shouldThrow: Bool) async throws {
        let resolved = await parityYield(value)
        if shouldThrow {
            throw AsyncInitializerProbeError.rejected
        }
        self.value = resolved
    }
}

struct FailableAsyncValue {
    let value: String

    init?(value: String, accepted: Bool) async {
        let resolved = await parityYield(value)
        if !accepted {
            return nil
        }
        self.value = resolved
    }
}

@MainActor
func asyncInitializerOutcomeProbe() async -> String {
    let success = try! await ThrowingAsyncValue(
        value: "success", shouldThrow: false)
    let failure = try? await ThrowingAsyncValue(
        value: "failure", shouldThrow: true)
    let accepted = await FailableAsyncValue(
        value: "accepted", accepted: true)
    let rejected = await FailableAsyncValue(
        value: "rejected", accepted: false)
    return success.value
        + "," + (failure == nil ? "threw" : "wrong")
        + "," + (accepted?.value ?? "missing")
        + "," + (rejected == nil ? "rejected" : "wrong")
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncInitializerOutcomeProbe()
}
