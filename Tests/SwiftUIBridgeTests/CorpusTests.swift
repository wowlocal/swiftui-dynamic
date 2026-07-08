import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// Corpus files live next to this test file (excluded from compilation in the
/// manifest) and are listed via #filePath. Test arguments are enumerated off
/// the main actor, so this path must be nonisolated despite the package-wide
/// MainActor default — hence the free function instead of a closure initializer.
private nonisolated func listCorpusFiles() -> [String] {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Corpus")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted()
}

nonisolated let corpusFiles: [String] = listCorpusFiles()

/// The "runs real-world code" gate: every program in Corpus/ must interpret,
/// deep-render (every View body force-evaluated, not just the lazy root),
/// survive having all its actions invoked, and render through real SwiftUI
/// hosting without inline errors.
enum Corpus {
    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus")
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite struct CorpusTests {
    @Test func corpusIsPopulated() {
        #expect(corpusFiles.count >= 10)
    }

    @Test(arguments: corpusFiles)
    func traceDeepRenderWithInteractions(file: String) throws {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: try Corpus.source(file))
        let symbol = try #require(interpreter.rootViewSymbol(), "no View struct in \(file)")
        guard case .instance(let instance) = try interpreter.instantiate(symbol, with: CallArguments()) else {
            Issue.record("could not instantiate root of \(file)")
            return
        }

        var actions: [ClosureValue] = []
        let root = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        let nodeCount = try deepRender(interpreter, root, actions: &actions)
        #expect(nodeCount > 1, "\(file) rendered a trivial tree")

        // Click through the UI like a user: each action fires against a FRESH
        // render of the tree (closures from stale trees may hold dead indices,
        // exactly as in real SwiftUI where old rows disappear).
        for position in 0..<actions.count {
            var current: [ClosureValue] = []
            let tree = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            _ = try deepRender(interpreter, tree, actions: &current)
            guard position < current.count else { break } // tree shrank
            _ = try interpreter.callClosure(current[position], arguments: [])
        }
        var ignored: [ClosureValue] = []
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        _ = try deepRender(interpreter, rerendered, actions: &ignored)
    }

    @Test(arguments: corpusFiles)
    func hostedRealRender(file: String) throws {
        RenderDiagnostics.reset()
        switch InterpreterHost().render(source: try Corpus.source(file)) {
        case .failure(let error):
            Issue.record("\(file): \(error)")
        case .success(let view):
            // Hosting in a (never-shown) window forces every nested
            // InterpretedView body to evaluate through the real gateways.
            let hosting = NSHostingView(rootView: view.frame(width: 480, height: 640))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for (viewName, error) in RenderDiagnostics.errors {
                Issue.record("\(file) → \(viewName): \(error)")
            }
        }
    }

    /// Recursively evaluates interpreted-View bodies and collects actions.
    @discardableResult
    private func deepRender(
        _ interpreter: Interpreter,
        _ node: TraceNode,
        actions: inout [ClosureValue],
        depth: Int = 0
    ) throws -> Int {
        guard depth < 16 else { return 1 }
        var count = 1
        actions += node.actions.values
        if let instance = node.instance {
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            count += try deepRender(interpreter, body, actions: &actions, depth: depth + 1)
        }
        for child in node.children {
            count += try deepRender(interpreter, child, actions: &actions, depth: depth + 1)
        }
        return count
    }
}
