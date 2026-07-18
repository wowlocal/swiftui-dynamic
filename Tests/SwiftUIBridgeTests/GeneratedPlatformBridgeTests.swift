import Foundation
import Darwin
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge
#if canImport(AppKit)
import AppKit
#endif

@Suite(.serialized) struct GeneratedPlatformBridgeTests {
    @Test func darwinSocketMemoryLayoutsMatchNativeSwift() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/PlatformParity/Fixtures/darwin-socket-memory-layout.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\ndarwinSocketMemoryLayouts()\n"
        let expected = [
            MemoryLayout<sockaddr>.size,
            MemoryLayout<sockaddr>.stride,
            MemoryLayout<sockaddr>.alignment,
            MemoryLayout<sockaddr_in>.size,
            MemoryLayout<sockaddr_in>.stride,
            MemoryLayout<sockaddr_in>.alignment,
            MemoryLayout<sockaddr_in6>.size,
            MemoryLayout<sockaddr_in6>.stride,
            MemoryLayout<sockaddr_in6>.alignment,
            MemoryLayout<sockaddr_storage>.size,
            MemoryLayout<sockaddr_storage>.stride,
            MemoryLayout<sockaddr_storage>.alignment,
            MemoryLayout<sockaddr_un>.size,
            MemoryLayout<sockaddr_un>.stride,
            MemoryLayout<sockaddr_un>.alignment,
        ].map(String.init).joined(separator: ",")

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == expected)
    }

    @Test func nativePlatformConstructorMethodAndProperties() throws {
#if canImport(AppKit)
        let source = """
        let color = NSColor(
            calibratedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1
        )
        let faded = color.withAlphaComponent(0.4)
        "\\(Int(faded.redComponent * 100))|\\(Int(faded.alphaComponent * 100))"
        """
        let expected = "25|40"
#else
        let source = """
        let view = UIView(frame: CGRect(x: 1, y: 2, width: 30, height: 40))
        view.tag = 7
        "\\(view.tag)|\\(Int(view.frame.width))"
        """
        let expected = "7|30"
#endif

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == expected)
    }

#if canImport(AppKit)
    @Test func oppositePlatformGraphicsContextPreservesImageLifecycle() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/PlatformParity/Fixtures/uigraphics-context-image.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nuiGraphicsContextImageLifecycle()\n"

        let viewResult = try Interpreter(registry: ViewRegistry()).run(source: source)
        let traceResult = try Interpreter(registry: TraceRegistry()).run(source: source)
        #expect(viewResult.stringValue == "nil,image,image,image,nil")
        #expect(traceResult.stringValue == "nil,image,image,image,nil")
    }

    @Test func appKitDecodedBitmapPropertiesUseNativeScalarContracts() throws {
        let fixtureData = NetworkBridge.placeholderPNG
        let native = try #require(NSBitmapImageRep(data: fixtureData))
        let source = """
        guard let bitmap = NSBitmapImageRep(data: bitmapFixture) else {
            fatalError("decode failed")
        }
        (bitmap.pixelsWide, bitmap.pixelsHigh, bitmap.bitsPerSample)
        """

        let interpreter = Interpreter(registry: ViewRegistry())
        interpreter.globals.define("bitmapFixture", .native(fixtureData))
        let result = try interpreter.run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == native.pixelsWide)
        #expect(tuple.values[1].intValue == native.pixelsHigh)
        #expect(tuple.values[2].intValue == native.bitsPerSample)
    }

    @Test func appKitBitmapPipelineMatchesNativeRoundTrip() throws {
        let fixtureData = NetworkBridge.placeholderPNG
        let nativeSource = try #require(NSBitmapImageRep(data: fixtureData))
        let nativeOutput = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: nativeSource.pixelsWide,
            pixelsHigh: nativeSource.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let nativeColor = try #require(
            nativeSource.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        nativeOutput.setColor(nativeColor, atX: 0, y: 0)
        nativeOutput.size = NSSize(
            width: nativeSource.pixelsWide,
            height: nativeSource.pixelsHigh)
        let nativePNG = try #require(
            nativeOutput.representation(using: .png, properties: [:]))
        let nativeImage = try #require(NSImage(data: nativePNG))

        let source = """
        guard let source = NSBitmapImageRep(data: bitmapFixture) else {
            fatalError("decode failed")
        }
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.pixelsWide,
            pixelsHigh: source.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("allocation failed")
        }
        guard let color = source.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            fatalError("color conversion failed")
        }
        output.setColor(color, atX: 0, y: 0)
        output.size = NSSize(width: source.pixelsWide, height: source.pixelsHigh)
        guard let png = output.representation(using: .png, properties: [:]),
              let image = NSImage(data: png) else {
            fatalError("encoding failed")
        }
        (png.count, Int(image.size.width), Int(image.size.height))
        """

        let interpreter = Interpreter(registry: ViewRegistry())
        interpreter.globals.define("bitmapFixture", .native(fixtureData))
        let result = try interpreter.run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == nativePNG.count)
        #expect(tuple.values[1].intValue == Int(nativeImage.size.width))
        #expect(tuple.values[2].intValue == Int(nativeImage.size.height))
    }

    @Test func appKitPixelRelayPipelineRunsThroughGeneratedBridge() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = packageRoot.appendingPathComponent(
            "Examples/AppKitPixelRelay/Fixtures")
        let fixture = fixtures.appendingPathComponent(
            "pixel-relay-source.png")
        let fixtureData = try Data(contentsOf: fixture)
        let native = try #require(NSBitmapImageRep(data: fixtureData))
        let pipelineFile = packageRoot.appendingPathComponent(
            "Examples/AppKitPixelRelay/Sources/AppKitPixelRelay/ImagePipeline.swift")
        let source = ProjectMaterial.mergedSource(files: [pipelineFile.path]) + """

        let output = try AppKitImagePipeline.process(
            data: pixelRelayFixture,
            effect: .warm,
            intensity: 0.82
        )
        (
            output.width,
            output.height,
            output.pngData.count,
            output.histogram.count
        )
        """

        let interpreter = Interpreter(registry: ViewRegistry())
        interpreter.globals.define("pixelRelayFixture", .native(fixtureData))
        let result = try interpreter.run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == native.pixelsWide)
        #expect(tuple.values[1].intValue == native.pixelsHigh)
        #expect((tuple.values[2].intValue ?? 0) > 100)
        #expect(tuple.values[3].intValue == 12)
    }

