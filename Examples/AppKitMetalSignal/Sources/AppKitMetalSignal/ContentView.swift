import AppKit
import SwiftUI

public struct ContentView: View {
    @StateObject private var model = MetalSignalStudioModel()

    public init() {}

    private var accent: Color {
        switch model.selectedPattern {
        case .aurora: return Color(red: 0.18, green: 0.92, blue: 0.72)
        case .plasma: return Color(red: 0.70, green: 0.36, blue: 1.0)
        case .rings: return Color(red: 1.0, green: 0.30, blue: 0.52)
        case .contour: return Color(red: 0.55, green: 0.92, blue: 0.42)
        }
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.018, green: 0.024, blue: 0.055),
                    Color(red: 0.035, green: 0.025, blue: 0.075),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(accent.opacity(0.17))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: 410, y: -330)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 226)

                Rectangle()
                    .fill(Color.white.opacity(0.075))
                    .frame(width: 1)

                workspace
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.startAutoloadIfNeeded()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(LinearGradient(
                            colors: [accent, Color(red: 0.42, green: 0.23, blue: 0.98)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    Image(systemName: "cpu")
                        .font(.system(size: 19, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("METAL")
                        .font(.system(size: 16, weight: .bold))
                    Text("SIGNAL LAB")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                Text("COMPUTE PIPELINE")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                pipelineStep(number: "01", title: "MSL source", detail: "Runtime compile", active: model.image != nil)
                pipelineStep(number: "02", title: "Compute grid", detail: "480 × 300 threads", active: model.isBusy)
                pipelineStep(number: "03", title: "Shared buffer", detail: "RGBA8 output", active: model.image != nil)
                pipelineStep(number: "04", title: "AppKit PNG", detail: "Preview + export", active: model.image != nil)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("DISPATCHES")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text("\(model.dispatchCount)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text(model.benchmarkTime == "—" ? "command buffers this session" : model.benchmarkTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.image == nil ? Color.orange : Color.green)
                        .frame(width: 8, height: 8)
                    Text(model.image == nil ? "GPU not dispatched" : "Compute pipeline online")
                        .font(.caption)
                }
                Text(model.deviceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(22)
    }

    private func pipelineStep(
        number: String,
        title: String,
        detail: String,
        active: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? accent : Color.secondary)
                .frame(width: 25, height: 25)
                .background((active ? accent : Color.white).opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("APPKIT × METAL COMPUTE WORKBENCH")
                        .font(.caption.bold())
                        .foregroundStyle(accent)
                    Text("Shape a signal field directly on the GPU.")
                        .font(.title2.bold())
                }
                Spacer()
                Button {
                    model.copyDigest()
                } label: {
                    Label(model.copyStatus, systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            patternBar

            HStack(spacing: 16) {
                previewCard
                inspectorCard
                    .frame(width: 276)
            }
            .frame(maxHeight: .infinity)

            statusBar
        }
        .padding(22)
    }

    private var patternBar: some View {
        HStack(spacing: 8) {
            ForEach(MetalSignalPattern.allCases) { pattern in
                Button {
                    model.selectPattern(pattern)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: pattern.symbol)
                        Text(pattern.title)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(model.selectedPattern == pattern ? Color.white : Color.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        (model.selectedPattern == pattern ? accent : Color.white)
                            .opacity(model.selectedPattern == pattern ? 0.24 : 0.055)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                model.render()
            } label: {
                Label(model.isBusy ? "Dispatching…" : "Render GPU", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(model.isBusy)
        }
        .padding(10)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.34))

            if let image = model.image {
                Image(nsImage: image)
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                    .padding(12)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.08, blue: 0.18),
                            accent.opacity(0.20),
                            Color(red: 0.11, green: 0.04, blue: 0.19),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Circle()
                        .stroke(accent.opacity(0.30), lineWidth: 1)
                        .frame(width: 210, height: 210)
                    Circle()
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                        .frame(width: 310, height: 310)
                    VStack(spacing: 9) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(accent)
                        Text("Awaiting compute dispatch")
                            .font(.headline)
                        Text("Compile the MSL kernel and write 144,000 pixels")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .padding(12)
            }

            VStack {
                HStack {
                    Text("RGBA8 · SHARED MEMORY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.52))
                        .clipShape(Capsule())
                    Spacer()
                    Text(model.outputSize)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.52))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(22)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .frame(minHeight: 390)
    }

    private var inspectorCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("KERNEL UNIFORMS")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(model.selectedPattern.title + " field")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Phase")
                    Spacer()
                    Text("\(Int(model.phase * 360))°")
                        .foregroundStyle(accent)
                }
                .font(.caption.weight(.semibold))
                Slider(value: $model.phase, in: 0...1)
                    .tint(accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Spatial scale")
                    Spacer()
                    Text("\(Int(model.scale * 100))%")
                        .foregroundStyle(accent)
                }
                .font(.caption.weight(.semibold))
                Slider(value: $model.scale, in: 0.5...2.4)
                    .tint(accent)
            }

            Rectangle()
                .fill(Color.white.opacity(0.075))
                .frame(height: 1)

            HStack(spacing: 9) {
                metric(title: "GPU", value: model.gpuTime)
                metric(title: "PNG", value: model.outputBytes)
            }
            HStack(spacing: 9) {
                metric(title: "MEAN", value: model.averageHex)
                metric(title: "RANGE", value: model.dynamicRange)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("RAW CHECKSUM")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(model.checksum)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }

            Spacer()

            Button {
                model.benchmark()
            } label: {
                Label("Benchmark ×12", systemImage: "speedometer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            Button {
                model.exportPNG()
            } label: {
                Label(model.exportStatus, systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.isBusy ? Color.orange : accent)
                .frame(width: 7, height: 7)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("Metal compute · AppKit bitmap bridge")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
