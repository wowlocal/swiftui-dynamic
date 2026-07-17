struct ParityMacAliasValue {
    let number: Int

    func platform() -> String {
        "mac"
    }
}

struct ParityOtherAliasValue {
    let number: Int

    func platform() -> String {
        "other"
    }
}

#if os(watchOS)
typealias ParityPlatformAliasValue = ParityOtherAliasValue
#else
typealias ParityPlatformAliasValue = ParityMacAliasValue
#endif

struct ParityAliasContainer {
    #if os(watchOS)
    typealias Value = ParityOtherAliasValue
    #else
    typealias Value = ParityPlatformAliasValue
    #endif
}

actor ParityAliasActor {
    let value: ParityAliasContainer.Value

    init(value: ParityAliasContainer.Value) {
        self.value = value
    }

    func snapshot() -> String {
        value.platform() + ":" + String(value.number)
    }
}

@MainActor
func typeAliasMetadataProbe() async -> String {
    let value = ParityAliasContainer.Value(number: 42)
    let actor = ParityAliasActor(value: value)
    return await actor.snapshot()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await typeAliasMetadataProbe()
}
