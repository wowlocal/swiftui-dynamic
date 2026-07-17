nonisolated(unsafe) var parityDeinitializerMetadataEvents: [String] = []

@MainActor
final class ParityDeinitializerMetadataOwner {
    let label: String

    init(label: String) {
        self.label = label
    }

    deinit {
        let isolation = #isolation
        let lane = isolation == nil ? "none" : "actor"
        parityDeinitializerMetadataEvents.append(lane + ":" + label)
    }
}

@MainActor
func deinitializerMetadataProbe() -> String {
    parityDeinitializerMetadataEvents = []
    do {
        let owner = ParityDeinitializerMetadataOwner(label: "foodtruck")
        parityDeinitializerMetadataEvents.append("body")
        _ = owner
    }
    parityDeinitializerMetadataEvents.append("after")
    return parityDeinitializerMetadataEvents.joined(separator: "|")
}

@MainActor
func parityNativeOutput() async throws -> String {
    deinitializerMetadataProbe()
}
