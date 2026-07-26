import Foundation
import SwiftSyntax

/// A host-type source-extension method family, optionally competing with an
/// imported standard-library member. Member lookup alone cannot select this
/// target: Swift ranks overloads after argument labels and types are known.
@MainActor
struct HostExtensionMethodOverloads {
    let typeName: String
    let sourceMethods: [FunctionDeclSyntax]
    let importedMethod: HostFunction?
    let receiver: RuntimeValue
}

extension Interpreter {
    // MARK: - Identifiers & members

    /// A module qualifier is semantic source metadata, not a small list of
    /// framework identities. `Swift` arrives through the language's implicit
    /// import; project merges preserve every explicit import as provenance.
    private func isVisibleModuleQualifier(_ name: String) -> Bool {
        currentProgramMetadata?.importedModuleNames.contains(name) == true
    }

    /// Project merging preserves each compiler input's declaring module as a
    /// source region. Qualified lookup must rank only declarations from that
    /// region; otherwise an unrelated target's same-named global can win by
    /// collection order. Legacy single-file inputs have no regions, so they
    /// retain their historical unscoped overload family.
    private func globalFunctionOverloads(
        _ overloads: [FunctionDeclSyntax],
        declaredIn moduleName: String
    ) -> [FunctionDeclSyntax] {
        let owned = overloads.map { function in
            let state = programStateOwningDeclaration(function.id)
            let metadata = state?.programPlan?.metadata
                ?? currentProgramMetadata
            return (
                function,
                metadata?.sourceModuleName(
                    at: function.positionAfterSkippingLeadingTrivia)
            )
        }
        let matching = owned.compactMap { function, owner in
            owner == moduleName ? function : nil
        }
        if !matching.isEmpty {
            return matching
        }
        return owned.allSatisfy { $0.1 == nil } ? overloads : []
    }

