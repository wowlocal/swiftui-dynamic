import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Identifiers & members

    /// Lazy globals evaluate their initializer on first read (memoized).
    func force(_ box: Box) throws -> RuntimeValue {
        if case .host(let any) = box.value, let computed = any as? ComputedGlobal {
            // Global computed var: evaluate fresh on every read.
            let result = try executeBlock(computed.accessor, in: Environment(parent: globals))
            switch result {
            case .normal(let value), .returnValue(let value):
                return try resolveAnnotated(value, annotation: computed.annotation)
            default:
                return .void
            }
        }
        guard case .host(let any) = box.value, let lazy = any as? LazyGlobal else {
            return try box.load()
        }
        let annotationText = lazy.annotation?.trimmedDescription ?? ""
        var value: RuntimeValue = RuntimeOptionalValue.wrappedType(in: annotationText) != nil
            ? .none(forTypeAnnotation: annotationText) : .void
        if let initializer = lazy.initializer {
            value = try resolveAnnotated(try evaluate(initializer, in: globals), annotation: lazy.annotation)
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
        if let box = globals.box(for: name) { return try force(box) }
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
        // SDK symbol graphs include imported module functions whose names are
        // conventionally uppercase (MTLCreateSystemDefaultDevice, UIGraphics…)
        // even though they are values, not types. Give an explicitly
        // registered host global priority over the unknown-type absorber.
        if let function = registry?.cFunction(named: name) {
            return .hostFunction(function)
        }
        if let ctor = registry?.constructor(named: aliasHeads[name] ?? name) {
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
            return .hostFunction(HostFunction(name: name) { [weak self] _, _ in
                self?.registry?.absorbedCValue(named: name)
                    ?? .native(ChainedImplicitCall(
                        base: .implicitMember(name), member: "call", arguments: CallArguments()))
            })
        }
        throw error(node, "unresolved identifier '\(name)'")
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
            if let value = try nativeMember(name, on: selfValue) { return value }
            if let value = try readHostMember(name, on: any) { return value }
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
                annotation: seed.annotation).copiedForValueSemantics()
            box.value = value
            return value
        }
        // A type's OWN nested types shadow same-named globals inside its
        // body (each IceCubes package declares its own `enum Constants`) —
        // scoped LEXICALLY to the running method's declaring type, so
        // protocol-extension bodies never see the runtime self's nesteds.
        if let nested = lexicalNestedType(name, runtime: instance.symbol) { return nested }
        if let box = instance.box(for: name) { return try box.load() }
        // Dynamic dispatch: the instance's OWN members win (overrides beat
        // the inherited definition), THEN interpreted-superclass members
        // dispatch with self unchanged, walking the chain.
        if let overloads = instance.symbol.methods[name], let first = overloads.first {
            // A PROPERTY/METHOD name collision (`var filteredReadings` +
            // `func filteredReadings(for:)`): a bare reference is the
            // property when every method overload requires arguments.
            if instance.symbol.computedProperties[name] != nil,
               overloads.allSatisfy({ method in
                   method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
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
               let superName = instance.symbol.superclassName,
               !isInterpretedType(superName),
               overloads.allSatisfy({ method in
                   method.signature.parameterClause.parameters.contains {
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
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(
                method, body: body, captured: instanceMethodEnvironment(instance)))
        }
        if let computed = instance.symbol.computedProperties[name] {
            return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
        }
        var parentName = instance.symbol.superclassName
        while let superName = parentName {
            guard case .type(let parent)? = globals.lookup(superName) else { break }
            if let overloads = parent.methods[name], let firstMethod = overloads.first {
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstMethod)
                    : firstMethod
                if let body = method.body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: instanceMethodEnvironment(instance)))
                }
            }
            if let computed = parent.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
            parentName = parent.superclassName
        }
        if instance.symbol.conformsToView,
           let value = try hostExtensionMember(name, candidates: ["View"], selfValue: .instance(instance)) {
            return value
        }
        // Protocol-extension defaults: `extension GameLogic { func start() … }`
        // serves conformers that don't define the member themselves —
        // through protocol REFINEMENT too (CountriesWebRepository:
        // WebRepository reaches WebRepository's `call(endpoint:)`).
        for conformance in transitiveConformances(of: instance.symbol) {
            guard let proto = hostExtensionSymbols[conformance] else { continue }
            if let overloads = proto.methods[name], let firstMethod = overloads.first {
                // PROPERTY/METHOD collision in the same extension (AnyStatus
                // declares `var isHidden` AND `func isHidden(in:)`): a bare
                // reference is the property when every method overload
                // requires arguments — the instanceMember rule.
                if let computed = proto.computedProperties[name],
                   overloads.allSatisfy({ method in
                       method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
                   }) {
                    return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
                }
                // Overload sets never re-enter the running declaration
                // (IconDrawable's image(ofSize:color:) → edgeInsets form,
                // served to conformers through the protocol-defaults walk).
                let method = overloads.count > 1
                    ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? firstMethod)
                    : firstMethod
                if let body = method.body {
                    return .closure(makeFunctionClosure(
                        method, body: body, captured: instanceMethodEnvironment(instance)))
                }
            }
            if let computed = proto.computedProperties[name] {
                return try evaluateComputed(computed, selfValue: .instance(instance), name: name)
            }
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
        guard let overloads = hostSymbol.staticMethods[name], !overloads.isEmpty,
              hostSymbol.staticProperties[name] == nil,
              hostSymbol.staticComputedProperties[name] == nil,
              hostSymbol.nestedTypes[name] == nil,
              hostSymbol.staticCache[name] == nil,
              hostSymbol.staticReferenceBoxes[name] == nil else { return nil }
        return .hostFunction(HostFunction(name: name) { [unowned self] args, _ in
            let available = overloads.filter { !activeFunctionBodies.contains($0.id) }
            let pool = available.isEmpty ? overloads : available
            // A declared overload only competes when it accepts every label
            // the call passes — `using:` against an (in:)-only shadow is a
            // host call, not a shadow hit.
            let callLabels = Set(args.arguments.compactMap(\.label))
            let shapePool = pool.filter { method in
                let paramLabels = Set(method.signature.parameterClause.parameters.compactMap {
                    parameter -> String? in
                    let label = parameter.firstName.text
                    return label == "_" ? nil : label
                })
                return callLabels.isSubset(of: paramLabels)
            }
            var chosen = chooseFunction(from: shapePool, for: args) ?? shapePool.first
            if chosen == nil,
               ((try? readHostMember(name, on: HostTypeMarker(name: typeName))) ?? nil) == nil {
                // No host to defer to: keep the historical force-first
                // behavior for label-lenient code.
                chosen = pool.first
            }
            if let method = chosen, let body = method.body {
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
                       method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
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
                guard let body = method.body else { return nil }
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
            guard let body = method.body else { return nil }
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

    /// Runs the best-matching user subscript getter (picked by arity).
    func callUserSubscriptGetter(on instance: Instance, with args: CallArguments) throws -> RuntimeValue {
        try runUserSubscriptGetter(instance.symbol, selfValue: .instance(instance), args: args)
    }

    /// Runs the user subscript setter with `newValue` and the index bound.
    func callUserSubscriptSetter(on instance: Instance, with args: CallArguments, newValue: RuntimeValue) throws {
        try runUserSubscriptSetter(instance.symbol, selfValue: .instance(instance), args: args, newValue: newValue)
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
            in: symbol, argumentCount: args.arguments.count)
        return try runUserSubscriptGetter(
            member,
            symbolName: symbol.name,
            selfValue: selfValue,
            args: args)
    }

    func userSubscriptMember(
        in symbol: StructSymbol, argumentCount: Int
    ) throws -> StructSymbol.SubscriptMember {
        guard let member = symbol.subscripts.first(where: {
            $0.parameters.count == argumentCount
        }) ?? symbol.subscripts.first else {
            throw RuntimeError(message: "'\(symbol.name)' has no subscript")
        }
        return member
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
                callableMetadataIndex: currentCallableMetadataIndex)
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
                callableMetadataIndex: currentCallableMetadataIndex)
            return try await callWithArgumentsSuspending(
                closure, args: args, node: nil)
        }
    }

    func runUserSubscriptSetter(
        _ symbol: StructSymbol, selfValue: RuntimeValue, args: CallArguments, newValue: RuntimeValue
    ) throws {
        let member = try userSubscriptMember(
            in: symbol, argumentCount: args.arguments.count)
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
        executor calleeExecutor: RuntimeExecutorKind?,
        selfValue: RuntimeValue,
        name: String,
        _ operation: (Environment) throws -> T
    ) throws -> T {
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
        if let declarationID, let owner = declLexicalOwners[declarationID] {
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
            executor: executor,
            selfValue: selfValue,
            name: name,
            operation)
    }

    private func withAccessorContextSuspending<T>(
        declarationID: SyntaxIdentifier?,
        executor calleeExecutor: RuntimeExecutorKind?,
        selfValue: RuntimeValue,
        name: String,
        _ operation: (Environment) async throws -> T
    ) async throws -> T {
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
        if let declarationID, let owner = declLexicalOwners[declarationID] {
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
                if let typeName = computed.typeAnnotation?.trimmedDescription,
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
                   let typeName = computed.typeAnnotation?.trimmedDescription {
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

    func evaluateComputedBodySuspending(
        _ computed: ComputedProperty,
        selfValue: RuntimeValue,
        name: String
    ) async throws -> RuntimeValue {
        try await withComputedPropertyContextSuspending(
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
                if let typeName = computed.typeAnnotation?.trimmedDescription,
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

    func accessMember(
        _ name: String,
        on baseValue: RuntimeValue,
        node: some SyntaxProtocol,
        env: Environment,
        deferringAsyncHostProperty: Bool = false
    ) throws -> RuntimeValue {
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
                   let body = method.body {
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
                   let body = method.body {
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
                deferringAsyncHostProperty: deferringAsyncHostProperty)
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
                   property.typeAnnotation?.trimmedDescription.contains("->") == true,
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
                   !method.signature.parameterClause.parameters.contains { $0.defaultValue == nil }
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
            if ["Swift", "Foundation", "SwiftUI", "Combine", "Dispatch"].contains(function.name),
               let global = globals.lookup(name) {
                switch global {
                case .type, .enumType: break
                default: return global
                }
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
            if let member = runtimeCheckedContinuationMember(name, on: any) {
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
                let symbol = superRef.instance.symbol
                if let parentName = symbol.superclassName,
                   case .type(let parent)? = globals.lookup(parentName) {
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
                            if initializer.signature.effectSpecifiers?.asyncSpecifier != nil {
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
                    if let method = parent.methods[name]?.first, let body = method.body {
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
                        return .native(BindingStub(box: box))
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
            if let typeName = registry?.hostTypeName(of: any) {
                extensionCandidates.append(typeName)
            }
            if any is BindingStub { extensionCandidates.append("Binding") }
            if !extensionCandidates.isEmpty,
               let value = try hostExtensionMember(
                   name, candidates: extensionCandidates, selfValue: baseValue) {
                return value
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
                // MODULE-qualified globals (`Swift.max`, `Foundation.pow`)
                // strip the qualifier — the merge has no modules. DECLARED
                // types never answer: `SwiftUI.Tab` explicitly bypasses the
                // app's own `enum Tab` (Interactive_Header), so those fall
                // through to the framework path.
                if ["Swift", "Foundation", "SwiftUI", "Combine", "Dispatch"].contains(marker.name),
                   let global = globals.lookup(name) {
                    switch global {
                    case .type, .enumType: break
                    default: return global
                    }
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
            if let value = try nativeMember(name, on: baseValue) {
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
