@MainActor
final class ParityInitializerMetadataOwner {
    nonisolated let observation: String

    init(label: String) {
        observation = "isolated:"
            + parityCurrentIsolationMatches(MainActor.shared)
            + ":" + label
    }

    nonisolated init(nonisolatedLabel label: String) {
        observation = "nonisolated:"
            + parityCurrentIsolationKind()
            + ":" + label
    }
}

struct ParityFailableInitializerToken {
    let value: String

    init?(value: String, accepted: Bool) {
        guard accepted else { return nil }
        self.value = value
    }
}

actor ParityInitializerMetadataRelay {
    func echo(_ value: String) -> String {
        value
    }
}

@MainActor
func initializerDeclarationMetadataProbe() async -> String {
    let isolated = ParityInitializerMetadataOwner(
        label: "foodtruck").observation
    let nonisolated = ParityInitializerMetadataOwner(
        nonisolatedLabel: "store").observation
    let accepted = ParityFailableInitializerToken(
        value: "accepted", accepted: true)?.value ?? "missing"
    let rejected = ParityFailableInitializerToken(
        value: "wrong", accepted: false) == nil ? "rejected" : "wrong"
    let value = isolated + "|" + nonisolated
        + "|" + accepted + "|" + rejected
    return await ParityInitializerMetadataRelay().echo(value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await initializerDeclarationMetadataProbe()
}
