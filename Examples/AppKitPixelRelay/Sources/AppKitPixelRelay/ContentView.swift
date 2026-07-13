import AppKit
import SwiftUI

public final class RelayStudioModel: ObservableObject {
    @Published public var endpoint: String
    @Published public var selectedEffect: RelayEffect = .warm
    @Published public var intensity = 0.82
    @Published public var isLoading = false
    @Published public var status = "Ready for local relay"
    @Published public var image: NSImage?
    @Published public var dimensions = "96 × 64 target"
    @Published public var sourceBytes = "—"
    @Published public var outputBytes = "—"
    @Published public var latency = "—"
    @Published public var averageHex = "#8F72C8"
    @Published public var checksum = "pending"
    @Published public var histogram: [Double] = [0.18, 0.28, 0.44, 0.62, 0.88, 0.72, 0.54, 0.68, 0.91, 0.58, 0.34, 0.22]
    @Published public var completedJobs = 0
    @Published public var exportStatus = "Export PNG"
    @Published public var copyStatus = "Copy digest"

    private var sourceData: Data?
    private var processedData: Data?
    private var didAutostart = false
    private let autoloadEndpoint: String?

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["PIXEL_RELAY_AUTOFETCH_URL"]
        endpoint = configured ?? "http://127.0.0.1:8765/pixel-relay-source.png"
        autoloadEndpoint = configured
    }

    public func startAutoloadIfNeeded() {
        guard !didAutostart, autoloadEndpoint != nil else { return }
        didAutostart = true
        fetch()
    }

    public func fetch() {
        guard !isLoading else { return }
        isLoading = true
        status = "Contacting image relay…"
        exportStatus = "Export PNG"
        copyStatus = "Copy digest"
        let requestedEndpoint = endpoint
        let effect = selectedEffect
        let requestedIntensity = intensity

        Task {
            do {
                let download = try await RelayNetworkPipeline.fetch(
                    endpoint: requestedEndpoint,
                    effect: effect,
                    intensity: requestedIntensity
                )
                sourceData = download.sourceData
                apply(download)
                status = "HTTP \(download.statusCode) · processed with AppKit"
                completedJobs += 1
                print("[PixelRelay] UI success jobs=\(completedJobs)")
            } catch {
                status = "Relay failed: \(error.localizedDescription)"
                print("[PixelRelay] UI failure \(error)")
            }
            isLoading = false
        }
    }

    public func selectEffect(_ effect: RelayEffect) {
        selectedEffect = effect
        copyStatus = "Copy digest"
        exportStatus = "Export PNG"
        reprocess()
    }

    public func reprocess() {
        guard let sourceData else {
            status = "Fetch an image before applying the pipeline"
            return
        }
        do {
            let result = try AppKitImagePipeline.process(
                data: sourceData,
                effect: selectedEffect,
                intensity: intensity
            )
            applyPipeline(result)
            status = "Reprocessed · \(selectedEffect.title) at \(Int(intensity * 100))%"
            print("[PixelRelay] reprocess effect=\(selectedEffect.title)")
        } catch {
            status = "Processing failed: \(error.localizedDescription)"
        }
    }

    public func exportPNG() {
        guard let processedData else {
            exportStatus = "Nothing to export"
            return
        }
        let path = ProcessInfo.processInfo.environment["PIXEL_RELAY_EXPORT_PATH"]
            ?? "/tmp/appkit-pixel-relay-export.png"
        do {
            try processedData.write(to: URL(fileURLWithPath: path))
            exportStatus = "Exported"
            print("[PixelRelay] export path=\(path) bytes=\(processedData.count)")
        } catch {
            exportStatus = "Export failed"
            print("[PixelRelay] export failure \(error)")
        }
    }

    public func copyDigest() {
        let text = "Pixel Relay · \(dimensions) · \(averageHex) · checksum \(checksum)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        copyStatus = copied ? "Copied" : "Copy failed"
        print("[PixelRelay] clipboard copied=\(copied)")
    }

    private func apply(_ download: RelayDownloadResult) {
        sourceBytes = byteLabel(download.sourceBytes)
        latency = "\(download.latencyMilliseconds) ms"
        applyPipeline(download.pipeline)
    }

    private func applyPipeline(_ result: RelayPipelineResult) {
        image = result.image
        processedData = result.pngData
        dimensions = "\(result.width) × \(result.height) px"
        outputBytes = byteLabel(result.pngData.count)
        averageHex = result.averageHex
        checksum = "#\(result.checksum)"
        histogram = result.histogram
    }

    private func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1_024 {
            let whole = bytes / 1_024
            let tenths = ((bytes % 1_024) * 10) / 1_024
            return "\(whole).\(tenths) KB"
        }
        return "\(bytes) B"
    }
}

public struct ContentView: View {
    @StateObject private var model = RelayStudioModel()

    public init() {}

    private var accent: Color {
        switch model.selectedEffect {
        case .original: return Color(red: 0.42, green: 0.82, blue: 0.98)
        case .monochrome: return Color(red: 0.78, green: 0.82, blue: 0.90)
        case .warm: return Color(red: 1.0, green: 0.49, blue: 0.35)
        case .posterize: return Color(red: 0.55, green: 0.42, blue: 1.0)
        }
    }

