struct SampleProgram: Identifiable, Hashable {
    let name: String
    let source: String
    var id: String { name }
}

enum SamplePrograms {
    static let all = [counter, form, weather, staticLayout, list]

    /// Enums with methods, switch in bodies, gradients, shapes, nested views.
    static let weather = SampleProgram(name: "Weather", source: """
    enum Condition: String, CaseIterable {
        case sunny
        case cloudy
        case rainy
        case snowy

        var icon: String {
            switch self {
            case .sunny: return "sun.max.fill"
            case .cloudy: return "cloud.fill"
            case .rainy: return "cloud.rain.fill"
            case .snowy: return "snowflake"
            }
        }
    }

    struct Forecast {
        var day = ""
        var condition: Condition = .sunny
        var high = 0
        var low = 0
    }

    struct ForecastRow: View {
        var forecast = Forecast()

        var body: some View {
            HStack {
                Text(forecast.day)
                    .frame(width: 44, alignment: .leading)
                Image(systemName: forecast.condition.icon)
                Spacer()
                Text("\\(forecast.low)°")
                    .foregroundStyle(.white.opacity(0.7))
                Text("\\(forecast.high)°")
                    .bold()
            }
            .font(.system(size: 14))
        }
    }

    struct ContentView: View {
        @State var selected: Condition = .sunny

        let week = [
            Forecast(day: "Mon", condition: .sunny, high: 28, low: 17),
            Forecast(day: "Tue", condition: .cloudy, high: 24, low: 16),
            Forecast(day: "Wed", condition: .rainy, high: 19, low: 12),
            Forecast(day: "Thu", condition: .snowy, high: 2, low: -3),
        ]

        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: selected.icon)
                    .font(.system(size: 56))
                Text(selected.rawValue.capitalized)
                    .font(.title)
                    .bold()

                HStack(spacing: 8) {
                    ForEach(Condition.allCases, id: \\.self) { condition in
                        Button {
                            selected = condition
                        } label: {
                            Image(systemName: condition.icon)
                        }
                        .buttonStyle(.plain)
                        .opacity(condition == selected ? 1.0 : 0.5)
                    }
                }

                Divider()

                VStack(spacing: 6) {
                    ForEach(week, id: \\.day) { forecast in
                        ForecastRow(forecast: forecast)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
            .cornerRadius(20)
            .shadow(radius: 12, y: 6)
            .frame(maxWidth: 320)
        }
    }
    """)

    /// The acceptance demo: @State + Button actions with live re-render.
    static let counter = SampleProgram(name: "Counter", source: """
    struct ContentView: View {
        @State var count = 0

        var body: some View {
            VStack(spacing: 16) {
                Text("Count: \\(count)")
                    .font(.largeTitle)
                HStack(spacing: 12) {
                    Button("-") {
                        count -= 1
                    }
                    Button("+") {
                        count += 1
                    }
                }
                if count >= 10 {
                    Text("That's a lot of taps.")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }
    """)

    /// Two-way bindings: $state projections driving Toggle/Slider/TextField.
    static let form = SampleProgram(name: "Form", source: """
    struct ContentView: View {
        @State var name = ""
        @State var notify = true
        @State var volume = 5

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.headline)
                TextField("Your name", text: $name)
                Toggle("Notifications", isOn: $notify)
                HStack {
                    Text("Volume: \\(volume)")
                    Slider(value: $volume, in: 0...10)
                }
                Divider()
                Text("Hi \\(name)! Notifications \\(notify ? "on" : "off"), volume \\(volume).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 340)
        }
    }
    """)

    static let staticLayout = SampleProgram(name: "Layout", source: """
    struct ContentView: View {
        let tags = ["COBOL", "UNIVAC", "Compilers"]

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Grace Hopper")
                    .font(.title)
                    .bold()
                Text("Rear admiral, computer scientist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 8) {
                    ForEach(tags, id: \\.self) { tag in
                        Text(tag)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(8)
                    }
                }
                .font(.caption)
            }
            .padding(24)
            .frame(maxWidth: 320)
        }
    }
    """)

    static let list = SampleProgram(name: "List", source: """
    struct Row: View {
        var name = ""
        var index = 0

        var body: some View {
            HStack {
                Image(systemName: "person")
                Text(name)
                Spacer()
                Text("#\\(index)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct ContentView: View {
        let names = ["Ada Lovelace", "Grace Hopper", "Katherine Johnson", "Margaret Hamilton"]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pioneers")
                    .font(.headline)
                Divider()
                ForEach(0..<names.count) { i in
                    Row(name: names[i], index: i + 1)
                }
            }
            .padding()
            .frame(maxWidth: 320)
        }
    }
    """)
}
