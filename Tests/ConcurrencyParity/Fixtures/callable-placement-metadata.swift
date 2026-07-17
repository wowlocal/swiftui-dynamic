@MainActor
final class ParityCallablePlacementOwner {
    static func typeValue(label: String) -> String {
        "type:" + parityCurrentIsolationMatches(MainActor.shared)
            + ":" + label
    }

    func instanceValue() -> String {
        "instance:" + parityCurrentIsolationMatches(MainActor.shared)
    }
}

actor ParityCallablePlacementRelay {
    func echo(_ value: String) -> String {
        value
    }
}

@MainActor
func callablePlacementMetadataProbe() async -> String {
    let owner = ParityCallablePlacementOwner()
    let value = ParityCallablePlacementOwner.typeValue(label: "foodtruck")
        + "|" + owner.instanceValue()
    return await ParityCallablePlacementRelay().echo(value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await callablePlacementMetadataProbe()
}
