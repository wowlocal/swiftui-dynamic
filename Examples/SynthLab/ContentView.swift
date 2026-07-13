import SwiftUI

struct SynthVoice: Identifiable {
    let id: Int
    let name: String
    let detail: String
    let symbol: String
    let color: Color
    let level: Double
    let waveform: [Double]
}

struct ContentView: View {
    @State private var isPlaying = true
    @State private var holdNotes = false
    @State private var masterLevel = 0.72
    @State private var selectedPreset = 1

    let voices = [
        SynthVoice(
            id: 0,
            name: "EMBER",
            detail: "Warm analog bass",
            symbol: "waveform.path",
            color: .orange,
            level: 0.82,
            waveform: [0.24, 0.52, 0.88, 0.64, 0.36, 0.72, 0.92, 0.48]
        ),
        SynthVoice(
            id: 1,
            name: "GLASS",
            detail: "Bright bell texture",
            symbol: "sparkles",
            color: .cyan,
            level: 0.64,
            waveform: [0.72, 0.36, 0.58, 0.94, 0.46, 0.78, 0.34, 0.62]
        ),
        SynthVoice(
            id: 2,
            name: "TIDE",
            detail: "Slow moving pad",
            symbol: "water.waves",
            color: .blue,
            level: 0.76,
            waveform: [0.38, 0.56, 0.74, 0.86, 0.82, 0.68, 0.52, 0.42]
        )
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.18),
                    Color.cyan.opacity(0.07),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 18) {
                header
                presetBar

                HStack(spacing: 14) {
                    ForEach(voices) { voice in
                        VoiceStrip(voice: voice)
                    }
                }

                masterPanel
            }
            .padding(24)
        }
        .frame(width: 920, height: 650)
        .background(Color.primary.opacity(0.025))
    }

    var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.purple.opacity(0.14))
                    .frame(width: 52, height: 52)

                Image(systemName: "pianokeys")
                    .font(.system(size: 25))
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("SYNTH LAB")
                    .font(.title2)
                    .bold()
                Text("Shape a three-voice ambient patch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(isPlaying ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(isPlaying ? "ENGINE LIVE" : "ENGINE PAUSED")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(isPlaying ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.055))
            .clipShape(Capsule())
        }
    }

    var presetBar: some View {
        HStack(spacing: 10) {
            Label("Preset", systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .bold()

            ForEach(0..<3) { index in
                Button {
                    selectedPreset = index
                } label: {
                    Text(presetName(index))
                        .font(.caption)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPreset == index ? Color.white : Color.secondary)
                .background(selectedPreset == index ? Color.purple : Color.primary.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    var masterPanel: some View {
        HStack(spacing: 18) {
            Button {
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause engine" : "Start engine", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 112)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("MASTER OUTPUT")
                        .font(.caption)
                        .bold()
                    Spacer()
                    Text("72%")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.mint)
                }

                Slider(value: $masterLevel, in: 0...1)
                    .tint(.mint)
            }

            Divider()
                .frame(height: 42)

            Toggle("Hold notes", isOn: $holdNotes)
                .font(.subheadline)
                .frame(width: 130)
        }
        .padding(16)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    func presetName(_ index: Int) -> String {
        if index == 0 {
            return "NIGHT DRIVE"
        }
        if index == 1 {
            return "AURORA ROOM"
        }
        return "SOFT CIRCUIT"
    }
}

struct VoiceStrip: View {
    let voice: SynthVoice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: voice.symbol)
                    .font(.title2)
                    .foregroundStyle(voice.color)

                Spacer()

                Text("0\(voice.id + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(voice.name)
                    .font(.headline)
                    .bold()
                Text(voice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 7) {
                ForEach(0..<8) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [voice.color.opacity(0.35), voice.color],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 28 + voice.waveform[index] * 72)
                }
            }
            .frame(height: 104, alignment: .bottom)

            VStack(spacing: 7) {
                HStack {
                    Text("LEVEL")
                    Spacer()
                    Text(voice.id == 0 ? "82%" : voice.id == 1 ? "64%" : "76%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ProgressView(value: voice.level)
                    .tint(voice.color)
            }

            HStack(spacing: 8) {
                Label("Stereo", systemImage: "hifispeaker.2")
                Spacer()
                Text(voice.id == 1 ? "+7" : voice.id == 0 ? "-4" : "0")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(voice.color.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 9, y: 4)
    }
}
