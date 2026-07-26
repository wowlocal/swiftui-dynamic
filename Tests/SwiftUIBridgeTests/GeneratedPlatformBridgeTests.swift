import Foundation
import Darwin
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge
#if canImport(AppKit)
import AppKit
#endif

@Suite(.serialized) struct GeneratedPlatformBridgeTests {
    /// Imported framework code can wrap a terminal callback in a generic
    /// result scope that also takes an ordinary SDK control value. The
    /// headless registry may carry that value opaquely, but the interface
    /// contract still requires the body to run and its result to escape.
    @Test func genericResultScopeExecutesWithOpaqueControlValue() throws {
        let source = ProjectMaterial.mergedSource(
            source: """
            import SwiftUI

            final class ScopeRecorder {
                var value = "pending"
            }

            let scopeRecorder = ScopeRecorder()
            let scopeResult: String = withTransaction(
                Transaction(animation: nil)
            ) {
                scopeRecorder.value = "entered"
                return "returned"
            }
            (scopeResult, scopeRecorder.value)
            """,
            moduleName: "ImportedPipeline")

        let value = try Interpreter(registry: TraceRegistry()).run(
            source: source)
        let tuple = try #require(value.tupleValue)
        #expect(tuple.values[0].stringValue == "returned")
        #expect(tuple.values[1].stringValue == "entered")
    }

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
    /// A compiled Catalyst twin reports the same positive rendering scale
    /// through `UITraitCollection.current` and the host screen (2x on the
    /// captured host). Preserve that ambient value when an iOS SDK carrier is
    /// interpreted on macOS so ordinary geometry transforms cannot collapse
    /// nonzero image targets.
    @Test func oppositePlatformRenderingScaleMatchesNativeHost() throws {
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "iOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }

        let source = """
        import CoreGraphics
        import UIKit

        extension CGSize {
            func scaled(by scale: CGFloat) -> CGSize {
                CGSize(width: width * scale, height: height * scale)
            }
        }

        let scale = UITraitCollection.current.displayScale
        let scaled = CGSize(width: 40, height: 12).scaled(by: scale)
        (scale, scaled.width, scaled.height)
        """
        let expectedScale = Double(
            NSScreen.main?.backingScaleFactor ?? 1)

        for registry: any HostRegistry in [ViewRegistry(), TraceRegistry()] {
            let result = try Interpreter(registry: registry).run(source: source)
            let tuple = try #require(result.tupleValue)
            #expect(tuple.values[0].doubleValue == expectedScale)
            #expect(tuple.values[1].doubleValue == 40 * expectedScale)
            #expect(tuple.values[2].doubleValue == 12 * expectedScale)
        }
    }

    /// EmojiText's platform-image extension reads `size.height` from an
    /// opaque image produced by its UIKit pipeline. The declared SDK role
    /// must expose the same swept property contract as the native AppKit
    /// platform image rather than degrading into an unknown dynamic member.
    @Test func opaqueGeneratedReferenceUsesSweptPropertyContract() throws {
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "iOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }

        let source = ProjectMaterial.mergedSource(
            source: """
            #if canImport(UIKit)
            import UIKit
            typealias PlatformImage = UIImage
            #elseif canImport(AppKit)
            import AppKit
            typealias PlatformImage = NSImage
            #endif

            extension PlatformImage {
                func sourceHeight() -> CGFloat {
                    size.height
                }
            }

            let image: PlatformImage = PlatformImage()
            image.sourceHeight()
            """,
            moduleName: "ImagePipeline")
        let expected = Double(NSImage().size.height)

        let result = try Interpreter(registry: ViewRegistry()).run(
            source: source)
        #expect(result.doubleValue == expected)
    }

