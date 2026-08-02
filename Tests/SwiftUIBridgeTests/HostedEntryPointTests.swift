import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// Hosting an app's own sources under a different scene — how a check harness
/// drives real app code (IceCubesCheck's row-tap rung merges the IceCubes app
/// target so the tap reaches the app's own `withAppRouter()` registry rather
/// than a restatement of it). Two properties make that possible: a merge can
/// hand its entry point to the caller, and a program with several `App` types
/// resolves the entry point the way Swift does.
@Suite(.serialized)
struct HostedEntryPointTests {
    /// Native-verified with real swiftc (`swiftc -parse-as-library`) on the
    /// two-type program below: it prints `attributed`, NOT `first-declared`.
    /// Swift picks the entry point by the `@main` attribute; declaration
    /// order carries no weight.
    ///
    ///     struct FirstDeclared { static func main() { print("first-declared") } }
    ///     @main struct AttributedEntryPoint { static func main() { print("attributed") } }
    private static let twoScenesSource = """
    struct FirstDeclaredApp: App {
        var body: some Scene {
            WindowGroup { Text("first-declared-scene") }
        }
    }

    @main
    struct AttributedApp: App {
        var body: some Scene {
            WindowGroup { Text("attributed-scene") }
        }
    }
    """

    @Test func attributedAppIsTheEntryPointNotTheFirstDeclared() async throws {
        let render = try await LiveCheckSupport.render(
            source: Self.twoScenesSource)
        #expect(render.rootSymbol == "scene:AttributedApp",
                Comment(rawValue:
                    "the @main App is the entry point, as the compiled "
                        + "program is; got \(render.rootSymbol)"))
        #expect(render.strings.contains("attributed-scene"),
                Comment(rawValue: "\(render.strings)"))
        #expect(!render.strings.contains("first-declared-scene"),
                Comment(rawValue: "\(render.strings)"))
    }

    /// One `App` and no attribute is every ordinary merge: unchanged.
    @Test func aLoneUnattributedAppStillLaunches() async throws {
        let render = try await LiveCheckSupport.render(source: """
        struct SoleApp: App {
            var body: some Scene {
                WindowGroup { Text("sole-scene") }
            }
        }
        """)
        #expect(render.rootSymbol == "scene:SoleApp")
        #expect(render.strings.contains("sole-scene"))
    }

    private static let hostedProgram = """
    @main
    struct HostedApp: App {
        var body: some Scene {
            WindowGroup { Text("hosted-scene") }
        }
    }

    @MainActor
    extension View {
        func withHostedRoutes() -> some View {
            navigationDestination(for: String.self) { value in
                Text("hosted-detail-" + value)
            }
        }
    }
    """

    private static func writeHostedProgram() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-entry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("HostedApp.swift")
        try Self.hostedProgram.write(
            to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test func aHostedMergeDropsTheProgramsOwnEntryPoint() throws {
        let file = try Self.writeHostedProgram()
        defer { try? FileManager.default.removeItem(atPath: file) }

        let declared = ProjectMaterial.mergedSource(files: [file])
        #expect(declared.contains("@main"),
                "an ordinary merge keeps the program's entry point")

        let hosted = ProjectMaterial.mergedSource(
            files: [file], entryPoint: .suppliedByCaller)
        #expect(!hosted.contains("@main"),
                "a hosted merge hands the entry point to the caller")
        // Only the attribute goes: the program's types are what the caller
        // came for.
        #expect(hosted.contains("struct HostedApp: App"))
        #expect(hosted.contains("func withHostedRoutes()"))
    }

    /// The whole arrangement end to end: the caller's scene is the root, and
    /// the hosted program's own `View` extension still registers the
    /// destination the caller's path pushes.
    @Test func aCallerSceneHostsTheProgramsOwnRegistry() async throws {
        let file = try Self.writeHostedProgram()
        defer { try? FileManager.default.removeItem(atPath: file) }

        let source = ProjectMaterial.mergedSource(
            files: [file], entryPoint: .suppliedByCaller)
            + ProjectMaterial.mergedSource(source: """
            @\u{6D}ain
            struct ProbeApp: App {
                @State private var path: [String] = ["alpha"]

                var body: some Scene {
                    WindowGroup {
                        NavigationStack(path: $path) {
                            Text("probe-root")
                                .withHostedRoutes()
                        }
                    }
                }
            }
            """, moduleName: "Probe")

        let render = try await LiveCheckSupport.render(source: source)
        #expect(render.rootSymbol == "scene:ProbeApp",
                Comment(rawValue:
                    "the caller supplies the entry point; got "
                        + render.rootSymbol))
        #expect(render.strings.contains("hosted-detail-alpha"),
                Comment(rawValue:
                    "the hosted program's own destination registry must "
                        + "resolve the pushed element; got \(render.strings)"))
        #expect(!render.strings.contains("hosted-scene"),
                Comment(rawValue:
                    "the hosted app's scene is not the entry point; got "
                        + "\(render.strings)"))
    }
}
