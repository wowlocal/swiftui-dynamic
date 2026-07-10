import SwiftSyntax

extension Interpreter {
    /// Evaluate a detached expression against the global environment. The
    /// bridge's test harness uses this for `@Test(arguments: …)` collections,
    /// whose expressions live in ATTRIBUTES rather than executable positions.
    public func evaluateGlobalExpression(_ expr: ExprSyntax) throws -> RuntimeValue {
        try evaluate(expr, in: globals)
    }

    /// Instantiate an interpreted type with labeled arguments — the bridge's
    /// structural JSON decode builds instances field by field.
    public func instantiateForBridge(_ symbol: StructSymbol, arguments: CallArguments) throws -> RuntimeValue {
        try instantiate(
            symbol, with: arguments,
            node: Syntax(DeclReferenceExprSyntax(baseName: .identifier("decodedInstance"))))
    }

    /// A declared type by name (`.type` / `.enumType`), if the program
    /// defines one — annotation-driven decode resolves element types here.
    public func typeValue(named name: String) -> RuntimeValue? {
        guard let value = globals.lookup(name) else { return nil }
        switch value {
        case .type, .enumType: return value
        default: return nil
        }
    }

    /// The full EXPRESSION the app declares as its root — the first
    /// statement inside an @main App scene's builder (wrappers like
    /// `StoreProvider(store:) { Tabbar() }` included, so the app's own
    /// environment seeding evaluates), or the delegate-hosted
    /// `rootView:` expression. Probes evaluate this in the global scope
    /// instead of instantiating a bare symbol.
    public func declaredRootViewExpression() -> (app: StructSymbol?, expression: ExprSyntax)? {
        for symbol in structSymbols where symbol.conformances.contains("App") {
            guard let body = symbol.computedProperties["body"] else { continue }
            if let sceneCall = Self.firstSceneBuilderCall(in: Syntax(body.accessor)),
               let trailing = sceneCall.trailingClosure,
               let first = trailing.statements.first,
               let expr = first.item.as(ExprSyntax.self) {
                return (symbol, expr)
            }
        }
        for symbol in structSymbols {
            for decls in symbol.methods.values {
                for decl in decls where decl.description.contains("HostingController") {
                    if let hosted = Self.hostedRootExpression(in: Syntax(decl)) {
                        return (nil, hosted)
                    }
                }
            }
        }
        return nil
    }

    /// Evaluate the declared root expression with the APP INSTANCE as self —
    /// `.environmentObject(appAccountsManager)` sees the App's own
    /// stored/@StateObject properties, exactly as at launch.
    public func evaluateAppRootExpression(_ expression: ExprSyntax, app: Instance?) throws -> RuntimeValue {
        guard let app else { return try evaluate(expression, in: globals) }
        return try evaluate(expression, in: selfEnvironment(.instance(app)))
    }

    private static let sceneContainers: Set<String> = ["WindowGroup", "Window", "DocumentGroup"]

    private static func firstSceneBuilderCall(in node: Syntax) -> FunctionCallExprSyntax? {
        if let call = node.as(FunctionCallExprSyntax.self),
           let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
           sceneContainers.contains(reference.baseName.text),
           call.trailingClosure != nil {
            return call
        }
        for child in node.children(viewMode: .sourceAccurate) {
            if let found = firstSceneBuilderCall(in: child) {
                return found
            }
        }
        return nil
    }

    /// The root view the APP declares — the first View-typed constructor in
    /// an @main App body's scene, or the expression a delegate hosts via
    /// UIHostingController(rootView:)/NSHostingController(rootView:).
    func declaredRootViewName() -> String? {
        let viewNames = Set(structSymbols.filter(\.conformsToView).map(\.name))
        guard !viewNames.isEmpty else { return nil }
        for symbol in structSymbols where symbol.conformances.contains("App") {
            if let body = symbol.computedProperties["body"],
               let name = Self.firstViewName(in: Syntax(body.accessor), among: viewNames) {
                return name
            }
        }
        for symbol in structSymbols {
            for decls in symbol.methods.values {
                for decl in decls where decl.description.contains("HostingController") {
                    if let hosted = Self.hostedRootExpression(in: Syntax(decl)),
                       let name = Self.firstViewName(in: Syntax(hosted), among: viewNames) {
                        return name
                    }
                }
            }
        }
        return nil
    }

    private static func hostedRootExpression(in node: Syntax) -> ExprSyntax? {
        if let call = node.as(FunctionCallExprSyntax.self),
           call.calledExpression.trimmedDescription.hasSuffix("HostingController"),
           let rootView = call.arguments.first(where: { $0.label?.text == "rootView" }) {
            return rootView.expression
        }
        for child in node.children(viewMode: .sourceAccurate) {
            if let found = hostedRootExpression(in: child) {
                return found
            }
        }
        return nil
    }

    private static func firstViewName(in node: Syntax, among viewNames: Set<String>) -> String? {
        if let call = node.as(FunctionCallExprSyntax.self),
           let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
           viewNames.contains(reference.baseName.text) {
            return reference.baseName.text
        }
        for child in node.children(viewMode: .sourceAccurate) {
            if let found = firstViewName(in: child, among: viewNames) {
                return found
            }
        }
        return nil
    }
}
