import SwiftInterpreter

/// LiveCheck's render probe: interpret a merged project, deep-render every
/// body (HeadlessVerifier mechanics), and collect every STRING argument in
/// the tree — scenario assertions check that fixture-derived content
/// (movie titles, status authors) actually reached the UI.
public enum LiveCheckSupport {
    public static func renderedStrings(source: String) throws -> [String] {
        let interpreter = Interpreter(registry: TraceRegistry())
        do {
            try interpreter.run(source: source, lazyTopLevelGlobals: true)
        } catch {
            throw RuntimeError(message: "top-level threw: \(error)")
        }
        for delegateSymbol in interpreter.structSymbols
        where delegateSymbol.conformances.contains("NSApplicationDelegate")
            || delegateSymbol.conformances.contains("UIApplicationDelegate") {
            guard case .instance(let delegate)? = try? interpreter.instantiateRoot(delegateSymbol) else {
                continue
            }
            let hook = RuntimeValue.native(ChainedImplicitCall(
                base: .implicitMember("launch"), member: "notification", arguments: CallArguments()))
            _ = try? interpreter.callMethod(
                named: "applicationDidFinishLaunching", on: delegate, arguments: [hook])
        }
        guard let symbol = interpreter.rootViewSymbol() else {
            throw RuntimeError(message: "no View-conforming struct found")
        }
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            throw RuntimeError(message: "could not instantiate '\(symbol.name)'")
        }
        try interpreter.injectEnvironmentObjects(into: instance, models: [:])
        interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
        let root = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
        var strings: [String] = []
        try collect(interpreter, root, into: &strings)
        return strings
    }

    private static func collect(
        _ interpreter: Interpreter, _ node: TraceNode, into strings: inout [String],
        environment: [String: Instance] = [:], depth: Int = 0
    ) throws {
        guard depth < 16 else { return }
        strings.append(contentsOf: node.args)
        var environment = environment
        environment.merge(node.environmentModels) { _, injected in injected }
        if let instance = node.instance {
            try interpreter.injectEnvironmentObjects(into: instance, models: environment)
            interpreter.injectEnvironmentValues(into: instance, values: InterpretedEnvironment.defaults())
            let body = try TraceRegistry.node(interpreter.evaluateBody(of: instance))
            try collect(interpreter, body, into: &strings, environment: environment, depth: depth + 1)
        }
        for child in node.children {
            try collect(interpreter, child, into: &strings, environment: environment, depth: depth + 1)
        }
    }
}
