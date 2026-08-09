import SwiftUI

enum PerihelionPalette {
    static var void: Color { Color(red: 0.025, green: 0.03, blue: 0.075) }
    static var midnight: Color { Color(red: 0.055, green: 0.065, blue: 0.14) }
    static var ink: Color { Color(red: 0.09, green: 0.105, blue: 0.20) }
    static var amber: Color { Color(red: 1.0, green: 0.66, blue: 0.25) }
    static var coral: Color { Color(red: 1.0, green: 0.35, blue: 0.28) }
    static var cyan: Color { Color(red: 0.24, green: 0.86, blue: 0.96) }
    static var mint: Color { Color(red: 0.34, green: 0.94, blue: 0.70) }
    static var violet: Color { Color(red: 0.66, green: 0.48, blue: 1.0) }

    static func accent(named name: String) -> Color {
        switch name {
        case "mint": return mint
        case "cyan": return cyan
        case "violet": return violet
        case "coral": return coral
        default: return amber
        }
    }

    static func worldColor(_ world: CandidateWorld) -> Color {
        Color(hue: world.hue, saturation: 0.68, brightness: 0.96)
    }

    static func bandColor(_ band: SpectralBand) -> Color {
        switch band {
        case .visible: return cyan
        case .infrared: return coral
        case .ultraviolet: return violet
        }
    }
}

struct ObservatoryPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(.ultraThinMaterial)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.055), Color.white.opacity(0.012)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 28, y: 14)
    }
}

struct SectionEyebrow: View {
    let text: String
    var color = PerihelionPalette.cyan

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.7)
            .foregroundStyle(color)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    var accent = PerihelionPalette.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                Spacer()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        )
    }
}

struct TagChip: View {
    let title: String
    var accent = PerihelionPalette.cyan

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(accent.opacity(0.12))
            .foregroundStyle(accent)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.18), lineWidth: 1))
    }
}

struct ObservatoryBackground: View {
    var body: some View {
        ZStack {
            PerihelionPalette.void
            RadialGradient(
                colors: [PerihelionPalette.violet.opacity(0.16), Color.clear],
                center: UnitPoint(x: 0.82, y: 0.08),
                startRadius: 20,
                endRadius: 620
            )
            RadialGradient(
                colors: [PerihelionPalette.cyan.opacity(0.11), Color.clear],
                center: UnitPoint(x: 0.18, y: 0.92),
                startRadius: 10,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct PrimaryActionStyle: ButtonStyle {
    var accent = PerihelionPalette.amber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [accent, accent.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundStyle(PerihelionPalette.void)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .shadow(color: accent.opacity(0.24), radius: 12, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