    public var body: some View {
        ZStack {
            Color(red: 0.027, green: 0.032, blue: 0.055)
                .ignoresSafeArea()

            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 430, height: 430)
                .blur(radius: 110)
                .offset(x: 420, y: -300)

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)

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
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [accent, Color(red: 0.38, green: 0.25, blue: 0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 42, height: 42)
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 18, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("PIXEL")
                        .font(.system(size: 16, weight: .bold))
                    Text("RELAY")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                Text("PIPELINE")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                pipelineStep(number: "01", title: "URLSession", subtitle: "Fetch bytes", active: model.isLoading)
                pipelineStep(number: "02", title: "NSBitmapImageRep", subtitle: "Decode pixels", active: model.image != nil)
                pipelineStep(number: "03", title: model.selectedEffect.title, subtitle: "Transform + encode", active: model.image != nil)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SESSION")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text("\(model.completedJobs)")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                Text("completed network jobs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(model.image == nil ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(model.image == nil ? "Awaiting payload" : "Pipeline online")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    private func pipelineStep(
        number: String,
        title: String,
        subtitle: String,
        active: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? accent : Color.secondary)
                .frame(width: 24, height: 24)
                .background((active ? accent : Color.white).opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NETWORK IMAGE WORKBENCH")
                        .font(.caption.bold())
                        .foregroundStyle(accent)
                    Text("Turn remote pixels into a local signal.")
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

            endpointBar

            HStack(spacing: 16) {
                previewCard
                inspectorCard
                    .frame(width: 262)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 16) {
                histogramCard
                outputCard
                    .frame(width: 262)
            }
            .frame(height: 148)
        }
        .padding(22)
    }

    private var endpointBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .foregroundStyle(accent)
            TextField("Image endpoint", text: $model.endpoint)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            Button {
                model.fetch()
            } label: {
                Label(model.isLoading ? "Fetching…" : "Fetch & process", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(model.isLoading)
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Processed frame", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Spacer()
                Text(model.selectedEffect.title.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(accent)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.25))

                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(18)
                } else {
                    placeholderArtwork
                        .padding(18)
                }

                VStack {
                    Spacer()
                    HStack {
                        Label(model.dimensions, systemImage: "viewfinder")
                        Spacer()
                        Text(model.averageHex)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .font(.caption2)
                    .padding(10)
                    .background(Color.black.opacity(0.48))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private var placeholderArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.14, blue: 0.34),
                        Color(red: 0.43, green: 0.29, blue: 0.78),
                        accent.opacity(0.92),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Circle()
                .fill(Color(red: 1.0, green: 0.83, blue: 0.42))
                .frame(width: 74, height: 74)
                .offset(x: 112, y: -52)
            RoundedRectangle(cornerRadius: 34)
                .fill(Color(red: 0.05, green: 0.08, blue: 0.18).opacity(0.78))
                .frame(height: 112)
                .rotationEffect(.degrees(-8))
                .offset(y: 72)
            RoundedRectangle(cornerRadius: 32)
                .fill(Color(red: 0.25, green: 0.84, blue: 0.76).opacity(0.63))
                .frame(height: 84)
                .rotationEffect(.degrees(7))
                .offset(y: 104)
            VStack(spacing: 7) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 25, weight: .semibold))
                Text("READY FOR PAYLOAD")
                    .font(.caption2.bold())
            }
            .foregroundStyle(.white.opacity(0.82))
        }
        .aspectRatio(1.5, contentMode: .fit)
    }

    private var inspectorCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Processing stack")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(RelayEffect.allCases) { effect in
                    effectButton(effect)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Effect intensity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.intensity * 100))%")
                        .font(.caption.bold())
                }
                Slider(value: $model.intensity, in: 0...1)
                    .tint(accent)
                Button("Apply intensity") {
                    model.reprocess()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Spacer()

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func effectButton(_ effect: RelayEffect) -> some View {
        let selected = model.selectedEffect == effect
        return Button {
            model.selectEffect(effect)
        } label: {
            HStack {
                Image(systemName: effect.symbol)
                    .frame(width: 20)
                Text(effect.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(selected ? accent.opacity(0.19) : Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? accent : Color.primary)
    }

    private var histogramCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Luminance histogram")
                    .font(.headline)
                Spacer()
                Text("12 BINS")
                    .font(.caption2.bold())
                    .foregroundStyle(accent)
            }
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(0..<model.histogram.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == 8 ? accent : accent.opacity(0.38))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(5, model.histogram[index] * 70))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(17)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 19))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output telemetry")
                    .font(.headline)
                Spacer()
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(accent)
            }
            metricRow("Network", value: model.sourceBytes, symbol: "arrow.down")
            metricRow("Encoded", value: model.outputBytes, symbol: "shippingbox")
            metricRow("Latency", value: model.latency, symbol: "timer")
            HStack {
                Text(model.checksum)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.exportStatus) {
                    model.exportPNG()
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
        }
        .padding(17)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 19))
    }

    private func metricRow(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.bold())
        }
    }
}
