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

struct ContentView: View {
    @State var score = 42

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
        }
        .padding()
        .frame(maxWidth: 320)
    }
}
