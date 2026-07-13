import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge
#if canImport(AppKit)
import AppKit
#endif

@Suite(.serialized) struct GeneratedPlatformBridgeTests {
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
}
