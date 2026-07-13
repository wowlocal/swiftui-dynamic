import AppKit
import Foundation
import SwiftUI

public final class MetalSignalStudioModel: ObservableObject {
    @Published public var selectedPattern: MetalSignalPattern = .aurora
    @Published public var phase = 0.18
    @Published public var scale = 1.15
    @Published public var image: NSImage?
    @Published public var status = "Ready to compile the compute kernel"
    @Published public var deviceName = "Metal device not queried"
    @Published public var gpuTime = "—"
    @Published public var benchmarkTime = "—"
    @Published public var checksum = "pending"
    @Published public var averageHex = "#33C7B4"
    @Published public var dynamicRange = "—"
    @Published public var outputSize = "480 × 300"
    @Published public var outputBytes = "—"
    @Published public var dispatchCount = 0
    @Published public var isBusy = false
    @Published public var exportStatus = "Export PNG"
    @Published public var copyStatus = "Copy digest"

    private var metalEngine: MetalSignalEngine?
    private var lastFrame: MetalSignalFrame?
    private var didAutostart = false

    public init() {}

    public func startAutoloadIfNeeded() {
        guard !didAutostart else { return }
        didAutostart = true
        if ProcessInfo.processInfo.environment["METAL_SIGNAL_AUTORENDER"] == "1" {
            render()
        }
    }

    public func selectPattern(_ pattern: MetalSignalPattern) {
        selectedPattern = pattern
        exportStatus = "Export PNG"
        copyStatus = "Copy digest"
        if lastFrame != nil {
            render()
        }
    }

    public func render() {
        guard !isBusy else { return }
        isBusy = true
        status = "Encoding \(selectedPattern.title) compute pass…"
        exportStatus = "Export PNG"
        copyStatus = "Copy digest"
        print(
            "[MetalSignal] render begin pattern=\(selectedPattern.title)"
                + " phase=\(Int(phase * 360)) scale=\(Int(scale * 100))"
        )

        do {
            let engine = try resolvedEngine()
            let frame = try engine.render(
                width: 480,
                height: 300,
                pattern: selectedPattern,
                phase: phase,
                scale: scale
            )
            apply(frame)
            dispatchCount += 1
            status = "GPU frame complete · \(selectedPattern.title)"
            print(
                "[MetalSignal] render success device=\(frame.deviceName)"
                    + " checksum=\(frame.checksum)"
                    + " gpuMicros=\(Int(frame.gpuMilliseconds * 1_000))"
            )
        } catch {
            status = "Metal unavailable: \(error.localizedDescription)"
            print("[MetalSignal] render failure \(error)")
        }
        isBusy = false
    }

    public func benchmark() {
        guard !isBusy else { return }
        isBusy = true
        status = "Running 12 deterministic GPU dispatches…"
        print("[MetalSignal] benchmark begin frames=12")

        do {
            let engine = try resolvedEngine()
            var totalMilliseconds = 0.0
            var finalFrame: MetalSignalFrame?
            for index in 0..<12 {
                var shiftedPhase = phase + Double(index) * 0.071
                if shiftedPhase > 1 {
                    shiftedPhase -= 1
                }
                let frame = try engine.render(
                    width: 480,
                    height: 300,
                    pattern: selectedPattern,
                    phase: shiftedPhase,
                    scale: scale
                )
                totalMilliseconds += frame.gpuMilliseconds
                finalFrame = frame
            }

            if let finalFrame {
                apply(finalFrame)
            }
            let average = totalMilliseconds / 12
            benchmarkTime = millisecondsLabel(average) + " avg"
            dispatchCount += 12
            status = "Benchmark complete · 12 command buffers"
            print(
                "[MetalSignal] benchmark success averageMicros="
                    + "\(Int(average * 1_000))"
            )
        } catch {
            status = "Benchmark failed: \(error.localizedDescription)"
            print("[MetalSignal] benchmark failure \(error)")
        }
        isBusy = false
    }

    public func exportPNG() {
        guard let lastFrame else {
            exportStatus = "Render first"
            return
        }
        let path = ProcessInfo.processInfo.environment["METAL_SIGNAL_EXPORT_PATH"]
            ?? "/tmp/appkit-metal-signal.png"
        do {
            try lastFrame.pngData.write(to: URL(fileURLWithPath: path))
            exportStatus = "Exported"
            print("[MetalSignal] export path=\(path) bytes=\(lastFrame.pngData.count)")
        } catch {
            exportStatus = "Export failed"
            print("[MetalSignal] export failure \(error)")
        }
    }

    public func copyDigest() {
        let digest = "Metal Signal · \(selectedPattern.title) · \(checksum) · \(gpuTime)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(digest, forType: .string)
        copyStatus = copied ? "Copied" : "Copy failed"
        print("[MetalSignal] clipboard copied=\(copied)")
    }

    private func resolvedEngine() throws -> MetalSignalEngine {
        if let metalEngine {
            return metalEngine
        }
        let engine = try MetalSignalEngine()
        metalEngine = engine
        return engine
    }

    private func apply(_ frame: MetalSignalFrame) {
        lastFrame = frame
        image = frame.image
        deviceName = frame.deviceName
        gpuTime = millisecondsLabel(frame.gpuMilliseconds)
        checksum = "#\(frame.checksum)"
        averageHex = frame.averageHex
        dynamicRange = "\(Int(frame.lumaSpread * 100))% · \(frame.distinctSamples) samples"
        outputSize = "\(frame.width) × \(frame.height)"
        outputBytes = byteLabel(frame.pngData.count)
    }

    private func millisecondsLabel(_ milliseconds: Double) -> String {
        let micros = max(0, Int(milliseconds * 1_000))
        let whole = micros / 1_000
        let fraction = micros % 1_000
        if fraction < 10 {
            return "\(whole).00\(fraction) ms"
        }
        if fraction < 100 {
            return "\(whole).0\(fraction) ms"
        }
        return "\(whole).\(fraction) ms"
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
