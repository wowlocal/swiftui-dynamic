import Foundation
import SwiftSyntax

/// Reference-typed stand-in for an imported class supplied by the headless
/// root synthesizer. Ordinary unknowable markers are value carriers, but a
/// weak/unowned source slot can only legally contain a class; this wrapper
/// preserves that compiled type fact and gives the synthetic caller a stable
/// identity to own.
private nonisolated final class SynthesizedExternalObject:
    Sendable, InertCallable, CustomStringConvertible
{
    let typeName: String

    init(typeName: String) {
        self.typeName = typeName
    }

    var description: String { "synthesized.\(typeName)" }
}

extension Interpreter {
    // MARK: - Instances

    /// A builder-attributed stored property builds from its trailing closure:
    /// `[X]`-annotated properties collect the block's items into an ARRAY
    /// (custom @resultBuilders' buildBlock), view-typed ones group as views.
    func builderValue(for property: StructSymbol.StoredProperty, closure: ClosureValue) throws -> RuntimeValue {
        let items = try callBuilderClosure(closure, arguments: [])
        let annotation = property.typeAnnotation?.trimmedDescription ?? ""
        if annotation.hasPrefix("[") {
            return .native(items)
        }
        return try groupViews(items)
    }


    /// Custom `init`s run with `self` bound to a defaults-initialized instance;
    /// otherwise default + memberwise initialization applies. `$binding`
    /// arguments for `@Binding` properties share the parent's Box.
    /// The symbol's stored properties plus its INTERPRETED superclass
    /// chain's (base-first, child names win) — inherited storage is real.
    func inheritedStoredProperties(of symbol: StructSymbol) -> [StructSymbol.StoredProperty] {
        var chain: [StructSymbol] = []
        var current: StructSymbol? = symbol
        var guardSet: Set<ObjectIdentifier> = []
        while let symbol = current, guardSet.insert(ObjectIdentifier(symbol)).inserted {
            chain.append(symbol)
            current = interpretedSuperclass(of: symbol)
        }
        var seen: Set<String> = []
        var merged: [StructSymbol.StoredProperty] = []
        for symbol in chain { // child first: child declarations win
            for property in symbol.storedProperties where seen.insert(property.name).inserted {
                merged.append(property)
            }
        }
        return merged
    }

    /// A class lifetime necessarily reaches every deinitializer in its
    /// superclass chain. Reject construction before allocating storage when
    /// any of those bodies requires executor-owned teardown for which the
    /// runtime has no capability. MainActor-owned bodies carry supported
    /// executor metadata instead. Declaration collection remains side-effect
    /// free.
    private func executorOwnedDeinitializerError(
        for symbol: StructSymbol
    ) -> RuntimeError? {
        var current: StructSymbol? = symbol
        var walked: Set<ObjectIdentifier> = []
        while let candidate = current,
              walked.insert(ObjectIdentifier(candidate)).inserted {
            if let error = candidate.executorOwnedDeinitializerError {
                return error
            }
            current = interpretedSuperclass(of: candidate)
        }
        return nil
    }

    /// Allocate an instance and evaluate non-suspending stored-property
    /// defaults. Sync and async declared initializers start from the same
    /// storage state; only execution of the selected body is effect-specific.
    private func makeInstanceSeed(
        for symbol: StructSymbol, node: Syntax?
    ) throws -> Instance {
        if let error = executorOwnedDeinitializerError(for: symbol) {
            throw error
        }
        let instance = Instance(
            symbol: symbol,
            lifecycleOwner: symbol.isClass ? self : nil,
            programState: currentProgramState)
        if symbol.isActor {
            instance.actorID = concurrencyRuntime.registerActor(instance)
        }
        let notifying = Set(symbol.notifyingPropertyNames)
        for property in inheritedStoredProperties(of: symbol) {
            // Optional-typed properties without initializers are nil.
            let annotationText = property.typeAnnotation?.trimmedDescription ?? ""
            var value: RuntimeValue = RuntimeOptionalValue.wrappedType(in: annotationText) != nil
                ? .none(forTypeAnnotation: annotationText) : .void
            if property.isLazy, let initializer = property.initializer {
                // Lazy defaults evaluate on first access with self bound.
                let box = Box(
                    .native(LazyMemberSeed(
                        initializer: initializer, annotation: property.typeAnnotation)),
                    declaredTypeName: annotationText,
                    referenceOwnership: property.referenceOwnership)
                instance.properties[property.name] = box
                continue
            }
            if let initializer = property.initializer {
                // Ordinary defaults execute in the nominal type's static
                // context before either sync or async init body begins.
                do {
                    value = try resolveAnnotated(
                        try evaluate(initializer, in: selfEnvironment(.type(symbol))),
                        annotation: property.typeAnnotation
                    )
                } catch is InterpretedThrow {
                    // Headless resource construction can legitimately throw;
                    // preserve the existing unknowable-default policy.
                    value = .native(ChainedImplicitCall(
                        base: .implicitMember("default"), member: property.name,
                        arguments: CallArguments()))
                }
            }
            if case .void = value, property.wrapper == .state {
                // State-like wrappers whose default lives in external
                // wrapper metadata receive a synthesized fresh identity.
                var seen: Set<String> = []
                value = (try? synthesizedFreshValue(
                    typeName: property.typeAnnotation?.trimmedDescription ?? "",
                    seen: &seen)) ?? .nilValue
            }
            let box = Box(
                value.copiedForValueSemantics(),
                declaredTypeName: annotationText.isEmpty ? nil : annotationText,
                referenceOwnership: property.referenceOwnership)
            if notifying.contains(property.name) {
                // Published/observable storage shares one change signal.
                let signal = instance.changeSignal
                box.onChange = { signal.fire() }
            }
            switch property.wrapper {
            case .state, .stateObject:
                if persistentViewState, symbol.conformsToView, let site = node?.id {
                    let key = ViewStateKey(
                        site: site, type: symbol.name, property: property.name,
                        salt: viewIdentitySalts.joined(separator: "/"))
                    if Self.traceStateCells,
                       property.name == "viewModel" || property.name == "fetcher" {
                        Swift.print("   ⌘ \(symbol.name).\(property.name) idx=\(site.indexInTree) salt=[\(key.salt)] \(viewStateCells[key] != nil ? "HIT" : "miss") src=\(node?.description.replacingOccurrences(of: "\n", with: " ").prefix(70) ?? "")")
                    }
                    if let existing = viewStateCells[key] {
                        instance.stateBoxes[property.name] = existing
                    } else {
                        viewStateCells[key] = box
                        instance.stateBoxes[property.name] = box
                    }
                } else {
                    if Self.traceStateCells,
                       property.name == "viewModel" || property.name == "fetcher" {
                        Swift.print("   ⌘ \(symbol.name).\(property.name) NO-SITE persistent=\(persistentViewState) view=\(symbol.conformsToView)")
                    }
                    instance.stateBoxes[property.name] = box
                }
            default:
                instance.properties[property.name] = box
            }
        }
        return instance
    }

    private func effectiveInitializers(
        for symbol: StructSymbol
    ) -> [InitializerDeclSyntax] {
        guard symbol.initializers.isEmpty else { return symbol.initializers }
        var parent = interpretedSuperclass(of: symbol)
        var walked: Set<ObjectIdentifier> = []
        while let candidate = parent,
              walked.insert(ObjectIdentifier(candidate)).inserted {
            if !candidate.initializers.isEmpty { return candidate.initializers }
            parent = interpretedSuperclass(of: candidate)
        }
        return []
    }

    private func initializerPlan(
        for symbol: StructSymbol, arguments: CallArguments
    ) -> (
        effective: [InitializerDeclSyntax],
        strict: InitializerDeclSyntax?,
        memberwise: Bool
    ) {
        let effective = effectiveInitializers(for: symbol)
        let available = effective.filter {
            !activeInitializers.contains($0.id)
        }
        let strict = chooseInitializerStrict(
            from: available, for: arguments)
        var memberwise = effective.isEmpty
        if !memberwise, strict == nil {
            let propertyNames = Set(
                inheritedStoredProperties(of: symbol).map(\.name))
            let labels = arguments.arguments.compactMap(\.label)
            if !labels.isEmpty,
               labels.allSatisfy({ propertyNames.contains($0) }) {
                memberwise = true
            }
        }
        return (effective, strict, memberwise)
    }

    private func initializerIsAsync(
        _ initializer: InitializerDeclSyntax
    ) -> Bool {
        initializerMetadata(for: initializer).isAsync
    }