#if canImport(Metal)
    @Test func generatedMetalBridgeExecutesComputeAndOwnedMemoryCopies() throws {
        let source = #"""
        struct Parameters {
            var count: UInt32
            var seed: UInt32
        }

        struct Padded {
            var word: UInt32
            var flag: UInt8
        }

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal unavailable")
        }
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Parameters { uint count; uint seed; };
        kernel void fill_values(
            device uint *output [[buffer(0)]],
            constant Parameters &parameters [[buffer(1)]],
            uint index [[thread_position_in_grid]]) {
            if (index < parameters.count) {
                output[index] = parameters.seed + index;
            }
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        guard let function = library.makeFunction(name: "fill_values") else {
            fatalError("kernel missing")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let count = 16
        guard let output = device.makeBuffer(
            length: count * 4, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            fatalError("command setup failed")
        }
        var parameters = Parameters(count: UInt32(count), seed: 7)
        encoder.label = "generated bridge regression"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(
            &parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let finalStatus = command.status

        let data = Data(bytes: output.contents(), count: count * 4)
        let bytes = [UInt8](data)
        var byteSum = 0
        for byte in bytes { byteSum += Int(byte) }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ), let bitmapData = bitmap.bitmapData else {
            fatalError("bitmap setup failed")
        }
        Data([255, 0, 0, 255]).copyBytes(to: bitmapData, count: 4)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("PNG encoding failed")
        }

        (
            MemoryLayout<Parameters>.stride,
            MemoryLayout<Padded>.size,
            MemoryLayout<Padded>.stride,
            MemoryLayout<Padded>.alignment,
            data.count,
            byteSum,
            png.count,
            device.name.isEmpty,
            finalStatus == .completed,
            finalStatus == command.status
        )
        """#

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 8)
        #expect(tuple.values[1].intValue == 5)
        #expect(tuple.values[2].intValue == 8)
        #expect(tuple.values[3].intValue == 4)
        #expect(tuple.values[4].intValue == 64)
        #expect(tuple.values[5].intValue == 232)
        #expect((tuple.values[6].intValue ?? 0) > 50)
        #expect(tuple.values[7].boolValue == false)
        #expect(tuple.values[8].boolValue == true)
        #expect(tuple.values[9].boolValue == true)
    }
#endif

    @Test func appKitGeometryAliasesGenerateAsCoreGraphicsContracts() throws {
        let source = """
        let origin = NSPoint(x: 3, y: 4)
        let size = NSSize(width: 50, height: 60)
        let view = NSView(frame: NSRect(origin: origin, size: size))
        "\\(Int(view.frame.minX))|\\(Int(view.frame.width))"
        """

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "3|50")
    }
#endif

    @Test func generatedStructsPreserveValueSemantics() throws {
        let source = """
        var original = NSDirectionalEdgeInsets(
            top: 1, leading: 2, bottom: 3, trailing: 4
        )
        var copy = original
        copy.leading = 9
        "\\(Int(original.leading))|\\(Int(copy.leading))"
        """

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "2|9")
    }

    @Test func generatedStaticMethodAcceptsContextualPlatformValue() throws {
#if canImport(AppKit)
        let source = """
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        Int(font.pointSize)
        """
#else
        let source = """
        let font = UIFont.systemFont(ofSize: 13, weight: .bold)
        Int(font.pointSize)
        """
#endif

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.intValue == 13)
    }

    @Test func optionalPlatformCollectionsNormalizeAsInterpreterArrays() throws {
#if canImport(AppKit)
        let source = """
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.allowedInputSourceLocales = ["en", "fr"]
        textView.allowedInputSourceLocales?.joined(separator: ",") ?? "nil"
        """
        let expected = "en,fr"
#else
        let source = """
        let imageView = UIImageView(image: nil)
        imageView.animationImages = []
        String(imageView.animationImages?.count ?? -1)
        """
        let expected = "0"
#endif

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == expected)
    }

    @Test func oppositePlatformUsesTheGeneratedTypedFallback() throws {
#if canImport(AppKit)
        let source = """
        let view = UIView(frame: CGRect(x: 1, y: 2, width: 30, height: 40))
        view.tag = 7
        view
        """
        let expectedFramework = "UIKit"
        let expectedType = "UIView"
#else
        let source = """
        NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        """
        let expectedFramework = "AppKit"
        let expectedType = "NSColor"
#endif

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let value = try #require(result.hostPayload as? GeneratedPlatformValue)
        #expect(value.framework == expectedFramework)
        #expect(value.typeName == expectedType)
        #expect(value.payload == nil)
#if canImport(AppKit)
        #expect(value.config["tag"]?.intValue == 7)
        #expect(value.config["frame"] != nil)
#endif
    }

#if canImport(AppKit)
    @Test func oppositePlatformImplicitStaticFactoryUsesReturnTypeContext() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/PlatformParity/Fixtures/implicit-uifont-static-factory.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nimplicitPlatformStaticFactorySucceeds()\n"

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.boolValue == true)
    }

    @Test func oppositePlatformStaticStringPreservesSymbolicIdentity() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = packageRoot.appendingPathComponent(
            "Tests/PlatformParity/Fixtures/uiapplication-open-settings-url.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nplatformStaticStringURLExists()\n"

        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.boolValue == true)
    }
#endif

    // The DetailedMapView surface (FoodTruck city screen): the generated
    // MapKit/CoreLocation platform tier must construct and configure the
    // exact objects the representable controller builds.
    @MainActor
    @Test func mapKitSurfaceConstructsAndConfigures() throws {
        let source = """
        import MapKit
        import CoreLocation

        let location = CLLocation(latitude: 37.335_690, longitude: -122.013_330)
        let mapView = MKMapView()
        let configuration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.isScrollEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        let camera = MKMapCamera(
            lookingAtCenter: location.coordinate,
            fromDistance: 1000.0,
            pitch: 55.0,
            heading: 120.0
        )
        mapView.camera = camera
        String(Int(camera.centerCoordinateDistance.rounded())) + "," +
            String(Int(camera.pitch.rounded())) + "," +
            String(Int(camera.heading.rounded())) + "," +
            String(Int(camera.centerCoordinate.latitude.rounded())) + "," +
            String(mapView.isZoomEnabled)
        """
        // Construction semantics read from the CAMERA object — an
        // unattached MKMapView normalizes its camera copy natively too.
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "1000,55,120,37,false")
    }
}
