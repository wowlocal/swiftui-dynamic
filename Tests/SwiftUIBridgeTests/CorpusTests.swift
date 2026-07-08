import AppKit
import SwiftUI
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The "runs real-world code" gate: every program in Corpus/ must interpret,
/// deep-render (every View body force-evaluated, not just the lazy root),
/// survive having all its actions invoked, and render through real SwiftUI
/// hosting without inline errors.
enum Corpus {
    static let files: [String] = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "swift", subdirectory: "Corpus") ?? []
        return urls.map(\.lastPathComponent).sorted()
    }()

    static func source(_ file: String) throws -> String {
        let name = file.hasSuffix(".swift") ? String(file.dropLast(6)) : file
        guard let url = Bundle.module.url(forResource: name, withExtension: "swift", subdirectory: "Corpus") else {
            throw RuntimeError(message: "missing corpus file \(file)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite struct CorpusTests {
    @Test func corpusIsPopulated() {
        #expect(Corpus.files.count >= 10)
    }

    @Test(arguments: Corpus.files)
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

        // Poke every recorded action once; the mutated state must still
        // deep-render cleanly.
        for action in actions {
            _ = try interpreter.callClosure(action, arguments: [])
        }
        var ignored: [ClosureValue] = []
        let rerendered = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        _ = try deepRender(interpreter, rerendered, actions: &ignored)
    }

    @Test(arguments: Corpus.files)
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