    public func instantiate(_ symbol: StructSymbol, with args: CallArguments, node: Syntax? = nil) throws -> RuntimeValue {
        if let traced = Self.tracedInitializer,
           symbol.name.contains(traced) {
            let shapes = args.arguments
                .map { "\($0.label ?? "_"): \($0.value.stringified.prefix(90))" }
                .joined(separator: ", ")
            Swift.print("⟶ init \(symbol.name)(\(shapes))")
        }
        let instance = try makeInstanceSeed(for: symbol, node: node)

        // Declared inits win when one FITS and isn't already running (a
        // convenience init delegating to itself would recurse forever);
        // otherwise property-shaped labels bind MEMBERWISE — extension
        // inits don't suppress the memberwise init (SeparatorHStack's
        // closure-taking convenience delegates to the synthesized
        // value-taking form).
        // Swift init INHERITANCE: a class that declares no initializers
        // inherits its superclass's designated inits (the test-suite
        // subclass pattern: `@Suite class Base { init() { sut = … } }` +
        // `final class CaseTests: Base` — instantiating the subclass runs
        // the base init with self = the subclass instance).
        let plan = initializerPlan(for: symbol, arguments: args)
        let effectiveInitializers = plan.effective
        let strictChoice = plan.strict
        let memberwise = plan.memberwise
        if memberwise {
            var assigned = Set<String>()
            // Labeled arguments claim their properties FIRST, so an unlabeled
            // trailing closure can't steal a property that a later labeled
            // trailing names (`CustomButton(tint:) { content } action: {…}`).
            for argument in args.arguments {
                guard let label = argument.label else { continue }
                guard let property = symbol.storedProperty(named: label),
                      let box = instance.box(for: label) else {
                    // Host-superclass classes (class RainFall: SKScene)
                    // inherit their initializers: unmatched labeled
                    // arguments bind as properties so later reads
                    // (`size` in sceneDidLoad) see the passed values.
                    if symbol.superclassName != nil,
                       interpretedSuperclass(of: symbol) == nil {
                        instance.properties[label] = Box(argument.value.copiedForValueSemantics())
                        assigned.insert(label)
                        continue
                    }
                    // MACRO-generated memberwise slots (@ModelActor's
                    // init(modelContainer:)): the attribute's generated
                    // init is invisible to the merge — bind the argument
                    // as a property.
                    if symbol.attributeNames.contains(where: { $0.first?.isUppercase == true }) {
                        instance.properties[label] = Box(argument.value.copiedForValueSemantics())
                        assigned.insert(label)
                        continue
                    }
                    let message = "argument '\(label)' doesn't match a stored property of '\(symbol.name)'"
                    if let node { throw error(node, message) }
                    throw RuntimeError(message: message)
                }
                assigned.insert(label)
                if property.wrapper == .binding,
                   case .host(let any) = argument.value, let stub = any as? BindingStub {
                    instance.properties[label] = stub.box
                } else if property.wrapper == .binding,
                          case .host(let any) = argument.value,
                          let call = any as? ImplicitMemberCall, call.name == "constant" {
                    // `.constant("")` — a binding to a fixed value.
                    instance.properties[label] = Box(try resolveAnnotated(
                        call.arguments.positional(0) ?? .void,
                        annotation: property.typeAnnotation).copiedForValueSemantics())
                } else if let closure = argument.value.closureValue,
                          property.isBuilderClosure,
                          !(property.typeAnnotation?.trimmedDescription.contains("->") ?? false) {
                    // Labeled trailing onto a builder property.
                    box.value = try builderValue(for: property, closure: closure)
                        .copiedForValueSemantics()
                } else {
                    box.value = try resolveAnnotated(
                        argument.value, annotation: property.typeAnnotation)
                        .copiedForValueSemantics()
                }
            }
            for argument in args.arguments where argument.label == nil {
                if argument.value.closureValue != nil {
                    // Unlabeled trailing closure → FIRST unassigned
                    // closure-shaped stored property (SE-0286 forward scan);
                    // @ViewBuilder properties store the BUILT view (matching
                    // Swift's synthesized memberwise + builder init).
                    // `TagLayout(spacing: 10) { … }` — Layout containers
                    // take trailing content; children stash for rendering
                    // (the custom layout math doesn't run — documented).
                    if symbol.conformsToLayout,
                       !symbol.storedProperties.contains(where: { !assigned.contains($0.name) && $0.acceptsTrailingClosure }) {
                        let closure = argument.value.closureValue!
                        let children = try callBuilderClosure(closure, arguments: [])
                        instance.properties[StructSymbol.layoutChildrenKey] = Box(
                            RuntimeValue.native(children).copiedForValueSemantics())
                        if ProcessInfo.processInfo.environment["FTCHECK_TRACE"] != nil {
                            FileHandle.standardError.write(Data(
                                "LAYOUTSTASH \(symbol.name) children=\(children.count)\n".utf8))
                        }
                        continue
                    }
                    guard let property = symbol.storedProperties.first(where: {
                        !assigned.contains($0.name) && $0.acceptsTrailingClosure
                    }), let box = instance.box(for: property.name) else {
                        let message = "trailing closure doesn't match a closure property of '\(symbol.name)'"
                        if let node { throw error(node, message) }
                        throw RuntimeError(message: message)
                    }
                    assigned.insert(property.name)
                    let functionTyped = property.typeAnnotation?.trimmedDescription.contains("->") ?? false
                    if property.isBuilderClosure && !functionTyped {
                        // Builder property — build now (array or grouped views).
                        let closure = argument.value.closureValue!
                        box.value = try builderValue(for: property, closure: closure)
                            .copiedForValueSemantics()
                    } else {
                        // `var content: (CGSize) -> Content` (builder or not) —
                        // store the closure; the body calls it with arguments.
                        box.value = argument.value.copiedForValueSemantics()
                    }
                } else {
                    let message = "argument '_' doesn't match a stored property of '\(symbol.name)'"
                    if let node { throw error(node, message) }
                    throw RuntimeError(message: message)
                }
            }
        } else {
            if strictChoice == nil,
               !args.arguments.isEmpty,
               registry?.constructor(named: symbol.name) != nil {
                // No init fits and a HOST type shares the name (protobuf's
                // `struct Link` vs SwiftUI.Link): real Swift overload-
                // resolves across modules — the binding error routes the
                // caller's registry retry.
                let message = "argument '\(args.arguments.first?.label ?? "_")' doesn't match a stored property of '\(symbol.name)'"
                if let node { throw error(node, message) }
                throw RuntimeError(message: message)
            }
            let chosen = strictChoice
                ?? chooseInitializer(from: effectiveInitializers, for: args)
            if initializerIsAsync(chosen) {
                let message = "async initializer for '\(symbol.name)' requires runAsync and await"
                if let node { throw error(node, message) }
                throw RuntimeError(message: message)
            }
            let initialized = try runInitializer(
                chosen, on: instance, args: args, node: node)
            return initializerMetadata(for: chosen).isFailable
                ? initialized.liftedToOptional(wrappedTypeName: symbol.name)
                : initialized
        }
        return .instance(instance)
    }

    /// Effect-aware constructor entry used by the async evaluator. Ordinary
    /// memberwise and synchronous constructors stay on the established
    /// synchronous dispatch path; only a selected async initializer allocates
    /// a seed and executes its body with suspension propagation.
    func instantiateSuspending(
        _ symbol: StructSymbol, with arguments: CallArguments,
        node: Syntax
    ) async throws -> RuntimeValue {
        let plan = initializerPlan(for: symbol, arguments: arguments)
        guard !plan.memberwise, !plan.effective.isEmpty else {
            return try invoke(
                .type(symbol), with: arguments,
                node: node)
        }
        if plan.strict == nil, !arguments.arguments.isEmpty,
           registry?.constructor(named: symbol.name) != nil {
            return try invoke(
                .type(symbol), with: arguments,
                node: node)
        }
        let chosen = plan.strict
            ?? chooseInitializer(from: plan.effective, for: arguments)
        guard initializerIsAsync(chosen) else {
            return try invoke(
                .type(symbol), with: arguments,
                node: node)
        }

        if let traced = Self.tracedInitializer,
           symbol.name.contains(traced) {
            let shapes = arguments.arguments
                .map { "\($0.label ?? "_"): \($0.value.stringified.prefix(90))" }
                .joined(separator: ", ")
            Swift.print("⟶ async init \(symbol.name)(\(shapes))")
        }
        let instance = try makeInstanceSeed(for: symbol, node: node)
        let initialized = try await runInitializerSuspending(
            chosen, on: instance, args: arguments, node: node)
        return initializerMetadata(for: chosen).isFailable
            ? initialized.liftedToOptional(wrappedTypeName: symbol.name)
            : initialized
    }

    /// Sentinel unwound when a DELEGATED failable init returns nil: the
    /// enclosing init fails too (real init-delegation semantics).
    static let initFailedSentinel = "__delegated_init_failed__"

