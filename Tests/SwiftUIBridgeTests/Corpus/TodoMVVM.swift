struct Todo {
    var title = ""
    var done = false
}

class TodoStore: ObservableObject {
    @Published var todos: [Todo] = [
        Todo(title: "Interpret Swift", done: true),
        Todo(title: "Render SwiftUI", done: true),
        Todo(title: "Run real projects"),
    ]
    @Published var newTitle = ""
    @Published var showCompleted = true

    var remaining: Int {
        todos.filter { !$0.done }.count
    }

    func add() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        todos.append(Todo(title: trimmed))
        newTitle = ""
    }

    func toggle(at index: Int) {
        guard index < todos.count else {
            return
        }
        let item = todos[index]
        item.done = !item.done
        // Reassign through the array so the publisher fires (nested instance
        // mutation alone doesn't — documented divergence).
        todos[index] = item
    }

    func remove(at index: Int) {
        guard index < todos.count else {
            return
        }
        todos.remove(at: index)
    }
}

struct AddBar: View {
    @ObservedObject var store: TodoStore

    var body: some View {
        HStack {
            TextField("What needs doing?", text: $store.newTitle)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                store.add()
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.newTitle.isEmpty)
        }
    }
}

struct TodoRow: View {
    @ObservedObject var store: TodoStore
    var index = 0

    var body: some View {
        HStack {
            Button(store.todos[index].done ? "☑" : "☐") {
                store.toggle(at: index)
            }
            .buttonStyle(.plain)
            Text(store.todos[index].title)
                .opacity(store.todos[index].done ? 0.4 : 1.0)
            Spacer()
            Button("✕") {
                store.remove(at: index)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }
}

struct StatsFooter: View {
    @ObservedObject var store: TodoStore
    @AppStorage("compactFooter") var compact = false

    var body: some View {
        HStack {
            Text(compact ? "\(store.remaining)" : "\(store.remaining) of \(store.todos.count) remaining")
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Compact", isOn: $compact)
                .font(.caption2)
            Toggle("Show done", isOn: $store.showCompleted)
        }
        .font(.caption)
    }
}

struct ContentView: View {
    @StateObject var store: TodoStore = .init()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Todos (MVVM)")
                .font(.title2)
                .bold()

            AddBar(store: store)

            VStack(spacing: 6) {
                ForEach(store.todos.indices) { i in
                    if store.showCompleted || !store.todos[i].done {
                        TodoRow(store: store, index: i)
                    }
                }
            }

            Divider()

            StatsFooter(store: store)
        }
        .padding()
        .frame(maxWidth: 380)
    }
}
