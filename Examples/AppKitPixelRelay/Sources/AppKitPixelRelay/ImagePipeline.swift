import AppKit
import Foundation

public enum RelayEffect: Int, CaseIterable, Identifiable {
    case original
    case monochrome
    case warm
    case posterize

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .monochrome: return "Mono"
        case .warm: return "Solar"
        case .posterize: return "Poster"
        }
    }

    public var symbol: String {
        switch self {
        case .original: return "circle.lefthalf.filled"
        case .monochrome: return "circle.dotted"
        case .warm: return "sun.max.fill"
        case .posterize: return "square.3.layers.3d"
        }
    }
}

public struct RelayPipelineResult {
    public let image: NSImage
    public let pngData: Data
    public let width: Int
    public let height: Int
    public let averageHex: String
    public let checksum: Int
    public let histogram: [Double]
}

public struct RelayDownloadResult {
    public let pipeline: RelayPipelineResult
    public let sourceData: Data
    public let statusCode: Int
    public let sourceBytes: Int
    public let latencyMilliseconds: Int
}

public enum RelayPipelineError: LocalizedError {
    case invalidURL
    case nonHTTPResponse
    case rejectedStatus(Int)
    case imageDecodeFailed
    case emptyBitmapDimensions(Int, Int)
    case bitmapAllocationFailed
    case pngEncodingFailed
    case imageConstructionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "The endpoint is not a valid URL."
        case .nonHTTPResponse: return "The server did not return HTTP metadata."
        case .rejectedStatus(let code): return "The server returned HTTP \(code)."
        case .imageDecodeFailed: return "AppKit could not decode the response image."
        case .emptyBitmapDimensions(let width, let height):
            return "AppKit decoded an empty \(width) × \(height) bitmap."
        case .bitmapAllocationFailed: return "AppKit could not allocate an output bitmap."
        case .pngEncodingFailed: return "AppKit could not encode the processed PNG."
        case .imageConstructionFailed: return "AppKit could not construct the preview image."
        }
    }
}

public enum AppKitImagePipeline {
    public static func process(
        data: Data,
        effect: RelayEffect,
        intensity: Double
    ) throws -> RelayPipelineResult {
        guard let source = NSBitmapImageRep(data: data) else {
            throw RelayPipelineError.imageDecodeFailed
        }

        let width = source.pixelsWide
        let height = source.pixelsHigh
        guard width > 0, height > 0 else {
            throw RelayPipelineError.emptyBitmapDimensions(width, height)
        }
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RelayPipelineError.bitmapAllocationFailed
        }

        let amount = clamp(intensity)
        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var bins = Array(repeating: 0, count: 12)
        var sampledPixels = 0

        for y in 0..<height {
            for x in 0..<width {
                guard let rawColor = source.colorAt(x: x, y: y),
                      let color = rawColor.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let alpha = Double(color.alphaComponent)
                let transformed = transform(
                    red: red,
                    green: green,
                    blue: blue,
                    effect: effect
                )
                let mixedRed = red + (transformed.0 - red) * amount
                let mixedGreen = green + (transformed.1 - green) * amount
                let mixedBlue = blue + (transformed.2 - blue) * amount
                let outputColor = NSColor(
                    calibratedRed: clamp(mixedRed),
                    green: clamp(mixedGreen),
                    blue: clamp(mixedBlue),
                    alpha: clamp(alpha)
                )
                output.setColor(outputColor, atX: x, y: y)

                redTotal += mixedRed
                greenTotal += mixedGreen
                blueTotal += mixedBlue
                let luminance = clamp(
                    mixedRed * 0.2126 + mixedGreen * 0.7152 + mixedBlue * 0.0722
                )
                let bin = min(11, Int(luminance * 12))
                bins[bin] += 1
                sampledPixels += 1
            }
        }

        output.size = NSSize(width: width, height: height)
        guard let pngData = output.representation(using: .png, properties: [:]) else {
            throw RelayPipelineError.pngEncodingFailed
        }
        guard let image = NSImage(data: pngData) else {
            throw RelayPipelineError.imageConstructionFailed
        }

        let divisor = Double(max(1, sampledPixels))
        let averageRed = redTotal / divisor
        let averageGreen = greenTotal / divisor
        let averageBlue = blueTotal / divisor
        let largestBin = max(1, bins.max() ?? 1)
        let histogram = bins.map { Double($0) / Double(largestBin) }

        return RelayPipelineResult(
            image: image,
            pngData: pngData,
            width: width,
            height: height,
            averageHex: hex(red: averageRed, green: averageGreen, blue: averageBlue),
            checksum: checksum(pngData),
            histogram: histogram
        )
    }

    private static func transform(
        red: Double,
        green: Double,
        blue: Double,
        effect: RelayEffect
    ) -> (Double, Double, Double) {
        switch effect {
        case .original:
            return (red, green, blue)
        case .monochrome:
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            return (luminance, luminance, luminance)
        case .warm:
            return (
                clamp(red * 1.18 + 0.06),
                clamp(green * 1.03 + 0.015),
                clamp(blue * 0.72)
            )
        case .posterize:
            return (quantize(red), quantize(green), quantize(blue))
        }
    }

    private static func quantize(_ value: Double) -> Double {
        Double(Int(clamp(value) * 3 + 0.5)) / 3
    }

    private static func clamp(_ value: Double) -> Double {
        max(0, min(value, 1))
    }

    private static func checksum(_ data: Data) -> Int {
        var value = 17
        for byte in data {
            value = (value * 31 + Int(byte)) % 1_000_003
        }
        return value
    }

    private static func hex(red: Double, green: Double, blue: Double) -> String {
        "#" + component(red) + component(green) + component(blue)
    }

    private static func component(_ value: Double) -> String {
        let byte = max(0, min(Int(value * 255), 255))
        return digit(byte / 16) + digit(byte % 16)
    }

    private static func digit(_ value: Int) -> String {
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
}

public enum RelayNetworkPipeline {
    public static func fetch(
        endpoint: String,
        effect: RelayEffect,
        intensity: Double
    ) async throws -> RelayDownloadResult {
        guard let url = URL(string: endpoint) else {
            throw RelayPipelineError.invalidURL
        }

        print("[PixelRelay] network begin \(endpoint)")
        let started = Date()
        let (data, response) = try await URLSession.shared.data(from: url)
        let latency = Int(Date().timeIntervalSince(started) * 1_000)
        guard let http = response as? HTTPURLResponse else {
            throw RelayPipelineError.nonHTTPResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw RelayPipelineError.rejectedStatus(http.statusCode)
        }
        print(
            "[PixelRelay] network status=\(http.statusCode) bytes=\(data.count)"
                + " latencyMs=\(latency)"
        )

        let pipeline = try AppKitImagePipeline.process(
            data: data,
            effect: effect,
            intensity: intensity
        )
        print(
            "[PixelRelay] pipeline size=\(pipeline.width)x\(pipeline.height)"
                + " outputBytes=\(pipeline.pngData.count)"
                + " checksum=\(pipeline.checksum) average=\(pipeline.averageHex)"
        )
        return RelayDownloadResult(
            pipeline: pipeline,
            sourceData: data,
            statusCode: http.statusCode,
            sourceBytes: data.count,
            latencyMilliseconds: latency
        )
    }
}