    /// Run one initializer body with `self` bound to the instance — used
    /// by instantiate and by `self.init(…)` delegation. Returns the FINAL
    /// self: struct inits may reassign it (`self = decoded`), and the
    /// caller must hand back that value, not the seed instance.
    @discardableResult
    func runInitializer(
        _ chosen: InitializerDeclSyntax, on instance: Instance,
        args: CallArguments, node: Syntax?
    ) throws -> RuntimeValue {
        let metadata = initializerMetadata(for: chosen)
        guard let body = metadata.body else {
            throw RuntimeError(message: "init of '\(instance.symbol.name)' has no body")
        }
        let inserted = activeInitializers.insert(chosen.id).inserted
        defer { if inserted { activeInitializers.remove(chosen.id) } }
        let instanceKey = ObjectIdentifier(instance)
        let instanceInserted = initializingInstances.insert(instanceKey).inserted
        defer { if instanceInserted { initializingInstances.remove(instanceKey) } }
        let ownsInitializationFlag = !instance.isInitializing
        if ownsInitializationFlag { instance.isInitializing = true }
        defer { if ownsInitializationFlag { instance.isInitializing = false } }
        let initEnv = selfEnvironment(.instance(instance))
        let closure = makeInitializerClosure(
            chosen,
            body: body,
            captured: initEnv,
            debugName: "init:\(instance.symbol.name)",
            fallbackLexicalOwner: instance.symbol)
        let outcome: RuntimeValue
        do {
            outcome = try callWithArguments(closure, args: args, node: node)
        } catch let failure as RuntimeError where failure.message == Self.initFailedSentinel {
            return .nilValue // a delegated failable init said no
        }
        if metadata.isFailable, outcome.isNil {
            return .nilValue // failable init: `return nil` means NO value
        }
        if case .instance(let final)? = initEnv.lookup("self"), final !== instance {
            if ownsInitializationFlag { final.isInitializing = false }
            return .instance(final) // `self = other` reassigned the value
        }
        return .instance(instance)
    }

    @discardableResult
    func runInitializerSuspending(
        _ chosen: InitializerDeclSyntax, on instance: Instance,
        args: CallArguments, node: Syntax?
    ) async throws -> RuntimeValue {
        let metadata = initializerMetadata(for: chosen)
        guard let body = metadata.body else {
            throw RuntimeError(
                message: "init of '\(instance.symbol.name)' has no body")
        }
        let inserted = activeInitializers.insert(chosen.id).inserted
        defer { if inserted { activeInitializers.remove(chosen.id) } }
        let instanceKey = ObjectIdentifier(instance)
        let instanceInserted = initializingInstances.insert(instanceKey).inserted
        defer { if instanceInserted { initializingInstances.remove(instanceKey) } }
        let ownsInitializationFlag = !instance.isInitializing
        if ownsInitializationFlag { instance.isInitializing = true }
        defer { if ownsInitializationFlag { instance.isInitializing = false } }

        let initEnv = selfEnvironment(.instance(instance))
        let closure = makeInitializerClosure(
            chosen,
            body: body,
            captured: initEnv,
            debugName: "asyncInit:\(instance.symbol.name)",
            fallbackLexicalOwner: instance.symbol)

        let outcome: RuntimeValue
        do {
            outcome = try await callWithArgumentsSuspending(
                closure, args: args, node: node)
        } catch let failure as RuntimeError
            where failure.message == Self.initFailedSentinel {
            return .nilValue
        }
        if metadata.isFailable, outcome.isNil { return .nilValue }
        if case .instance(let final)? = initEnv.lookup("self"),
           final !== instance {
            if ownsInitializationFlag { final.isInitializing = false }
            return .instance(final)
        }
        return .instance(instance)
    }

    /// Whether a declared result type supplies an immediately chained
    /// instance member. Swift uses this constraint to disambiguate overloads
    /// that differ only in result type (`make().member`). Keep the test over
    /// declaration structure rather than over either API identity.
    private func functionResultDeclaresMember(
        _ function: FunctionDeclSyntax,
        named memberName: String
    ) -> Bool {
        guard var typeName = functionMetadata(for: function).returnTypeName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !typeName.isEmpty else {
            return false
        }
        while let wrapped = RuntimeOptionalValue.wrappedType(in: typeName) {
            typeName = wrapped
        }
        if let generic = typeName.firstIndex(of: "<") {
            typeName = String(typeName[..<generic])
        }

        func structDeclaresMember(_ symbol: StructSymbol) -> Bool {
            var current: StructSymbol? = symbol
            while let candidate = current {
                if candidate.methods[memberName] != nil
                    || candidate.computedProperties[memberName] != nil
                    || candidate.storedProperty(named: memberName) != nil {
                    return true
                }
                for conformance in transitiveConformances(of: candidate) {
                    if hostExtensionSymbols[conformance]?.methods[memberName] != nil
                        || hostExtensionSymbols[conformance]?
                            .computedProperties[memberName] != nil {
                        return true
                    }
                }
                current = interpretedSuperclass(of: candidate)
            }
            return false
        }

        let lexicalOwner = lexicalOwner(of: function.id) as? StructSymbol
        switch typeValue(named: typeName, within: lexicalOwner) {
        case .type(let symbol):
            return structDeclaresMember(symbol)
        case .enumType(let symbol):
            if symbol.methods[memberName] != nil
                || symbol.computedProperties[memberName] != nil {
                return true
            }
            return symbol.conformances.contains { conformance in
                hostExtensionSymbols[conformance]?.methods[memberName] != nil
                    || hostExtensionSymbols[conformance]?
                        .computedProperties[memberName] != nil
            }
        default:
            return hostExtensionSymbols[typeName]?.methods[memberName] != nil
                || hostExtensionSymbols[typeName]?
                    .computedProperties[memberName] != nil
        }
    }

    /// The candidates whose declared call shape fits, narrowed by positive
    /// runtime argument types when those types are conclusive.
    func functionsFittingCall(
        from candidates: [FunctionDeclSyntax],
        args: CallArguments
    ) -> [FunctionDeclSyntax] {
        let arguments = ArgumentShape(args)
        let shaped = candidates.filter {
            functionMetadata(for: $0).shape.matches(arguments)
        }
        // Native overload ranking prefers a value that already has the
        // parameter's runtime type over a candidate reachable only through a
        // conversion. In particular, `[Element]` must select an array
        // overload even when an earlier `Set<Element>` overload could be
        // constructed from the same collection.
        let exact = shaped.filter {
            let metadata = functionMetadata(for: $0)
            return runtimeArgumentsFitDeclaredTypes(
                metadata.parameters,
                args: args,
                genericParameterNames: Set(metadata.genericParameters),
                genericConformanceRequirements:
                    metadata.genericConformanceRequirements,
                allowValueCoercion: false)
        }
        if !exact.isEmpty { return exact }
        let typed = shaped.filter {
            let metadata = functionMetadata(for: $0)
            return runtimeArgumentsFitDeclaredTypes(
                metadata.parameters,
                args: args,
                genericParameterNames: Set(metadata.genericParameters),
                genericConformanceRequirements:
                    metadata.genericConformanceRequirements)
        }
        return typed.isEmpty ? shaped : typed
    }

    /// Operator calls bind operands positionally even though their declaration
    /// parameters are conventionally named `lhs` and `rhs`. They also have no
    /// dynamically callable fallback: a concrete type mismatch rejects the
    /// overload instead of selecting an arbitrary declaration of equal arity.
    func operatorFunctionsFittingRuntimeTypes(
        from candidates: [FunctionDeclSyntax],
        args: CallArguments
    ) -> [FunctionDeclSyntax] {
        return candidates.filter { declaration in
            let metadata = functionMetadata(for: declaration)
            guard metadata.parameters.count == args.arguments.count else {
                return false
            }
            let positional = CallArguments(arguments: zip(
                metadata.parameters, args.arguments
            ).map { parameter, argument in
                .init(label: parameter.label, value: argument.value)
            })
            return runtimeArgumentsFitDeclaredTypes(
                metadata.parameters,
                args: positional,
                genericParameterNames: Set(metadata.genericParameters),
                genericConformanceRequirements:
                    metadata.genericConformanceRequirements)
        }
    }

    /// Overloaded methods pick by call shape, then positive runtime argument
    /// types, and, when the call is the base of a member access, by that
    /// result-member constraint. If every typed check is inconclusive, retain
    /// the historical shape-only fallback for opaque imported values.
    func chooseFunction(
        from candidates: [FunctionDeclSyntax],
        for args: CallArguments,
        contextualResultMember: String? = nil
    ) -> FunctionDeclSyntax? {
        let viable = functionsFittingCall(from: candidates, args: args)
        if let contextualResultMember,
           let constrained = viable.first(where: {
               functionResultDeclaresMember(
                   $0, named: contextualResultMember)
           }) {
            return constrained
        }
        return viable.first
    }

    /// Shape first, then positive runtime parameter types. Source modules can
    /// contribute overloads with identical labels (`parse(String)`,
    /// `parse(Data)`, `parse(URL)`); selecting an arbitrary same-shaped body
    /// loses native overload semantics. The shaped fallback preserves the
    /// interpreter's compatibility behavior for genuinely opaque values.
    func chooseFunctionByRuntimeTypes(
        from candidates: [FunctionDeclSyntax],
        for args: CallArguments,
        contextualResultMember: String? = nil
    ) -> FunctionDeclSyntax? {
        chooseFunction(
            from: candidates,
            for: args,
            contextualResultMember: contextualResultMember)
    }

    /// A structural override signature. Subclasses replace only the inherited
    /// declaration with the same labels, parameter types, generic arity, and
    /// effects; differently shaped siblings remain in the overload family.
    private func methodOverrideSignature(
        _ declaration: FunctionDeclSyntax
    ) -> String {
        let metadata = functionMetadata(for: declaration)
        let parameters = metadata.parameters.map { parameter in
            let type = (parameter.typeName ?? "_").filter { !$0.isWhitespace }
            return "\(parameter.label ?? "_"):\(type)"
                + (parameter.isVariadic ? "..." : "")
                + (parameter.isIsolated ? ":isolated" : "")
        }.joined(separator: ",")
        return "\(metadata.genericParameters.count)|\(parameters)"
            + "|async:\(metadata.isAsync)|throws:\(metadata.isThrowing)"
    }

