struct ParityConditionalMemberOwner {
    let value: Int

    #if os(watchOS)
    static let platform = "watch"

    static func typeValue() -> String {
        "watch-type"
    }

    struct Nested {
        static let name = "watch-nested"
    }
    #else
    static let platform = "foodtruck"

    static func typeValue() -> String {
        "type"
    }

    struct Nested {
        static let name = "nested"
    }
    #endif
}

extension ParityConditionalMemberOwner {
    #if os(watchOS)
    func extensionValue() -> String {
        "watch-extension"
    }
    #else
    func extensionValue() -> String {
        "extension"
    }
    #endif
}

enum ParityConditionalMemberPhase: String {
    #if os(watchOS)
    case watch
    #else
    case regular
    #endif
}

actor ParityConditionalMemberRelay {
    func echo(_ value: String) -> String {
        value
    }
}

@MainActor
func conditionalMemberMetadataProbe() async -> String {
    let owner = ParityConditionalMemberOwner(value: 7)
    let value = ParityConditionalMemberOwner.platform
        + ":" + String(owner.value)
        + ":" + ParityConditionalMemberOwner.typeValue()
        + ":" + owner.extensionValue()
        + ":" + ParityConditionalMemberPhase.regular.rawValue
        + ":" + ParityConditionalMemberOwner.Nested.name
    return await ParityConditionalMemberRelay().echo(value)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await conditionalMemberMetadataProbe()
}
