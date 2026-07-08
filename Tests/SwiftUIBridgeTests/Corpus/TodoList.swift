struct Todo {
    var title = ""
    var done = false
}

struct ContentView: View {
    @State var todos: [Todo] = [Todo(title: "Learn SwiftUI"), Todo(title: "Write interpreter", done: true)]
    @State var newTitle = ""

    var remaining: Int {
        todos.filter { !$0.done }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Todos")
                .font(.largeTitle)
                .bold()
            Text("\(remaining) of \(todos.count) remaining")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("What needs doing?", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    addTodo()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTitle.isEmpty)
            }

            List(todos.indices) { i in
                HStack {
                    Button(todos[i].done ? "☑" : "☐") {
                        todos[i].done = !todos[i].done
                    }
                    .buttonStyle(.plain)
                    Text(todos[i].title)
                        .strikethrough()
                        .opacity(todos[i].done ? 0.4 : 1.0)
                    Spacer()
                    Button("✕") {
                        removeTodo(at: i)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .listStyle(.plain)

            if todos.isEmpty {
                Text("All clear — nice work.")
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: 380)
    }

    func addTodo() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        todos.append(Todo(title: trimmed))
        newTitle = ""
    }

    func removeTodo(at index: Int) {
        guard index < todos.count else {
            return
        }
        todos.remove(at: index)
    }
}

#Preview {
    ContentView()
}