    /// Merge an inherited overload family from child to base. All declarations
    /// at one level survive (including return-type overloads); a child level
    /// shadows only matching structural override signatures in its ancestors.
    private func inheritedMethodOverloads(
        named name: String,
        on symbol: StructSymbol,
        table: KeyPath<StructSymbol, [String: [FunctionDeclSyntax]]>
    ) -> [FunctionDeclSyntax]? {
        var result: [FunctionDeclSyntax] = []
        var shadowed = Set<String>()
        var candidate: StructSymbol? = symbol
        var walked = Set<ObjectIdentifier>()
        while let owner = candidate,
              walked.insert(ObjectIdentifier(owner)).inserted {
            let level = owner[keyPath: table][name] ?? []
            result.append(contentsOf: level.filter {
                !shadowed.contains(methodOverrideSignature($0))
            })
            shadowed.formUnion(level.map(methodOverrideSignature))
            candidate = interpretedSuperclass(of: owner)
        }
        return result.isEmpty ? nil : result
    }

    /// Instance lookup retains inherited overload siblings while honoring
    /// structural overrides from the most-derived declaration level.
    func instanceMethodOverloads(
        named name: String, on instance: Instance
    ) -> [FunctionDeclSyntax]? {
        inheritedMethodOverloads(
            named: name, on: instance.symbol, table: \.methods)
    }

    /// Static lookup follows the same overload/override rule as instances.
    func staticMethodOverloads(
        named name: String, on symbol: StructSymbol
    ) -> [FunctionDeclSyntax]? {
        inheritedMethodOverloads(
            named: name, on: symbol, table: \.staticMethods)
    }

    /// Excludes running declarations only among overloads that compete for
    /// this call shape. A unique shaped declaration is ordinary recursion,
    /// even when differently-shaped siblings share its base name. Multiple
    /// shaped declarations still route around active bodies so return-type or
    /// same-shape delegation cannot cycle forever.
    func functionsAvailableForCall(
        from candidates: [FunctionDeclSyntax],
        args: CallArguments
    ) -> [FunctionDeclSyntax] {
        let fitting = functionsFittingCall(from: candidates, args: args)
        let pool = fitting.isEmpty ? candidates : fitting
        guard pool.count > 1 else { return pool }
        return pool.filter { !activeFunctionBodies.contains($0.id) }
    }

    /// `init(from decoder:)` / `init(coder:)` — only decoders reach these.
    func isCodableInitializer(_ initializer: InitializerDeclSyntax) -> Bool {
        initializerMetadata(for: initializer).isCodable
    }

    func chooseInitializer(from initializers: [InitializerDeclSyntax], for args: CallArguments) -> InitializerDeclSyntax {
        chooseInitializerStrict(from: initializers, for: args)
            ?? initializers.first { !isCodableInitializer($0) }
            ?? initializers[0]
    }

    /// Shape-matching only — nil when NO candidate fits (callers decide
    /// whether to fall back or treat the call as an inherited init).
    func chooseInitializerStrict(from initializers: [InitializerDeclSyntax], for args: CallArguments) -> InitializerDeclSyntax? {
        let arguments = ArgumentShape(args)
        var fits: [InitializerDeclSyntax] = []
        for candidate in initializers {
            // Shape match: every arg label exists, every required label is
            // provided (trailing closures may fill one), and positional args
            // have `_` slots — `Pubkey(data)` must NOT pick init?(hex:).
            // Only UNLABELED trailing closures can fill missing required
            // labels (labeled trailings already matched by name) — the
            // binder gives them to the LAST unbound slot, so selection
            // must not over-promise (IceSection's 5-param designated init
            // vs its 4-param delegation).
            if initializerMetadata(for: candidate).shape.matches(arguments) {
                fits.append(candidate)
            }
        }
        guard fits.count > 1 else { return fits.first }
        // Same-labeled overloads (`init(_ source:)` vs `init(_ sources:
        // [X])`; closure-taking convenience inits delegating to
        // value-taking designated ones): the argument's ARRAY-ness and
        // CLOSURE-ness pick the matching annotations — real overload
        // resolution's type dimension, coarsely.
        func typeScore(_ candidate: InitializerDeclSyntax) -> Int {
            var score = 0
            var positionalIndex = 0
            for parameter in initializerMetadata(for: candidate).parameters {
                let value: RuntimeValue?
                if let label = parameter.label {
                    value = args.labeled(label)
                } else {
                    value = args.positional(positionalIndex)
                    positionalIndex += 1
                }
                guard let value else { continue }
                let annotation = parameter.typeName ?? ""
                let wantsArray = annotation.hasPrefix("[") && !annotation.contains(":")
                let wantsClosure = annotation.contains("->")
                let isArray = value.arrayValue != nil
                let isClosure = value.closureValue != nil
                score += (wantsArray == isArray) ? 1 : -1
                score += (wantsClosure == isClosure) ? 1 : -1
                // NOMINAL dimension: `init(appState: Store<AppState>)` must
                // lose to `init(appState: AppState)` when the argument IS an
                // AppState (typealias heads canonicalize: Store →
                // CurrentValueSubject). Weighted above shape hints.
                var head = annotation.trimmingCharacters(in: .whitespaces)
                if head.hasSuffix("?") || head.hasSuffix("!") { head = String(head.dropLast()) }
                if let angle = head.firstIndex(of: "<") { head = String(head[..<angle]) }
                head = aliasHeads[head] ?? head
                var dynamicNames: [String] = []
                if case .instance(let instance) = value {
                    dynamicNames = [instance.symbol.name] + instance.symbol.conformances
                } else if case .enumCase(let caseValue) = value {
                    dynamicNames = [caseValue.symbol.name] + caseValue.symbol.conformances
                } else if case .host(let any) = value,
                          let hostName = registry?.hostTypeName(of: any) {
                    dynamicNames = [hostName]
                }
                if !head.isEmpty, head.first?.isUppercase == true, !dynamicNames.isEmpty {
                    score += dynamicNames.contains(head) ? 2 : -2
                }
            }
            return score
        }
        var best = fits[0]
        var bestScore = typeScore(best)
        for candidate in fits.dropFirst() {
            let score = typeScore(candidate)
            if score > bestScore { best = candidate; bestScore = score }
        }
        return best
    }

