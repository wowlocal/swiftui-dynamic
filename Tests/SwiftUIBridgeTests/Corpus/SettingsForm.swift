struct ContentView: View {
    @State var username = ""
    @State var notifications = true
    @State var previews = false
    @State var fontSize = 14
    @State var theme = "System"

    let themes = ["System", "Light", "Dark"]

    var summary: String {
        let name = username.isEmpty ? "anonymous" : username
        return "\(name) · \(theme) · \(fontSize)pt"
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Username", text: $username)
                SecureField("Password", text: $username)
            }

            Section {
                Toggle("Notifications", isOn: $notifications)
                Toggle("Show previews", isOn: $previews)
                    .disabled(!notifications)
            } header: {
                Label("Alerts", systemImage: "bell")
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(themes, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Font size: \(fontSize)")
                    Slider(value: $fontSize, in: 10...24, step: 1)
                }
            }

            Section {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 420)
        .padding()
    }
}
