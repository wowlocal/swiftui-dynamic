import Foundation
import SwiftInterpreter
import SwiftUIBridge
import Testing

@Suite("Generated SwiftUI compiler-preflight surface", .serialized)
struct GeneratedCompilerPreflightSurfaceTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

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

    @Test
    func publicProjectFacadeCanRequireNativeCompilerChecking() {
        let projectRoot = repositoryRoot()
            .appendingPathComponent("Examples/TaskObservatory")
            .path
        let source = ProjectMaterial.mergedSource(at: projectRoot)
        let compilerSources = ProjectMaterial.compilerPreflightSources(
            from: source)
        #expect(compilerSources?.map(\.fileName) == [
            "ContentView.swift",
            "Models.swift",
            "TaskObservatoryStore.swift",
        ])
        #expect(compilerSources?.allSatisfy {
            !$0.source.contains("// FILE:")
        } == true)
        let outcome = InterpreterHost(compilerPreflightMode: .required)
            .render(source: source, lazyTopLevelGlobals: true)

        if case .failure(let error) = outcome {
            Issue.record("compiler-checked project render failed: \(error)")
        }
    }

    @Test
    func requiredProjectFacadeRejectsNativeIsolationDiagnostic() {
        let outcome = InterpreterHost(compilerPreflightMode: .required)
            .render(source: """
            // FILE: State.swift
            @MainActor func update() {}

            // FILE: ContentView.swift
            func invalidCall() {
                update()
            }
            struct ContentView: View {
                var body: some View { Text("Invalid") }
            }
            """)

        guard case .failure(let error) = outcome else {
            Issue.record("required compiler checking accepted invalid source")
            return
        }
        #expect(error.message.contains("ContentView.swift"))
        #expect(error.message.contains("main actor-isolated global function"))
        #expect(error.message.contains("synchronous nonisolated context"))
    }

    @Test
    func requiredProjectFacadePreservesSwiftFilePrivateScope() {
        let source = """
        // FILE: First.swift
        private func fileScopedValue() -> Int { 20 }

        // FILE: Second.swift
        private func fileScopedValue() -> Int { 22 }

        // FILE: ContentView.swift
        struct ContentView: View {
            var body: some View { Text("Ready") }
        }
        """
        let outcome = InterpreterHost(compilerPreflightMode: .required)
            .render(source: source, lazyTopLevelGlobals: true)

        if case .failure(let error) = outcome {
            Issue.record("multi-file private scope was flattened: \(error)")
        }
    }
}
