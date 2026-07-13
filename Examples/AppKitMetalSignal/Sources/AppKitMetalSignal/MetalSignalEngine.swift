import AppKit
import Foundation
import Metal

public enum MetalSignalPattern: Int, CaseIterable, Identifiable {
    case aurora
    case plasma
    case rings
    case contour

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .plasma: return "Plasma"
        case .rings: return "Pulse"
        case .contour: return "Contour"
        }
    }

    public var symbol: String {
        switch self {
        case .aurora: return "waveform.path.ecg"
        case .plasma: return "sparkles"
        case .rings: return "dot.radiowaves.left.and.right"
        case .contour: return "map"
        }
    }
}

public struct MetalSignalFrame {
    public let image: NSImage
    public let pngData: Data
    public let width: Int
    public let height: Int
    public let checksum: Int
    public let averageHex: String
    public let lumaSpread: Double
    public let distinctSamples: Int
    public let gpuMilliseconds: Double
    public let deviceName: String
}

public enum MetalSignalError: LocalizedError {
    case noDevice
    case commandQueueCreationFailed
    case shaderCompilationFailed(String)
    case kernelMissing
    case pipelineCreationFailed(String)
    case outputBufferCreationFailed
    case outputReadbackSizeMismatch(Int, Int)
    case commandBufferCreationFailed
    case encoderCreationFailed
    case commandFailed(String)
    case bitmapCreationFailed
    case bitmapStorageMissing
    case pngEncodingFailed
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No Metal device is available."
        case .commandQueueCreationFailed:
            return "Metal could not create a command queue."
        case .shaderCompilationFailed(let detail):
            return "The Metal shader did not compile: \(detail)"
        case .kernelMissing:
            return "The signal_field compute kernel is missing."
        case .pipelineCreationFailed(let detail):
            return "Metal could not create the compute pipeline: \(detail)"
        case .outputBufferCreationFailed:
            return "Metal could not allocate a shared output buffer."
        case .outputReadbackSizeMismatch(let expected, let actual):
            return "Metal returned \(actual) bytes; expected \(expected)."
        case .commandBufferCreationFailed:
            return "Metal could not create a command buffer."
        case .encoderCreationFailed:
            return "Metal could not create a compute encoder."
        case .commandFailed(let detail):
            return "The GPU command failed: \(detail)"
        case .bitmapCreationFailed:
            return "AppKit could not create the output bitmap."
        case .bitmapStorageMissing:
            return "AppKit did not expose bitmap storage."
        case .pngEncodingFailed:
            return "AppKit could not encode the GPU frame as PNG."
        case .imageCreationFailed:
            return "AppKit could not construct an image from the GPU frame."
        }
    }
}

private struct MetalSignalParameters {
    var width: UInt32
    var height: UInt32
    var pattern: UInt32
    var phase: Float
    var scale: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

public final class MetalSignalEngine {
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState

    public var deviceName: String { device.name }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalSignalError.noDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalSignalError.commandQueueCreationFailed
        }

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalSignalError.shaderCompilationFailed(error.localizedDescription)
        }
        guard let function = library.makeFunction(name: "signal_field") else {
            throw MetalSignalError.kernelMissing
        }

        let pipeline: any MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw MetalSignalError.pipelineCreationFailed(error.localizedDescription)
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }

    public func render(
        width: Int,
        height: Int,
        pattern: MetalSignalPattern,
        phase: Double,
        scale: Double
    ) throws -> MetalSignalFrame {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let byteCount = safeWidth * safeHeight * 4
        guard let output = device.makeBuffer(
            length: byteCount,
            options: .storageModeShared
        ) else {
            throw MetalSignalError.outputBufferCreationFailed
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalSignalError.commandBufferCreationFailed
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalSignalError.encoderCreationFailed
        }

        var parameters = MetalSignalParameters(
            width: UInt32(safeWidth),
            height: UInt32(safeHeight),
            pattern: UInt32(pattern.rawValue),
            phase: Float(max(0, min(phase, 1))),
            scale: Float(max(0.25, min(scale, 3)))
        )

        encoder.label = "Metal Signal Lab · \(pattern.title)"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(
            &parameters,
            length: MemoryLayout<MetalSignalParameters>.stride,
            index: 1
        )

        let threadWidth = max(1, pipeline.threadExecutionWidth)
        let threadHeight = max(
            1,
            min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        )
        encoder.dispatchThreads(
            MTLSize(width: safeWidth, height: safeHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        encoder.endEncoding()

        let started = Date()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let gpuMilliseconds = Date().timeIntervalSince(started) * 1_000

        if commandBuffer.status == .error {
            throw MetalSignalError.commandFailed(
                commandBuffer.error?.localizedDescription ?? "unknown Metal error"
            )
        }

        let rawData = Data(bytes: output.contents(), count: byteCount)
        guard rawData.count == byteCount else {
            throw MetalSignalError.outputReadbackSizeMismatch(byteCount, rawData.count)
        }
        let statistics = Self.statistics(for: rawData)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: safeWidth,
            pixelsHigh: safeHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: safeWidth * 4,
            bitsPerPixel: 32
        ) else {
            throw MetalSignalError.bitmapCreationFailed
        }
        guard let bitmapData = bitmap.bitmapData else {
            throw MetalSignalError.bitmapStorageMissing
        }
        rawData.copyBytes(to: bitmapData, count: byteCount)
        bitmap.size = NSSize(width: safeWidth, height: safeHeight)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw MetalSignalError.pngEncodingFailed
        }
        guard let image = NSImage(data: pngData) else {
            throw MetalSignalError.imageCreationFailed
        }

        return MetalSignalFrame(
            image: image,
            pngData: pngData,
            width: safeWidth,
            height: safeHeight,
            checksum: statistics.checksum,
            averageHex: statistics.averageHex,
            lumaSpread: statistics.lumaSpread,
            distinctSamples: statistics.distinctSamples,
            gpuMilliseconds: gpuMilliseconds,
            deviceName: device.name
        )
    }

    private static func statistics(
        for data: Data
    ) -> (checksum: Int, averageHex: String, lumaSpread: Double, distinctSamples: Int) {
        let bytes = [UInt8](data)
        var checksum = 17
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        var minimumLuma = 255
        var maximumLuma = 0
        var sampledColors: Set<UInt32> = []
        var pixel = 0

        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset])
            let green = Int(bytes[offset + 1])
            let blue = Int(bytes[offset + 2])
            redTotal += red
            greenTotal += green
            blueTotal += blue
            let luma = (red * 54 + green * 183 + blue * 19) / 256
            minimumLuma = min(minimumLuma, luma)
            maximumLuma = max(maximumLuma, luma)

            if pixel % 97 == 0 {
                let packed = UInt32(red << 16 | green << 8 | blue)
                sampledColors.insert(packed)
            }
            pixel += 1
        }

        for byte in bytes {
            checksum = (checksum * 31 + Int(byte)) % 1_000_003
        }

        let divisor = max(1, pixel)
        return (
            checksum,
            hex(
                red: redTotal / divisor,
                green: greenTotal / divisor,
                blue: blueTotal / divisor
            ),
            Double(maximumLuma - minimumLuma) / 255,
            sampledColors.count
        )
    }

    private static func hex(red: Int, green: Int, blue: Int) -> String {
        "#" + hexByte(red) + hexByte(green) + hexByte(blue)
    }

    private static func hexByte(_ value: Int) -> String {
        let bounded = max(0, min(value, 255))
        return hexDigit(bounded / 16) + hexDigit(bounded % 16)
    }

    private static func hexDigit(_ value: Int) -> String {
        switch value {
        case 0: return "0"
        case 1: return "1"
        case 2: return "2"
        case 3: return "3"
        case 4: return "4"
        case 5: return "5"
        case 6: return "6"
        case 7: return "7"
        case 8: return "8"
        case 9: return "9"
        case 10: return "A"
        case 11: return "B"
        case 12: return "C"
        case 13: return "D"
        case 14: return "E"
        default: return "F"
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct SignalParameters {
        uint width;
        uint height;
        uint pattern;
        float phase;
        float scale;
        float padding0;
        float padding1;
        float padding2;
    };

    float3 palette(float value, float3 a, float3 b, float3 c, float3 d) {
        constexpr float tau = 6.28318530718;
        return a + b * cos(tau * (c * value + d));
    }

    kernel void signal_field(
        device uchar4 *pixels [[buffer(0)]],
        constant SignalParameters &parameters [[buffer(1)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= parameters.width || position.y >= parameters.height) {
            return;
        }

        constexpr float tau = 6.28318530718;
        float2 size = float2(parameters.width, parameters.height);
        float2 uv = (float2(position) + 0.5) / size;
        float2 point = uv * 2.0 - 1.0;
        point.x *= size.x / size.y;
        float phase = parameters.phase * tau;
        float scale = max(parameters.scale, 0.25);
        float3 color = float3(0.0);

        if (parameters.pattern == 0) {
            float waveA = sin(point.x * 3.8 * scale + phase + sin(point.y * 2.4));
            float waveB = sin(point.x * 6.4 - phase * 0.7 + point.y * 2.0);
            float ribbonA = exp(-abs(point.y * 1.45 - waveA * 0.22) * 8.0);
            float ribbonB = exp(-abs(point.y * 1.8 + waveB * 0.16 + 0.25) * 10.0);
            color = float3(0.025, 0.035, 0.11);
            color += ribbonA * float3(0.08, 0.95, 0.78);
            color += ribbonB * float3(0.52, 0.18, 1.0);
            color += pow(ribbonA, 3.0) * float3(0.35, 0.65, 1.0);
        } else if (parameters.pattern == 1) {
            float value = sin(point.x * 3.2 * scale + phase);
            value += sin(point.y * 4.1 * scale - phase * 0.8);
            value += sin((point.x + point.y) * 5.0 + phase * 0.45);
            value += sin(length(point + float2(sin(phase), cos(phase)) * 0.25) * 9.0);
            value = value * 0.125 + 0.5;
            color = palette(
                value,
                float3(0.48, 0.42, 0.52),
                float3(0.48, 0.45, 0.48),
                float3(1.0),
                float3(0.00, 0.14, 0.27)
            );
        } else if (parameters.pattern == 2) {
            float radius = length(point);
            float angle = atan2(point.y, point.x);
            float pulse = 0.5 + 0.5 * cos(radius * 24.0 * scale - phase * 3.0);
            float spokes = 0.5 + 0.5 * sin(angle * 7.0 + phase + radius * 5.0);
            float core = exp(-radius * 2.8);
            color = mix(
                float3(0.015, 0.025, 0.09),
                float3(1.0, 0.18, 0.46),
                pulse * 0.72
            );
            color += spokes * core * float3(0.18, 0.72, 1.0);
            color += pow(core, 3.0) * float3(0.92, 0.88, 1.0);
        } else {
            float elevation = sin(point.x * 3.0 * scale + phase);
            elevation += cos(point.y * 4.4 * scale - phase * 0.5);
            elevation += sin((point.x - point.y) * 7.0 + phase) * 0.45;
            float bands = 1.0 - smoothstep(0.02, 0.13, abs(fract(elevation * 0.28) - 0.5));
            float field = elevation * 0.18 + 0.5;
            color = mix(
                float3(0.02, 0.08, 0.12),
                float3(0.12, 0.72, 0.62),
                saturate(field)
            );
            color += bands * float3(0.72, 0.95, 0.68);
            color += (1.0 - bands) * float3(0.03, 0.02, 0.12);
        }

        float vignette = 1.0 - smoothstep(0.45, 1.5, length(point));
        float scanline = sin(float(position.y) * 0.46) * 0.012;
        color = color * (0.62 + vignette * 0.52) + scanline;
        color = saturate(color);

        uint offset = position.y * parameters.width + position.x;
        pixels[offset] = uchar4(
            uchar(color.r * 255.0),
            uchar(color.g * 255.0),
            uchar(color.b * 255.0),
            255
        );
    }
    """
}
