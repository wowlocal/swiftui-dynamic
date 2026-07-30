import AppKit
import SwiftUI
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// IceCubes R2 navigation header: compiled Catalyst owns the large title
/// inside the 900×700 content surface, while a macOS NavigationStack sends it
/// to window chrome. The native `NavigationChromeProbe` records dark title
/// pixels at x=2...158, y=76...99. This distilled source contains no app
/// imports or fixture data and proves the target-platform placement contract.
@Suite(.serialized)
struct NavigationChromeTargetProbeTests {
    @MainActor
    @Test func iOSTargetPlacesTitleInsideNavigationContainerOnly() throws {
        let previous = Interpreter.interpretsAsPlatform
        defer { Interpreter.interpretsAsPlatform = previous }

        Interpreter.interpretsAsPlatform = "iOS"
        let inStack = try Self.titleInk(navigationStack: true)
        #expect(inStack.count > 1_500)
        #expect(inStack.minX <= 2)
        #expect(inStack.maxX >= 157)
        #expect(inStack.minY == 76)
        #expect(inStack.maxY == 99)

        let outsideStack = try Self.titleInk(navigationStack: false)
        #expect(outsideStack.count == 0)

        Interpreter.interpretsAsPlatform = "macOS"
        let macOSHostChrome = try Self.titleInk(navigationStack: true)
        #expect(macOSHostChrome.count == 0)
    }

    /// Target-aware renders own one immutable build identity. SwiftUI-magic
    /// adapters must consume that identity through their EvalContext rather
    /// than consulting the legacy process-global default.
    @MainActor
    @Test func explicitBuildConfigurationOwnsNavigationPlatform() throws {
        let previous = Interpreter.interpretsAsPlatform
        defer { Interpreter.interpretsAsPlatform = previous }

        Interpreter.interpretsAsPlatform = "macOS"
        let catalystChrome = try Self.titleInk(
            navigationStack: true,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"))
        #expect(catalystChrome.count > 1_500)
        #expect(catalystChrome.minY == 76)
        #expect(catalystChrome.maxY == 99)

        Interpreter.interpretsAsPlatform = "iOS"
        let macOSChrome = try Self.titleInk(
            navigationStack: true,
            buildConfiguration: .init(platformName: "macOS"))
        #expect(macOSChrome.count == 0)
    }

    /// A non-View result-builder overload must execute the source conformer's
    /// body and preserve its native leaf. The counter distinguishes this from
    /// both the former pass-through and the same-shaped ViewBuilder overload.
    @MainActor
    @Test func interfaceResultBuilderExecutesConformingBody() throws {
        let source = """
        var toolbarExecutions = 0

        func toolbarLabel() -> String {
            toolbarExecutions += 1
            return "TOOLS"
        }

        struct ProbeToolbar: ToolbarContent {
            var body: some ToolbarContent {
                ToolbarItem(placement: .primaryAction) {
                    Text(toolbarLabel())
                }
            }
        }

        @main
        struct NavigationChromeApp: App {
            var body: some Scene {
                WindowGroup {
                    NavigationStack {
                        Color.white.toolbar {
                            ProbeToolbar()
                        }
                    }
                }
            }
        }
        """
        let session = try InterpreterHost().renderSession(
            source: source,
            buildConfiguration: .init(
                platformName: "iOS", targetEnvironment: "macCatalyst"),
            lazyTopLevelGlobals: true
        ).get()
        #expect(
            session.interpreter.globals.lookup("toolbarExecutions")?.intValue
                == 1)
    }

    @MainActor
    private static func titleInk(
        navigationStack: Bool,
        buildConfiguration: InterpreterBuildConfiguration? = nil
    ) throws -> (count: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) {
        let content = "Color.white.navigationTitle(\"Federated\")"
        let root = navigationStack
            ? "NavigationStack { \(content) }"
            : content
        let source = """
        @main
        struct NavigationChromeApp: App {
            var body: some Scene {
                WindowGroup {
                    \(root)
                        .frame(width: 900, height: 700)
                }
            }
        }
        """
        let host = InterpreterHost()
        let rendered = if let buildConfiguration {
            host.render(
                source: source,
                buildConfiguration: buildConfiguration,
                lazyTopLevelGlobals: true)
        } else {
            host.render(source: source, lazyTopLevelGlobals: true)
        }
        guard case .success(let view) = rendered else {
            Issue.record("navigation chrome probe failed to render")
            return (0, 0, 0, 0, 0)
        }

        let size = NSSize(width: 900, height: 700)
        let hosting = NSHostingView(rootView: view.background(Color.white))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 700,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.orderOut(nil)

        var points: [(x: Int, y: Int)] = []
        for y in 60..<116 {
            for x in 0..<200 {
                if let color = bitmap.colorAt(x: x, y: y),
                   color.brightnessComponent < 0.5 {
                    points.append((x, y))
                }
            }
        }
        guard !points.isEmpty else { return (0, 0, 0, 0, 0) }
        return (
            points.count,
            points.map(\.x).min()!, points.map(\.x).max()!,
            points.map(\.y).min()!, points.map(\.y).max()!)
    }
}
