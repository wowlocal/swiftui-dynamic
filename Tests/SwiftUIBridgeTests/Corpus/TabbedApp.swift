struct Item {
    var id = UUID()
    var name = ""
}

class AppStore: ObservableObject {
    @Published var items: [Item] = [Item(name: "First"), Item(name: "Second")]
    @Published var draft = ""
    @Published var showEditor = false
    @Published var confirmingClear = false

    func addFromDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        items.append(Item(name: trimmed))
        draft = ""
        showEditor = false
    }

    func clear() {
        items.removeAll()
        confirmingClear = false
    }
}

struct ItemsTab: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Items")
                    .font(.headline)
                Spacer()
                Button("Add") {
                    store.showEditor = true
                }
                Button("Clear", role: .destructive) {
                    store.confirmingClear = true
                }
                .disabled(store.items.isEmpty)
            }

            ForEach(store.items.indices) { i in
                Label(store.items[i].name, systemImage: "circle")
            }

            if store.items.isEmpty {
                Text("Nothing yet")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .sheet(isPresented: $store.showEditor) {
            EditorSheet()
        }
        .alert("Remove everything?", isPresented: $store.confirmingClear) {
            Button("Clear", role: .destructive) {
                store.clear()
            }
            Button("Cancel", role: .cancel) {
            }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

struct EditorSheet: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 12) {
            Text("New item")
                .font(.headline)
            TextField("Name", text: $store.draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel", role: .cancel) {
                    store.showEditor = false
                }
                Button("Save") {
                    store.addFromDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.draft.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 260)
    }
}

struct SettingsTab: View {
    @EnvironmentObject var store: AppStore

    let launched = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.headline)
            Text("Items: \(store.items.count)")
            Text("Session: \(UUID().uuidString.prefix(8))")
                .monospaced()
            Text("Launched: \(launched.formatted())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct ContentView: View {
    @StateObject var store = AppStore()

    var body: some View {
        TabView {
            ItemsTab()
                .tabItem {
                    Label("Items", systemImage: "list.bullet")
                }
            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .environmentObject(store)
        .frame(width: 380, height: 320)
    }
}
