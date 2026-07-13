import AppKit
import SwiftUI

private struct NativeLevelMeter: NSViewRepresentable {
    let value: Double
    let tint: NSColor

    func makeNSView(context: Context) -> NSLevelIndicator {
        let meter = NSLevelIndicator()
        meter.levelIndicatorStyle = .continuousCapacity
        meter.minValue = 0
        meter.maxValue = 1
        meter.warningValue = 0.72
        meter.criticalValue = 0.9
        meter.isEditable = false
        meter.fillColor = tint
        return meter
    }

    func updateNSView(_ meter: NSLevelIndicator, context: Context) {
        meter.doubleValue = value
        meter.fillColor = tint
    }
}

private struct WeekBar: Identifiable {
    let id: Int
    let day: String
    let value: Double
}

public struct ContentView: View {
    @State private var session: FocusSessionEngine
    @State private var copyStatus = "Copy summary"
    @State private var timerGeneration = 0

    private let tickMilliseconds: Int

    private let report = AppKitFocusChecks.run()
    private let week = [
        WeekBar(id: 0, day: "M", value: 0.46),
        WeekBar(id: 1, day: "T", value: 0.78),
        WeekBar(id: 2, day: "W", value: 0.58),
        WeekBar(id: 3, day: "T", value: 0.92),
        WeekBar(id: 4, day: "F", value: 0.64),
        WeekBar(id: 5, day: "S", value: 0.34),
        WeekBar(id: 6, day: "S", value: 0.52),
    ]

    public init() {
        let environment = ProcessInfo.processInfo.environment
        var initialSession = FocusSessionEngine()
        if environment["FOCUS_STUDIO_AUTOSTART"] == "1" {
            initialSession.isRunning = true
        }
        _session = State(initialValue: initialSession)
        tickMilliseconds = environment["FOCUS_STUDIO_FAST_TIMER"] == "1" ? 20 : 1_000
    }

    private var palette: AppKitPalette {
        AppKitPalette(index: session.selectedPreset)
    }

    private var accent: Color {
        Color(red: palette.red, green: palette.green, blue: palette.blue)
    }

    private var accentShadow: Color {
        Color(
            red: palette.shadowRed,
            green: palette.shadowGreen,
            blue: palette.shadowBlue
        )
    }

    private var timeText: String {
        let totalSeconds = Int(Double(palette.durationMinutes * 60) * (1 - session.progress))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds < 10 ? "\(minutes):0\(seconds)" : "\(minutes):\(seconds)"
    }

