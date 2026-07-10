import SwiftUI

struct TemperatureCurve: Shape {
    var values: [Double]

    func path(in rect: CGRect) -> Path {
        Path { path in
            if values.count > 1 {
                let low = values.min() ?? 0
                let high = values.max() ?? 1
                let spread = max(1.0, high - low)
                for index in values.indices {
                    let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
                    let ratio = (values[index] - low) / spread
                    let y = rect.maxY - rect.height * CGFloat(ratio)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
        }
    }
}

struct SunArc: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.minY)
            )
        }
    }
}

struct WeatherPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial)
            .cornerRadius(22)
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}

struct WeatherSectionHeader: View {
    var icon: String
    var title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title.uppercased())
                .tracking(0.5)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.62))
    }
}

struct WeatherMetricTile: View {
    var icon: String
    var title: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WeatherSectionHeader(icon: icon, title: title)
            Text(value)
                .font(.system(size: 28, weight: .regular))
                .monospaced()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.42, extraBounce: 0.04), value: value)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(2)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }
}

struct AQIRing: View {
    var air: CurrentAir
    @State private var ringVisible = false

    var body: some View {
        WeatherPanel {
            VStack(alignment: .leading, spacing: 13) {
                WeatherSectionHeader(icon: "aqi.medium", title: "Air Quality")

                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 8)
                        Circle()
                            .trim(
                                from: 0,
                                to: ringVisible ? min(1.0, Double(air.aqi) / 100.0) : 0
                            )
                            .stroke(aqiColor(air.aqi), lineWidth: 8)
                            .rotationEffect(.degrees(-90))
                            .animation(
                                .easeOut(duration: 0.85).delay(0.22),
                                value: ringVisible
                            )
                        VStack(spacing: 0) {
                            Text("\(air.aqi)")
                                .font(.title2)
                                .bold()
                                .monospaced()
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.4), value: air.aqi)
                            Text("EAQI")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.58))
                        }
                    }
                    .frame(width: 82, height: 82)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(aqiLabel(air.aqi))
                            .font(.title3)
                            .bold()
                        Text(aqiDescription(air.aqi))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("PM2.5  \(String(format: "%.1f", air.particles)) µg/m³")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            ringVisible = true
        }
    }

    func aqiLabel(_ value: Int) -> String {
        switch value {
        case 0..<20: return "Good"
        case 20..<40: return "Fair"
        case 40..<60: return "Moderate"
        case 60..<80: return "Poor"
        default: return "Very poor"
        }
    }

    func aqiDescription(_ value: Int) -> String {
        switch value {
        case 0..<20: return "Air quality is ideal for outdoor activity."
        case 20..<40: return "Air quality is acceptable for most people."
        case 40..<60: return "Sensitive people may notice mild effects."
        case 60..<80: return "Consider reducing prolonged outdoor activity."
        default: return "Limit outdoor activity when possible."
        }
    }

    func aqiColor(_ value: Int) -> Color {
        switch value {
        case 0..<20: return Color.green
        case 20..<40: return Color.mint
        case 40..<60: return Color.yellow
        case 60..<80: return Color.orange
        default: return Color.red
        }
    }
}
