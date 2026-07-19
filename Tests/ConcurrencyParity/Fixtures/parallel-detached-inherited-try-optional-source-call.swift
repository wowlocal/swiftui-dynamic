func physicalInheritedTryOptionalIsolation(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

enum PhysicalInheritedTryOptionalFailure: Error {
    case expected
}

final class PhysicalInheritedTryOptionalProbe: @unchecked Sendable {
    private let shouldFail: Bool
    private var observation = ""

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func refreshDevicesAPIData() async throws {
        let before = physicalInheritedTryOptionalIsolation()
        await Task.yield()
        let after = physicalInheritedTryOptionalIsolation()
        await record("\(shouldFail ? "failure" : "success"):\(before)|\(after)")
        if shouldFail {
            throw PhysicalInheritedTryOptionalFailure.expected
        }
    }

    func launch() -> Task<Void?, Never> {
        Task.detached(priority: .utility) {
            try? await self.refreshDevicesAPIData()
        }
    }

    @MainActor
    private func record(_ value: String) {
        observation = value
    }

    @MainActor
    func result() -> String {
        observation
    }
}

func parallelDetachedInheritedTryOptionalSourceCallProbe() async -> String {
    let successProbe = PhysicalInheritedTryOptionalProbe(shouldFail: false)
    let success: Void? = await successProbe.launch().value
    let successObservation = await successProbe.result()

    let failureProbe = PhysicalInheritedTryOptionalProbe(shouldFail: true)
    let failure: Void? = await failureProbe.launch().value
    let failureObservation = await failureProbe.result()

    return "\(successObservation)#\(success == nil ? "nil" : "some")"
        + "|\(failureObservation)#\(failure == nil ? "nil" : "some")"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedInheritedTryOptionalSourceCallProbe()
}
