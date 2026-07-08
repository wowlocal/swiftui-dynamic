struct TitledBox<Content: View>: View {
    var title = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .background(.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

struct BadgeRow: View {
    var label = ""
    var format: (Int) -> String
    var value = 0

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(format(value))
                .monospaced()
                .bold()
        }
    }
}

struct SizedBox<Content: View>: View {
    var height = 40.0
    @ViewBuilder var content: (CGSize) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.size)
        }
        .frame(height: height)
    }
}

struct ContentView: View {
    @State var score = 42
    @Environment(\.colorScheme) var scheme

    var body: some View {
        VStack(spacing: 12) {
            TitledBox(title: "Stats") {
                BadgeRow(label: "Score", format: { "\($0) pts" }, value: score)
                BadgeRow(label: "Double", format: { "\($0 * 2)" }, value: score)
            }

            TitledBox(title: "Actions") {
                Button("Increase") {
                    score += 10
                }
                .buttonStyle(.borderedProminent)
            }

            SizedBox(height: 30.0) { size in
                Text("inner width \(Int(size.width))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(scheme == .dark ? "dark mode" : "light mode")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: 320)
    }
}