    /// An opaque carrier has no native payload from which optional presence
    /// can be observed. The generated adapter must not turn interface
    /// optionality into an invented nil; configured optionals still use the
    /// generated contract, while unknown presence remains absorptive.
    @Test func opaqueGeneratedReferenceDoesNotInventOptionalAbsence() throws {
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "iOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }

        let image = UIKitStub(roles: ["UIImage"])
        #expect(GeneratedPlatformBridge.property(
            "size", onOpaqueReference: image) != nil)
        #expect(GeneratedPlatformBridge.property(
            "cgImage", onOpaqueReference: image) == nil)

        image.config["cgImage"] = .none(wrappedTypeName: "CGImage")
        #expect(GeneratedPlatformBridge.property(
            "cgImage", onOpaqueReference: image) != nil)
    }

    /// A native reference returned by one imported framework method can feed
    /// an opposite-platform constructor, then reappear through that value's
    /// generated optional property contract. The result type must come from
    /// SDK metadata rather than the unresolved method-chain spelling.
    @Test func importedReferenceMethodResultKeepsConstructorTypeContext() throws {
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "iOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }

        let source = """
        import CoreGraphics
        import UIKit

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("context creation failed")
        }
        guard let output = context.makeImage() else {
            fatalError("image creation failed")
        }
        let image = UIImage(cgImage: output)
        image.cgImage != nil
        """

        let value = try Interpreter(registry: TraceRegistry()).run(
            source: source)
        #expect(value.boolValue == true)
    }

    @Test func annotatedOpaquePipelineResultUsesSweptPropertyContract() throws {
        let previousPlatform = Interpreter.interpretsAsPlatform
        Interpreter.interpretsAsPlatform = "iOS"
        defer { Interpreter.interpretsAsPlatform = previousPlatform }

        let source = ProjectMaterial.mergedSource(
            source: """
            #if canImport(UIKit)
            import UIKit
            typealias PlatformImage = UIImage
            #elseif canImport(AppKit)
            import AppKit
            typealias PlatformImage = NSImage
            #endif

            extension PlatformImage {
                func sourceHeight() -> CGFloat {
                    size.height
                }
            }

            func sourceHeight(of image: PlatformImage) -> CGFloat {
                image.sourceHeight()
            }

            sourceHeight(of: importedImagePipeline())
            """,
            moduleName: "ImagePipeline")
        let expected = Double(NSImage().size.height)

        let interpreter = Interpreter(registry: ViewRegistry())
        interpreter.globals.define(
            "importedImagePipeline",
            .hostFunction(HostFunction(name: "importedImagePipeline") { _, _ in
                .native(ChainedImplicitCall(
                    base: .implicitMember("opaque"),
                    member: "result",
                    arguments: CallArguments()))
            }))
        let result = try interpreter.run(source: source)
        #expect(result.doubleValue == expected)
    }

    @Test func headlessBitmapNormalizesNonfiniteDimensions() {
        let image = UIImageBox.solid(size: CGSize(
            width: CGFloat.nan, height: CGFloat.infinity))

        #expect(image.size == CGSize(width: 1, height: 1))
        #expect(image.pngData != nil)
    }
#endif

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

#if canImport(AppKit)
    /// A selected platform nominal grows every mechanically bridgeable API
    /// that accepts it. The opposite-platform fallback exercises the iOS
    /// signature on macOS without requiring a UIKit runtime payload.
    @Test func generatedPlatformReferenceParameterCompletesOverloadFamily() throws {
        let result = try Interpreter(registry: ViewRegistry()).run(source: """
        UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: nil
        )
        """)
        let font = try #require(
            result.hostPayload as? GeneratedPlatformValue)
        #expect(font.framework == "UIKit")
        #expect(font.typeName == "UIFont")
    }
#endif

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
    @Test func oppositePlatformReferenceArgumentsAcceptGeneratedAndOpaqueImportedValues() throws {
        let source = """
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        parent.addSubview(UIView(frame: CGRect(x: 1, y: 1, width: 2, height: 2)))
        parent.addSubview(ExternalController().contentView)
        true
        """

        for registry: any HostRegistry in [ViewRegistry(), TraceRegistry()] {
            let result = try Interpreter(registry: registry).run(source: source)
            #expect(result.boolValue == true)
        }
    }

    @Test func sourceSubclassUsesImportedSuperclassHierarchyForHostArguments() throws {
        let source = """
        class PlatformWebView: WKWebView {}
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        parent.addSubview(PlatformWebView())
        true
        """

        for registry: any HostRegistry in [ViewRegistry(), TraceRegistry()] {
            let result = try Interpreter(registry: registry).run(source: source)
            #expect(result.boolValue == true)
        }
    }

    @Test func opaqueImportedReferencesDoNotBypassNativeReferenceTypes() throws {
        let source = """
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        parent.addSubview(ExternalController().contentView)
        """

        for registry: any HostRegistry in [ViewRegistry(), TraceRegistry()] {
            #expect(throws: RuntimeError.self) {
                _ = try Interpreter(registry: registry).run(source: source)
            }
        }
    }

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
