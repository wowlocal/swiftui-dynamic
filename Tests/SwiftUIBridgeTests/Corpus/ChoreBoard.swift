struct Chore: Identifiable {
    let id: Int
    var title: String
    var done: Bool
}

struct ContentView: View {
    @State private var chores: [Chore] = [
        Chore(id: 1, title: "Dishes", done: false),
        Chore(id: 2, title: "Trash", done: true),
        Chore(id: 3, title: "Plants", done: false),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach($chores) { $chore in
                HStack {
                    Toggle(chore.title, isOn: $chore.done)
                    Text(chore.done ? "done" : "todo")
                        .font(.caption)
                        .foregroundStyle(chore.done ? .green : .secondary)
                }
            }
            Button("Reset") {
                chores = chores.map { Chore(id: $0.id, title: $0.title, done: false) }
            }
            Text("\(chores.filter { $0.done }.count) of \(chores.count) complete")
                .font(.footnote)
        }
        .padding()
    }
}
