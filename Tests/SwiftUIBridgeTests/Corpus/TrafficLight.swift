enum Light: String, CaseIterable {
    case red
    case yellow
    case green

    var advice: String {
        switch self {
        case .red: return "Stop"
        case .yellow: return "Get ready"
        case .green: return "Go"
        }
    }

    func next() -> Light {
        switch self {
        case .red: return .green
        case .green: return .yellow
        case .yellow: return .red
        }
    }
}

struct ContentView: View {
    @State var light: Light = .red
    @State var switches = 0

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Circle()
                    .fill(light == .red ? .red : .gray.opacity(0.25))
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(light == .yellow ? .yellow : .gray.opacity(0.25))
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(light == .green ? .green : .gray.opacity(0.25))
                    .frame(width: 44, height: 44)
            }
            .padding(16)
            .background(.black.opacity(0.85))
            .cornerRadius(16)

            Text(light.advice)
                .font(.headline)

            Button("Advance") {
                light = light.next()
                switches += 1
            }
            .buttonStyle(.borderedProminent)
            .disabled(switches >= 100)

            Text("Switched \(switches) times")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
