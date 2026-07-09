@Observable
class Session {
    var isSignedIn: Bool = false
    var name: String = "guest"
}

struct BadgeView: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 8) {
            Text(session.isSignedIn ? "Hello, \(session.name)" : "Signed out")
                .font(.headline)
            Button("Sign in") {
                session.isSignedIn = true
                session.name = "Mike"
            }
        }
    }
}

struct StatusLine: View {
    @Environment(Session.self) private var session

    var body: some View {
        Text(session.name)
            .font(.caption)
            .foregroundStyle(session.isSignedIn ? .green : .secondary)
    }
}

struct ContentView: View {
    var session: Session = .init()

    var body: some View {
        VStack(spacing: 12) {
            BadgeView()
            StatusLine()
        }
        .padding()
        .environment(session)
    }
}
