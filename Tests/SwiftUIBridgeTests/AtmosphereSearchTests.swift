import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite(.serialized) struct AtmosphereSearchTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func typedQueryReachesSearchRequest() throws {
        let root = repositoryRoot()
        let source = ProjectMaterial.mergedSource(
            at: root.appendingPathComponent("Examples/Atmosphere").path
        )
        NetworkBridge.policy = .replay(
            fixturesDirectory: root.appendingPathComponent("Fixtures/open-meteo-lisbon").path
        )
        NetworkBridge.requestLog = []
        defer { NetworkBridge.policy = .absorbed }

        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source, lazyTopLevelGlobals: true)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("Atmosphere root was not instantiated")
            return
        }

        let tree = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        let field = try #require(tree.findAll("TextField").first)
        let text = try #require(field.bindings["text"])
        text.box.value = .native("Berlin")
        #expect(text.box.value.stringValue == "Berlin")
        #expect(field.modifiers.contains { $0.hasPrefix("onSubmit") })
        #expect(ViewRegistry().modifier(named: "onSubmit") != nil)

        let searchButton = try #require(tree.findAll("Button").first)
        let action = try #require(searchButton.actions["action"])
        _ = try interpreter.callClosure(action, arguments: [])

        #expect(NetworkBridge.requestLog.count == 3)
        #expect(NetworkBridge.requestLog.contains {
            $0.contains("/v1/search?") && $0.contains("name=Berlin") && $0.contains("hit")
        })
        #expect(NetworkBridge.requestLog.contains { $0.contains("/v1/forecast?") })
        #expect(NetworkBridge.requestLog.contains { $0.contains("/v1/air-quality?") })
    }

    @Test func taskBodyExecutesWithRealRegistry() throws {
        let source = """
        var result = "idle"
        Task {
            result = "ran"
        }
        result
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "ran")
    }

    @Test func suggestionsDebounceAndReachTheModel() async throws {
        let root = repositoryRoot()
        let source = ProjectMaterial.mergedSource(
            at: root.appendingPathComponent("Examples/Atmosphere").path
        )
        NetworkBridge.policy = .replay(
            fixturesDirectory: root.appendingPathComponent("Fixtures/open-meteo-lisbon").path
        )
        NetworkBridge.requestLog = []
        defer { NetworkBridge.policy = .absorbed }

        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source, lazyTopLevelGlobals: true)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let rootView) = try interpreter.instantiateRoot(symbol),
              case .instance(let store)? = rootView.box(for: "store")?.value else {
            Issue.record("Atmosphere store was not instantiated")
            return
        }

        store.box(for: "query")?.value = .native("Lo")
        _ = try interpreter.callMethod(named: "queryChanged", on: store, arguments: [])
        store.box(for: "query")?.value = .native("Lon")
        _ = try interpreter.callMethod(named: "queryChanged", on: store, arguments: [])

        try await Task.sleep(for: .milliseconds(450))

        let suggestions = try #require(store.box(for: "suggestions")?.value.arrayValue)
        #expect(suggestions.count == 1)
        #expect(NetworkBridge.requestLog.count == 1)
        #expect(NetworkBridge.requestLog[0].contains("name=Lon"))
        #expect(NetworkBridge.requestLog[0].contains("count=6"))
    }

    @Test func clearAndDismissControlsResetSearchState() throws {
        let root = repositoryRoot()
        let source = ProjectMaterial.mergedSource(
            at: root.appendingPathComponent("Examples/Atmosphere").path
        )
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source, lazyTopLevelGlobals: true)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let rootView) = try interpreter.instantiateRoot(symbol),
              case .instance(let store)? = rootView.box(for: "store")?.value else {
            Issue.record("Atmosphere store was not instantiated")
            return
        }

        store.box(for: "query")?.value = .native("Berlin")
        store.box(for: "suggestionMessage")?.value = .native("No matching cities found.")
        store.box(for: "errorMessage")?.value = .native("Previous error")
        store.box(for: "isSuggesting")?.value = .native(true)
        _ = try interpreter.callMethod(named: "dismissSuggestions", on: store, arguments: [])

        #expect(store.box(for: "query")?.value.stringValue == "Berlin")
        #expect(store.box(for: "suggestionMessage")?.value.stringValue == "")
        #expect(store.box(for: "isSuggesting")?.value.boolValue == false)

        store.box(for: "isLoading")?.value = .native(true)
        _ = try interpreter.callMethod(named: "clearSearch", on: store, arguments: [])

        #expect(store.box(for: "query")?.value.stringValue == "")
        #expect(store.box(for: "errorMessage")?.value.stringValue == "")
        #expect(store.box(for: "isLoading")?.value.boolValue == false)
    }

    @Test func temperatureUnitButtonRerendersDashboard() throws {
        let root = repositoryRoot()
        let source = ProjectMaterial.mergedSource(
            at: root.appendingPathComponent("Examples/Atmosphere").path
        )
        NetworkBridge.policy = .replay(
            fixturesDirectory: root.appendingPathComponent("Fixtures/open-meteo-lisbon").path
        )
        defer { NetworkBridge.policy = .absorbed }

        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source, lazyTopLevelGlobals: true)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let rootView) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("Atmosphere root was not instantiated")
            return
        }

        let initialTree = try TraceRegistry.node(interpreter.evaluateBody(of: rootView))
        let search = try #require(initialTree.findAll("Button").first)
        _ = try interpreter.callClosure(
            try #require(search.actions["action"]),
            arguments: []
        )

        let celsiusTree = try TraceRegistry.node(interpreter.evaluateBody(of: rootView))
        let celsiusDashboard = try #require(
            celsiusTree.findAll("View:AtmosphereDashboard").first?.instance
        )
        let celsiusDashboardTree = try TraceRegistry.node(
            interpreter.evaluateBody(of: celsiusDashboard)
        )
        #expect(celsiusDashboardTree.findAll("Text").contains { $0.args.first == "20°" })
        let unitButton = try #require(celsiusTree.findAll("Button").first {
            $0.findAll("Text").contains { $0.args.first == "°C" }
        })
        _ = try interpreter.callClosure(
            try #require(unitButton.actions["action"]),
            arguments: []
        )

        let fahrenheitTree = try TraceRegistry.node(interpreter.evaluateBody(of: rootView))
        let fahrenheitDashboard = try #require(
            fahrenheitTree.findAll("View:AtmosphereDashboard").first?.instance
        )
        let fahrenheitDashboardTree = try TraceRegistry.node(
            interpreter.evaluateBody(of: fahrenheitDashboard)
        )
        #expect(fahrenheitDashboardTree.findAll("Text").contains { $0.args.first == "68°" })
        #expect(fahrenheitTree.findAll("Button").contains {
            $0.findAll("Text").contains { $0.args.first == "°F" }
        })
    }
}
