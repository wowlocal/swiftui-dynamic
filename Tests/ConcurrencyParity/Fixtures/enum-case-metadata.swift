enum ParityUser {
    case `default`
    case authenticated(username: String)
}

enum ParityHeaderSize: Double {
    case standard = 1.0
    case reduced = 0.5
}

actor ParityEnumCaseActor {
    let user: ParityUser

    init(user: ParityUser) {
        self.user = user
    }

    func snapshot() -> String {
        switch user {
        case .default:
            return "default"
        case .authenticated(let username):
            return "authenticated:" + username
        }
    }
}

func parityUserName(_ user: ParityUser) -> String {
    switch user {
    case .default:
        return "default"
    case .authenticated(let username):
        return username
    }
}

@MainActor
func enumCaseMetadataProbe() async -> String {
    let actor = ParityEnumCaseActor(
        user: .authenticated(username: "foodtruck"))
    let associated = await actor.snapshot()
    return associated
        + "|" + parityUserName(.default)
        + "|" + String(ParityHeaderSize.standard.rawValue)
        + ":" + String(ParityHeaderSize.reduced.rawValue)
}

@MainActor
func parityNativeOutput() async throws -> String {
    await enumCaseMetadataProbe()
}
