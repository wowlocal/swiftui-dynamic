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

    /// Whether the type declares `init(from: Decoder)` — the bridge's decode
    /// routes SCALARS through it (synthesized-Codable types stay structural).
    public func declaresCodableInit(_ symbol: StructSymbol) -> Bool {
        symbol.initializers.contains(where: isCodableInitializer)
    }

    /// Call a STATIC method on an interpreted type (the bridge's
    /// URLProtocol shim asks `canInit(with:)`).
    public func callStatic(
        _ name: String, on symbol: StructSymbol, arguments: [RuntimeValue]
    ) throws -> RuntimeValue? {
        guard let overloads = symbol.staticMethods[name],
              let method = overloads.first,
              let body = functionMetadata(for: method).body else { return nil }
        let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(.type(symbol)))
        return try callWithArguments(
            closure,
            args: CallArguments(arguments: arguments.map { .init(label: nil, value: $0) }),
            node: nil)
    }

    /// Read a STATIC property/let of an interpreted type (diagnostics).
    public func readStatic(_ name: String, of symbol: StructSymbol) -> RuntimeValue? {
        try? staticMember(name, of: symbol)
    }

    /// Labeled method invocation for bridge shims (the Layout protocol's
    /// sizeThatFits(proposal:subviews:cache:) genre).
    public func callMethodLabeled(
        named name: String, on instance: Instance,
        arguments: [(label: String?, value: RuntimeValue)]
    ) throws -> RuntimeValue {
        guard let member = try instanceMember(name, on: instance),
              let closure = member.closureValue else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no method '\(name)'")
        }
        let args = CallArguments(arguments: arguments.map {
            .init(label: $0.label, value: $0.value)
        })
        return try callWithArguments(closure, args: args, node: nil)
    }

    /// Bridge-side key-path application (the Table gateway's value columns).
    public func applyKeyPathForBridge(_ stub: KeyPathStub, to value: RuntimeValue) throws -> RuntimeValue {
        try applyKeyPath(stub, to: value)
    }

    /// Bridge-side annotation resolution: turn markers into the named
    /// type's cases/statics/inits (`Binding<Loadable<String>>`'s get()
    /// returning `.notRequested` becomes the real case).
    ///
    /// Resolution is a typed operation, not merely a successful lookup. An
    /// unresolved result is semantic progress (`.fixtureScaledBody` may become
    /// `.body`) and remains subject to the generated consumer's validation.
    /// A concrete result, however, may be an off-host validation token because
    /// the native declaration cannot be named in this process; that token must
    /// not erase the original contextual expression unless the ordinary
    /// runtime type system proves it satisfies the expected type.
    public func resolveForBridge(_ value: RuntimeValue, typeName: String) -> RuntimeValue {
        guard let resolved = try? resolveAnnotated(value, typeName: typeName)
        else {
            return value
        }
        if resolved.carriesUnresolvedContextualMember {
            return resolved
        }
        return hostValue(resolved, matchesType: typeName) ? resolved : value
    }

    /// Interpreted URLProtocol subclasses (their canInit gates mocking).
    public var urlProtocolSymbols: [StructSymbol] {
        structSymbols.filter { $0.superclassName == "URLProtocol" }
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

    /// Lexically-scoped type lookup: a name used INSIDE a type prefers its
    /// nested types over same-named globals (`Instance.statuses: Statuses`
    /// is the nested config struct, not the merged program's endpoint enum).
    public func typeValue(named name: String, within owner: StructSymbol?) -> RuntimeValue? {
        if let nested = owner?.nestedTypes[name] {
            switch nested {
            case .type, .enumType: return nested
            default: break
            }
        }
        guard let owner else { return typeValue(named: name) }
        let ownerModules = sourceModuleNames(owning: .type(owner))
        if ownerModules.count == 1 {
            return lexicallyVisibleType(
                named: name, from: owner,
                sourceModuleName: ownerModules.first)
        }
        return lexicallyVisibleType(named: name, from: owner)
    }

    /// The full EXPRESSION the app declares as its root — the first
    /// statement inside an @main App scene's builder (wrappers like
    /// `StoreProvider(store:) { Tabbar() }` included, so the app's own
    /// environment seeding evaluates), or the delegate-hosted
    /// `rootView:` expression. Probes evaluate this in the global scope
    /// instead of instantiating a bare symbol.
    public func declaredRootViewExpression() -> (app: StructSymbol?, expression: ExprSyntax)? {
        for symbol in appSymbolsInEntryPointOrder() {
            if let sceneCall = Self.sceneBuilderCall(app: symbol),
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
                        return (nil, Self.resolvingLocalReference(hosted, in: Syntax(decl)))
                    }
                }
            }
        }
        return nil
    }

    /// The @main App's scene BODY as a builder: instantiate the App once
    /// (stored/@StateObject props evaluate), then collect the scene
    /// closure's views with the App as self — multi-statement and
    /// conditional scenes included. nil when there is no App/scene.
    /// Swift picks a program's entry point by the `@main` attribute, not by
    /// declaration order: a program may declare several `App` types (a host
    /// harness merged with the app it hosts, an app alongside a preview or
    /// probe scene) and exactly one of them is attributed. Ordering the
    /// attributed types first makes that the interpreter's rule too, while a
    /// program with a single unattributed `App` — every ordinary merge —
    /// resolves exactly as before.
    func appSymbolsInEntryPointOrder() -> [StructSymbol] {
        let apps = structSymbols.filter { $0.conformances.contains("App") }
        let attributed = apps.filter { $0.attributeNames.contains("main") }
        return attributed + apps.filter {
            !$0.attributeNames.contains("main")
        }
    }

    public func declaredAppSceneRoot() -> (app: Instance, sceneBody: CodeBlockItemListSyntax)? {
        for symbol in appSymbolsInEntryPointOrder() {
            guard let sceneCall = Self.sceneBuilderCall(app: symbol),
                  let trailing = sceneCall.trailingClosure else { continue }
            guard case .instance(let app)? = try? instantiateRoot(symbol) else { continue }
            return (app, trailing.statements)
        }
        return nil
    }

    /// Collect the scene's views (builder semantics) with the App as self.
    public func sceneViews(app: Instance, sceneBody: CodeBlockItemListSyntax) throws -> [RuntimeValue] {
        try withDetachedSourceContext(
            at: sceneBody.positionAfterSkippingLeadingTrivia,
            owner: app.symbol,
            programState: app.programState
        ) {
            try collectBuilderViews(
                sceneBody, in: selfEnvironment(.instance(app)))
        }
    }

    /// Evaluate the declared root expression with the APP INSTANCE as self —
    /// `.environmentObject(appAccountsManager)` sees the App's own
    /// stored/@StateObject properties, exactly as at launch.
    public func evaluateAppRootExpression(_ expression: ExprSyntax, app: Instance?) throws -> RuntimeValue {
        try withDetachedSourceContext(
            at: expression.positionAfterSkippingLeadingTrivia,
            owner: app?.symbol,
            programState: app?.programState ?? compatibilityProgramState
        ) {
            guard let app else { return try evaluate(expression, in: globals) }
            return try evaluate(
                expression, in: selfEnvironment(.instance(app)))
        }
    }

    /// Bridge-facing launch APIs detach syntax from its declaring accessor.
    /// Re-enter the immutable program, nominal, and per-file source context so
    /// later evaluation has the same lexical visibility as ordinary accessor
    /// dispatch. This is property-based provenance recovery: the syntax byte
    /// position selects its compiler module and imports without naming an SDK
    /// or source nominal.
    private func withDetachedSourceContext<T>(
        at sourcePosition: AbsolutePosition,
        owner: StructSymbol?,
        programState: RuntimeProgramState?,
        _ operation: () throws -> T
    ) throws -> T {
        evaluationTaskContext.enterProgramState(programState)
        defer { evaluationTaskContext.leaveProgramState(programState) }

        let metadata = programState?.programPlan?.metadata
            ?? currentProgramMetadata
        lexicalSourceModuleFrames.append(
            metadata?.sourceModuleName(at: sourcePosition))
        lexicalSourceImportFrames.append(
            metadata?.sourceImportedModuleNames(at: sourcePosition))
        lexicalSourceFileFrames.append(
            metadata?.sourceFileIdentity(at: sourcePosition))
        if let owner { lexicalOwnerFrames.append(owner) }
        defer {
            if owner != nil { lexicalOwnerFrames.removeLast() }
            lexicalSourceFileFrames.removeLast()
            lexicalSourceImportFrames.removeLast()
            lexicalSourceModuleFrames.removeLast()
        }
        return try operation()
    }

    private static let sceneContainers: Set<String> = [
        "WindowGroup", "Window", "DocumentGroup",
        // Menu-bar and settings apps: their FIRST scene is the primary UI
        // (a MenuBarExtra-first app's launch surface IS the menu content) —
        // the last opaque shell in the app-shell census.
        "MenuBarExtra", "Settings",
    ]

    /// The App's scene-builder call, following ONE level of indirection:
    /// `var body: some Scene { appScene; otherScenes }` references
    /// scene-valued computed properties (extensions merge them into the
    /// symbol) whose accessors hold the real WindowGroup — IceCubes' shape.
    /// Without this, the share-extension's UIHostingController hunt hijacks
    /// root selection.
    static func sceneBuilderCall(app symbol: StructSymbol) -> FunctionCallExprSyntax? {
        guard let body = symbol.computedProperties["body"] else { return nil }
        if let direct = firstSceneBuilderCall(in: Syntax(body.accessor)) { return direct }
        for name in referencedIdentifiers(in: Syntax(body.accessor)) {
            if let property = symbol.computedProperties[name],
               let call = firstSceneBuilderCall(in: Syntax(property.accessor)) {
                return call
            }
        }
        return nil
    }

    private static func referencedIdentifiers(in node: Syntax) -> [String] {
        var names: [String] = []
        func walk(_ node: Syntax) {
            if let reference = node.as(DeclReferenceExprSyntax.self) {
                let name = reference.baseName.text
                if !names.contains(name) { names.append(name) }
            }
            for child in node.children(viewMode: .sourceAccurate) { walk(child) }
        }
        walk(node)
        return names
    }

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
            if let call = Self.sceneBuilderCall(app: symbol),
               let name = Self.firstViewName(in: Syntax(call), among: viewNames) {
                return name
            }
            if let body = symbol.computedProperties["body"],
               let name = Self.firstViewName(in: Syntax(body.accessor), among: viewNames) {
                return name
            }
        }
        for symbol in structSymbols {
            for decls in symbol.methods.values {
                for decl in decls where decl.description.contains("HostingController") {
                    if let hosted = Self.hostedRootExpression(in: Syntax(decl)),
                       let name = Self.firstViewName(
                           in: Syntax(Self.resolvingLocalReference(hosted, in: Syntax(decl))),
                           among: viewNames) {
                        return name
                    }
                }
            }
        }
        return nil
    }

    /// `let view = StoreProvider(store:) {…}; UIHostingController(rootView:
    /// view)` — a bare reference resolves to its LOCAL declaration's
    /// initializer, so the probe evaluates the real wrapper expression
    /// instead of an undefined global name.
    static func resolvingLocalReference(_ expr: ExprSyntax, in method: Syntax) -> ExprSyntax {
        guard let ref = expr.as(DeclReferenceExprSyntax.self) else { return expr }
        let name = ref.baseName.text
        var result: ExprSyntax?
        func walk(_ node: Syntax) {
            if let varDecl = node.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings
                where binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
                    if let initializer = binding.initializer?.value {
                        result = initializer
                    }
                }
            }
            for child in node.children(viewMode: .sourceAccurate) { walk(child) }
        }
        walk(method)
        return result ?? expr
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