    /// Evaluate an instance's `body` computed property in ViewBuilder mode.
    /// Multiple top-level views are grouped by the registry (TupleView stand-in).
    public func evaluateBody(of instance: Instance) throws -> RuntimeValue {
        steps = 0
        guard let computed = bodyProperty(of: instance.symbol) else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no body property")
        }
        var pushedLexicalOwner = false
        if let id = computed.declarationID,
           let owner = lexicalOwner(of: id) {
            lexicalOwnerFrames.append(owner)
            pushedLexicalOwner = true
        }
        defer { if pushedLexicalOwner { lexicalOwnerFrames.removeLast() } }
        let views = try collectBuilderViews(
            computed.accessor, in: selfEnvironment(.instance(instance)))
        return try groupViews(views)
    }

    /// Call an instance method with positional arguments — the bridge's entry
    /// point for protocol requirements it hosts (a Shape's `path(in:)`).
    public func callMethod(named name: String, on instance: Instance, arguments: [RuntimeValue]) throws -> RuntimeValue {
        guard let member = try instanceMember(name, on: instance),
              let closure = member.closureValue else {
            throw RuntimeError(message: "'\(instance.symbol.name)' has no method '\(name)'")
        }
        return try callClosure(closure, arguments: arguments)
    }

    /// Run the declared `deinit` bodies for an instance being discarded —
    /// own class first, then up the superclass chain, in native order. Host
    /// ARC calls this when the final strong edge to a source-class instance
    /// disappears; explicit lifecycle cleanup may call it sooner. The guard
    /// makes both paths idempotent. `deinit` is non-throwing in Swift, so
    /// interpreter errors in a body are swallowed like native cleanup that
    /// cannot propagate.
    public func runDeinitializer(on instance: Instance) {
        guard instance.symbol.isClass, !instance.didRunDeinitializer else { return }
        // Mark before executing user code: a deinitializer cannot re-enter
        // itself through a release caused by its own cleanup.
        instance.didRunDeinitializer = true
        var cursor: StructSymbol? = instance.symbol
        var hops = 0
        while let symbol = cursor, hops < 16 {
            if let body = symbol.deinitBody {
                let closure = ClosureValue(
                    parameters: [], body: body.statements,
                    captured: selfEnvironment(.instance(instance)),
                    programMetadata: currentProgramMetadata,
                    programPlan: currentProgramPlan)
                closure.programState = currentProgramState
                closure.lexicalOwner = symbol
                closure.lexicalExecutor = symbol.deinitializerExecutor
                closure.executorPreference = symbol.deinitializerExecutor
                _ = try? callClosure(closure, arguments: [])
            }
            cursor = interpretedSuperclass(of: symbol)
            hops += 1
        }
    }

    /// Fill `@EnvironmentObject` properties from ambient models (keyed by type
    /// name). The SwiftUI bridge reads the models off the real Environment;
    /// headless harnesses thread them down the trace tree. When no ambient
    /// model exists (the App shell that would inject it never runs), a fresh
    /// instance of the type is synthesized once and reused — the same
    /// fresh-store doctrine as @Query.
    public func injectEnvironmentObjects(into instance: Instance, models: [String: Instance]) throws {
        for property in instance.symbol.storedProperties {
            // Observation's TYPED environment (`@Environment(MastodonClient
            // .self) var client`) resolves from the same ambient-models
            // dict — `.environment(model)` injections key by symbol name.
            // Keypath keys (`\.dismiss`) are lowercase and stay with
            // injectEnvironmentValues.
            var typeName: String
            var typedEnvironment = false
            switch property.wrapper {
            case .environmentObject:
                typeName = property.typeAnnotation?.trimmedDescription ?? ""
            case .environment(let name) where name.first?.isUppercase == true:
                typeName = name
                typedEnvironment = true
            default:
                continue
            }
            if let generic = typeName.firstIndex(of: "<") {
                typeName = String(typeName[..<generic]) // generics drop everywhere
            }
            // Typed-environment properties fill ONLY from what the app
            // actually injected (or an earlier synthesis) — a missing
            // injection stays an absorbed read (on device it would crash;
            // headlessly the fresh canvas absorbs), never a fresh instance
            // with side-effecting init.
            if typedEnvironment, models[typeName] == nil,
               synthesizedEnvironmentModels[typeName] == nil {
                continue
            }
            let model: Instance
            if let ambient = models[typeName] {
                model = ambient
            } else if let synthesized = synthesizedEnvironmentModels[typeName] {
                model = synthesized
            } else if case .type(let symbol)? = globals.lookup(typeName),
                      case .instance(let fresh) = try instantiateRoot(symbol) {
                // Fresh model with FRESH parameter values — the same
                // synthesis roots get (inits with required params work).
                synthesizedEnvironmentModels[typeName] = fresh
                model = fresh
            } else if assumesCompiledImports {
                // UNMERGED model types (an external package's Updater): the
                // device's App shell injected something real — an absorbing
                // bag stands in (reads chain, writes accepted).
                instance.box(for: property.name)?.value = registry?.absorbedCValue(named: typeName)
                    ?? .native(ChainedImplicitCall(
                        base: .implicitMember(typeName), member: "shared", arguments: CallArguments()))
                continue
            } else {
                throw RuntimeError(message: "no ObservableObject of type '\(typeName)' in the environment — inject it with .environmentObject(_:)")
            }
            instance.box(for: property.name)?.value = RuntimeValue.instance(model)
                .copiedForValueSemantics()
        }
    }

    /// Fill `@Environment(\.key)` properties from a key→value table (the
    /// bridge reads real values off SwiftUI's Environment; headless harnesses
    /// inject honest defaults). Unknown keys are left untouched.
    public func injectEnvironmentValues(into instance: Instance, values: [String: RuntimeValue]) {
        for property in instance.symbol.storedProperties {
            guard case .environment(let key) = property.wrapper else { continue }
            if let value = values[key] {
                instance.box(for: property.name)?.value = value.copiedForValueSemantics()
                continue
            }
            // CUSTOM environment keys (extension EnvironmentValues { @Entry
            // var indentationLevel: UInt = 0 }): read the extension's OWN
            // declared default when present; otherwise the fresh identity
            // of the annotation (false/0/""/nil) — the fresh-canvas reading.
            if let box = instance.box(for: property.name), case .void = box.value {
                if let envExtension = hostExtensionSymbols["EnvironmentValues"],
                   let declared = envExtension.storedProperty(named: key),
                   let initializer = declared.initializer,
                   let value = try? evaluate(initializer, in: globals) {
                    box.value = ((try? resolveAnnotated(
                        value, annotation: declared.typeAnnotation)) ?? value)
                        .copiedForValueSemantics()
                    continue
                }
                // Pre-@Entry custom keys: `var currentDate: Date {
                // self[CurrentDateKey.self] }` — the getter runs against a
                // stub whose subscript answers the key's static
                // defaultValue.
                if let envExtension = hostExtensionSymbols["EnvironmentValues"],
                   let computed = envExtension.computedProperties[key],
                   let value = try? evaluateComputed(
                       computed, selfValue: .native(EnvironmentValuesStub()), name: key),
                   !value.isNil {
                    box.value = value.copiedForValueSemantics()
                    continue
                }
                let typeName = property.typeAnnotation?.trimmedDescription ?? ""
                var seen: Set<String> = []
                box.value = ((try? synthesizedFreshValue(
                    typeName: typeName, seen: &seen)) ?? .nilValue)
                    .copiedForValueSemantics()
            }
        }
    }

    /// The struct to render when the program doesn't end in an explicit view
    /// expression: `ContentView` if present, then `Main`, then the first
    /// View-conforming struct in declaration order.
    /// Instantiate a root view for standalone verification: required
    /// parameters (un-defaulted stored properties, or a custom init's
    /// parameters) receive synthesized FRESH values — the fresh-state
    /// doctrine applied to view parameters.
    public func instantiateRoot(_ symbol: StructSymbol) throws -> RuntimeValue {
        // This is an external evaluation entry point, just like callClosure
        // and evaluateBody. A large merged library can legitimately consume
        // most of run(source:)'s budget while initializing unrelated globals;
        // root construction must receive its own bounded budget.
        steps = 0
        var seen: Set<String> = [symbol.name]
        let args = try synthesizedArguments(for: symbol, seen: &seen)
        let root = try instantiate(symbol, with: args)
        if case .instance(let instance) = root {
            // Native callers own the arguments they pass for at least their
            // lexical lifetime. A headless synthetic root has no source-level
            // caller, so preserve that ownership on the root itself; this
            // keeps valid unowned dependencies alive without changing normal
            // weak/unowned storage semantics.
            instance.synthesizedRootOwners = args.arguments.map(\.value)
        }
        return root
    }

    /// A property typed by one of the OWNER's generic parameters: fresh
    /// empty view for View-constrained params (registry-backed), otherwise
    /// an unknowable chain — never a same-named concrete type.
    private func synthesizedGenericValue(constraint: String, parameter: String) -> RuntimeValue {
        if constraint.contains("View"), let ctor = registry?.constructor(named: "EmptyView"),
           let view = try? ctor.invoke(CallArguments(arguments: []), self) {
            return view
        }
        return .native(ChainedImplicitCall(
            base: .implicitMember("generic"), member: parameter, arguments: CallArguments()))
    }

    private func rootArgumentOwner(
        _ value: RuntimeValue, typeName: String,
        ownership: ReferenceOwnership
    ) -> RuntimeValue {
        guard ownership != .strong,
              case .host(let payload) = value,
              payload is ChainedImplicitCall || payload is ImplicitMemberCall
                || payload is HostTypeMarker else {
            return value
        }
        return .native(SynthesizedExternalObject(typeName: typeName))
    }

    private func synthesizedArguments(for symbol: StructSymbol, seen: inout Set<String>) throws -> CallArguments {
        var arguments: [CallArguments.Argument] = []
        // Prefer a NON-failable, NON-Codable init: synthesized fresh
        // arguments rarely satisfy `init?` guards, and `init(from:
        // decoder)` is only ever reached through real decoders.
        let preferred = symbol.initializers.first {
            let metadata = initializerMetadata(for: $0)
            return !metadata.isFailable && !metadata.isCodable
        } ?? symbol.initializers.first {
            !initializerMetadata(for: $0).isCodable
        }
            ?? symbol.initializers.first
        if let initializer = preferred {
            for parameter in initializerMetadata(for: initializer).parameters
            where parameter.defaultValue == nil {
                let label = parameter.label ?? "_"
                let typeName = parameter.typeAnnotation?.trimmedDescription
                    ?? "Any"
                let value: RuntimeValue
                if let constraint = symbol.genericParameters[typeName] {
                    value = synthesizedGenericValue(constraint: constraint, parameter: typeName)
                } else {
                    value = try synthesizedFreshValue(typeName: typeName, owner: symbol, seen: &seen)
                }
                let ownership = symbol.storedProperty(named: label)?.referenceOwnership
                    ?? .strong
                arguments.append(.init(
                    label: label == "_" ? nil : label,
                    value: rootArgumentOwner(
                        value, typeName: typeName, ownership: ownership)))
            }
        } else {
            for property in symbol.storedProperties
            where property.initializer == nil && !property.isBuilderClosure {
                let typeName = property.typeAnnotation?.trimmedDescription ?? ""
                switch property.wrapper {
                case .none:
                    if let constraint = symbol.genericParameters[typeName] {
                        arguments.append(.init(
                            label: property.name,
                            value: rootArgumentOwner(
                                synthesizedGenericValue(
                                    constraint: constraint, parameter: typeName),
                                typeName: typeName,
                                ownership: property.referenceOwnership)))
                        continue
                    }
                    arguments.append(.init(
                        label: property.name,
                        value: rootArgumentOwner(
                            try synthesizedFreshValue(
                                typeName: typeName, owner: symbol, seen: &seen),
                            typeName: typeName,
                            ownership: property.referenceOwnership)))
                case .binding:
                    // A standalone root has no parent to pass bindings —
                    // synthesize one over the inner type's fresh value.
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: "Binding<\(typeName)>", seen: &seen)))
                case .observedObject, .stateObject:
                    // Fresh model per the missing-environment-object doctrine
                    // (initializer-less wrappers only — the where clause).
                    arguments.append(.init(
                        label: property.name,
                        value: try synthesizedFreshValue(typeName: typeName, owner: symbol, seen: &seen)))
                default:
                    break // @State/@StateObject etc. default independently
                }
            }
        }
        return CallArguments(arguments: arguments)
    }

    /// Owner-scoped fresh value: the OWNER's nested types win over
    /// same-named globals (each view's `enum Location` is its own).
    func synthesizedFreshValue(
        typeName rawName: String, owner: StructSymbol, seen: inout Set<String>
    ) throws -> RuntimeValue {
        let typeName = rawName.trimmingCharacters(in: .whitespaces)
        if !typeName.hasSuffix("?"), !typeName.hasSuffix("!") {
            if let enumSymbol = enumSymbols["\(owner.name).\(typeName)"],
               let first = enumSymbol.cases.first(where: { !$0.hasAssociatedValues }) {
                return .enumCase(EnumCaseValue(symbol: enumSymbol, name: first.name))
            }
            if case .type(let nested)? = owner.nestedTypes[typeName], !seen.contains(nested.name) {
                seen.insert(nested.name)
                defer { seen.remove(nested.name) }
                if let args = try? synthesizedArguments(for: nested, seen: &seen),
                   let built = try? instantiate(nested, with: args), !built.isNil {
                    return built
                }
            }
        }
        return try synthesizedFreshValue(typeName: rawName, seen: &seen)
    }

    /// The fresh value of a type: identity for primitives, empty for
    /// collections, nil for optionals, recursive fresh instances for
    /// interpreted types, and an unknowable chain (absorbs everywhere)
    /// for host/generic types.
    func synthesizedFreshValue(typeName rawName: String, seen: inout Set<String>) throws -> RuntimeValue {
        var typeName = rawName.trimmingCharacters(in: .whitespaces)
        if RuntimeOptionalValue.wrappedType(in: typeName) != nil {
            return .none(forTypeAnnotation: typeName)
        }
        if typeName.hasPrefix("[") { // arrays AND dictionaries start empty
            return typeName.contains(":") ? .native(DictValue()) : .native([RuntimeValue]())
        }
        if typeName == "Set" || typeName.hasPrefix("Set<") {
            return .native(RuntimeSetValue())
        }
        if typeName.contains("->") {
            return .hostFunction(HostFunction(name: "synthesized") { _, _ in .void })
        }
        if typeName.hasPrefix("Binding<"), typeName.hasSuffix(">") {
            let inner = String(typeName.dropFirst("Binding<".count).dropLast())
            let value = try synthesizedFreshValue(typeName: inner, seen: &seen)
            return .native(BindingStub(box: Box(value)))
        }
        switch typeName {
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8",
             "UInt16", "UInt32", "UInt64": return .native(0)
        case "String", "Character": return .native("")
        case "Bool": return .native(false)
        case "Date": return .native(Date())
        case "Data": return .native(Data())
        default: break
        }
        if Self.doubleFamilyTypeNames.contains(typeName) { return .native(0.0) }
        if let generic = typeName.firstIndex(of: "<") {
            typeName = String(typeName[..<generic]) // Store<A, B> → Store
        }
        if !seen.contains(typeName) {
            seen.insert(typeName)
            defer { seen.remove(typeName) }
            if case .type(let nested)? = globals.lookup(typeName) {
                // A throwing/guarded init that rejects fresh inputs means
                // the value is unobtainable headlessly — fall through to
                // the unknowable chain instead of failing the whole unit.
                if let args = try? synthesizedArguments(for: nested, seen: &seen),
                   let built = try? instantiate(nested, with: args),
                   !built.isNil {
                    return built
                }
            }
            if let enumSymbol = enumSymbols[typeName],
               let first = enumSymbol.cases.first(where: { !$0.hasAssociatedValues }) {
                return .enumCase(EnumCaseValue(symbol: enumSymbol, name: first.name))
            }
        }
        // Host/generic/cyclic types: an unknowable chain — reads chain,
        // bools read false, numerics zero, iteration empty.
        return .native(ChainedImplicitCall(
            base: .implicitMember("synthesized"), member: typeName, arguments: CallArguments()))
    }

    public func rootViewSymbol() -> StructSymbol? {
        let candidates = structSymbols.filter(\.conformsToView)
        // The app's OWN declared root wins: the first View constructed in an
        // @main App body, or the one a delegate hosts via
        // UIHostingController(rootView:)/NSHostingController — name-based
        // heuristics are the fallback, not the first resort.
        if let declared = declaredRootViewName(),
           let symbol = candidates.first(where: { $0.name == declared }) {
            return symbol
        }
        return candidates.first { $0.name == "ContentView" }
            ?? candidates.first { $0.name == "Main" }
            ?? candidates.first
    }

    static let doubleFamilyTypeNames: Set<String> = [
        "Double", "CGFloat", "Float", "TimeInterval", "Float32", "Float64",
    ]

    /// Fixed-width integer declarations share RuntimeValue's exact-in-range
    /// `Int` carrier. Keep their nominal spellings available to overload
    /// fitting even though the storage representation is intentionally
    /// unified.
    static let integerFamilyTypeNames: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "NSInteger", "NSUInteger",
    ]

    static func rangeAnnotation(_ rawName: String) -> (name: String, bound: String)? {
        let text = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "<"), text.hasSuffix(">") else { return nil }
        let qualifiedHead = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let name = qualifiedHead.split(separator: ".").last.map(String.init) ?? qualifiedHead
        guard ["Range", "ClosedRange", "PartialRangeFrom", "PartialRangeUpTo", "PartialRangeThrough"]
            .contains(name) else { return nil }
        let bound = text[text.index(after: open)..<text.index(before: text.endIndex)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bound.isEmpty else { return nil }
        return (name, bound)
    }

    func selfEnvironment(_ selfValue: RuntimeValue) -> Environment {
        let env = Environment(parent: globals)
        env.defineBorrowing("self", selfValue)
        return env
    }

    /// A bound source-struct method owns a snapshot of its receiver rather
    /// than the caller's storage node. That also makes closures returned by
    /// the method capture the invocation's value, as native Swift does.
    /// Class method values retain their receiver identity.
    func boundMethodSelfValue(_ selfValue: RuntimeValue) -> RuntimeValue {
        selfValue.copiedForValueSemantics()
    }

    func instanceMethodEnvironment(_ instance: Instance) -> Environment {
        selfEnvironment(boundMethodSelfValue(.instance(instance)))
    }

    func methodIsMutating(_ declaration: FunctionDeclSyntax) -> Bool {
        functionMetadata(for: declaration).modifierNames.contains("mutating")
    }

    /// A type annotation turns a bare `.member` (or `.member(payload)`) into
    /// the annotated type's case, `.init`, or static member — the dynamic
    /// stand-in for type context. `[Type]` annotations resolve array elements.
    func resolveAnnotated(_ value: RuntimeValue, annotation: TypeSyntax?) throws -> RuntimeValue {
        guard let annotation else { return value }
        return try resolveAnnotated(value, typeName: annotation.trimmedDescription)
    }

    func resolveAnnotated(
        _ value: RuntimeValue, parameter: ClosureValue.Parameter
    ) throws -> RuntimeValue {
        guard let typeName = parameter.typeName else { return value }
        // A closure literal bound to a FUNCTION-TYPED parameter inherits
        // the annotation's return type, so its `return .none` implicit
        // members resolve on exit (`Reducer { … in return .none }` — the
        // init parameter says `-> Effect<Action, Never>`).
        if case .closure(let closure) = value, closure.returnTypeName == nil,
           let arrow = Self.lastTopLevelArrow(in: typeName) {
            let returnPart = String(typeName[typeName.index(arrow, offsetBy: 2)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !returnPart.isEmpty {
                closure.returnTypeName = returnPart.hasSuffix(")") && returnPart.hasPrefix("(")
                    ? String(returnPart.dropFirst().dropLast())
                    : returnPart
            }
            return value
        }
        return try resolveAnnotated(value, typeName: typeName)
    }

    /// Index of the LAST `->` at paren/angle depth zero, if any.
    static func lastTopLevelArrow(in text: String) -> String.Index? {
        var depth = 0
        var found: String.Index? = nil
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "(" || ch == "<" || ch == "[" { depth += 1 }
            if ch == ")" || ch == ">" || ch == "]" { depth -= 1 }
            if ch == "-", depth == 0 {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == ">" {
                    found = index
                }
            }
            index = text.index(after: index)
        }
        return found
    }

    /// Overload fallback for a marker call against a host-type EXTENSION:
    /// when no declared overload matches the call shape and the HOST can
    /// serve the member, defer to the host — native overload resolution
    /// reaches past the module extension (`Double.random(in:using:)` with
    /// a 1-arg program shadow picks the stdlib). Only a host miss keeps
    /// the historical force-first behavior for label-lenient user code.
    private func extensionFallback(
        _ overloads: [FunctionDeclSyntax], member: String, typeName: String
    ) -> FunctionDeclSyntax? {
        let hostServes = ((try? readHostMember(
            member, on: HostTypeMarker(name: typeName))) ?? nil) != nil
        return hostServes ? nil : overloads.first
    }

    func resolveAnnotated(_ value: RuntimeValue, typeName rawName: String) throws -> RuntimeValue {
        // Cyclic marker graphs (lazy-global cycles can weave a chain whose
        // base reaches itself) must not recurse the native stack to death:
        // past any plausible nesting the value stays an absorbing marker.
        resolveAnnotatedDepth += 1
        defer { resolveAnnotatedDepth -= 1 }
        guard resolveAnnotatedDepth < 64 else { return value }
        var typeName = rawName.trimmingCharacters(in: .whitespaces)
        if let wrappedTypeName = RuntimeOptionalValue.wrappedType(in: typeName) {
            return try resolveOptionalAnnotation(
                value, wrappedTypeName: wrappedTypeName,
                isImplicitlyUnwrapped: typeName.hasSuffix("!"))
        }

        if let range = value.rangeValue, let annotation = Self.rangeAnnotation(typeName) {
            guard range.matchesNominalShape(annotation.name) else {
                throw RuntimeError(message: "\(range.description) is not a \(annotation.name)")
            }
            do {
                return .native(try range.coercingBounds(to: annotation.bound))
            } catch let message as EvalMessage {
                throw RuntimeError(message: message.text)
            }
        }

        // `(hrp: String, data: Data)` annotations LABEL positional tuple
        // literals so `decoded.hrp` member reads work.
        if typeName.hasPrefix("("), typeName.hasSuffix(")"), typeName.contains(":"),
           let tuple = value.tupleValue, tuple.labels.allSatisfy({ $0 == nil }) {
            let inner = String(typeName.dropFirst().dropLast())
            var depth = 0
            var parts: [String] = []
            var current = ""
            for ch in inner {
                if ch == "(" || ch == "<" || ch == "[" { depth += 1 }
                if ch == ")" || ch == ">" || ch == "]" { depth -= 1 }
                if ch == ",", depth == 0 {
                    parts.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            parts.append(current)
            if parts.count == tuple.values.count {
                let labels = parts.map { part -> String? in
                    guard let colon = part.firstIndex(of: ":") else { return nil }
                    let label = part[..<colon].trimmingCharacters(in: .whitespaces)
                    return label.isEmpty || label.contains(" ") ? nil : label
                }
                if labels.contains(where: { $0 != nil }) {
                    return .native(TupleValue(labels: labels, values: tuple.values))
                }
            }
        }

        // Double-family storage holds doubles: `var offset: CGFloat = 0`
        // stores 0.0, so division/interpolation behave like compiled Swift
        // (20 / offset is IEEE infinity, not an Int-division trap).
        if Self.doubleFamilyTypeNames.contains(typeName), let i = value.intValue {
            return .native(Double(i))
        }

        // `[Item]` — contextual `.init(repeating:count:)` constructs the
        // annotated collection before element coercion. This path is shared
        // by every inferred Array type; it must not degrade to the empty
        // collection used for an unresolved marker.
        if typeName.hasPrefix("["), typeName.hasSuffix("]"), !typeName.contains(":"),
           case .host(let payload) = value,
           let call = payload as? ImplicitMemberCall,
           call.name == "init" {
            let elementType = String(typeName.dropFirst().dropLast())
            if call.arguments.isEmpty {
                return .native([RuntimeValue]())
            }
            if let repeated = call.arguments.labeled("repeating"),
               let count = call.arguments.labeled("count")?.intValue {
                let element = try resolveAnnotated(repeated, typeName: elementType)
                return .native((0..<max(0, count)).map { _ in
                    element.copiedForValueSemantics()
                })
            }
        }

        // `[Item]` — resolve each element against the element type.
        if typeName.hasPrefix("["), typeName.hasSuffix("]"), !typeName.contains(":"),
           let array = value.arrayValue {
            let elementType = String(typeName.dropFirst().dropLast())
            return .native(try array.map { try resolveAnnotated($0, typeName: elementType) })
        }

        // `[Key: Value]` — annotations apply to both stored key and value;
        // in particular `[String: Int?]` retains Optional wrappers for nil
        // and non-nil entries instead of flattening them inside DictValue.
        if typeName.hasPrefix("["), typeName.hasSuffix("]"),
           let dictionary = value.dictValue {
            let inner = String(typeName.dropFirst().dropLast())
            let parts = SwiftInterpreter.splitTopLevel(
                inner, separator: ":")
            if parts.count == 2 {
                return .native(DictValue(
                    keys: try dictionary.keys.map {
                        try resolveAnnotated($0, typeName: parts[0])
                    },
                    values: try dictionary.values.map {
                        try resolveAnnotated($0, typeName: parts[1])
                    }))
            }
        }

        // `Set<Item> = [literal, ...]` uses Set's array-literal conformance;
        // an existing Set re-resolves marker elements against the annotation.
        if typeName.hasPrefix("Set<"), typeName.hasSuffix(">") {
            let elementType = String(typeName.dropFirst("Set<".count).dropLast())
            let elements = value.setValue?.elements ?? value.arrayValue
            if let elements {
                let resolved = try elements.map {
                    try resolveAnnotated($0, typeName: elementType)
                }
                return .native(try makeRuntimeSet(
                    resolved, elementTypeName: elementType))
            }
        }

        // `Loadable<V>` — generic applications resolve by their HEAD
        // (generics drop everywhere): a generic enum method's return
        // annotation must still turn `.loaded(x)` markers into cases.
        if let angle = typeName.firstIndex(of: "<"), typeName.hasSuffix(">") {
            typeName = String(typeName[..<angle])
        }
        // Typealias annotations canonicalize to their target HEAD when no
        // declared type claims the name (`httpCodes: HTTPCodes = .success`
        // where `typealias HTTPCodes = Range<HTTPCode>` — the extension's
        // statics were collected under "Range", so the lookup must follow).
        let ownerHasNested: Bool = {
            guard let owner = lexicalOwnerFrames.last else { return false }
            return (owner as? StructSymbol)?.nestedTypes[typeName] != nil
                || (owner as? EnumSymbol)?.nestedTypes[typeName] != nil
        }()
        let globalDeclaredType: Bool = {
            switch globals.lookup(typeName) {
            case .type, .enumType: return true
            default: return false
            }
        }()
        if enumSymbols[typeName] == nil, !globalDeclaredType,
           !ownerHasNested, aliasHeads[typeName] != nil {
            var canonical = typeName
            var hops = 0
            while let target = aliasHeads[canonical], hops < 8 {
                canonical = target
                hops += 1
            }
            typeName = canonical
        }
        // Annotation names resolve in the LEXICAL scope of the declaration
        // they annotate: the running function's declaring type sees its own
        // nested types AND member typealiases first (WebRepositoryTests'
        // `typealias API = TestWebRepository.API` beats whichever same-named
        // nested enum claimed the bare global slot).
        var scopedEnum = enumSymbols[typeName]
        var scopedStruct: StructSymbol?
        if case .type(let symbol)? = globals.lookup(typeName) { scopedStruct = symbol }
        if typeName.contains("."),
           let qualified = lexicallyVisibleType(
               named: typeName, from: lexicalOwnerFrames.last) {
            switch qualified {
            case .enumType(let symbol):
                scopedEnum = symbol
                scopedStruct = nil
            case .type(let symbol):
                scopedStruct = symbol
                scopedEnum = nil
            default:
                break
            }
        }
        if let owner = lexicalOwnerFrames.last {
            let nested = (owner as? StructSymbol)?.nestedTypes[typeName]
                ?? (owner as? EnumSymbol)?.nestedTypes[typeName]
            if case .enumType(let symbol)? = nested {
                scopedEnum = symbol
                scopedStruct = nil
            } else if case .type(let symbol)? = nested {
                scopedStruct = symbol
                scopedEnum = nil
            }
        }
        if let symbol = scopedEnum {
            if case .implicitMember(let name) = value,
               let info = symbol.caseInfo(named: name), !info.hasAssociatedValues {
                return .enumCase(EnumCaseValue(symbol: symbol, name: name))
            }
            // `self = .init(rawValue: n)!` inside enum inits — the marker
            // resolves through the raw-value initializer in type context.
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               call.name == "init", call.arguments.arguments.count == 1,
               let raw = call.arguments.labeled("rawValue") {
                return symbol.cases
                    .first { (try? Builtins.areEqual($0.rawValue, raw)) == true }
                    .map { RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name)) }
                    ?? .nilValue
            }
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               let info = symbol.caseInfo(named: call.name), info.hasAssociatedValues {
                let associated = try zip(
                    call.arguments.arguments.map(\.value),
                    info.associatedTypeNames
                ).map { value, typeName in
                    try resolveAnnotated(value, typeName: typeName)
                }
                return .enumCase(EnumCaseValue(
                    symbol: symbol,
                    name: call.name,
                    associated: associated
                ))
            }
            return value
        }

        // User structs/classes: `= .init(...)`, static factories, static values.
        if let symbol = scopedStruct {
            if case .host(let any) = value, let call = any as? ImplicitMemberCall {
                if call.name == "init" {
                    return try instantiate(symbol, with: call.arguments)
                }
                if let overloads = symbol.staticMethods[call.name],
                   let method = chooseFunction(from: overloads, for: call.arguments) ?? overloads.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try callWithArguments(closure, args: call.arguments, node: nil)
                }
            }
            if case .implicitMember(let name) = value,
               let staticValue = try staticMember(name, of: symbol) {
                return staticValue
            }
            return value
        }

        // Program extensions SHADOW imported statics in annotation position
        // too — `: Date = .now` with an interpreted `extension Date {
        // static var now }` resolves to the PROGRAM's static, exactly like
        // a same-module declaration beats an import in compiled Swift.
        if let hostSymbol = hostExtensionSymbols[typeName] {
            if case .implicitMember(let memberName) = value,
               let staticValue = try staticMember(memberName, of: hostSymbol) {
                return staticValue
            }
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               let overloads = hostSymbol.staticMethods[call.name],
               let method = chooseFunction(from: overloads, for: call.arguments)
                   ?? extensionFallback(overloads, member: call.name, typeName: typeName),
               let body = functionMetadata(for: method).body {
                let closure = makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.type(hostSymbol)))
                return try callWithArguments(closure, args: call.arguments, node: nil)
            }
        }
        // Some imported generic nominals are represented by callable host
        // type markers in the global environment. A contextual static call
        // such as a Task-returning function whose body starts with .detached
        // must resolve and invoke that nominal's real static member while the
        // expected type is still available. Leaving it as an
        // ImplicitMemberCall silently loses the operation before return-value
        // annotation resolution completes.
        //
        // Source enum/struct statics and host-type extensions have already
        // received precedence above. This path is generic over callable
        // imported nominals; Task API identity remains selected by the
        // generated member gateway in accessMember.
        if case .host(let any) = value,
           let call = any as? ImplicitMemberCall,
           let annotatedType = globals.lookup(typeName),
           case .hostFunction = annotatedType {
            let anchor = DeclReferenceExprSyntax(
                baseName: .identifier(typeName))
            let member = try accessMember(
                call.name,
                on: annotatedType,
                node: anchor,
                env: globals)
            if case .implicitMember = member {
                // Unknown imported statics retain the ordinary typed-marker
                // fallback below.
            } else {
                return try invoke(
                    member,
                    with: call.arguments,
                    node: anchor)
            }
        }
        // Host-type annotations: `: Date = .init()`, `: CGSize = .init(…)`,
        // `.now`-style statics served by the bridge.
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            if call.name == "init" {
                if let ctor = registry?.hostObjectConstructor(named: typeName) {
                    return try ctor.invoke(call.arguments, self)
                }
                if case .hostFunction(let builtin)? = globals.lookup(typeName) {
                    return try builtin.invoke(call.arguments, self)
                }
            }
            if let member = try readHostMember(
                call.name, on: HostTypeMarker(name: typeName)) {
                if case .hostFunction(let function) = member {
                    return try function.invoke(call.arguments, self)
                }
                return member
            }
        }
        if case .implicitMember(let memberName) = value,
           let member = try readHostMember(
            memberName, on: HostTypeMarker(name: typeName)) {
            return member
        }
        // `.success(x)` against a host-typed annotation (`Result<T, Error>`):
        // the marker's static FUNCTION constructs the value (the bridge's
        // Result carrier; head-only names — generics dropped above).
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           case .hostFunction(let factory)? =
               try readHostMember(
                call.name, on: HostTypeMarker(name: typeName)) {
            return try factory.invoke(call.arguments, self)
        }
        // `.now.startOfMonth` — chained markers resolve their base against
        // the type, then the member (host natives and user extensions both).
        if case .host(let any) = value, let chained = any as? ChainedImplicitCall {
            let resolvedBase = try resolveAnnotated(chained.base, typeName: typeName)
            let stillMarker: Bool = {
                if case .implicitMember = resolvedBase { return true }
                if case .host(let inner) = resolvedBase,
                   inner is ImplicitMemberCall || inner is ChainedImplicitCall { return true }
                return false
            }()
            if !stillMarker {
                let anchor = ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier("resolvedChainBase")))
                let member = try accessMember(chained.member, on: resolvedBase, node: anchor, env: globals)
                switch member {
                case .closure(let closure):
                    return try callWithArguments(closure, args: chained.arguments, node: nil)
                case .hostFunction(let function):
                    return try function.invoke(chained.arguments, self)
                default:
                    return member
                }
            }
        }

        // User extensions of host types add statics too:
        // `extension Date { static var currentMonth: Date }` resolves
        // `: Date = .currentMonth` (and `.createDate(…)` factories).
        if let hostSymbol = hostExtensionSymbols[typeName] {
            if case .implicitMember(let memberName) = value,
               let staticValue = try staticMember(memberName, of: hostSymbol) {
                return staticValue
            }
            // A bare case of an EXTENDED host type (`authorizationStatus:
            // UNAuthorizationStatus` seeded with `.authorized`): keep it a
            // marker, but a TYPED one, so the extension's instance members
            // (`.map`) dispatch on later reads.
            if case .implicitMember(let memberName) = value {
                return .host(ImplicitMemberCall(
                    name: memberName, arguments: CallArguments(), typeHint: typeName))
            }
            if case .host(let any) = value, let call = any as? ImplicitMemberCall,
               let overloads = hostSymbol.staticMethods[call.name],
               let method = chooseFunction(from: overloads, for: call.arguments)
                   ?? extensionFallback(overloads, member: call.name, typeName: typeName),
               let body = functionMetadata(for: method).body {
                let closure = makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.type(hostSymbol)))
                return try callWithArguments(closure, args: call.arguments, node: nil)
            }
        }
        return value
    }

    /// Apply one source-level Optional conversion without flattening an
    /// Optional that already has the target shape. Re-entering
    /// `resolveAnnotated` for the wrapped type naturally builds and preserves
    /// every layer of `T??`.
    private func resolveOptionalAnnotation(
        _ value: RuntimeValue, wrappedTypeName: String,
        isImplicitlyUnwrapped: Bool
    ) throws -> RuntimeValue {
        if case .nilValue = value {
            return .none(
                wrappedTypeName: wrappedTypeName,
                isImplicitlyUnwrapped: isImplicitlyUnwrapped)
        }
        if case .implicitMember(let name) = value, name == "none" {
            return .none(
                wrappedTypeName: wrappedTypeName,
                isImplicitlyUnwrapped: isImplicitlyUnwrapped)
        }
        if case .host(let any) = value, let call = any as? ImplicitMemberCall {
            if call.name == "none", call.arguments.isEmpty {
                return .none(
                    wrappedTypeName: wrappedTypeName,
                    isImplicitlyUnwrapped: isImplicitlyUnwrapped)
            }
            if call.name == "some", let payload = call.arguments.positional(0) {
                return .some(
                    try resolveAnnotated(payload, typeName: wrappedTypeName),
                    wrappedTypeName: wrappedTypeName,
                    isImplicitlyUnwrapped: isImplicitlyUnwrapped)
            }
        }
        if case .optional(let optional) = value {
            let canonical: (String) -> String = {
                $0.filter { !$0.isWhitespace }
                    .replacingOccurrences(of: "Swift.", with: "")
            }
            let sameKnownLayer = optional.wrappedTypeName.map(canonical)
                == canonical(wrappedTypeName)
            // Any Optional-producing API already represents this layer when
            // the target's wrapped type is non-Optional; type context merely
            // refines its metadata. If the target's wrapped type is itself
            // Optional, injection adds the required outer layer instead.
            let sameStructuralLayer = RuntimeOptionalValue.wrappedType(
                in: wrappedTypeName) == nil
            if sameKnownLayer || sameStructuralLayer {
                guard let payload = optional.wrapped else {
                    return .none(
                        wrappedTypeName: wrappedTypeName,
                        isImplicitlyUnwrapped: isImplicitlyUnwrapped)
                }
                return .some(
                    try resolveAnnotated(payload, typeName: wrappedTypeName),
                    wrappedTypeName: wrappedTypeName,
                    isImplicitlyUnwrapped: isImplicitlyUnwrapped)
            }
        }
        return .some(
            try resolveAnnotated(value, typeName: wrappedTypeName),
            wrappedTypeName: wrappedTypeName,
            isImplicitlyUnwrapped: isImplicitlyUnwrapped)
    }

    /// The conversion character of each %-directive in a format string,
    /// in order (`"%d of %@"` → ["d", "@"]); `%%` is skipped.
    static func formatDirectives(_ format: String) -> [Character] {
        var out: [Character] = []
        var iterator = format.makeIterator()
        while let ch = iterator.next() {
            guard ch == "%" else { continue }
            // skip flags/width/precision/length up to the conversion char
            var current = iterator.next()
            if current == "%" { continue }
            while let c = current, "0123456789.+-# hlLqztj*'".contains(c) {
                current = iterator.next()
            }
            if let c = current { out.append(c) }
        }
        return out
    }
}
