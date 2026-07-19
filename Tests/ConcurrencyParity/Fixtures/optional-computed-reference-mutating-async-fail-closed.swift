struct OptionalComputedReferenceValue {
    var text: String

    mutating func mutate() async {
        text += "-entered"
        await Task.yield()
        text += "-resumed"
    }
}

final class OptionalComputedReferenceBox: @unchecked Sendable {
    var storage: OptionalComputedReferenceValue?
    init(_ storage: OptionalComputedReferenceValue?) { self.storage = storage }

    var value: OptionalComputedReferenceValue? {
        get { storage }
        set { storage = newValue }
    }
}

func optionalComputedReferenceMutatingAsyncFailClosedProbe() async -> String {
    let box = OptionalComputedReferenceBox(
        OptionalComputedReferenceValue(text: "seed"))
    await box.value?.mutate()
    return box.storage?.text ?? "nil"
}

func parityNativeOutput() async throws -> String {
    await optionalComputedReferenceMutatingAsyncFailClosedProbe()
}
