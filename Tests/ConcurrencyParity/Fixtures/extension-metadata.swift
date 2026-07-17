protocol ParityExtensionMarker {}

struct ParityDonut {
    struct Topping {
        let count: Int
    }
}

extension ParityDonut.Topping: ParityExtensionMarker {
    func doubled() -> Int {
        count * 2
    }
}

struct ParityMeasure<Value> {
    let value: Value
}

extension ParityMeasure where Value == Int {
    func text() -> String {
        String(value)
    }
}

actor ParityExtensionActor {
    let topping: ParityDonut.Topping

    init(topping: ParityDonut.Topping) {
        self.topping = topping
    }

    func snapshot() -> String {
        let conforms = (topping as? ParityExtensionMarker) != nil
        return String(conforms)
            + ":" + String(topping.doubled())
            + ":" + ParityMeasure(value: topping.count).text()
    }
}

@MainActor
func extensionMetadataProbe() async -> String {
    let actor = ParityExtensionActor(
        topping: ParityDonut.Topping(count: 21))
    return await actor.snapshot()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await extensionMetadataProbe()
}
