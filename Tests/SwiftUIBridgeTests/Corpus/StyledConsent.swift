struct ContentView: View {
    @State private var toggles: [Bool] = Array(repeating: false, count: 3)

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
            Toggle("Accept terms", isOn: $toggles[0])
            Toggle("Newsletter", isOn: $toggles[1])
            Toggle("Analytics", isOn: $toggles[2])
            Text("\(toggles.filter { $0 }.count) of \(toggles.count) accepted")
                .font(.caption)
        }
        .padding()
    }

    var title: AttributedString {
        var text = AttributedString("Please accept the Terms of Service")
        text.foregroundColor = .secondary
        if let range = text.range(of: "Terms of Service") {
            text[range].foregroundColor = .blue
            text[range].font = .body.bold()
        }
        return text
    }
}