    public var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.041, blue: 0.072)
                .ignoresSafeArea()

            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 440, height: 440)
                .blur(radius: 95)
                .offset(x: 330, y: -260)

            Circle()
                .fill(accentShadow.opacity(0.13))
                .frame(width: 360, height: 360)
                .blur(radius: 100)
                .offset(x: -420, y: 320)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 240)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)

                dashboard
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if session.isRunning {
                timerGeneration += 1
                scheduleTimer(generation: timerGeneration)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(accent)
                        .frame(width: 42, height: 42)
                    Image(systemName: "command")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("FOCUS")
                        .font(.system(size: 17, weight: .bold))
                    Text("STUDIO")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("SESSION MODE")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)

                presetButton(index: 0)
                presetButton(index: 1)
                presetButton(index: 2)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("TODAY")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Text("\(session.completedSessions)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("sessions")
                        .foregroundStyle(.secondary)
                }

                Text("2h 18m of intentional work")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(report.allPassed ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("\(report.passedCount)/5 AppKit checks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private func presetButton(index: Int) -> some View {
        let item = AppKitPalette(index: index)
        let selected = session.selectedPreset == index
        return Button {
            timerGeneration += 1
            session.choosePreset(index)
            copyStatus = "Copy summary"
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.72) : .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(selected ? accent.opacity(0.24) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MONDAY · DEEP WORK")
                        .font(.caption.bold())
                        .foregroundStyle(accent)
                    Text("Build a calmer momentum.")
                        .font(.title2.bold())
                }
                Spacer()
                Button {
                    copySummary()
                } label: {
                    Label(copyStatus, systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 18) {
                timerCard
                insightsCard
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 18) {
                nativeProbeCard
                weekCard
            }
            .frame(height: 170)
        }
        .padding(26)
    }

    private var timerCard: some View {
        VStack(spacing: 18) {
            HStack {
                Label(palette.name, systemImage: palette.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(palette.hex)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: session.progress)
                    .stroke(accent, lineWidth: 14)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: accent.opacity(0.46), radius: 18)

                VStack(spacing: 4) {
                    Text(timeText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(session.isRunning ? "IN SESSION" : "READY")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 8)
                NativeLevelMeter(value: session.progress, tint: palette.nativeAccent)
                    .frame(height: 10)
            }
            .frame(height: 10)

            HStack(spacing: 10) {
                Button {
                    timerGeneration += 1
                    session.reset()
                    copyStatus = "Copy summary"
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)

                Button {
                    toggleTimer()
                    copyStatus = "Copy summary"
                } label: {
                    Label(
                        session.isRunning ? "Pause" : "Start session",
                        systemImage: session.isRunning ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)

                Button {
                    timerGeneration += 1
                    session.advance()
                    copyStatus = "Copy summary"
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Session architecture")
                    .font(.headline)
                Spacer()
                Image(systemName: "sparkles")
                    .foregroundStyle(accent)
            }

            insightRow(
                symbol: "brain.head.profile",
                title: "Focus window",
                value: "\(palette.durationMinutes) minutes"
            )
            insightRow(
                symbol: "paintpalette",
                title: "AppKit blend",
                value: "\(palette.alphaPercent)% alpha"
            )
            insightRow(
                symbol: "textformat",
                title: "Native typography",
                value: AppKitObjectProbe(progress: session.progress).fontName
            )

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Session progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(session.progress * 100))%")
                        .font(.caption.bold())
                }
                Slider(value: $session.progress, in: 0...1)
                    .tint(accent)
            }
        }
        .padding(22)
        .frame(width: 282)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func insightRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .foregroundStyle(accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
    }

    private var nativeProbeCard: some View {
        let probe = AppKitObjectProbe(progress: session.progress)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Native object probe")
                    .font(.headline)
                Spacer()
                Text("LIVE")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.green)
            }

            Text("NSView  \(probe.canvasWidth) × \(probe.canvasHeight)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("NSProgressIndicator  \(probe.meterValue)%")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("NSTextField  \(probe.labelValue)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("This week")
                    .font(.headline)
                Spacer()
                Text("8h 42m")
                    .font(.caption.bold())
                    .foregroundStyle(accent)
            }

            HStack(alignment: .bottom, spacing: 12) {
                ForEach(week) { item in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(accent.opacity(item.value == 0.92 ? 1 : 0.42))
                            .frame(width: 16, height: 72 * item.value)
                        Text(item.day)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(18)
        .frame(width: 282)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func copySummary() {
        let summary = "\(palette.name) · \(Int(session.progress * 100))% · \(palette.hex)"
        let copied = AppKitClipboard.copyAndVerify(summary)
        copyStatus = copied ? "Copied" : "Copy failed"
        print("[FocusStudio] clipboard \(copied ? "verified" : "failed"): \(summary)")
    }

    private func toggleTimer() {
        timerGeneration += 1
        session.toggleRunning()
        if session.isRunning {
            scheduleTimer(generation: timerGeneration)
        }
    }

    private func scheduleTimer(generation: Int) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(tickMilliseconds)
        ) {
            guard generation == timerGeneration && session.isRunning else { return }
            print("[FocusStudio] scheduled timer fired")
            session.tick()
            if session.isRunning {
                scheduleTimer(generation: generation)
            }
        }
    }
}
