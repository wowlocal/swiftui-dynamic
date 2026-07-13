import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

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
    @Test func appKitGeometryAliasesGenerateAsCoreGraphicsContracts() throws {
        let source = """
        let view = NSView(frame: CGRect(x: 1, y: 2, width: 30, height: 40))
        view.frame = CGRect(x: 3, y: 4, width: 50, height: 60)
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
