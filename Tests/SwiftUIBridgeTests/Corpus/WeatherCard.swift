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

    var headline: String {
        rawValue.capitalized
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
            Text("\(forecast.low)°")
                .foregroundStyle(.secondary)
            Text("\(forecast.high)°")
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

    var hottest: Int {
        week.map { $0.high }.max() ?? 0
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: selected.icon)
                .font(.system(size: 56))
                .foregroundStyle(.white)
            Text(selected.headline)
                .font(.title)
                .bold()
                .foregroundStyle(.white)
            Text("Week high: \(hottest)°")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 8) {
                ForEach(Condition.allCases, id: \.self) { condition in
                    Button {
                        selected = condition
                    } label: {
                        Image(systemName: condition.icon)
                    }
                    .buttonStyle(.plain)
                    .opacity(condition == selected ? 1.0 : 0.5)
                }
            }
            .foregroundStyle(.white)

            Divider()

            VStack(spacing: 6) {
                ForEach(week, id: \.day) { forecast in
                    ForecastRow(forecast: forecast)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(24)
        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
        .cornerRadius(20)
        .shadow(radius: 12, y: 6)
        .frame(maxWidth: 320)
    }
}