    /// Resolve `Module.global` without collapsing a source overload family to
    /// whichever declaration happened to be collected last.
    private func moduleQualifiedGlobal(
        named name: String,
        moduleName: String
    ) -> RuntimeValue? {
        guard isVisibleModuleQualifier(moduleName) else { return nil }
        if let sourceDeclaration = globals.lookup("\(moduleName).\(name)") {
            return sourceDeclaration
        }
        let allOverloads = globalFunctionOverloads[name] ?? []
        let overloads = globalFunctionOverloads(
            allOverloads, declaredIn: moduleName)
        if !overloads.isEmpty {
            return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                guard let self else { return .void }
                let available = self.functionsAvailableForCall(
                    from: overloads, args: args)
                guard let function = self.chooseFunctionByRuntimeTypes(
                    from: available, for: args) ?? available.first,
                      let body = self.functionMetadata(for: function).body
                else {
                    return .native(ChainedImplicitCall(
                        base: .implicitMember(name),
                        member: "call",
                        arguments: args))
                }
                let closure = self.makeFunctionClosure(
                    function, body: body, captured: self.globals)
                return try self.callWithArguments(
                    closure, args: args, node: nil)
            })
        }
        // A differently owned source function is not a member of this
        // qualifier. Suppress the unqualified global fallback so imported
        // registry dispatch can answer (or absorb) the qualified call.
        if allOverloads.isEmpty, let global = globals.lookup(name) {
            switch global {
            case .type, .enumType:
                break
            default:
                return global
            }
        }
        // A qualifier deliberately bypasses a same-named source nominal and
        // asks for the imported symbol. Constructor availability is the
        // structural proof that the member is an imported constructible type;
        // retaining the HostFunction also retains every call-site argument,
        // including trailing result-builder closures.
        return registry?.constructor(named: name).map(RuntimeValue.hostFunction)
    }

    /// Lazy globals evaluate their initializer on first read (memoized).
    func force(_ box: Box) throws -> RuntimeValue {
        if case .host(let any) = box.value, let computed = any as? ComputedGlobal {
            // Global computed var: evaluate fresh on every read.
            let result = try executeBlock(computed.accessor, in: Environment(parent: globals))
            switch result {
            case .normal(let value), .returnValue(let value):
                return try resolveAnnotated(value, typeName: computed.typeName)
            default:
                return .void
            }
        }
        guard case .host(let any) = box.value, let lazy = any as? LazyGlobal else {
            return try box.load()
        }
        let annotationText = lazy.typeName ?? ""
        var value: RuntimeValue = RuntimeOptionalValue.wrappedType(in: annotationText) != nil
            ? .none(forTypeAnnotation: annotationText) : .void
        if let initializer = lazy.initializer {
            value = try resolveAnnotated(
                try evaluate(initializer, in: globals), typeName: lazy.typeName)
        }
        var stored: RuntimeValue? = value.copiedForValueSemantics()
        box.value = stored!
        if box.referenceOwnership != .strong {
            // Drop evaluator temporaries before observing a weak result. A
            // temporary-only initializer (`weak var x = C()`) must already
            // read nil on its first source-level access, like compiled Swift.
            value = .void
            stored = nil
            return try box.load()
        }
        return stored!
    }

    /// Diagnostics: INTERP_TRACE_CALLS="a,b,c" prints each entry into a
    /// matching declared function — localizing silent absorbs in deep chains.
    static let tracedCallNames: Set<String>? = ProcessInfo.processInfo
        .environment["INTERP_TRACE_CALLS"].map { Set($0.split(separator: ",").map(String.init)) }

    /// `$selectedTab` / `self.$selectedTab` / `home.$selectedTab` — the
    /// projected value of a wrapper property on an INSTANCE: @Published's
    /// inert publisher, model projections for object wrappers, and
    /// BindingStub for @State/@Binding storage.
    func instanceProjection(
        _ propertyName: String, on instance: Instance, node: some SyntaxProtocol
    ) throws -> RuntimeValue {
        try requireActorStoredPropertyAccess(
            instance, property: propertyName)
        // `$searchText` on a @Published property (inside the model) is
        // the Combine publisher projection — an inert pipeline.
        if let property = instance.symbol.storedProperty(named: propertyName),
           property.wrapper == .published {
            // Replay/live registries deliver the CURRENT value synchronously
            // (the doctrine fork); absorbed mode stays inert.
            if let current = instance.box(for: propertyName)?.value,
               let publisher = registry?.publishedProjection(current: current) {
                return publisher
            }
            return .native(PublishedProjection())
        }
        // `$store` on a model property projects the model so `$store.field`
        // can become a binding to the model's own box.
        if let property = instance.symbol.storedProperty(named: propertyName),
           property.wrapper == .stateObject || property.wrapper == .observedObject
            || property.wrapper == .environmentObject {
            let boxValue = instance.box(for: propertyName)?.value
            guard case .instance(let model)? = boxValue else {
                // External-package models synthesize as unknowables —
                // their projection is equally unknowable (absorbs).
                if case .host(let any)? = boxValue,
                   any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                    return boxValue ?? .nilValue
                }
                if case .implicitMember? = boxValue { return boxValue ?? .nilValue }
                if case .hostFunction? = boxValue { return boxValue ?? .nilValue }
                throw error(node, "'$\(propertyName)' has no model instance assigned")
            }
            return .native(ModelProjection(model: model))
        }
        guard let box = instance.projectedBox(for: propertyName) else {
            throw error(node, "'$\(propertyName)' requires an @State or @Binding property named '\(propertyName)'")
        }
        return .native(BindingStub(box: box))
    }

    func resolveIdentifier(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
        if Self.tracedIdentifier == name {
            let result = Result { try resolveIdentifierCore(name, in: env, node: node) }
            let location = error(node, "").line
            let owners = lexicalOwnerFrames.map {
                ($0 as? StructSymbol)?.name ?? ($0 as? EnumSymbol)?.name ?? "?"
            }
            switch result {
            case .success(let value):
                var detail = value.stringified.prefix(60).description
                if case .enumType(let symbol) = value {
                    detail += "(cases: \(symbol.cases.map(\.name).prefix(4).joined(separator: ",")))"
                }
                Swift.print("   ⌖ \(name)@\(location) → \(detail) owners=\(owners)")
                return value
            case .failure(let failure):
                Swift.print("   ⌖ \(name)@\(location) → THREW \(failure) owners=\(owners)")
                throw failure
            }
        }
        return try resolveIdentifierCore(name, in: env, node: node)
    }

    private func resolveIdentifierCore(_ name: String, in env: Environment, node: some SyntaxProtocol) throws -> RuntimeValue {
        // Real Swift scoping: locals first, implicit-self members second,
        // globals LAST (a method named like a global type wins in its body).
        if let box = env.box(for: name, before: globals) {
            let value = try force(box)
            if value.hostPayload is RuntimeAsyncLetBinding {
                throw error(node,
                    "async let binding '\(name)' requires await")
            }
            return value
        }
        // `$count` — projected value of an @State or @Binding property.
        // (`$0`-style closure shorthands were already bound in the environment.)
        if name.hasPrefix("$"), name.count > 1, !name.dropFirst().allSatisfy(\.isNumber) {
            let propertyName = String(name.dropFirst())
            // `@Bindable var x = model` — a LOCAL holding a model instance
            // projects member bindings (`$x.activeTab`); a local binding
            // projects itself.
            if let localBox = env.box(for: propertyName) {
                let local = try force(localBox)
                if case .instance(let model) = local {
                    return .native(ModelProjection(model: model))
                }
                if case .host(let any) = local, any is BindingStub {
                    return local
                }
            }
            guard case .instance(let instance)? = env.lookup("self") else {
                throw error(node, "'\(name)' can only be used inside a View body")
            }
            return try instanceProjection(propertyName, on: instance, node: node)
        }
        if let selfValue = env.lookup("self"),
           let value = try selfMember(name, on: selfValue) {
            return value
        }
        // A nested nominal remains in the lexical scope of every enclosing
        // nominal. Swift therefore permits `Inner` bodies to refer to an
        // outer static member without qualification. Runtime `self` only
        // identifies `Inner`, so walk the declaration-owner chain before
        // consulting module globals.
        if let value = try lexicallyEnclosingTypeMember(name) {
            return value
        }
        if let value = lexicallyVisibleType(
            named: name, from: lexicalOwnerFrames.last
        ) {
            return value
        }
        if let box = globals.box(for: name) {
            let value = try force(box)
            if (currentLexicalSourceModuleName == nil
                    && currentLexicalSourceImportedModuleNames == nil)
                || sourceModuleNames(owning: value).isEmpty {
                return value
            }
        }
        // Operator-function references (`reduce(0, +)`, `sorted(by: >)`) —
        // real Swift passes the global operator function; ours applies the
        // builtin table. User-declared operator functions won above (globals).
        if name.count <= 3, name.allSatisfy({ "+-*/%<>=!&|^~".contains($0) }) {
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let lhs = args.positional(0), let rhs = args.positional(1) else {
                    throw EvalMessage(text: "operator '\(name)' needs two arguments")
                }
                return try Builtins.binary(name, lhs, rhs)
            })
        }
        if name == "Self", let selfValue = env.lookup("self") {
            switch selfValue {
            case .instance(let instance):
                return globals.lookup(instance.symbol.name) ?? .type(instance.symbol)
            case .type, .enumType:
                return selfValue
            default:
                break
            }
        }
        if let value = registry?.hostGlobal(named: name) {
            return value
        }
        // SDK symbol graphs include imported module functions whose names are
        // conventionally uppercase (MTLCreateSystemDefaultDevice, UIGraphics…)
        // even though they are values, not types. Give an explicitly
        // registered host global priority over the unknown-type absorber.
        if let function = registry?.cFunction(named: name) {
            return .hostFunction(function)
        }
        let constructorName = lexicallyVisibleTypeAliasHead(named: name) ?? name
        if let ctor = registry?.constructor(named: constructorName) {
            return .hostFunction(ctor)
        }
        // Unknown type-looking names are assumed host types used for static
        // access (Color.red, UIScreen.main). Calling them errors clearly.
        if let first = name.first, first.isUppercase {
            return .native(HostTypeMarker(name: name))
        }
        // LAST resort — unqualified MODIFIER calls inside View-extension
        // bodies: `func withSheet(…) -> some View { sheet(item:…) { … } }`.
        // Everything else resolved above (members, globals, constructors),
        // so this only rescues would-be-unresolved lowercase names when
        // implicit self is a view (native or interpreted instance).
        // C-interop names never rescue as modifiers: inside host-type
        // extension bodies (self = host object) a bare `uname(&info)` must
        // reach the C absorber below, not the registry's modifier table.
        if let selfValue = env.lookup("self"),
           !Self.looksLikeCImport(name),
           registry?.cFunction(named: name) == nil,
           let modifier = registry?.modifier(named: name),
           let target = modifierTarget(for: selfValue) {
            return .hostFunction(HostFunction(name: name) { args, ctx in
                try modifier.apply(target, args, ctx)
            })
        }
        // Unresolved snake_case identifiers are C imports (sqlite3_open,
        // ndb_builder — the merge holds all the app's OWN Swift): inert
        // absorbing functions, values chain per the fresh-state doctrine.
        if Self.looksLikeCImport(name) || assumesCompiledImports {
            if let real = registry?.cFunction(named: name) { return .hostFunction(real) }
            // SCREAMING_SNAKE identifiers are C CONSTANTS (EXIT_SUCCESS,
            // _SYS_NAMELEN): numeric-absorbing markers, not host types.
            if name.contains("_"), name.dropFirst(name.hasPrefix("_") ? 1 : 0)
                .allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                return .implicitMember(name)
            }
            return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                // Preserve unresolved-import provenance in the result. A
                // metadata-recognized zero-argument C record constructor is
                // concrete and writable; all other unknown imported calls
                // retain their unresolved chain so `if let` can still
                // distinguish a missing imported result.
                if args.isEmpty,
                   let record = self?.registry?.absorbedCValue(named: name) {
                    return record
                }
                return .native(ChainedImplicitCall(
                    base: .implicitMember(name), member: "call",
                    arguments: args))
            })
        }
        throw error(node, "unresolved identifier '\(name)'")
    }

    /// Finds the current nominal's own type identity or a static member in its
    /// lexical namespace, then walks each enclosing nominal. The ownership
    /// links are collected from source nesting, so this dispatch is structural
    /// rather than keyed to a type or member identity.
    private func lexicallyEnclosingTypeMember(
        _ name: String
    ) throws -> RuntimeValue? {
        var owner = lexicalOwnerFrames.last
        var visited: Set<ObjectIdentifier> = []
        while let current = owner,
              visited.insert(ObjectIdentifier(current)).inserted {
            if let symbol = current as? StructSymbol {
                if name == symbol.name {
                    // An extension of an SDK/host type owns members, not the
                    // nominal itself. A reference to the extended type from
                    // inside its body must therefore keep using the native
                    // constructor (including labels unrelated to storage),
                    // rather than memberwise-constructing the synthetic
                    // extension symbol.
                    if hostExtensionSymbols[symbol.name] === symbol,
                       let global = globals.lookup(name) {
                        if case .type(let globalSymbol) = global,
                           globalSymbol === symbol {
                            return .type(symbol)
                        }
                        return global
                    }
                    if hostExtensionSymbols[symbol.name] === symbol,
                       let constructor = registry?.constructor(named: name) {
                        return .hostFunction(constructor)
                    }
                    return .type(symbol)
                }
                if let value = try staticMember(name, of: symbol) {
                    return value
                }
                owner = symbol.lexicalTypeOwner
            } else if let symbol = current as? EnumSymbol {
                if name == symbol.name { return .enumType(symbol) }
                if let value = try staticMember(name, of: symbol) {
                    return value
                }
                owner = symbol.lexicalTypeOwner
            } else {
                break
            }
        }
        return nil
    }

    /// Implicit-self member resolution (works for struct instances, enum
    /// values, and native selves inside host-extension method bodies).
    private func selfMember(_ name: String, on selfValue: RuntimeValue) throws -> RuntimeValue? {
        switch selfValue {
        case .instance(let instance):
            return try instanceMember(name, on: instance, preferHostSuperclassProperty: true)
        case .enumCase(let value):
            return try enumCaseMember(name, on: value)
        case .type(let symbol):
            // Static context: bare sibling-static references inside a
            // `static var`/`static func` body.
            return try staticMember(name, of: symbol)
        case .enumType(let symbol):
            return try staticMember(name, of: symbol)
        case .int, .double, .bool, .string, .array, .set, .dictionary, .tuple, .range, .host:
            // Bare `count`/`firstIndex(...)` inside a host-type extension body
            // is implicit self on the native value. Inline scalars box on
            // demand for host-extension and gateway compatibility.
            let any = selfValue.hostPayload!
            if let stub = any as? BindingStub {
                // `wrappedValue.setIsLoading(…)` inside `extension Binding`
                // — the binding's own properties resolve bare.
                if name == "wrappedValue" { return stub.box.value }
                if name == "projectedValue" { return selfValue }
            }
            // `modifier(SourceModifier(...))` inside `extension View` is the
            // implicit-self spelling of the same generic SwiftUI operation
            // handled for `self.modifier(...)` at member call sites. The
            // interface cannot bridge an interpreted generic conformer into
            // native SwiftUI, so run its source body through the shared
            // ViewModifier semantic primitive.
            if name == "modifier",
               let target = modifierTarget(for: selfValue) {
                return .hostFunction(HostFunction(name: name) {
                    [weak self] args, _ in
                    guard let self else {
                        throw RuntimeError(message: "interpreter gone")
                    }
                    guard let result = try self.applyCustomViewModifierArgument(
                        args, to: target, node: nil
                    ) else {
                        throw RuntimeError(
                            message: "modifier requires a source ViewModifier")
                    }
                    return result
                })
            }
            if let value = try nativeMember(name, on: selfValue) { return value }
            if let value = try readHostMember(
                name, on: any, includingFallback: false
            ) { return value }
            return try hostExtensionMember(name, candidates: hostCandidates(for: any), selfValue: selfValue)
        default:
            return nil
        }
    }

    /// Property → method → computed property → own nested types, or nil
    /// if the name is unknown.
    func instanceMember(
        _ rawName: String, on instance: Instance,
        preferHostSuperclassProperty: Bool = false
    ) throws -> RuntimeValue? {
        // `self.$selectedTab` / `home.$path` — member-form projections
        // resolve exactly like bare `$name` (the TV-home genre passes
        // `self.$selectedTab` into a child's @Binding).
        if rawName.hasPrefix("$"), rawName.count > 1,
           !rawName.dropFirst().allSatisfy(\.isNumber) {
            return try instanceProjection(
                String(rawName.dropFirst()), on: instance,
                node: Syntax(DeclReferenceExprSyntax(baseName: .identifier(rawName))))
        }
        let name = instance.symbol.canonicalPropertyName(rawName)
        if name == "objectWillChange", instance.symbol.isClass {
            let signal = instance.changeSignal
            return .native(ObjectWillChangePublisher(fire: { signal.fire() }))
        }
        if instance.box(for: name) != nil {
            try requireActorStoredPropertyAccess(instance, property: name)
        }
        if let box = instance.box(for: name),
           case .host(let any) = box.value, let seed = any as? LazyMemberSeed {
            // Force the lazy member now, with self bound.
            let value = try resolveAnnotated(
                try evaluate(seed.initializer, in: selfEnvironment(.instance(instance))),
                typeName: seed.typeName).copiedForValueSemantics()
            box.value = value
            return value
        }
        // A type's OWN nested types shadow same-named globals inside its
        // body (each IceCubes package declares its own `enum Constants`) —
        // scoped LEXICALLY to the running method's declaring type, so
        // protocol-extension bodies never see the runtime self's nesteds.
        if let nested = lexicalNestedType(name, runtime: instance.symbol) { return nested }
        if let box = instance.box(for: name) { return try box.load() }
        let conformances = transitiveConformances(of: instance.symbol)

        // Bare member syntax selects a protocol property over a concrete
        // same-base method; call syntax is resolved independently by
        // CallEvaluator. Source-authored properties remain more specific
        // than a generated standard-library default.
        var hierarchyDefinesComputedProperty = false
        var propertyCandidate: StructSymbol? = instance.symbol
        var walkedPropertyOwners = Set<ObjectIdentifier>()
        while let owner = propertyCandidate,
              walkedPropertyOwners.insert(ObjectIdentifier(owner)).inserted {
            if owner.computedProperties[name] != nil {
                hierarchyDefinesComputedProperty = true
                break
            }
            propertyCandidate = interpretedSuperclass(of: owner)
        }
        let sourceProtocolDefinesComputedProperty = conformances.contains {
            hostExtensionSymbols[$0]?.computedProperties[name] != nil
        }
        if !hierarchyDefinesComputedProperty,
           !sourceProtocolDefinesComputedProperty,
           let generated = try GeneratedCollectionDefaultSurface.property(
               named: name,
               conformances: Set(conformances),
               receiver: .instance(instance),
               interpreter: self) {
            return generated
        }
        // Dynamic dispatch: the instance's OWN members win (overrides beat
        // the inherited definition), THEN interpreted-superclass members
        // dispatch with self unchanged, walking the chain.
        if let overloads = instance.symbol.methods[name], let first = overloads.first {
            // A PROPERTY/METHOD name collision (`var filteredReadings` +
            // `func filteredReadings(for:)`): a bare reference is the
            // property when every method overload requires arguments.
            if instance.symbol.computedProperties[name] != nil,
               overloads.allSatisfy({ method in
                   functionMetadata(for: method).parameters.contains {
                       $0.defaultValue == nil
                   }
               }) {
                return try evaluateComputed(
                    instance.symbol.computedProperties[name]!,
                    selfValue: .instance(instance), name: name)
            }
            // Host superclasses can contribute a property whose name is
            // reused by an argument-taking subclass method
            // (`NSWindowController.window` and delegate `window(_:)`). Bare
            // access is the inherited property; call syntax is dispatched
            // directly by CallEvaluator. Carry the unavailable property as
            // an inert marker.
            if preferHostSuperclassProperty,
               instance.symbol.superclassName != nil,
               interpretedSuperclass(of: instance.symbol) == nil,
               overloads.allSatisfy({ method in
                   functionMetadata(for: method).parameters.contains {
                       $0.defaultValue == nil
                   }
               }) {
                return .native(ChainedImplicitCall(
                    base: .instance(instance), member: name, arguments: CallArguments()))
            }
            // Within an OVERLOAD SET the running declaration never re-enters
            // itself: `send(_:) -> StoreTask` delegates to its identically-
            // shaped sibling (return-type disambiguation). A set exhausted
            // by recursion absorbs — but a UNIQUE decl recursing (fib) is
            // legitimate and stays.
            var method = first
            if overloads.count > 1 {
                guard let candidate = overloads.first(where: { !activeFunctionBodies.contains($0.id) }) else {
                    return .native(ChainedImplicitCall(
                        base: .instance(instance), member: name, arguments: CallArguments()))
                }
                method = candidate
            }
            guard let body = functionMetadata(for: method).body else {
                return nil
            }
            return .closure(makeFunctionClosure(
                method, body: body, captured: instanceMethodEnvironment(instance)))
        }
        if let computed = instance.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
        }
        var parent = interpretedSuperclass(of: instance.symbol)
        while let candidate = parent {
            if let overloads = candidate.methods[name], let firstMethod = overloads.first {
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstMethod)
                    : firstMethod
                if let body = functionMetadata(for: method).body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: instanceMethodEnvironment(instance)))
                }
            }
            if let computed = candidate.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
            parent = interpretedSuperclass(of: candidate)
        }
        // A generated native backing carries interface-declared members from
        // an imported direct superclass. Source members above retain normal
        // override precedence; dynamic compatibility fallbacks are excluded.
        if let inherited = try inheritedHostSuperclassMember(
            name, on: instance
        ) {
            return inherited
        }
        if instance.symbol.conformsToView,
           let value = try hostExtensionMember(name, candidates: ["View"], selfValue: .instance(instance)) {
            return value
        }
        // Protocol-extension defaults: `extension GameLogic { func start() … }`
        // serves conformers that don't define the member themselves —
        // through protocol REFINEMENT too (CountriesWebRepository:
        // WebRepository reaches WebRepository's `call(endpoint:)`).
        for conformance in conformances {
            guard let proto = hostExtensionSymbols[conformance] else { continue }
            if let overloads = proto.methods[name], let firstMethod = overloads.first {
                // PROPERTY/METHOD collision in the same extension (AnyStatus
                // declares `var isHidden` AND `func isHidden(in:)`): a bare
                // reference is the property when every method overload
                // requires arguments — the instanceMember rule.
                if let computed = proto.computedProperties[name],
                   overloads.allSatisfy({ method in
                       functionMetadata(for: method).parameters.contains {
                           $0.defaultValue == nil
                       }
                   }) {
                    return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
                }
                // Overload sets never re-enter the running declaration
                // (IconDrawable's image(ofSize:color:) → edgeInsets form,
                // served to conformers through the protocol-defaults walk).
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstMethod)
                    : firstMethod
                if let body = functionMetadata(for: method).body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: instanceMethodEnvironment(instance)))
                }
            }
            if let computed = proto.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
        }
        // Compiled protocol extensions cannot execute against an interpreted
        // conformer. BridgeGen emits the constrained default implementations
        // whose scalar representation can cross that boundary losslessly.
        if let generated = GeneratedCollectionDefaultSurface.member(
            named: name, conformances: Set(conformances)
        ) {
            return .hostFunction(generated)
        }
        if let generated = try GeneratedCollectionDefaultSurface.property(
            named: name,
            conformances: Set(conformances),
            receiver: .instance(instance),
            interpreter: self
        ) {
            return generated
        }
        // @ModelActor's generated `modelContext` reads the bound
        // container's shared context.
        if name == "modelContext",
           instance.symbol.attributeNames.contains("ModelActor"),
           let container = instance.box(for: "modelContainer")?.value,
           case .host(let containerAny) = container,
           let member = try readHostMember("mainContext", on: containerAny) {
            return member
        }
        // Bare sibling STATICS are visible from any member context
        // (`assert(blurRadius > 0)` where the parameter default is
        // `defaultBlurRadius`, a static let on the type) — resolved in the
        // DECLARING type's scope: a protocol-extension body sees the
        // extension's own statics/nesteds, never the runtime conformer's
        // (clean-architecture's test double nests a shadowing APIError).
        let staticScope = (lexicalOwnerFrames.last as? StructSymbol) ?? instance.symbol
        if let value = try staticMember(name, of: staticScope) {
            return value
        }
        return nil
    }

    /// Interpreted extension-of-host-type members (`extension View { … }`).
    /// Static METHODS of a host-type extension dispatch at INVOKE time so
    /// the call shape can resolve past the program shadow to the host —
    /// `Double.random(in:using:)` against a 1-arg shadow picks the stdlib,
    /// exactly like native overload resolution. Returns nil when the name
    /// isn't purely a method (properties keep the staticMember path).
    func hostExtensionStaticMethodDispatcher(
        _ name: String, hostSymbol: StructSymbol, typeName: String
    ) -> RuntimeValue? {
        guard hostSymbol.isStaticMember(
                  named: name,
                  visibleFrom: currentLexicalSourceFileIdentity),
              let overloads = hostSymbol.staticMethods[name], !overloads.isEmpty,
              hostSymbol.staticProperties[name] == nil,
              hostSymbol.staticComputedProperties[name] == nil,
              hostSymbol.nestedTypes[name] == nil,
              hostSymbol.staticCache[name] == nil,
              hostSymbol.staticReferenceBoxes[name] == nil else { return nil }
        return .hostFunction(HostFunction(name: name) { [unowned self] args, _ in
            let pool = functionsAvailableForCall(
                from: overloads, args: args)
            // A declared overload only competes when it accepts every label
            // the call passes — `using:` against an (in:)-only shadow is a
            // host call, not a shadow hit.
            let callLabels = Set(args.arguments.compactMap(\.label))
            let shapePool = pool.filter { method in
                let paramLabels = Set(
                    functionMetadata(for: method).parameters.compactMap(\.label))
                return callLabels.isSubset(of: paramLabels)
            }
            var chosen = chooseFunction(from: shapePool, for: args) ?? shapePool.first
            if chosen == nil,
               ((try? readHostMember(name, on: HostTypeMarker(name: typeName))) ?? nil) == nil {
                // No host to defer to: keep the historical force-first
                // behavior for label-lenient code.
                chosen = pool.first
            }
            if let method = chosen,
               let body = functionMetadata(for: method).body {
                let closure = makeFunctionClosure(
                    method, body: body, captured: selfEnvironment(.type(hostSymbol)))
                return try callWithArguments(closure, args: args, node: nil)
            }
            guard let host = try readHostMember(name, on: HostTypeMarker(name: typeName)),
                  case .hostFunction(let function) = host else {
                throw RuntimeError(
                    message: "\(typeName).\(name): no overload matches the call")
            }
            return try function.invoke(args, self)
        })
    }

    func hostExtensionMember(_ name: String, candidates: [String], selfValue: RuntimeValue) throws -> RuntimeValue? {
        for typeName in candidates {
            guard let symbol = hostExtensionSymbols[typeName] else { continue }
            if let overloads = symbol.methods[name], let firstOverload = overloads.first {
                // Bare reference on a property/method collision: the
                // property wins when every overload requires arguments —
                // UNLESS that property is already evaluating (its body
                // calling the same-named METHOD must reach the method:
                // nextcloud's `var resolvedWindow` calls
                // `resolvedWindow(in:)`).
                let collisionKey = "\(typeName).\(name)"
                if let computed = symbol.computedProperties[name],
                   !activeCollisionProperties.contains(collisionKey),
                   overloads.allSatisfy({ method in
                       functionMetadata(for: method).parameters.contains {
                           $0.defaultValue == nil
                       }
                   }) {
                    activeCollisionProperties.insert(collisionKey)
                    defer { activeCollisionProperties.remove(collisionKey) }
                    return try evaluateComputed(computed, selfValue: selfValue, name: name)
                }
                // Overload sets never re-enter the running declaration
                // (IconDrawable's image(ofSize:color:) delegating to the
                // edgeInsets form).
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstOverload)
                    : firstOverload
                guard let body = functionMetadata(for: method).body else {
                    return nil
                }
                let frame = ExtensionFrame(typeName: typeName, member: name)
                // A same-named self-call INSIDE this method's own body is
                // the other overload (UTM: onReceive(Notification.Name…)
                // delegating to SwiftUI's onReceive(publisher…)) — prefer
                // the registry gateway when one exists; recurse only when
                // there is no alternative (fib-style helpers).
                if activeExtensionFrames.contains(frame),
                   let registry, registry.isViewValue(selfValue),
                   registry.modifier(named: name) != nil {
                    continue
                }
                let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(selfValue))
                closure.extensionFrame = frame
                closure.functionDeclID = method.id
                return .closure(closure)
            }
            if let computed = symbol.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: selfValue, name: name)
            }
        }
        return nil
    }

    /// Canonical host-extension names proven by the receiver's source type.
    /// A host payload may deliberately erase its concrete SDK type, so source
    /// aliases must be followed through the declaring file's module/import
    /// visibility before an absorbing imported member gets first refusal.
    func declaredHostExtensionTypeNames(
        _ declaredTypeName: String?
    ) -> [String] {
        guard var current = RuntimeDeclaredType.nominalTypeName(
            declaredTypeName
        ) else {
            return []
        }

        var names: [String] = []
        var seen: Set<String> = []
        while seen.insert(current).inserted {
            names.append(current)
            guard let target = lexicallyVisibleTypeAliasHead(named: current),
                  let canonical = RuntimeDeclaredType.nominalTypeName(target)
            else {
                break
            }
            current = canonical
        }
        return names
    }

    /// Preserve compiler-style overload selection for source extensions on a
    /// host type, including families that also contain an imported member.
    /// Returning a closure during bare member lookup is too early: for example,
    /// `String.appending(String?)` wins for `nil`, while Foundation's
    /// `appending(String)` wins for a non-optional String.
    func hostExtensionMethodOverloads(
        named name: String,
        on receiver: RuntimeValue,
        declaredTypeName: String? = nil
    ) throws -> HostExtensionMethodOverloads? {
        guard let payload = receiver.hostPayload else { return nil }

        var typeNames: [String] = []
        func appendTypeName(_ typeName: String?) {
            guard let typeName, !typeName.isEmpty,
                  !typeNames.contains(typeName) else { return }
            typeNames.append(typeName)
        }

        if let declaredTypeName {
            let declared = declaredTypeName.trimmingCharacters(
                in: .whitespacesAndNewlines)
            appendTypeName(declared)
            for typeName in declaredHostExtensionTypeNames(declared) {
                appendTypeName(typeName)
            }
            if let element = RuntimeDeclaredType.arrayElementTypeName(
                in: declared) {
                appendTypeName("[\(element)]")
                appendTypeName("Array")
            }
        }
        if let typeName = registry?.hostTypeName(of: payload) {
            appendTypeName(typeName)
        }
        if payload is String, !typeNames.contains("String") {
            appendTypeName("String")
        }
        if payload is [RuntimeValue] {
            if let elements = receiver.arrayValue,
               let first = elements.first {
                let elementType = hostTypeName(of: first)
                if elements.dropFirst().allSatisfy({
                    valueIsType($0, elementType)
                }) {
                    appendTypeName("[\(elementType)]")
                }
            }
            appendTypeName("Array")
        }
        if payload is BindingStub, !typeNames.contains("Binding") {
            appendTypeName("Binding")
        }
        let directTypeNames = Set(typeNames)
        // Conformance evidence makes source protocol extensions visible on a
        // host value, but it does not turn them into concrete host overloads.
        // Admit a conformance-only family to this signature matcher only when
        // an exact imported peer participates; otherwise ordinary source
        // label dispatch must remain free to accept opaque imported values.
        for typeName in hostCandidates(for: payload) {
            appendTypeName(typeName)
        }

        let delegatesFromSourceExtension = typeNames.contains { typeName in
            activeExtensionFrames.contains(ExtensionFrame(
                typeName: typeName, member: name))
        }
        let importedMethod: HostFunction?
        if let imported = try nativeMember(name, on: receiver)
            ?? registry?.hostMethod(name, on: payload),
           case .hostFunction(let method) = imported,
           !method.canSuspend {
            importedMethod = method
        } else if assumesCompiledImports && delegatesFromSourceExtension {
            // The merged source was accepted by its original compiler, so a
            // same-named call from inside a source extension that fits no
            // source declaration may target an imported SDK peer the runtime
            // bridge has not modeled yet. Keep that peer in the overload
            // family as an absorbing callable; source candidates still win
            // whenever their runtime types fit.
            importedMethod = HostFunction(name: name) { args, _ in
                .native(ChainedImplicitCall(
                    base: receiver, member: name, arguments: args))
            }
        } else {
            importedMethod = nil
        }
        for typeName in typeNames {
            guard let sourceMethods = hostExtensionSymbols[typeName]?
                .methods[name],
                  !sourceMethods.isEmpty,
                  directTypeNames.contains(typeName)
                      || importedMethod != nil,
                  sourceMethods.count > 1 || importedMethod != nil,
                  sourceMethods.allSatisfy({
                    !functionMetadata(for: $0).isAsync
                  }) else {
                continue
            }
            return HostExtensionMethodOverloads(
                typeName: typeName,
                sourceMethods: sourceMethods,
                importedMethod: importedMethod,
                receiver: receiver)
        }
        return nil
    }

    /// Recover the source type of a member receiver without attaching type
    /// metadata to every RuntimeValue. Native array-payload subscripting
    /// produces the declared element type; an interpreted subscript's result
    /// value disambiguates overloads with different declared result types; and
    /// a standard-library `filter` preserves its receiver's array type even
    /// when the result is empty.
    func declaredMemberReceiverTypeName(
        for expression: ExprSyntax,
        in environment: Environment,
        evaluatedValue: RuntimeValue? = nil
    ) -> String? {
        func storedValue(
            for expression: ExprSyntax
        ) -> RuntimeValue? {
            if let reference = expression.as(
                DeclReferenceExprSyntax.self) {
                let name = reference.baseName.text
                if name == "self" { return environment.lookup("self") }
                if let box = environment.box(for: name, before: globals) {
                    if case .host(let payload) = box.value,
                       payload is LazyGlobal {
                        return nil
                    }
                    return box.value
                }
                if case .instance(let instance)? = environment.lookup("self"),
                   let box = instance.box(for:
                       instance.symbol.canonicalPropertyName(name)) {
                    return box.value
                }
                if let box = globals.box(for: name) {
                    if case .host(let payload) = box.value,
                       payload is LazyGlobal {
                        return nil
                    }
                    return box.value
                }
                return nil
            }
            guard let member = expression.as(MemberAccessExprSyntax.self),
                  let base = member.base,
                  case .instance(let instance)? = storedValue(for: base) else {
                return nil
            }
            return instance.box(for: instance.symbol.canonicalPropertyName(
                member.declName.baseName.text))?.value
        }

        if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
            if let base = storedValue(for: subscriptCall.calledExpression) {
                if case .host(let payload) = base,
               let readable = payload as? any RuntimeIntegerSubscriptReadable {
                    return readable.runtimeElementTypeName
                }
                if let evaluatedValue,
                   let (symbol, _) = userSubscriptOwner(for: base) {
                    let arityMatches = symbol.subscripts.filter {
                        $0.parameters.count == subscriptCall.arguments.count
                    }
                    let shaped = arityMatches.isEmpty
                        ? symbol.subscripts : arityMatches
                    let matchingResultTypes = shaped.compactMap(
                        \.resultTypeName).filter {
                            valueIsType(evaluatedValue, $0)
                        }
                    if let first = matchingResultTypes.first,
                       matchingResultTypes.dropFirst().allSatisfy({
                           HostSignature.equivalentTypeName($0, first)
                       }) {
                        return first
                    }
                }
            }
            let collectionTypeName = declaredMemberReceiverTypeName(
                for: subscriptCall.calledExpression, in: environment)
            return RuntimeDeclaredType.arrayPayloadElementTypeName(
                in: collectionTypeName)
        }
        if let call = expression.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(
               MemberAccessExprSyntax.self),
           member.declName.baseName.text == "filter",
           let receiver = member.base {
            return declaredMemberReceiverTypeName(
                for: receiver, in: environment)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if let annotation = environment.box(
                for: name, before: globals)?.declaredTypeName {
                return annotation
            }
            if case .instance(let instance)? = environment.lookup("self") {
                let canonical = instance.symbol.canonicalPropertyName(name)
                return instance.symbol.storedProperty(named: canonical)?
                    .typeName
                    ?? instance.symbol.computedProperties[canonical]?
                        .typeName
            }
            return globals.box(for: name)?.declaredTypeName
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
           let base = member.base,
           case .instance(let instance)? = storedValue(for: base) {
            let name = instance.symbol.canonicalPropertyName(
                member.declName.baseName.text)
            return instance.symbol.storedProperty(named: name)?
                .typeName
                ?? instance.symbol.computedProperties[name]?
                    .typeName
        }
        return nil
    }

    /// Resolve the overload set only after argument evaluation. Every source
    /// candidate and any imported peer use HostSignature's shared
    /// label/type/default/generic scoring, so an Optional promotion cannot
    /// outrank an exact parameter.
    func resolveHostExtensionMethodTarget(
        _ overloads: HostExtensionMethodOverloads,
        arguments: CallArguments,
        allowsExplicitThrowingSource: Bool
    ) throws -> RuntimeValue {
        // Swift removes a `throws` declaration from an unmarked call's
        // overload set. Apply that rule only when an imported peer actually
        // competes, preserving ordinary source recursion when no alternate
        // target exists. `rethrows` stays viable because argument effects,
        // rather than the declaration alone, govern its call site.
        let sourceMethods = !allowsExplicitThrowingSource
            && overloads.importedMethod != nil
            ? overloads.sourceMethods.filter {
                !functionMetadata(for: $0).requiresExplicitTry
            }
            : overloads.sourceMethods
        let available = functionsAvailableForCall(
            from: sourceMethods, args: arguments)

        var bestSource: (declaration: FunctionDeclSyntax, score: Int)?
        for declaration in available {
            let genericClause = declaration.genericParameterClause?
                .trimmedDescription ?? ""
            let whereClause = declaration.genericWhereClause.map {
                " " + $0.trimmedDescription
            } ?? ""
            let sourceDeclaration = "func \(declaration.name.text)"
                + genericClause + declaration.signature.trimmedDescription
                + whereClause
            guard let signature = try? HostSignature(
                    parsing: sourceDeclaration) else {
                continue
            }
            let lexicalOwner = lexicalOwner(of: declaration.id)
            let runtimeSignature = signature.replacingRuntimeParameterTypes(
                signature.parameters.map {
                    expandedRuntimeTypeAlias(
                        $0.type, lexicalOwner: lexicalOwner)
                })
            guard let match = runtimeSignature.match(
                    arguments: arguments, in: self) else {
                continue
            }
            if bestSource == nil || match.score > bestSource!.score {
                bestSource = (declaration, match.score)
            }
        }

        let importedScore = overloads.importedMethod?.signatures.compactMap {
            $0.match(arguments: arguments, in: self)?.score
        }.max()
        if let importedScore,
           let importedMethod = overloads.importedMethod,
           importedScore > (bestSource?.score ?? Int.min) {
            return .hostFunction(importedMethod)
        }
        if let declaration = bestSource?.declaration,
           let body = functionMetadata(for: declaration).body {
            let closure = makeFunctionClosure(
                declaration,
                body: body,
                captured: selfEnvironment(overloads.receiver))
            closure.extensionFrame = ExtensionFrame(
                typeName: overloads.typeName,
                member: functionMetadata(for: declaration).name)
            closure.functionDeclID = declaration.id
            return .closure(closure)
        }
        if let importedMethod = overloads.importedMethod,
           importedScore != nil || importedMethod.signatures.isEmpty {
            return .hostFunction(importedMethod)
        }
        let memberName = overloads.sourceMethods.first?.name.text
            ?? overloads.importedMethod?.name ?? "member"
        throw RuntimeError(
            message: "no matching source or imported overload for "
                + "'\(overloads.typeName).\(memberName)'")
    }

    func hostCandidates(for any: Any) -> [String] {
        var names: [String] = []
        if let registry, registry.isViewValue(.native(any)) { names.append("View") }
        if let typeName = registry?.hostTypeName(of: any) { names.append(typeName) }
        if let protocols = registry?.hostProtocolCandidates(of: any), !protocols.isEmpty {
            names.append(contentsOf: protocols)
        }
        // TYPED markers dispatch their minting type's user extensions
        // (`UNAuthorizationStatus.notDetermined.map`).
        if let call = any as? ImplicitMemberCall, let hint = call.typeHint {
            names.append(hint)
        }
        if any is String { names.append("String") }
        if any is Int { names.append("Int") }
        if any is Double { names.append("Double"); names.append("CGFloat") }
        if any is Bool { names.append("Bool") }
        if any is Date { names.append("Date") }
        // UIColor/NSColor statics absorb into SwiftUI Colors (the asset
        // doctrine) — user extensions of the UIKit faces still dispatch
        // on them (`UIColor.red.image(size)` test helpers).
        if names.contains("Color") {
            names.append("UIColor")
            names.append("NSColor")
        }
        if any is BindingStub { names.append("Binding") }
        if any is RuntimeTaskHandle {
            names.append("Task")
            names.append("Cancellable")
        }
        if any is DictValue { names.append("Dictionary") }
        if any is Data { names.append("Data") }
        if any is URL { names.append("URL") }
        if any is UUID { names.append("UUID") }
        if let range = any as? RuntimeRangeValue {
            switch (range.lowerBound, range.upperBound, range.includesUpperBound) {
            case (.some, .some, false): names.append("Range")
            case (.some, .some, true): names.append("ClosedRange")
            case (.some, nil, _): names.append("PartialRangeFrom")
            case (nil, .some, false): names.append("PartialRangeUpTo")
            case (nil, .some, true): names.append("PartialRangeThrough")
            default: break
            }
            names.append("RangeExpression")
        }
        if any is [RuntimeValue] {
            // `extension Array` and sugar-typed `extension [Item]` both apply.
            names.append("Array")
            names.append(contentsOf: hostExtensionSymbols.keys.filter { $0.hasPrefix("[") })
        }
        // Protocol umbrellas: `extension Collection { var isNotEmpty }`
        // applies to every conforming native (twostraws idiom).
        let integerRangeCollection = (any as? RuntimeRangeValue).map {
            $0.lowerBound?.intValue != nil && $0.upperBound?.intValue != nil
        } ?? false
        if any is [RuntimeValue] || any is String || any is DictValue || integerRangeCollection {
            names.append("Collection")
            names.append("Sequence")
        }
        if any is [RuntimeValue] || integerRangeCollection {
            names.append("RandomAccessCollection")
        }
        if any is [RuntimeValue] {
            names.append("MutableCollection")
            names.append("BidirectionalCollection")
        }
        if any is String { names.append("StringProtocol") }
        if any is Int { names.append("BinaryInteger"); names.append("Numeric") }
        if any is Double { names.append("FloatingPoint"); names.append("BinaryFloatingPoint") }
        return names
    }

    private func enumCaseMember(_ name: String, on value: EnumCaseValue) throws -> RuntimeValue? {
        if name == "hashValue" {
            // Synthesized Hashable: equal cases hash equal (name +
            // stringified payloads — deterministic under the tools'
            // SWIFT_DETERMINISTIC_HASHING re-exec).
            var hasher = Hasher()
            hasher.combine(value.symbol.name)
            hasher.combine(value.name)
            for payload in value.associated { hasher.combine(payload.stringified) }
            return .native(hasher.finalize())
        }
        if name == "rawValue" { return value.rawValue }
        if value.symbol.conformances.contains("CodingKey") {
            if name == "stringValue" {
                return .native(value.rawValue.stringValue ?? value.name)
            }
            if name == "intValue" {
                return .optional(
                    value.rawValue.intValue.map(RuntimeValue.native),
                    wrappedTypeName: "Int")
            }
        }
        if let overloads = value.symbol.methods[name], let first = overloads.first {
            // Overload sets never re-enter the running declaration
            // (IconDrawable's image(ofSize:color:) → edgeInsets form,
            // merged into the enum via its conformance extension).
            let method = overloads.count > 1
                ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? first)
                : first
            guard let body = functionMetadata(for: method).body else {
                return nil
            }
            let closure = makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumCase(value)))
            closure.functionDeclID = method.id
            return .closure(closure)
        }
        if let computed = value.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .enumCase(value), name: name)
        }
        // Protocol-extension members (`extension RawRepresentable where
        // Self: NotificationName { var name }`): the enum's conformances
        // (plus RawRepresentable itself for raw-valued enums) dispatch.
        var candidates = value.symbol.conformances + ["RawRepresentable"]
        candidates.removeAll { ["String", "Int", "Double", "Codable", "Hashable", "Equatable"].contains($0) }
        if let member = try hostExtensionMember(name, candidates: candidates, selfValue: .enumCase(value)) {
            return member
        }
        if name == "localizedDescription" {
            // Every Error carries this on device. Foundation consults
            // LocalizedError's errorDescription first, then falls back to
            // the NSError boilerplate.
            if let described = try enumCaseMember("errorDescription", on: value),
               let unwrapped = described.unwrappedOptionalOrSelf,
               let text = unwrapped.stringValue {
                return .native(text)
            }
            return .native("The operation couldn\u{2019}t be completed. (\(value.symbol.name) error.)")
        }
        return nil
    }

    /// Runs the best-matching user subscript getter.
    func callUserSubscriptGetter(on instance: Instance, with args: CallArguments) throws -> RuntimeValue {
        try runUserSubscriptGetter(instance.symbol, selfValue: .instance(instance), args: args)
    }

    /// Runs the user subscript setter with `newValue` and the index bound.
    func callUserSubscriptSetter(on instance: Instance, with args: CallArguments, newValue: RuntimeValue) throws {
        try runUserSubscriptSetter(instance.symbol, selfValue: .instance(instance), args: args, newValue: newValue)
    }

    /// Compares two generated Index-typed collection endpoints without
    /// naming either requirement in handwritten runtime dispatch.
    func interpretedIntegerIndexedCollectionEndpointsAreEqual(
        _ value: RuntimeValue,
        leftMemberName: String,
        rightMemberName: String
    ) throws -> Bool? {
        guard case .instance(let instance) = value,
              let left = try instanceMember(
                  leftMemberName, on: instance)?.intValue,
              let right = try instanceMember(
                  rightMemberName, on: instance)?.intValue
        else { return nil }
        return left == right
    }

    /// Materializes the protocol shape used by integer-indexed interpreted
    /// collections. The source compiler has already proved Sequence
    /// conformance; at runtime, readable `startIndex`/`endIndex` plus a
    /// one-argument subscript are the reusable capabilities needed by
    /// synchronous `for in` execution.
    func interpretedIntegerIndexedCollectionBounds(
        _ value: RuntimeValue
    ) throws -> Range<Int>? {
        guard case .instance(let instance) = value,
              !instance.symbol.subscripts.isEmpty,
              let start = try instanceMember(
                  "startIndex", on: instance)?.intValue,
              let end = try instanceMember(
                  "endIndex", on: instance)?.intValue,
              start <= end else {
            return nil
        }
        return start..<end
    }

    /// Resolve any integer RangeExpression against an interpreted
    /// collection's actual indices. Collection's generic range-expression
    /// subscript performs this projection before calling the conformer's
    /// required Range subscript.
    func interpretedIntegerIndexedCollectionRange(
        _ range: RuntimeRangeValue,
        relativeTo value: RuntimeValue
    ) throws -> RuntimeValue? {
        guard let bounds = try interpretedIntegerIndexedCollectionBounds(
            value) else {
            return nil
        }
        let lower: Int
        if let lowerValue = range.lowerBound {
            guard let provided = lowerValue.intValue else { return nil }
            lower = provided
        } else {
            lower = bounds.lowerBound
        }
        let upper: Int
        if let upperValue = range.upperBound {
            guard let provided = upperValue.intValue else { return nil }
            if range.includesUpperBound {
                let incremented = provided.addingReportingOverflow(1)
                guard !incremented.overflow else { return nil }
                upper = incremented.partialValue
            } else {
                upper = provided
            }
        } else {
            upper = bounds.upperBound
        }
        return .native(RuntimeRangeValue(
            lowerBound: .native(lower),
            upperBound: .native(upper)))
    }

    func interpretedIntegerIndexedCollectionElements(
        _ value: RuntimeValue
    ) throws -> [RuntimeValue]? {
        guard case .instance(let instance) = value,
              let bounds = try interpretedIntegerIndexedCollectionBounds(
                  value) else {
            return nil
        }
        let probe = CallArguments(arguments: [
            .init(label: nil, value: .native(bounds.lowerBound)),
        ])
        let member = try userSubscriptMember(
            in: instance.symbol, args: probe)
        var elements: [RuntimeValue] = []
        elements.reserveCapacity(bounds.count)
        for index in bounds {
            let arguments = CallArguments(arguments: [
                .init(label: nil, value: .native(index)),
            ])
            elements.append(try runUserSubscriptGetter(
                member,
                symbolName: instance.symbol.name,
                selfValue: value,
                args: arguments))
        }
        return elements
    }

    /// Materializes a runtime collection without naming its concrete API.
    /// Native carriers use their stored elements; interpreted collections use
    /// the same integer-indexed protocol shape as generated defaults and
    /// `for in` execution.
    func materializedCollectionElements(
        _ value: RuntimeValue
    ) throws -> [RuntimeValue]? {
        if let array = value.arrayValue { return array }
        if let set = value.setValue { return set.elements }
        if let string = value.stringValue {
            return string.map { .native(String($0)) }
        }
        if let range = value.rangeValue {
            return range.integerValues()
        }
        return try interpretedIntegerIndexedCollectionElements(value)
    }

    /// The symbol whose user subscripts serve `base`: an interpreted
    /// instance's own, or — for host values — the EXTENSION symbol under
    /// the value's host type name (clean-architecture's
    /// `extension Store { subscript(keyPath:) }` on CurrentValueSubject).
    func userSubscriptOwner(for base: RuntimeValue) -> (StructSymbol, RuntimeValue)? {
        if case .instance(let instance) = base, !instance.symbol.subscripts.isEmpty {
            return (instance.symbol, base)
        }
        if case .host(let any) = base,
           let typeName = registry?.hostTypeName(of: any),
           let extensionSymbol = hostExtensionSymbols[typeName],
           !extensionSymbol.subscripts.isEmpty {
            return (extensionSymbol, base)
        }
        return nil
    }

    func runUserSubscriptGetter(
        _ symbol: StructSymbol, selfValue: RuntimeValue, args: CallArguments
    ) throws -> RuntimeValue {
        let member = try userSubscriptMember(
            in: symbol, args: args)
        return try runUserSubscriptGetter(
            member,
            symbolName: symbol.name,
            selfValue: selfValue,
            args: args)
    }

    func userSubscriptMember(
        in symbol: StructSymbol, args: CallArguments
    ) throws -> StructSymbol.SubscriptMember {
        let arityMatches = symbol.subscripts.filter {
            $0.parameters.count == args.arguments.count
        }
        let shaped = arityMatches.isEmpty ? symbol.subscripts : arityMatches
        guard let member = matchingUserSubscriptMember(
            in: symbol, args: args) ?? shaped.first else {
            throw RuntimeError(message: "'\(symbol.name)' has no subscript")
        }
        return member
    }

    func matchingUserSubscriptMember(
        in symbol: StructSymbol, args: CallArguments
    ) -> StructSymbol.SubscriptMember? {
        let arityMatches = symbol.subscripts.filter {
            $0.parameters.count == args.arguments.count
        }
        let shaped = arityMatches.isEmpty ? symbol.subscripts : arityMatches
        return shaped.first {
            runtimeArgumentsFitDeclaredTypes(
                $0.parameters, args: args, lexicalOwner: symbol)
        }
    }

    func runUserSubscriptGetter(
        _ member: StructSymbol.SubscriptMember,
        symbolName: String,
        selfValue: RuntimeValue,
        args: CallArguments
    ) throws -> RuntimeValue {
        if member.isAsync && evaluationTaskContext.isAsyncSession {
            throw RuntimeError(
                message: "async subscript getter on '\(symbolName)' requires "
                    + "an awaited suspending entry",
                fatal: true)
        }
        return try withUserSubscriptContext(
            member, selfValue: selfValue, symbolName: symbolName
        ) { env in
            let closure = ClosureValue(
                parameters: member.parameters,
                body: member.getter,
                captured: env,
                returnTypeName: member.resultTypeName,
                programMetadata: currentProgramMetadata,
                programPlan: currentProgramPlan)
            closure.programState = currentProgramState
            return try callWithArguments(closure, args: args, node: nil)
        }
    }

    func runUserSubscriptGetterSuspending(
        _ member: StructSymbol.SubscriptMember,
        symbolName: String,
        selfValue: RuntimeValue,
        args: CallArguments
    ) async throws -> RuntimeValue {
        try await withUserSubscriptContextSuspending(
            member, selfValue: selfValue, symbolName: symbolName
        ) { env in
            let closure = ClosureValue(
                parameters: member.parameters,
                body: member.getter,
                captured: env,
                returnTypeName: member.resultTypeName,
                programMetadata: currentProgramMetadata,
                programPlan: currentProgramPlan)
            closure.programState = currentProgramState
            return try await callWithArgumentsSuspending(
                closure, args: args, node: nil)
        }
    }

    func runUserSubscriptSetter(
        _ symbol: StructSymbol, selfValue: RuntimeValue, args: CallArguments, newValue: RuntimeValue
    ) throws {
        let member = try userSubscriptMember(
            in: symbol, args: args)
        try runUserSubscriptSetter(
            member,
            symbolName: symbol.name,
            selfValue: selfValue,
            args: args,
            newValue: newValue)
    }

    private func runUserSubscriptSetter(
        _ member: StructSymbol.SubscriptMember,
        symbolName: String,
        selfValue: RuntimeValue,
        args: CallArguments,
        newValue: RuntimeValue
    ) throws {
        guard let setter = member.setter else {
            throw RuntimeError(message: "subscript on '\(symbolName)' is get-only")
        }
        try withUserSubscriptContext(
            member, selfValue: selfValue, symbolName: symbolName
        ) { env in
            for (parameter, argument) in zip(
                member.parameters, args.arguments
            ) {
                env.define(
                    parameter.name,
                    try resolveAnnotated(
                        argument.value, parameter: parameter))
            }
            env.define(setter.parameterName, newValue)
            _ = try executeBlock(setter.body, in: env)
        }
    }

    private func withAccessorContext<T>(
        declarationID: SyntaxIdentifier?,
        sourcePosition: AbsolutePosition,
        executor calleeExecutor: RuntimeExecutorKind?,
        selfValue: RuntimeValue,
        name: String,
        _ operation: (Environment) throws -> T
    ) throws -> T {
        let programState = accessorProgramState(
            declarationID: declarationID, selfValue: selfValue)
        evaluationTaskContext.enterProgramState(programState)
        defer { evaluationTaskContext.leaveProgramState(programState) }
        let sourceMetadata = programState?.programPlan?.metadata
            ?? currentProgramMetadata
        let sourceModuleName = sourceMetadata?.sourceModuleName(
            at: sourcePosition)
        let sourceImportedModuleNames = sourceMetadata?
            .sourceImportedModuleNames(at: sourcePosition)
        let sourceFileIdentity = sourceMetadata?.sourceFileIdentity(
            at: sourcePosition)
        lexicalSourceModuleFrames.append(sourceModuleName)
        lexicalSourceImportFrames.append(sourceImportedModuleNames)
        lexicalSourceFileFrames.append(sourceFileIdentity)
        defer {
            lexicalSourceFileFrames.removeLast()
            lexicalSourceImportFrames.removeLast()
            lexicalSourceModuleFrames.removeLast()
        }
        let previousExecutor = evaluationTaskContext.currentExecutor
        if let calleeExecutor {
            evaluationTaskContext.currentExecutor = calleeExecutor
            lexicalExecutorFrames.append(calleeExecutor)
        }
        defer {
            if calleeExecutor != nil {
                lexicalExecutorFrames.removeLast()
            }
            evaluationTaskContext.currentExecutor = previousExecutor
        }
        try requireSynchronousActorInvocationAccess(to: calleeExecutor)

        callDepth += 1
        defer { callDepth -= 1 }
        guard callDepth < callDepthLimit else {
            throw RuntimeError(message: "call depth exceeded evaluating '\(name)' (possible infinite recursion)", fatal: true)
        }

        var pushedLexicalOwner = false
        if let declarationID,
           let owner = programState?.declarationLexicalOwners[declarationID]
                ?? lexicalOwner(of: declarationID) {
            lexicalOwnerFrames.append(owner)
            pushedLexicalOwner = true
        }
        defer { if pushedLexicalOwner { lexicalOwnerFrames.removeLast() } }
        let env = selfEnvironment(selfValue)
        return try operation(env)
    }

    private func withComputedPropertyContext<T>(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String,
        _ operation: (Environment) throws -> T
    ) throws -> T {
        let executor: RuntimeExecutorKind?
        if case .instance(let instance) = selfValue {
            executor = try resolvedExecutor(for: computed, on: instance)
        } else {
            executor = nil
        }
        return try withAccessorContext(
            declarationID: computed.declarationID,
            sourcePosition: computed.accessor.positionAfterSkippingLeadingTrivia,
            executor: executor,
            selfValue: selfValue,
            name: name,
            operation)
    }

    /// Host-driven property reads can outlive the evaluator entry that made
    /// their receiver. The receiver retains its exact program capability, so
    /// accessor lookup must recover declaration and source-module provenance
    /// from that capability instead of whichever facade run is current.
    private func accessorProgramState(
        declarationID: SyntaxIdentifier?, selfValue: RuntimeValue
    ) -> RuntimeProgramState? {
        let receiverState: RuntimeProgramState?
        if case .instance(let instance) = selfValue {
            receiverState = instance.programState
        } else {
            receiverState = nil
        }
        if let declarationID,
           let owningState = receiverState?.stateOwningDeclaration(
               declarationID) {
            return owningState
        }
        return receiverState ?? programStateOwningDeclaration(declarationID)
    }

    private func withAccessorContextSuspending<T>(
        declarationID: SyntaxIdentifier?,
        sourcePosition: AbsolutePosition,
        executor calleeExecutor: RuntimeExecutorKind?,
        selfValue: RuntimeValue,
        name: String,
        _ operation: (Environment) async throws -> T
    ) async throws -> T {
        let programState = accessorProgramState(
            declarationID: declarationID, selfValue: selfValue)
        evaluationTaskContext.enterProgramState(programState)
        defer { evaluationTaskContext.leaveProgramState(programState) }
        let sourceMetadata = programState?.programPlan?.metadata
            ?? currentProgramMetadata
        lexicalSourceModuleFrames.append(
            sourceMetadata?.sourceModuleName(at: sourcePosition))
        lexicalSourceImportFrames.append(
            sourceMetadata?.sourceImportedModuleNames(at: sourcePosition))
        lexicalSourceFileFrames.append(
            sourceMetadata?.sourceFileIdentity(at: sourcePosition))
        defer {
            lexicalSourceFileFrames.removeLast()
            lexicalSourceImportFrames.removeLast()
            lexicalSourceModuleFrames.removeLast()
        }
        let previousExecutor = evaluationTaskContext.currentExecutor
        if let calleeExecutor {
            evaluationTaskContext.currentExecutor = calleeExecutor
            lexicalExecutorFrames.append(calleeExecutor)
        }
        defer {
            if calleeExecutor != nil {
                lexicalExecutorFrames.removeLast()
            }
            evaluationTaskContext.currentExecutor = previousExecutor
        }
        try requireSynchronousActorInvocationAccess(to: calleeExecutor)

        callDepth += 1
        defer { callDepth -= 1 }
        guard callDepth < callDepthLimit else {
            throw RuntimeError(
                message: "call depth exceeded evaluating '\(name)' "
                    + "(possible infinite recursion)",
                fatal: true)
        }

        var pushedLexicalOwner = false
        if let declarationID,
           let owner = programState?.declarationLexicalOwners[declarationID]
                ?? lexicalOwner(of: declarationID) {
            lexicalOwnerFrames.append(owner)
            pushedLexicalOwner = true
        }
        defer { if pushedLexicalOwner { lexicalOwnerFrames.removeLast() } }

        return try await operation(selfEnvironment(selfValue))
    }

    private func withComputedPropertyContextSuspending<T>(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String,
        _ operation: (Environment) async throws -> T
    ) async throws -> T {
        let executor: RuntimeExecutorKind?
        if case .instance(let instance) = selfValue {
            executor = try resolvedExecutor(for: computed, on: instance)
        } else {
            executor = nil
        }
        return try await withAccessorContextSuspending(
            declarationID: computed.declarationID,
            sourcePosition: computed.accessor.positionAfterSkippingLeadingTrivia,
            executor: executor,
            selfValue: selfValue,
            name: name,
            operation)
    }

    private func withUserSubscriptContext<T>(
        _ member: StructSymbol.SubscriptMember,
        selfValue: RuntimeValue,
        symbolName: String,
        _ operation: (Environment) throws -> T
    ) throws -> T {
        let executor: RuntimeExecutorKind?
        if case .instance(let instance) = selfValue {
            executor = try resolvedExecutor(for: member, on: instance)
        } else {
            executor = nil
        }
        return try withAccessorContext(
            declarationID: member.declarationID,
            sourcePosition: member.getter.positionAfterSkippingLeadingTrivia,
            executor: executor,
            selfValue: selfValue,
            name: "\(symbolName).subscript",
            operation)
    }

    private func withUserSubscriptContextSuspending<T>(
        _ member: StructSymbol.SubscriptMember,
        selfValue: RuntimeValue,
        symbolName: String,
        _ operation: (Environment) async throws -> T
    ) async throws -> T {
        let executor: RuntimeExecutorKind?
        if case .instance(let instance) = selfValue {
            executor = try resolvedExecutor(for: member, on: instance)
        } else {
            executor = nil
        }
        return try await withAccessorContextSuspending(
            declarationID: member.declarationID,
            sourcePosition: member.getter.positionAfterSkippingLeadingTrivia,
            executor: executor,
            selfValue: selfValue,
            name: "\(symbolName).subscript",
            operation)
    }

    func evaluateComputed(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String
    ) throws -> RuntimeValue {
        if let failure = computed.unsupportedCoroutineReadError {
            throw failure
        }
        if computed.isAsync && evaluationTaskContext.isAsyncSession {
            throw RuntimeError(
                message: "async computed property '\(name)' requires an "
                    + "awaited suspending entry",
                fatal: true)
        }
        return try withComputedPropertyContext(
            computed, selfValue: selfValue, name: name
        ) { env in
            if computed.isBuilder {
                let views = try collectBuilderViews(computed.accessor, in: env)
                return try groupViews(views)
            }
            if let prepared = preparedScalarAccessor(
                    computed, captured: env),
               let value = try prepared.execute(
                    arguments: [], receiver: selfValue,
                    interpreter: self) {
                if let typeName = computed.typeName,
                   RuntimeOptionalValue.wrappedType(in: typeName) != nil {
                    return try resolveAnnotated(value, typeName: typeName)
                }
                return value
            }
            let result = try executeBlock(computed.accessor, in: env)
            switch result {
            case .normal(let value), .returnValue(let value):
                if let typeName = computed.typeName,
                   RuntimeOptionalValue.wrappedType(in: typeName) != nil {
                    return try resolveAnnotated(value, typeName: typeName)
                }
                // Keep contextual markers lazy. Receiver operations that
                // require the concrete type (notably user subscripts) resolve
                // this value against the annotation at their dispatch boundary.
                // A HINTLESS marker can never resolve downstream, though —
                // carry the property's declared type with it
                // (`var title: LocalizedStringKey { .init(name) }`).
                if case .host(let any) = value, let call = any as? ImplicitMemberCall,
                   call.typeHint == nil,
                   let typeName = computed.typeName {
                    return .native(ImplicitMemberCall(
                        name: call.name, arguments: call.arguments, typeHint: typeName))
                }
                return value
            default:
                throw RuntimeError(message:
                    "control flow escaped computed property '\(name)'")
            }
        }
    }

    /// `View.body` inherits SwiftUI's result builder from the protocol even
    /// when the concrete witness omits an explicit `@ViewBuilder`. Keep that
    /// protocol-supplied semantic while entering the ordinary accessor
    /// context for isolation, owning program state, and file imports.
    func evaluateComputedViewBody(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String
    ) throws -> RuntimeValue {
        if let failure = computed.unsupportedCoroutineReadError {
            throw failure
        }
        if computed.isAsync && evaluationTaskContext.isAsyncSession {
            throw RuntimeError(
                message: "async computed property '\(name)' requires an "
                    + "awaited suspending entry",
                fatal: true)
        }
        return try withComputedPropertyContext(
            computed, selfValue: selfValue, name: name
        ) { env in
            if computed.isBuilder {
                let views = try collectBuilderViews(computed.accessor, in: env)
                return try groupViews(views)
            }
            let result = try executeBlock(computed.accessor, in: env)
            switch result {
            case .normal(let value), .returnValue(let value):
                return try groupViewValue(value)
            case .breakLoop, .continueLoop:
                throw RuntimeError(message:
                    "control flow escaped computed property '\(name)'")
            }
        }
    }

    func evaluateComputedBodySuspending(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String
    ) async throws -> RuntimeValue {
        if let failure = computed.unsupportedCoroutineReadError {
            throw failure
        }
        return try await withComputedPropertyContextSuspending(
            computed, selfValue: selfValue, name: name
        ) { env in
            guard !computed.isBuilder else {
                throw RuntimeError(
                    message: "async result-builder computed property "
                        + "'\(name)' is not supported",
                    fatal: true)
            }
            let result = try await executeBlockSuspending(
                computed.accessor, in: env)
            switch result {
            case .normal(let value), .returnValue(let value):
                if let typeName = computed.typeName,
                   RuntimeOptionalValue.wrappedType(in: typeName) != nil {
                    return try resolveAnnotated(value, typeName: typeName)
                }
                return value
            default:
                throw RuntimeError(message:
                    "control flow escaped computed property '\(name)'")
            }
        }
    }

    func assignComputed(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String,
        value: RuntimeValue
    ) throws {
        if let failure = computed.unsupportedCoroutineModifyError {
            throw failure
        }
        guard let setter = computed.setter else {
            throw EvalMessage(text:
                "cannot assign to get-only property '\(name)'")
        }
        try withComputedPropertyContext(
            computed, selfValue: selfValue, name: name
        ) { env in
            env.define(setter.parameterName, value)
            _ = try executeBlock(setter.body, in: env)
        }
    }

    func groupViews(_ views: [RuntimeValue]) throws -> RuntimeValue {
        if views.count == 1 { return views[0] }
        guard let registry else {
            throw RuntimeError(message: "no host registry configured")
        }
        return try registry.makeGroup(views)
    }

    /// A non-builder View witness still returns a View value. Normalize that
    /// selected value through the same structural conversion used for each
    /// builder expression so an interpreted child becomes host-renderable.
    func groupViewValue(_ value: RuntimeValue) throws -> RuntimeValue {
        var views: [RuntimeValue] = []
        appendViewValue(value, to: &views)
        return try groupViews(views)
    }

    func accessMember(
        _ name: String,
        on baseValue: RuntimeValue,
        node: some SyntaxProtocol,
        env: Environment,
        deferringAsyncHostProperty: Bool = false,
        declaredTypeName: String? = nil
    ) throws -> RuntimeValue {
        let declaredBaseTypeName = declaredTypeName
            ?? Syntax(node).as(MemberAccessExprSyntax.self)?.base.flatMap {
                declaredMemberReceiverTypeName(
                    for: $0, in: env, evaluatedValue: baseValue)
            }
        if name == "self" {
            return baseValue // `SizeKey.self`, `x.self` — the value itself
        }
        switch baseValue {
        case .nilValue:
            // Ecosystem Optional truths (swift-extras): nil knows it's nil.
            if name == "isNil" { return .native(true) }
            if name == "isSome" || name == "isNotNil" { return .native(false) }
            // User extensions on Optional (`var isNil: Bool { self == nil }`)
            // dispatch with self = nil before nil-propagation.
            if let optionalExtension = hostExtensionSymbols["Optional"] {
                if let computed = optionalExtension.computedProperties[name] {
                    return try evaluateComputed(computed, selfValue: .nilValue, name: name)
                }
                if let overloads = optionalExtension.methods[name], let method = overloads.first,
                   let body = functionMetadata(for: method).body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.nilValue)))
                }
            }
            // Optional chaining: member access on an untyped nil becomes an
            // explicit Optional.none at the first semantic operation.
            return .none()

        case .optional(let optional):
            // Source extensions on Optional receive the wrapper as `self`.
            if let optionalExtension = hostExtensionSymbols["Optional"] {
                if let computed = optionalExtension.computedProperties[name] {
                    return try evaluateComputed(
                        computed, selfValue: baseValue, name: name)
                }
                if let overloads = optionalExtension.methods[name],
                   let method = chooseFunction(
                       from: overloads, for: CallArguments()) ?? overloads.first,
                   let body = functionMetadata(for: method).body {
                    return .closure(makeFunctionClosure(
                        method, body: body,
                        captured: selfEnvironment(baseValue)))
                }
            }
            if let member = optionalMember(name, optional) { return member }

            let explicitlyChained = Syntax(node).as(MemberAccessExprSyntax.self)?
                .base?.is(OptionalChainingExprSyntax.self) == true
            // Any other member reached through `?.`: none propagates; some
            // dispatches onto the payload and flattens the chain's result.
            // An implicitly-unwrapped Optional uses the payload directly
            // when no `?` appears at this access site.
            guard let wrapped = optional.wrapped else {
                if optional.isImplicitlyUnwrapped && !explicitlyChained {
                    // Whole-project verification invokes every recorded
                    // action, including controls that are disabled because
                    // their imported/IUO payload is unavailable headlessly.
                    // Keep strict standalone interpretation trapping, but
                    // let compiled-import artifact mode preserve its existing
                    // absorbing boundary instead of inventing a payload.
                    if assumesCompiledImports { return .none() }
                    throw error(node, "unexpectedly found nil while implicitly unwrapping")
                }
                return .none()
            }
            let member = try accessMember(
                name,
                on: wrapped,
                node: node,
                env: env,
                deferringAsyncHostProperty: deferringAsyncHostProperty,
                declaredTypeName: optional.wrappedTypeName)
            if optional.isImplicitlyUnwrapped && !explicitlyChained {
                return member
            }
            switch member {
            case .closure, .hostFunction:
                let callSite = Syntax(node)
                return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                    guard let self else {
                        throw RuntimeError(message: "interpreter gone")
                    }
                    return try self.invoke(member, with: args, node: callSite)
                        .liftedToOptional()
                })
            default:
                return member.liftedToOptional()
            }

        case .instance(let instance):
            // `self.init(…)` — delegating initializers run another init on
            // the SAME instance (convenience inits). A failable delegate
            // that returns nil fails the WHOLE init (sentinel unwinds to
            // runInitializer, which reports nil).
            if name == "init", !instance.symbol.initializers.isEmpty {
                return .hostFunction(HostFunction(name: "init") { [weak self] args, _ in
                    guard let self else { throw RuntimeError(message: "interpreter gone") }
                    // The RUNNING init never re-enters itself: extension
                    // convenience inits delegate to the memberwise form.
                    let available = instance.symbol.initializers.filter {
                        !self.activeInitializers.contains($0.id)
                    }
                    if self.chooseInitializerStrict(from: available, for: args) == nil,
                       available.count < instance.symbol.initializers.count {
                        let propertyNames = Set(self.inheritedStoredProperties(of: instance.symbol).map(\.name))
                        let labels = args.arguments.compactMap(\.label)
                        if !labels.isEmpty, labels.allSatisfy({ propertyNames.contains($0) }) {
                            for argument in args.arguments {
                                guard let label = argument.label else { continue }
                                if let box = instance.box(for: label) {
                                    box.value = argument.value.copiedForValueSemantics()
                                } else {
                                    instance.properties[label] = Box(
                                        argument.value.copiedForValueSemantics())
                                }
                            }
                            return .void
                        }
                    }
                    guard let chosen = self.chooseInitializerStrict(
                        from: available, for: args) else {
                        // No interpreted candidate: `self.init(window:)`
                        // delegates to a HOST superclass's designated init —
                        // labeled args bind as properties (iter-93 rule).
                        // A blind fallback here self-delegates forever.
                        for argument in args.arguments {
                            guard let label = argument.label else { continue }
                            instance.properties[label] = Box(
                                argument.value.copiedForValueSemantics())
                        }
                        return .void
                    }
                    let outcome = try self.runInitializer(
                        chosen, on: instance, args: args, node: nil)
                    if outcome.isNil {
                        throw RuntimeError(message: Interpreter.initFailedSentinel)
                    }
                    // A struct initializer may replace `self` while assigning
                    // through value-semantic lvalues. Delegation commits that
                    // final value into the CALLER's initialization frame;
                    // the old reference-backed representation made this
                    // propagation happen accidentally through aliasing.
                    if case .instance = outcome,
                       let callerSelf = env.box(for: "self") {
                        callerSelf.value = outcome
                    }
                    return .void
                })
            }
            if let value = try instanceMember(
                name, on: instance, preferHostSuperclassProperty: true
            ) {
                // A nil STORED closure sharing a modifier's name
                // (`.onSubmit { }` on a Representable declaring
                // `var onSubmit: (() -> Void)?`): real overload resolution
                // can't call nil — the registry modifier applies.
                if value.isNil, instance.symbol.rendersLikeView,
                   let property = instance.symbol.storedProperty(named: name),
                   property.typeName?.contains("->") == true,
                   let registry, let modifier = registry.modifier(named: name) {
                    let wrapped = registry.makeRenderable(instance: instance, interpreter: self)
                    return .hostFunction(HostFunction(name: name) { args, ctx in
                        try modifier.apply(wrapped, args, ctx)
                    })
                }
                return value
            }
            // A modifier applied to an interpreted View (or Shape — the
            // registry wraps those shape-typed, so .fill/.stroke/.trim see a
            // shape): wrap it renderable first.
            if instance.symbol.rendersLikeView
                || instance.symbol.conformsToShape || instance.symbol.conformsToLayout,
               let registry,
               let modifier = registry.modifier(named: name) {
                let wrapped = registry.makeRenderable(instance: instance, interpreter: self)
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(wrapped, args, ctx)
                })
            }
            if assumesCompiledImports {
                // Compiled sources: an unknown member that survived every
                // dispatch (own, inherited, protocol extensions) is an
                // UNMERGED extension — absorbs.
                return .native(ChainedImplicitCall(
                    base: baseValue, member: name, arguments: CallArguments()))
            }
            throw error(node, "'\(instance.symbol.name)' has no member '\(name)'")

        case .enumCase(let value):
            if let member = try enumCaseMember(name, on: value) { return member }
            throw error(node, "'\(value.symbol.name).\(value.name)' has no member '\(name)'")

        case .enumType(let symbol):
            if let caseInfo = symbol.caseInfo(named: name) {
                if caseInfo.hasAssociatedValues {
                    return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                        guard let self else {
                            throw RuntimeError(message: "interpreter gone")
                        }
                        let associated = try zip(
                            args.arguments.map(\.value),
                            caseInfo.associatedTypeNames
                        ).map { value, typeName in
                            try self.resolveAnnotated(value, typeName: typeName)
                        }
                        return .enumCase(EnumCaseValue(
                            symbol: symbol, name: name,
                            associated: associated))
                    })
                }
                return .enumCase(EnumCaseValue(symbol: symbol, name: name))
            }
            if name == "allCases",
               symbol.staticComputedProperties["allCases"] == nil,
               symbol.staticMethods["allCases"]?.contains(where: { method in
                   !functionMetadata(for: method).parameters.contains {
                       $0.defaultValue == nil
                   }
               }) != true {
                // SYNTHESIZED CaseIterable for BARE references — an argful
                // `static func allCases(for:)` overload dispatches at CALL
                // sites (below), while its body's bare `allCases` still
                // reads the synthesized array (the property/method
                // collision rule, static flavor).
                let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                    RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
                }
                return .native(all)
            }
            if let value = try staticMember(name, of: symbol) {
                return value
            }
            // An interpreted enum SHADOWING a host type (home-assistant's
            // design-token `Color` vs SwiftUI.Color): statics the enum
            // doesn't declare cross the module boundary to the host.
            if let member = try readHostMember(
                name,
                on: HostTypeMarker(name: symbol.name),
                deferringAsyncProperty: deferringAsyncHostProperty) {
                return member
            }
            if assumesCompiledImports, name.first?.isUppercase == true,
               symbol.attributeNames.contains(where: { $0.first?.isUppercase == true }) {
                // MACRO-ATTRIBUTED enums (@Reducer) generate nested types
                // the merge can't see (State/Action): an absorbing type
                // marker. Plain enums keep the fast throw — launch-hook
                // tolerance depends on it.
                return .native(HostTypeMarker(name: "\(symbol.name).\(name)"))
            }
            throw error(node, "'\(symbol.name)' has no case or static member '\(name)'")

        case .type(let symbol):
            if name == "init" {
                return baseValue // `Self.init(...)` ≡ `Self(...)`
            }
            if let nested = symbol.nestedTypes[name] {
                return nested
            }
            if let value = try staticMember(name, of: symbol) {
                return value
            }
            // Vendored types sharing a host type's name (Lottie's `struct
            // Color`): the miss falls through to the bridge's statics
            // (Color.black) or the gateway-boundary implicit member.
            if registry?.constructor(named: symbol.name) != nil {
                if let value = try readHostMember(
                    name,
                    on: HostTypeMarker(name: symbol.name),
                    deferringAsyncProperty: deferringAsyncHostProperty) {
                    return value
                }
                return .implicitMember(name)
            }
            throw error(node, "'\(symbol.name)' has no static member '\(name)'")

        case .implicitMember:
            // View modifiers on color-shaped bases (`Color.black.ignoresSafeArea()`)
            // route to the modifier table; `opacity`/`gradient` stay opaque
            // chains because they're style transforms, not view modifiers here.
            if name != "opacity", name != "gradient",
               let registry, registry.isViewValue(baseValue),
               let modifier = registry.modifier(named: name) {
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(baseValue, args, ctx)
                })
            }
            // `.blue.opacity(0.2)` / `.blue.gradient` — keep the chain opaque
            // for gateways. Calling the result refines the arguments.
            return .native(ChainedImplicitCall(base: baseValue, member: name, arguments: CallArguments()))

        case .hostFunction(let function):
            if name == "init" {
                return baseValue // `NSNumber.init(value:)` ≡ `NSNumber(value:)`
            }
            if function.name == "AsyncStream" || function.name == "AsyncThrowingStream",
               name == "makeStream" {
                return .hostFunction(sourceAsyncStreamMakeStreamFunction(
                    throwing: function.name == "AsyncThrowingStream"))
            }
            if function.name == "Task" {
                switch GeneratedConcurrencySurface.taskStaticIntrinsic(
                    memberName: name
                ) {
                case .detached:
                    return .hostFunction(HostFunction(name: name) { args, context in
                        guard args.labeled("executorPreference") == nil else {
                            throw RuntimeError(message:
                                "Task.detached(executorPreference:) is declared "
                                + "by the active _Concurrency.swiftinterface "
                                + "but is not supported yet")
                        }
                        guard let body = args.firstUnlabeledClosure
                                ?? args.closure(labeled: "operation") else {
                            throw RuntimeError(
                                message: "Task.detached needs an operation closure")
                        }
                        let priority = try RuntimeTaskPriority.sourceValue(
                            args.labeled("priority"))
                        if let sourceName = args.labeled("name") {
                            return try context.spawnDetachedTask(
                                body,
                                arguments: [],
                                name: try RuntimeTaskName.sourceValue(sourceName),
                                priority: priority)
                        }
                        return try context.spawnDetachedTask(
                            body,
                            arguments: [],
                            priority: priority)
                    })
                case .immediate:
                    return sourceImmediateTaskMember(
                        name: name, contextInheritance: .inherited)
                case .immediateDetached:
                    return sourceImmediateTaskMember(
                        name: name, contextInheritance: .detached)
                case .currentPriority:
                    return .native(evaluationTaskContext.priority)
                case .isCancelled:
                    let isCancelled = isSourceTaskCancellationRequested()
                    if isCancelled { observeSourceCancellation() }
                    return .native(isCancelled)
                case .name:
                    let name = evaluationTaskContext.runtimeTaskID.flatMap {
                        concurrencyRuntime.records[$0]?.name
                    }
                    return .optional(
                        name.map(RuntimeValue.string),
                        wrappedTypeName: "String")
                case .checkCancellation:
                    return .hostFunction(HostFunction(name: name) { _, _ in
                        try self.checkSourceTaskCancellation()
                        return .void
                    })
                case .sleep:
                    if evaluationTaskContext.isAsyncSession {
                        return .hostFunction(sourceTaskSleepFunction())
                    }
                case .yield:
                    if evaluationTaskContext.isAsyncSession {
                        return .hostFunction(sourceTaskYieldFunction())
                    }
                case nil:
                    if GeneratedConcurrencySurface.knowsTaskStaticMember(name) {
                        throw RuntimeError(message:
                            "Task.\(name) is declared by the active "
                            + "_Concurrency.swiftinterface but is not supported yet")
                    }
                }
            }
            // Host TYPE names (Color, UIScreen, …) resolve to constructor
            // functions. The bridge may serve real statics (UIScreen.main);
            // user extensions add more (`extension ChatClient { static var
            // shared }`); otherwise they act like implicit members resolved
            // against the expected type at the gateway boundary.
            // MODULE-qualified globals (`Swift.max`) — the catch-all ctor
            // claimed the module name; strip the qualifier. Declared types
            // fall through (the qualifier asks for the FRAMEWORK's symbol).
            if let global = moduleQualifiedGlobal(
                named: name, moduleName: function.name) {
                return global
            }
            // Program extensions SHADOW imported statics — `extension Date {
            // static var now }` wins over Foundation's own, exactly like a
            // same-module declaration beats an import in compiled Swift
            // (the FoodTruck frozen-clock harness rides this). Static
            // METHOD sets defer overload choice to INVOKE time.
            if let symbol = hostExtensionSymbols[function.name] {
                if let dispatcher = hostExtensionStaticMethodDispatcher(
                    name, hostSymbol: symbol, typeName: function.name) {
                    return dispatcher
                }
                if let value = try staticMember(name, of: symbol) {
                    return value
                }
            }
            if let value = try readHostMember(
                name,
                on: HostTypeMarker(
                    name: function.name,
                    genericArguments: function.genericArguments),
                deferringAsyncProperty: deferringAsyncHostProperty) {
                return value
            }
            // An imported nested nominal is interface-proven. It must beat
            // the open-ended typed marker used to resolve otherwise unknown
            // static members on a source-extended host type.
            if let importedType = registry?.importedNestedTypeName(
                for: "\(function.name).\(name)"
            ) {
                return .native(HostTypeMarker(
                    name: importedType))
            }
            // The program EXTENDS this host type: mint a TYPED marker so the
            // extension's instance members dispatch on it
            // (`UNAuthorizationStatus.notDetermined.map`).
            if hostExtensionSymbols[function.name] != nil {
                return .native(ImplicitMemberCall(
                    name: name, arguments: CallArguments(), typeHint: function.name))
            }
            return .implicitMember(name)

        case .int, .double, .bool, .string, .array, .set, .dictionary, .tuple, .range, .host:
            // Core values and opaque hosts share the extension/gateway tail,
            // but standard-library dispatch receives the typed RuntimeValue
            // before any compatibility boxing occurs. (See
            // hostExtensionStaticMethodDispatcher below for static METHODS
            // of extended host types.)
            let any = baseValue.hostPayload!
            if let member = runtimeContinuationMember(name, on: any) {
                return member
            }
            if let member = runtimeAsyncStreamMember(name, on: any) {
                return member
            }
            if let projection = any as? RuntimeTaskLocalProjection {
                if name == "get" {
                    return .hostFunction(HostFunction(
                        name: name,
                        invoke: { arguments, context in
                            guard arguments.isEmpty else {
                                throw RuntimeError(message:
                                    "TaskLocal.get does not accept arguments")
                            }
                            return (context.taskLocalValue(for: projection.key)
                                ?? projection.defaultValue)
                                .copiedForValueSemantics()
                        }))
                }
                guard name == "withValue" else {
                    throw error(
                        node,
                        "TaskLocal projection has no member '\(name)'")
                }
                return .hostFunction(HostFunction(
                    name: name,
                    invoke: { arguments, context in
                        guard let value = arguments.positional(0)
                                ?? arguments.labeled("value"),
                              let operation = arguments.closure(
                                labeled: "operation")
                                ?? arguments.firstUnlabeledClosure else {
                            throw RuntimeError(message:
                                "TaskLocal.withValue requires a value and operation")
                        }
                        return try context.withTaskLocalValue(
                            value,
                            for: projection.key,
                            operation: operation,
                            arguments: [])
                    },
                    tracksHostOperation: false,
                    asyncInvoke: { arguments, context in
                        guard let value = arguments.positional(0)
                                ?? arguments.labeled("value"),
                              let operation = arguments.closure(
                                labeled: "operation")
                                ?? arguments.firstUnlabeledClosure else {
                            throw RuntimeError(message:
                                "TaskLocal.withValue requires a value and operation")
                        }
                        return try await context.withTaskLocalValue(
                            value,
                            for: projection.key,
                            operation: operation,
                            arguments: [])
                    }
                ))
            }
            if let casePath = any as? CasePathMarker, name == "extract",
               let symbol = casePath.enumSymbol, let caseName = casePath.caseName {
                // `casePath.extract(action)` → the payload (labeled tuple
                // for multi-payload cases) or nil on case mismatch.
                return .hostFunction(HostFunction(name: name) { args, _ in
                    let info = symbol.caseInfo(named: caseName)
                    let wrappedTypeName: String? = {
                        guard let info else { return nil }
                        if info.associatedTypeNames.count == 1 {
                            return info.associatedTypeNames[0]
                        }
                        if info.associatedTypeNames.isEmpty { return "Void" }
                        return "(" + info.associatedTypeNames.joined(separator: ", ") + ")"
                    }()
                    var payloads: [RuntimeValue]?
                    if case .enumCase(let value)? = args.positional(0),
                       value.symbol === symbol, value.name == caseName {
                        payloads = value.associated
                    } else if case .host(let any)? = args.positional(0),
                              let call = any as? ImplicitMemberCall, call.name == caseName {
                        // Never-context-typed actions (a generic parameter
                        // slot) still carry the case shape.
                        payloads = call.arguments.arguments.map(\.value)
                    }
                    guard let payloads else {
                        return .none(wrappedTypeName: wrappedTypeName)
                    }
                    if payloads.count == 1 {
                        return .some(payloads[0], wrappedTypeName: wrappedTypeName)
                    }
                    let labels = info?.associatedLabels
                        ?? Array(repeating: nil, count: payloads.count)
                    return .some(
                        .native(TupleValue(labels: labels, values: payloads)),
                        wrappedTypeName: wrappedTypeName)
                })
            }
            if any is PublishedProjection {
                // Every pipeline stage chains another silent projection.
                return .hostFunction(HostFunction(name: name) { _, _ in
                    .native(PublishedProjection())
                })
            }
            if let publisher = any as? ObjectWillChangePublisher {
                if name == "send" {
                    return .hostFunction(HostFunction(name: "send") { _, _ in
                        publisher.fire()
                        return .void
                    })
                }
                // Pipeline members (.debounce, .sink…) chain silently.
                return .native(PublishedProjection())
            }
            if let tuple = any as? TupleValue {
                // `(hrp: String, data: Data)` — member by label or index.
                let idx = Int(name) ?? tuple.labels.firstIndex(of: name) ?? -1
                if tuple.values.indices.contains(idx) { return tuple.values[idx] }
            }
            if let superRef = any as? SuperReference {
                let symbol = superRef.dispatchOwner
                if let parent = interpretedSuperclass(of: symbol) {
                    if name == "init" {
                        return .hostFunction(HostFunction(name: name) { [weak self] args, _ in
                            guard let self else {
                                throw RuntimeError(message: "interpreter gone")
                            }
                            let available = parent.initializers.filter {
                                !self.activeInitializers.contains($0.id)
                            }
                            guard let initializer = self.chooseInitializerStrict(
                                from: available, for: args) else {
                                if args.arguments.isEmpty, parent.initializers.isEmpty {
                                    return .void
                                }
                                throw RuntimeError(
                                    message: "no matching superclass initializer "
                                        + "'\(parent.name).init'")
                            }
                            if self.initializerMetadata(for: initializer).isAsync {
                                throw RuntimeError(
                                    message: "async superclass initializers require "
                                        + "suspension-aware dispatch")
                            }
                            let outcome = try self.runInitializer(
                                initializer, on: superRef.instance,
                                args: args, node: nil)
                            if outcome.isNil {
                                throw RuntimeError(
                                    message: Interpreter.initFailedSentinel)
                            }
                            return .void
                        })
                    }
                    // Interpreted superclass: dispatch methods/computed with
                    // self bound to the SAME instance (super dispatch).
                    if let method = parent.methods[name]?.first,
                       let body = functionMetadata(for: method).body {
                        return .closure(makeFunctionClosure(
                            method, body: body,
                            captured: selfEnvironment(.instance(superRef.instance))))
                    }
                    if let computed = parent.computedProperties[name] {
                        return try evaluateComputed(
                            computed, selfValue: .instance(superRef.instance), name: name)
                    }
                }
                // Host superclass (NSObject, UIViewController, …): super.init()
                // and lifecycle calls are inert — no interpreter analog.
                return .hostFunction(HostFunction(name: name) { _, _ in .void })
            }
            if let stub = any as? BindingStub {
                switch name {
                case "wrappedValue": return stub.box.value
                case "projectedValue": return baseValue
                case "animation", "transaction":
                    // `$flag.animation()` — presentation-side; the binding
                    // carries through unchanged.
                    return .hostFunction(HostFunction(name: name) { _, _ in baseValue })
                default:
                    // REAL members win over @dynamicMemberLookup, exactly as
                    // in compiled Swift: app `extension Binding { func load }`
                    // methods dispatch before any member projection
                    // (clean-architecture's Loadable bindings).
                    if let value = try hostExtensionMember(
                        name, candidates: ["Binding"], selfValue: baseValue) {
                        return value
                    }
                    // Binding is @dynamicMemberLookup: `$item.field` projects
                    // a binding to the field. Instance fields bind their own
                    // box (reference-backed); tuple elements write through
                    // the parent box; other members read through.
                    if case .instance(let inner) = stub.box.value,
                       let box = inner.box(for: inner.symbol.canonicalPropertyName(name)) {
                        // Nested-field binding writes ($model.newDonut.name)
                        // mutate the reference-backed instance IN PLACE — the
                        // model's @Published property box never sees a write,
                        // so nothing publishes and live observers stay stale
                        // (the donut rename retitles the NATIVE app's window;
                        // the interpreted one froze). The derived write-through
                        // box bubbles the write through the PARENT binding box,
                        // whose own onChange carries the @Published wiring.
                        let parent = stub.box
                        let derived = Box(box.value)
                        derived.onChange = { [weak box, weak parent] in
                            guard let box else { return }
                            box.value = derived.value
                            if ProcessInfo.processInfo.environment["INTERP_TRACE_BINDING"] != nil {
                                var parentField = "?"
                                if case .instance(let parentInstance)? = parent?.value {
                                    parentField = parentInstance.box(for: "name")?.value.stringValue ?? "?"
                                    parentField += " inst=\(ObjectIdentifier(parentInstance))"
                                }
                                print("TRACE-BINDING nested write -> \(derived.value.stringValue ?? "?"); parentInstance name=\(parentField)")
                            }
                            parent?.onChange?()
                        }
                        return .native(BindingStub(box: derived))
                    }
                    if let tuple = stub.box.value.tupleValue {
                        let index = Int(name) ?? tuple.labels.firstIndex(of: name) ?? -1
                        if tuple.values.indices.contains(index) {
                            let parent = stub.box
                            let element = Box(tuple.values[index])
                            element.onChange = {
                                guard var current = parent.value.tupleValue,
                                      current.values.indices.contains(index) else { return }
                                current.values[index] = element.value
                                parent.value = .native(current)
                            }
                            return .native(BindingStub(box: element))
                        }
                    }
                    // A binding over an UNKNOWABLE value projects a detached
                    // binding to the member chain (reads absorb, writes land
                    // in the detached box).
                    if case .host(let inner) = stub.box.value,
                       inner is InertCallable || inner is ChainedImplicitCall || inner is ImplicitMemberCall {
                        return .native(BindingStub(box: Box(.native(ChainedImplicitCall(
                            base: stub.box.value, member: name, arguments: CallArguments())))))
                    }
                    if case .implicitMember = stub.box.value {
                        return .native(BindingStub(box: Box(.native(ChainedImplicitCall(
                            base: stub.box.value, member: name, arguments: CallArguments())))))
                    }
                }
                switch name {
                case "append" where stub.box.value.arrayValue != nil,
                     "remove" where stub.box.value.arrayValue != nil:
                    // Projected-collection writes (`$results.append(x)` —
                    // the Realm/SwiftData binding idiom) mutate through the
                    // box, notifying like any state write.
                    let box = stub.box
                    let member = name
                    return .hostFunction(HostFunction(name: name) { args, _ in
                        guard var array = box.value.arrayValue,
                              let element = args.positional(0) else { return .void }
                        if member == "append" {
                            array.append(element)
                        } else {
                            array.removeAll { (try? Builtins.areEqual($0, element)) ?? false }
                        }
                        box.value = .native(array)
                        return .void
                    })
                default: break
                }
            }
            // User extensions of the host TYPE a value stands for win over
            // bridge-served members — they intentionally override our stubs
            // (`extension Color { var isDarkColor }` on a real Color,
            // `extension UIColor { … }` on a recorded UIColor node).
            // Core stubs the bridge can't name map explicitly (Binding).
            var extensionCandidates: [String] = []
            for typeName in declaredHostExtensionTypeNames(
                declaredBaseTypeName
            ) where hostExtensionSymbols[typeName] != nil {
                extensionCandidates.append(typeName)
            }
            if let typeName = registry?.hostTypeName(of: any) {
                if !extensionCandidates.contains(typeName) {
                    extensionCandidates.append(typeName)
                }
            }
            // Core RuntimeValue payloads do not require a HostRegistry, but
            // same-module extensions still shadow their imported members.
            // Keep the concrete type ahead of nativeMember so ordinary
            // evaluation and physical target admission select the same
            // source declaration.
            if any is String, !extensionCandidates.contains("String") {
                extensionCandidates.append("String")
            }
            if any is [RuntimeValue],
               !extensionCandidates.contains("Array") {
                extensionCandidates.append("Array")
            }
            if any is BindingStub { extensionCandidates.append("Binding") }
            if !extensionCandidates.isEmpty,
               let value = try hostExtensionMember(
                   name, candidates: extensionCandidates, selfValue: baseValue) {
                return value
            }
            // A protocol conformance makes its source extensions visible,
            // but a conformance-only method must not replace an exact native
            // property during bare lookup (`Collection.count(where:)` beside
            // Array.count). Probe exact members first, then source protocol
            // extensions, and only afterward permit the open-ended fallback.
            var conformanceExtensionCandidates: [String] = []
            for typeName in hostCandidates(for: any)
            where !extensionCandidates.contains(typeName) {
                guard let symbol = hostExtensionSymbols[typeName],
                      symbol.methods[name] != nil
                          || symbol.computedProperties[name] != nil
                else { continue }
                conformanceExtensionCandidates.append(typeName)
            }
            if !conformanceExtensionCandidates.isEmpty {
                if let value = try nativeMember(
                    name,
                    on: baseValue,
                    declaredTypeName: declaredBaseTypeName) {
                    return value
                }
                if let value = try readHostMember(
                    name,
                    on: any,
                    deferringAsyncProperty: deferringAsyncHostProperty,
                    includingFallback: false) {
                    return value
                }
                if let value = try hostExtensionMember(
                    name,
                    candidates: conformanceExtensionCandidates,
                    selfValue: baseValue) {
                    return value
                }
            }
            // Program extensions SHADOW imported statics — `extension Date {
            // static var now }` wins over Foundation's own, exactly like a
            // same-module declaration beats an import in compiled Swift.
            if let marker = any as? HostTypeMarker,
               let hostSymbol = hostExtensionSymbols[marker.name] {
                if let dispatcher = hostExtensionStaticMethodDispatcher(
                    name, hostSymbol: hostSymbol, typeName: marker.name) {
                    return dispatcher
                }
                if let value = try staticMember(name, of: hostSymbol) {
                    return value
                }
            }
            // The bridge gets first refusal on host natives (GeometryProxy,
            // CGRect, and static chains like UIScreen.main / DispatchQueue.main).
            if let value = try readHostMember(
                name,
                on: any,
                deferringAsyncProperty: deferringAsyncHostProperty) {
                return value
            }
            if let marker = any as? HostTypeMarker {
                if GeneratedConcurrencySurface.knowsNominalMember(
                    typeName: marker.name, memberName: name
                ) {
                    throw RuntimeError(message:
                        "\(marker.name).\(name) is declared by the active "
                            + "_Concurrency.swiftinterface but is not "
                            + "supported in this call path")
                }
                // MODULE-qualified globals (`Swift.max`, `Foundation.pow`)
                // strip the qualifier — the merge has no modules. DECLARED
                // types never answer: `SwiftUI.Tab` explicitly bypasses the
                // app's own `enum Tab` (Interactive_Header), so those fall
                // through to the framework path.
                if let global = moduleQualifiedGlobal(
                    named: name, moduleName: marker.name) {
                    return global
                }
                // Interface metadata proves this member path denotes a type;
                // do not let the host-extension fallback reinterpret it as an
                // arbitrary static value.
                if let importedType = registry?.importedNestedTypeName(
                    for: "\(marker.name).\(name)"
                ) {
                    return .native(HostTypeMarker(
                        name: importedType))
                }
                // `UNAuthorizationStatus.notDetermined` where the program
                // EXTENDS the host type: mint a TYPED marker so `.map`
                // (the extension's member) dispatches on it.
                if hostExtensionSymbols[marker.name] != nil {
                    return .native(ImplicitMemberCall(
                        name: name, arguments: CallArguments(), typeHint: marker.name))
                }
                // `Color.red` ≡ `.red` — resolved by expected type at gateways.
                return .implicitMember(name)
            }
            if let projection = any as? ModelProjection {
                if let box = projection.model.box(for: name) {
                    return .native(BindingStub(box: box))
                }
                // Computed properties with setters bind through their
                // accessors (Observation's access/withMutation idiom:
                // `$store.sortType` where sortType wraps _sortType).
                if let computed = projection.model.symbol.computedProperties[name],
                   computed.setter != nil {
                    let model = projection.model
                    let seed = try evaluateComputed(computed, selfValue: .instance(model), name: name)
                    let box = Box(seed)
                    box.onChange = { [weak self] in
                        guard let self else { return }
                        try? self.assignComputed(
                            computed,
                            selfValue: .instance(model),
                            name: name,
                            value: box.value)
                    }
                    return .native(BindingStub(box: box))
                }
                // `$store.scope(state:action:)` — TCA's bindable scoping:
                // the model's own MEMBER dispatches (the projection's
                // binding-ness only matters for write-back, which absorbs).
                if let member = try instanceMember(name, on: projection.model) {
                    return member
                }
                if assumesCompiledImports {
                    // @dynamicMemberLookup projections (TCA's `$store.filter`
                    // rides Store's dynamic member into State) — the
                    // un-modeled lookup absorbs to a fresh binding.
                    return .native(BindingStub(box: Box(.native(ChainedImplicitCall(
                        base: .instance(projection.model), member: name,
                        arguments: CallArguments())))))
                }
                throw error(node, "'$\(projection.model.symbol.name)' has no stored property '\(name)'")
            }
            if let tuple = any as? TupleValue, let value = tuple.value(for: name) {
                return value
            }
            if let value = try nativeMember(
                name,
                on: baseValue,
                declaredTypeName: declaredBaseTypeName) {
                return value
            }
            if let value = try hostExtensionMember(name, candidates: hostCandidates(for: any), selfValue: baseValue) {
                return value
            }
            if let registry, registry.isViewValue(baseValue), let modifier = registry.modifier(named: name) {
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    try modifier.apply(baseValue, args, ctx)
                })
            }
            // Members on unresolved markers extend the chain instead of dying
            // here — `.easeInOut(duration: 0.3).delay(0.2)` folds at the
            // gateway boundary where the expected type is known.
            if any is ImplicitMemberCall || any is ChainedImplicitCall {
                // `.init(width: 100, height: 120).height` — reading a member
                // that matches a labeled constructor argument returns it
                // (memberwise read-back on an unresolved init marker).
                if let call = any as? ImplicitMemberCall, call.name == "init",
                   let argument = call.arguments.labeled(name) {
                    return argument
                }
                // Wrapper-storage markers behave as their wrapped value:
                // `.init(initialValue: Model(…)).statusesState` dispatches
                // onto the model (the storage IS the value doctrine).
                if let call = any as? ImplicitMemberCall, call.name == "init",
                   let wrapped = call.arguments.labeled("initialValue")
                    ?? call.arguments.labeled("wrappedValue") {
                    return try accessMember(
                        name,
                        on: wrapped,
                        node: node,
                        env: env,
                        deferringAsyncHostProperty:
                            deferringAsyncHostProperty)
                }
                return .native(ChainedImplicitCall(base: baseValue, member: name, arguments: CallArguments()))
            }
            if name == "description" {
                // CustomStringConvertible: every stdlib value prints
                // (`store.count.description` — Int, Double, Bool, …).
                return .native(baseValue.stringValue ?? baseValue.stringified)
            }
            if name == "debugDescription" {
                // CustomDebugStringConvertible: the reflecting form quotes
                // Strings and any String elements nested in the value.
                return .native(baseValue.debugStringified)
            }
            if name == "map" || name == "flatMap" {
                // Optional.map on a non-nil value — optionals ARE the value
                // here, so `url.map { … }` applies the transform to it
                // (collections and strings matched their own map earlier).
                // Function REFERENCES (`​.flatMap(Bundle.init(url:))`) apply
                // like closures; unresolvable transforms absorb.
                return .hostFunction(HostFunction(name: name) { args, ctx in
                    if let closure = args.firstUnlabeledClosure {
                        return try ctx.callClosure(closure, arguments: [baseValue])
                    }
                    if case .hostFunction(let fn)? = args.positional(0) {
                        return try fn.invoke(
                            CallArguments(arguments: [.init(label: nil, value: baseValue)]), ctx)
                    }
                    if case .closure(let closure)? = args.positional(0) {
                        return try ctx.callClosure(closure, arguments: [baseValue])
                    }
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                })
            }
            if let caught = any as? RuntimeError,
               name == "localizedDescription" || name == "description" || name == "message" {
                // A caught interpreter error in an interpreted `catch`: its
                // message IS what a compiled error would surface (the last
                // absorb-census entry — now served for real).
                return .native(caught.message)
            }
            if let stub = any as? KeyPathStub, name == "appending" {
                // `pathToPermissions.appending(path: \.push)` — native
                // KeyPath concatenation; `\.self` roots contribute nothing.
                return .hostFunction(HostFunction(name: name) { args, _ in
                    guard case .host(let other)? = args.labeled("path") ?? args.positional(0),
                          let tail = other as? KeyPathStub else {
                        throw RuntimeError(message: "appending(path:) needs a key path")
                    }
                    let head = stub.components.filter { $0 != "self" }
                    let rest = tail.components.filter { $0 != "self" }
                    return .native(KeyPathStub(components: head + rest))
                })
            }
            if assumesCompiledImports {
                // Compiled sources: an unknown member on a NATIVE that
                // survived every dispatch (host members, extensions, stdlib)
                // is an UNMERGED-package extension (`query.isReallyEmpty`
                // from a utility dependency) — absorbs, exactly like the
                // interpreted-instance rule.
                recordAbsorbedHostMember(type: String(describing: type(of: any)), member: name)
                return .native(ChainedImplicitCall(
                    base: baseValue, member: name, arguments: CallArguments()))
            }
            throw error(node, "unsupported member '\(name)' on \(type(of: any))")

        case .void:
            if assumesCompiledImports {
                // A () in member position is a SYNTHESIS gap — a DI-wrapper
                // property nothing injected (`@Dependency(\.analytics)` on a
                // non-view class), a compiled call whose value we couldn't
                // model. The device had something real there: absorb.
                return .native(ChainedImplicitCall(
                    base: .implicitMember(name), member: name, arguments: CallArguments()))
            }
            throw error(node, "cannot access member '\(name)' on \(baseValue.stringified)")

        default:
            throw error(node, "cannot access member '\(name)' on \(baseValue.stringified)")
        }
    }

    private func sourceImmediateTaskMember(
        name: String,
        contextInheritance: RuntimeTaskContextInheritance
    ) -> RuntimeValue {
        .hostFunction(HostFunction(name: name) { arguments, context in
            let api = "Task.\(name)"
            try RuntimeTaskExecutorPreference.requireSupportedNil(
                arguments.labeled("executorPreference"), api: api)
            guard let operation = arguments.closure(labeled: "operation")
                    ?? arguments.firstUnlabeledClosure else {
                throw RuntimeError(message:
                    "\(api) needs an operation closure")
            }
            let priority = try RuntimeTaskPriority.sourceValue(
                arguments.labeled("priority"))
            let taskName = try RuntimeTaskName.sourceValue(
                arguments.labeled("name"))
            let operationExecutor = try RuntimeImmediateOperationExecutor
                .supportedExecutor(
                    operation: operation, context: context, api: api)
            return try context.spawnUnstructuredTask(
                operation,
                arguments: [],
                contextInheritance: contextInheritance,
                startPolicy: .immediate,
                operationExecutor: operationExecutor,
                name: taskName,
                priority: priority)
        })
    }

    /// Static property initializers reference bare sibling statics
    /// (`static let network = custom(category: "network")`).
}
