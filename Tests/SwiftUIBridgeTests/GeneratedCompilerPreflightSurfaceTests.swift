import SwiftInterpreter
import SwiftUIBridge
import Testing

@Suite("Generated SwiftUI compiler-preflight surface", .serialized)
struct GeneratedCompilerPreflightSurfaceTests {
    @Test
    func viewRegistryExportsRealSwiftUIEffectsAndIsolation() throws {
        let registry = ViewRegistry()
        let module = try #require(registry.compilerPreflightHostModule)
        #expect(module.moduleName == "DynamicSwiftUIHostSurface")
        #expect(module.source.contains("@_exported import SwiftUI"))
        #expect(module.source.contains("@_exported import _Concurrency"))

        let preflight = try SwiftCompilerPreflight.activeMacOS(
            registry: registry)
        #expect(preflight.hostModule == module)
        #expect(preflight.configuration.gatewayManifestSHA256
            == module.manifestSHA256)
        let legal = try preflight.preflight(
            source: """
            @MainActor func update() {}
            func makeView() -> some View {
                Button("Run") { update() }
            }
            """,
            fileName: "swiftui-action-isolation.swift")
        #expect(legal.succeeded)

        let illegal = try preflight.preflight(
            source: """
            @MainActor func update() {}
            func invalidCall() {
                update()
            }
            """,
            fileName: "swiftui-action-isolation-negative.swift")
        #expect(!illegal.succeeded)
        #expect(illegal.diagnostics.contains {
            $0.file == "swiftui-action-isolation-negative.swift"
                && $0.line == 3
                && $0.message.contains("main actor-isolated global function")
                && $0.message.contains("nonisolated context")
        })

        let interpreter = try Interpreter.withActiveCompilerPreflight(
            registry: registry)
        let rendered = try interpreter.run(source: """
        @MainActor func update() {}
        Button("Run") { update() }
        """)
        #expect(registry.isViewValue(rendered))
        #expect(interpreter.lastCompilerPreflightResult?.succeeded == true)
        #expect(interpreter.compilerPreflight?.hostModule == module)
    }
}
