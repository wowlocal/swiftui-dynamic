struct Note: Identifiable {
    let id: Int
    let text: String
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var notes: [Note]
    @State private var tags: [String] = ["swift"]
    @State private var added = 0

    var body: some View {
        VStack(spacing: 10) {
            if notes.isEmpty {
                Text("No notes yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                Text(note.text)
            }
            Button("Add note") {
                context.insert(Note(id: added, text: "Note \(added)"))
                added += 1
            }
            Button("Tag") {
                $tags.append("tag-\(tags.count)")
            }
            Text("\(tags.count) tags, \(added) adds")
                .font(.caption)
        }
        .padding()
    }
}
