import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Calls

    static let cStdlibNames: Set<String> = [
        "malloc", "calloc", "realloc", "free", "memcpy", "memmove", "memset",
        "strlen", "strcmp", "strncmp", "strcpy", "strdup",
        // Process-control calls in merged helper-tool files: interpreted
        // execution continues (the app target never runs them at launch).
        "exit", "abort", "usleep", "sleep",
        // sysctl/process-info family.
        "sysctl", "sysctlbyname", "getpid", "getppid", "getenv", "setenv",
        "unsetenv", "getuid", "geteuid",
    ]

    static let optionalIntrinsicMemberNames: Set<String> = [
        "isNil", "isSome", "isNotNil", "unsafelyUnwrapped",
        "map", "flatMap",
    ]

    /// Identifier shapes that read as C imports (snake_case, leading
    /// underscore, or the known stdlib list) — these absorb via the C
    /// branch and must never be claimed by the modifier rescue.
    static func looksLikeCImport(_ name: String) -> Bool {
        cStdlibNames.contains(name)
            || (name.contains("_") && name.first?.isLowercase == true)
            || (name.hasPrefix("_") && name.dropFirst().first?.isLowercase == true)
    }

    /// Runtime type test for `is`: primitives and interpreted symbols check
    /// truly; host natives match the registry's type name; markers and nil
    /// read false.
    func valueIsType(_ value: RuntimeValue, _ rawType: String) -> Bool {
        // Ownership/calling-convention prefixes constrain how an argument is
        // passed, not the value type used for overload selection. Share the
        // host-signature normalizer so source-extension initializers with an
        // `inout` parameter compete by their underlying nominal type.
        var typeName = HostSignature.normalizedType(rawType)
        if let wrappedType = RuntimeOptionalValue.wrappedType(in: typeName) {
            switch value.optionalState {
            case .none(let observed):
                return observed.map {
                    HostSignature.equivalentTypeName($0, wrappedType)
                } ?? true
            case .some(let wrapped, _):
                return valueIsType(wrapped, wrappedType)
            case .notOptional:
                return valueIsType(value, wrappedType)
            }
        }
        if let range = value.rangeValue, let annotation = Self.rangeAnnotation(typeName) {
            guard range.matchesNominalShape(annotation.name) else { return false }
            let bounds = [range.lowerBound, range.upperBound].compactMap { $0 }
            if Self.doubleFamilyTypeNames.contains(annotation.bound) {
                return bounds.allSatisfy { $0.doubleValue != nil }
            }
            if annotation.bound == "Int" { return bounds.allSatisfy { $0.intValue != nil } }
            if annotation.bound == "String" { return bounds.allSatisfy { $0.stringValue != nil } }
            if annotation.bound == "Date" {
                return bounds.allSatisfy { value in
                    if case .host(let any) = value { return any is Date }
                    return false
                }
            }
            if annotation.bound == "String.Index" {
                return bounds.allSatisfy { value in
                    if case .host(let any) = value { return any is String.Index }
                    return false
                }
            }
            return false
        }
        // Function types participate in source overload ranking just like
        // nominal types. A trailing closure must positively fit a closure
        // parameter so an earlier, label-compatible overload cannot win by
        // declaration order. Key paths retain Swift's callable conversion.
        if isFunctionType(typeName) {
            switch value {
            case .closure, .hostFunction:
                return true
            case .host(let any) where any is KeyPathStub:
                return true
            default:
                return false
            }
        }
        if let angle = typeName.firstIndex(of: "<") { typeName = String(typeName[..<angle]) }
        if typeName.hasPrefix("Swift.") {
            typeName.removeFirst("Swift.".count)
        }
        if typeName == "Any" || typeName == "AnyObject" { return !value.isNil }
        if value.isOptional { return false }
        if value.isNil { return false }
        switch value {
        case .int:
            return Self.integerFamilyTypeNames.contains(typeName)
                || ["Double", "CGFloat", "TimeInterval", "NSNumber"].contains(typeName)
        case .double: return ["Double", "CGFloat", "TimeInterval", "Float", "NSNumber"].contains(typeName)
        case .bool: return typeName == "Bool" || typeName == "NSNumber"
        case .string: return ["String", "NSString"].contains(typeName)
        case .array: return ["Array", "NSArray"].contains(typeName) || typeName.hasPrefix("[")
        case .set: return typeName == "Set"
        case .dictionary:
            return ["Dictionary", "NSDictionary"].contains(typeName) || typeName.hasPrefix("[")
        case .tuple: return typeName == "Tuple"
        case .range:
            return ["Range", "ClosedRange", "PartialRangeFrom", "PartialRangeUpTo",
                    "PartialRangeThrough", "RangeExpression"].contains(typeName)
        case .instance(let instance):
            if case .type(let expected)? = typeValue(named: typeName),
               expected === instance.symbol {
                return true
            }
            var symbol: StructSymbol? = instance.symbol
            while let current = symbol {
                if current.name == typeName { return true }
                if current.conformances.contains(where: { conformance in
                    var seen = Set<String>()
                    return protocolReaches(conformance, target: typeName, seen: &seen)
                }) { return true }
                guard let parent = interpretedSuperclass(of: current) else {
                    // The generated host contract names the imported nominal
                    // without requiring the source's module qualification.
                    // A source subclass remains substitutable for that direct
                    // host superclass even though its storage stays owned by
                    // the interpreter.
                    if let superclassName = current.superclassName,
                       HostSignature.equivalentTypeName(
                           superclassName, typeName) {
                        return true
                    }
                    break
                }
                symbol = parent
            }
            return false
        case .enumCase(let caseValue):
            if case .enumType(let expected)? = typeValue(named: typeName),
               expected === caseValue.symbol {
                return true
            }
            if caseValue.symbol.name == typeName { return true }
            return caseValue.symbol.conformances.contains { conformance in
                var seen = Set<String>()
                return protocolReaches(conformance, target: typeName, seen: &seen)
            }
        case .host(let any):
            if let concurrency = any as? RuntimeConcurrencyHostValue {
                let observed = concurrency.sourceTypeName
                let nominal = observed.firstIndex(of: "<").map {
                    String(observed[..<$0])
                } ?? observed
                return HostSignature.equivalentTypeName(observed, typeName)
                    || HostSignature.equivalentTypeName(nominal, typeName)
            }
            if any is String || any is NSString { return ["String", "NSString"].contains(typeName) }
            if any is Date { return ["Date", "NSDate"].contains(typeName) }
            if any is URL { return ["URL", "NSURL"].contains(typeName) }
            if any is Data { return ["Data", "NSData"].contains(typeName) }
            if any is [RuntimeValue] { return ["Array", "NSArray"].contains(typeName) || typeName.hasPrefix("[") }
            if any is DictValue { return ["Dictionary", "NSDictionary"].contains(typeName) || typeName.hasPrefix("[") }
            // A registry may attach concrete source-type evidence to an
            // otherwise opaque/inert host carrier (trace-recorded values are
            // the canonical example). That evidence wins over the generic
            // marker fallback below, just as it does for ordinary host
            // natives.
            if let observed = registry?.hostTypeName(of: any),
               HostSignature.equivalentTypeName(observed, typeName) {
                return true
            }
            if any is InertCallable || any is ChainedImplicitCall || any is ImplicitMemberCall {
                return false // unknowable: fresh state IS nothing yet
            }
            return false
        default:
            return false
        }
    }

    /// A custom ViewModifier applies by RUNNING its body(content:) — real
    /// semantics for both spellings (`.modifier(m)` and
    /// `ModifiedContent(content:modifier:)`).
    func applyViewModifier(
        _ modifier: Instance, to content: RuntimeValue, node: Syntax?
    ) throws -> RuntimeValue {
        guard let overloads = modifier.symbol.methods["body"], let method = overloads.first,
              let body = functionMetadata(for: method).body else {
            return content // bodyless conformer: identity
        }
        let closure = makeFunctionClosure(
            method, body: body, captured: selfEnvironment(.instance(modifier)))
        return try callWithArguments(
            closure,
            args: CallArguments(arguments: [.init(label: "content", value: content)]),
            node: node)
    }

    func evaluateCall(
        _ call: FunctionCallExprSyntax,
        in env: Environment,
        contextualResultMember: String? = nil,
        declaredResultType: ((String?) -> Void)? = nil
    ) throws -> RuntimeValue {
        func reportDeclaredResult(of callee: RuntimeValue) {
            switch callee {
            case .closure(let closure):
                declaredResultType?(closure.returnTypeName)
            case .type(let symbol):
                declaredResultType?(symbol.name)
            case .enumType(let symbol):
                declaredResultType?(symbol.name)
            default:
                break
            }
        }

        let calleeMetadata = callSiteMetadata(for: call).callee
        // `ModifiedContent(content: self, modifier: TitleFont(size: 16))` —
        // the explicit ViewModifier application (MovieSwiftUI's titleStyle).
        if calleeMetadata.shape == .directReference,
           calleeMetadata.name == "ModifiedContent",
           env.box(for: "ModifiedContent") == nil, globals.lookup("ModifiedContent") == nil {
            let args = try collectArguments(of: call, in: env)
            if let content = args.labeled("content"),
               case .instance(let modifier)? = args.labeled("modifier") {
                return try applyViewModifier(modifier, to: content, node: Syntax(call))
            }
        }
        // `[Index]()` / `[String: Int]()` — typed empty containers.
        if calleeMetadata.shape == .arrayType {
            if call.arguments.isEmpty { return .native([RuntimeValue]()) }
            // `[CChar](repeating: 0, count: n)` — the typed-array ctor.
            let args = try collectArguments(of: call, in: env)
            if let element = args.labeled("repeating"), let count = args.labeled("count")?.intValue {
                return .native([RuntimeValue](repeating: element, count: max(0, count)))
            }
            if let array = args.positional(0)?.arrayValue { return .native(array) }
            return .native([RuntimeValue]())
        }
        if calleeMetadata.shape == .dictionaryType, call.arguments.isEmpty {
            return .native(DictValue())
        }
        // `.system(size: 40)` — implicit member call, resolved later by a gateway.
        if calleeMetadata.shape == .implicitMember,
           let member = calleeMetadata.member {
            let args = try collectArguments(of: call, in: env)
            return .native(ImplicitMemberCall(name: member.declName.baseName.text, arguments: args))
        }
        // Methods that mutate collections in place, and property/method pairs
        // like `first` / `first(where:)`, need the base handled specially.
        if calleeMetadata.shape == .explicitMember,
           let member = calleeMetadata.member,
           let baseExpr = member.base {
            let name = member.declName.baseName.text
            // Evaluate the receiver once, before arguments (native order).
            // Special mutation dispatch receives this value and only probes
            // an lvalue after confirming the receiver/method shape.
            var evaluatedBaseTypeName: String?
            let baseValue: RuntimeValue
            if let baseCall = baseExpr.as(FunctionCallExprSyntax.self) {
                baseValue = try evaluateCall(
                    baseCall,
                    in: env,
                    contextualResultMember: name,
                    declaredResultType: { evaluatedBaseTypeName = $0 })
            } else {
                baseValue = try evaluate(baseExpr, in: env)
            }
            let declaredBaseTypeName = evaluatedBaseTypeName
                ?? declaredMemberReceiverTypeName(for: baseExpr, in: env)
            // A call continuing an Optional chain dispatches the METHOD on
            // the payload, then lifts the result. This matters for names that
            // also have a property spelling (`array?.first(where:)`): member
            // lookup alone would otherwise return `first`'s value and try to
            // call that element. Optional's own members stay on the wrapper.
            var specialBaseValue = baseValue
            var liftsMemberResult = false
            if !Self.optionalIntrinsicMemberNames.contains(name),
               case .optional(let optional) = baseValue,
               let wrapped = optional.wrapped {
                specialBaseValue = wrapped
                liftsMemberResult = !optional.isImplicitlyUnwrapped
            }
            if let result = try specialMemberCall(
                name, base: baseExpr, baseValue: specialBaseValue,
                call: call, in: env,
                declaredBaseTypeName: declaredBaseTypeName) {
                return liftsMemberResult ? result.liftedToOptional() : result
            }
            // Methods dispatch from call syntax, where labels disambiguate
            // overloads and a host-superclass property can coexist with a
            // same-named subclass method (`window` vs `window(_:)`).
            if case .instance(let instance) = specialBaseValue,
               let overloads = instanceMethodOverloads(
                   named: name, on: instance),
               shouldDirectlyDispatchInstanceCall(
                   named: name, on: instance, overloads: overloads
               ) {
                let args = try collectArguments(of: call, in: env)
                let fitting = functionsFittingCall(
                    from: overloads, args: args)
                if !fitting.isEmpty {
                    let available = functionsAvailableForCall(
                        from: fitting, args: args)
                    if available.isEmpty {
                        // Every fitting overload is already running
                        // (send#StoreTask ↔ send#Task mutual delegation):
                        // absorb the return-type dispatch path we cannot see.
                        let result = RuntimeValue.native(ChainedImplicitCall(
                            base: specialBaseValue, member: name, arguments: args))
                        return liftsMemberResult
                            ? result.liftedToOptional() : result
                    }
                    if let method = chooseFunction(
                        from: available,
                        for: args,
                        contextualResultMember: contextualResultMember
                    ) ?? available.first,
                       let body = functionMetadata(for: method).body {
                        let closure = makeFunctionClosure(
                            method, body: body,
                            captured: instanceMethodEnvironment(instance))
                        let result = try invoke(
                            .closure(closure), with: args, node: call)
                        return liftsMemberResult
                            ? result.liftedToOptional() : result
                    }
                }
            }
            // STATIC overloads pick by call shape too:
            // KioskRow.label(_:systemSymbol:) vs label(_:icon:).
            if case .type(let symbol) = baseValue,
               let overloads = staticMethodOverloads(
                   named: name, on: symbol), overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                }
                if let method = chooseFunction(
                    from: available,
                    for: args,
                    contextualResultMember: contextualResultMember
                ) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            if case .enumType(let symbol) = baseValue,
               let overloads = symbol.staticMethods[name], !overloads.isEmpty,
               !call.arguments.isEmpty || call.trailingClosure != nil
                   || symbol.staticComputedProperties[name] == nil {
                // Static-method CALLS dispatch even for single overloads —
                // `Sort.allCases(for:)` must not invoke the synthesized
                // CaseIterable ARRAY (the collision rule at call sites).
                let args = try collectArguments(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: baseValue, member: name, arguments: args))
                }
                if let method = chooseFunction(
                    from: available,
                    for: args,
                    contextualResultMember: contextualResultMember
                ) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.enumType(symbol)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            let callee = try accessMember(
                name,
                on: baseValue,
                node: member,
                env: env,
                declaredTypeName: declaredBaseTypeName)
            let args = try collectArguments(of: call, in: env)
            // A nil PROPERTY at a call site never throws (nil-call absorbs),
            // so the collision rescue below can't fire — pre-check it. The
            // property `timeZone.nextDaylightSavingTimeTransition` is
            // honestly nil (a zone with no future DST), but the call shape
            // names the METHOD form (after:), which answers for real.
            if callee.isNil, let any = baseValue.hostPayload,
               let method = registry?.hostMethod(name, on: any) {
                return try invoke(method, with: args, node: call)
            }
            reportDeclaredResult(of: callee)
            do {
                return try invoke(callee, with: args, node: call)
            } catch let bindingError as RuntimeError
                where !bindingError.fatal
                    && (bindingError.message.hasPrefix("missing argument")
                        || bindingError.message.hasSuffix("is not callable")) {
                // PROPERTY/METHOD collision at a CALL site: the type's own
                // computed property shadowed a PROTOCOL-EXTENSION method
                // (Status's `var isHidden` vs AnyStatus's `isHidden(in:)`)
                // — dispatch the method, as overload resolution would. The
                // SAME-SYMBOL form first: FoodTruckModel's stored dict
                // `dailyOrderSummaries` beside `dailyOrderSummaries(cityID:)`.
                if case .instance(let instance) = baseValue {
                    let family = functionsAvailableForCall(
                        from: instanceMethodOverloads(
                            named: name, on: instance) ?? [],
                        args: args)
                    if let method = chooseFunction(
                        from: family,
                        for: args,
                        contextualResultMember: contextualResultMember),
                       let body = functionMetadata(for: method).body {
                        let closure = makeFunctionClosure(
                            method, body: body, captured: instanceMethodEnvironment(instance))
                        return try invoke(.closure(closure), with: args, node: call)
                    }
                    for conformance in transitiveConformances(of: instance.symbol) {
                        guard let proto = hostExtensionSymbols[conformance],
                              let overloads = proto.methods[name] else { continue }
                        let available = functionsAvailableForCall(
                            from: overloads, args: args)
                        // Only a FITTING overload rescues — a wrong-shaped
                        // sibling must fall through to the modifier retry.
                        guard let method = chooseFunction(
                            from: available,
                            for: args,
                            contextualResultMember: contextualResultMember),
                              let body = functionMetadata(for: method).body else {
                            continue
                        }
                        let closure = makeFunctionClosure(
                            method, body: body, captured: instanceMethodEnvironment(instance))
                        return try invoke(.closure(closure), with: args, node: call)
                    }
                }
                // The SAME collision on a HOST value: the generated table's
                // property answered the access (`url.query` → "x=1&y=2"),
                // but the call shape names the METHOD
                // (`query(percentEncoded:)`) — re-dispatch through the
                // methods-only table, as native overload resolution would.
                if let any = baseValue.hostPayload,
                   let method = registry?.hostMethod(name, on: any) {
                    return try invoke(method, with: args, node: call)
                }
                // A user extension OR a same-named PROPERTY can shadow a
                // built-in modifier (`extension View { func offset(
                // coordinateSpace:…) }`; `var offset: CGFloat` on a view
                // struct vs `.offset(y:)`). Binding/invocation fails before
                // any body runs, so retrying through the modifier table is
                // safe.
                guard let registry, let modifier = registry.modifier(named: name),
                      let target = modifierTarget(for: baseValue) else {
                    throw bindingError
                }
                do {
                    return try modifier.apply(target, args, self)
                } catch let e as RuntimeError where e.line == 0 {
                    throw error(call, locating: e)
                }
            }
        }
        // Unqualified overloaded calls inside the type's own body.
        if calleeMetadata.shape == .directReference,
           let name = calleeMetadata.name,
           env.box(for: name, before: globals) == nil {
            // Bare `path(percentEncoded:)` inside a URL extension — the
            // METHOD/property collision, implicit-self flavor.
            if name == "path",
               call.arguments.contains(where: { $0.label?.text == "percentEncoded" }),
               let url = env.lookup("self")?.hostPayload as? URL {
                let args = try collectArguments(of: call, in: env)
                return .native(url.path(percentEncoded: args.labeled("percentEncoded")?.boolValue ?? true))
            }
            // GLOBAL function overloads pick by call shape with the
            // running-declaration exclusion (L10n's variadic form delegates
            // to its single-argument sibling).
            if let overloads = globalFunctionOverloads[name], overloads.count > 1,
               env.box(for: name, before: globals) == nil {
                let args = try collectArguments(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: .implicitMember(name), member: "call", arguments: args))
                }
                if let method = chooseFunctionByRuntimeTypes(
                    from: available,
                    for: args,
                    contextualResultMember: contextualResultMember
                ) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(method, body: body, captured: globals)
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            // Bare calls inside a host-type extension use the same combined
            // source/imported overload family as `self.member(...)`. Member
            // lookup alone has no argument types and otherwise re-enters a
            // single source declaration even when its runtime parameter type
            // cannot fit the delegating call.
            if let selfValue = env.lookup("self"),
               selfValue.hostPayload != nil,
               let overloads = try hostExtensionMethodOverloads(
                   named: name,
                   on: selfValue,
                   // An implicit-self call retains the extension's lexical
                   // receiver type even when its Objective-C payload has no
                   // nominal runtime identity. Do not apply this recovery to
                   // explicit receivers: a different host value used inside
                   // the extension must dispatch by its own declared/runtime
                   // type.
                   declaredTypeName: (lexicalOwnerFrames.last as? StructSymbol)
                       .flatMap { lexicalHost in
                           hostExtensionSymbols[lexicalHost.name]
                               === lexicalHost ? lexicalHost.name : nil
                       }
               ) {
                let args = try collectArguments(of: call, in: env)
                let target = try resolveHostExtensionMethodTarget(
                    overloads, arguments: args)
                return try invoke(target, with: args, node: call)
            }
            if case .instance(let instance)? = env.lookup("self"),
               let overloads = instanceMethodOverloads(
                   named: name, on: instance),
               shouldDirectlyDispatchImplicitSelfCall(
                   named: name, on: instance, overloads: overloads
               ) {
                let args = try collectArguments(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: .instance(instance), member: name, arguments: args))
                }
                if let method = chooseFunction(
                    from: available,
                    for: args,
                    contextualResultMember: contextualResultMember
                ) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let methodEnvironment = methodIsMutating(method)
                        ? selfEnvironment(.instance(instance))
                        : instanceMethodEnvironment(instance)
                    let closure = makeFunctionClosure(
                        method, body: body, captured: methodEnvironment)
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
            if case .type(let symbol)? = env.lookup("self"),
               let overloads = staticMethodOverloads(
                   named: name, on: symbol), overloads.count > 1 {
                let args = try collectArguments(of: call, in: env)
                let available = functionsAvailableForCall(
                    from: overloads, args: args)
                if available.isEmpty {
                    return .native(ChainedImplicitCall(
                        base: .type(symbol), member: name, arguments: args))
                }
                if let method = chooseFunction(
                    from: available,
                    for: args,
                    contextualResultMember: contextualResultMember
                ) ?? available.first,
                   let body = functionMetadata(for: method).body {
                    let closure = makeFunctionClosure(
                        method, body: body, captured: selfEnvironment(.type(symbol)))
                    return try invoke(.closure(closure), with: args, node: call)
                }
            }
        }
        let callee = try evaluate(calleeMetadata.expression, in: env)
        let args = try collectArguments(of: call, in: env)
        reportDeclaredResult(of: callee)
        return try invoke(callee, with: args, node: call)
    }

    /// Direct call-site dispatch is only needed when bare member lookup is
    /// ambiguous. Ordinary unique methods must stay on the normal lexical
    /// path: eagerly selecting every same-named method can steal calls from
    /// local/global declarations and can bypass constructor or subscript
    /// resolution in large merged modules.
    func shouldDirectlyDispatchInstanceCall(
        named name: String,
        on instance: Instance,
        overloads: [FunctionDeclSyntax]
    ) -> Bool {
        if overloads.count > 1
            || instance.symbol.computedProperties[name] != nil
            || GeneratedCollectionDefaultSurface.suppliesProperty(
                named: name,
                conformances: Set(transitiveConformances(
                    of: instance.symbol))) {
            return true
        }
        guard instance.symbol.superclassName != nil,
              interpretedSuperclass(of: instance.symbol) == nil else {
            return false
        }
        return overloads.allSatisfy { method in
            functionMetadata(for: method).parameters.contains {
                $0.defaultValue == nil
            }
        }
    }

    /// A bare nested mutating call must borrow the current method's working
    /// self. Bound-method lookup snapshots source structs by value, which is
    /// correct for nonmutating method values but would discard every write
    /// made by the nested call.
    func shouldDirectlyDispatchImplicitSelfCall(
        named name: String,
        on instance: Instance,
        overloads: [FunctionDeclSyntax]
    ) -> Bool {
        overloads.contains(where: methodIsMutating)
            || shouldDirectlyDispatchInstanceCall(
                named: name, on: instance, overloads: overloads)
    }

    /// The value a retried modifier applies to: view values directly,
    /// view/shape-conforming instances wrapped renderable.
    func modifierTarget(for value: RuntimeValue) -> RuntimeValue? {
        guard let registry else { return nil }
        if registry.isViewValue(value) { return value }
        if case .instance(let instance) = value,
           instance.symbol.rendersLikeView
            || instance.symbol.conformsToShape || instance.symbol.conformsToLayout {
            return registry.makeRenderable(instance: instance, interpreter: self)
        }
        return nil
    }

    /// Mutating candidates supplied directly by the nominal type or by a
    /// protocol-extension default. Both dispatch paths must participate in
    /// the same source-value copy-out transaction.
    func mutatingInstanceMethods(
        named name: String, on instance: Instance
    ) -> [FunctionDeclSyntax] {
        var methods = instanceMethodOverloads(named: name, on: instance) ?? []
        for conformance in transitiveConformances(of: instance.symbol) {
            if let defaults = hostExtensionSymbols[conformance]?.methods[name] {
                methods.append(contentsOf: defaults)
            }
        }
        return methods.filter(methodIsMutating)
    }

    /// Mutating collection methods (`items.append(x)`) resolve the base as an
    /// lvalue; `first(where:)`/`last(where:)` collide with the same-named
    /// properties. Returns nil to fall through to normal dispatch.
    private func specialMemberCall(
        _ name: String,
        base: ExprSyntax,
        baseValue: RuntimeValue,
        call: FunctionCallExprSyntax,
        in env: Environment,
        declaredBaseTypeName: String? = nil
    ) throws -> RuntimeValue? {
        // `.modifier(TitleFont(size: 16))` — a custom ViewModifier applies
        // by RUNNING its body(content:), with the modifier's OWN
        // @Environment/@State properties injected first (uninjected reads
        // were voids — the iteration-198 revert). Only the strict
        // ViewModifier shape dispatches: declared conformance AND a body
        // method whose single parameter is the content.
        if name == "modifier" {
            let args = try collectArguments(of: call, in: env)
            if case .instance(let modifier)? = args.positional(0),
               modifier.symbol.conformances.contains("ViewModifier"),
               let overloads = modifier.symbol.methods["body"],
               let method = overloads.first,
               functionMetadata(for: method).body != nil,
               functionMetadata(for: method).parameters.count == 1 {
                injectEnvironmentValues(into: modifier, values: [:])
                return try applyViewModifier(modifier, to: baseValue, node: Syntax(call))
            }
        }
        // Host-type source extensions, plus any imported peer, form one
        // overload set. Defer the decision until arguments are evaluated
        // instead of letting bare member lookup choose the first declaration.
        if let overloads = try hostExtensionMethodOverloads(
            named: name,
            on: baseValue,
            declaredTypeName: declaredBaseTypeName
                ?? declaredMemberReceiverTypeName(for: base, in: env)
        ) {
            let args = try collectArguments(of: call, in: env)
            let target = try resolveHostExtensionMethodTarget(
                overloads, arguments: args)
            return try invoke(target, with: args, node: call)
        }
        // MUTATING methods on ENUM receivers through writable lvalues:
        // `wrappedValue.setIsLoading(cancelBag:)` — the method runs on a
        // copy whose `self` reassignments write BACK through the lvalue
        // (value semantics; through a Binding this fires the set-closure
        // exactly once, like the native read-modify-write).
        if case .enumCase(let receiver) = baseValue,
           let overloads = receiver.symbol.methods[name],
           let method = overloads.first(where: { declared in
               functionMetadata(for: declared).modifierNames
                   .contains("mutating")
           }),
           let body = functionMetadata(for: method).body,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            let selfEnv = selfEnvironment(.enumCase(receiver))
            let closure = makeFunctionClosure(method, body: body, captured: selfEnv)
            let result = try callWithArguments(closure, args: args, node: Syntax(call))
            if let newSelf = selfEnv.box(for: "self")?.value {
                // `self = .loaded(last)` rides as a marker — the receiver's
                // own symbol is the annotation that resolves it to a case.
                let resolved = try resolveAnnotated(newSelf, typeName: receiver.symbol.name)
                try relocating(call) { try target.writeOwned(resolved, self) }
            }
            return result
        }
        // MUTATING methods on source structs use the same copy-in/copy-out
        // transaction as nested container writes. The method never receives
        // the caller's storage node; its final `self` is committed through
        // the complete lvalue path, firing outer observers/state hooks once.
        if case .instance(let receiver) = baseValue,
           !receiver.symbol.isClass {
            let mutating = mutatingInstanceMethods(named: name, on: receiver)
            if !mutating.isEmpty {
                let args = try collectArguments(of: call, in: env)
                if let method = chooseFunction(from: mutating, for: args) ?? mutating.first,
                   let body = functionMetadata(for: method).body,
                   let target = try? resolveLValue(base, in: env),
                   case .instance(let working) = baseValue.copiedForValueSemantics() {
                    let selfEnv = selfEnvironment(.instance(working))
                    let closure = makeFunctionClosure(method, body: body, captured: selfEnv)
                    let result = try callWithArguments(
                        closure, args: args, node: Syntax(call))
                    let finalSelf = selfEnv.lookup("self") ?? .instance(working)
                    let resolved = try resolveAnnotated(
                        finalSelf, typeName: receiver.symbol.name)
                    try relocating(call) { try target.writeOwned(resolved, self) }
                    return result
                }
            }
        }
        // Bool.toggle() — ubiquitous in SwiftUI code (`show.toggle()`); writes
        // through the lvalue so @State/@Published notification fires.
        if name == "toggle",
           let current = baseValue.boolValue,
           let target = try? resolveLValue(base, in: env) {
            _ = try collectArguments(of: call, in: env) // evaluate (empty) args for side effects
            try relocating(call) { try target.writeOwned(.native(!current), self) }
            return .void
        }

        let requiredEndpointRemoval = GeneratedCollectionDefaultSurface
            .requiredEndpointRemoval(named: name)

        // The active standard-library interface supplies the semantic
        // endpoint for required zero-argument collection removals. Native
        // String and Array carriers share that generated rule and differ only
        // in how their erased storage is copied back through the lvalue.
        if let endpoint = requiredEndpointRemoval,
           call.arguments.isEmpty,
           call.trailingClosure == nil,
           call.additionalTrailingClosures.isEmpty,
           var text = baseValue.stringValue,
           let target = try? resolveLValue(base, in: env) {
            _ = try collectArguments(of: call, in: env)
            guard !text.isEmpty else {
                throw error(call, "endpoint removal on an empty String")
            }
            let removed: Character
            switch endpoint {
            case .first: removed = text.removeFirst()
            case .last: removed = text.removeLast()
            }
            try relocating(call) {
                try target.writeOwned(.native(text), self)
            }
            return .native(String(removed))
        }

        // `url.path(percentEncoded:)` — the modern METHOD collides with the
        // legacy `path` PROPERTY; the call shape resolves here (the
        // first(where:) precedent). Only URL bases match; the labeled-arg
        // guard keeps other `path(…)` calls off this route.
        if name == "path",
           call.arguments.contains(where: { $0.label?.text == "percentEncoded" }),
           case .host(let any) = baseValue,
           let url = any as? URL {
            let args = try collectArguments(of: call, in: env)
            let encoded = args.labeled("percentEncoded")?.boolValue ?? true
            return .native(url.path(percentEncoded: encoded))
        }

        // Mutating String members write through the lvalue:
        // `text.replaceSubrange(range, with: "…")`.
        if name == "replaceSubrange",
           var text = baseValue.stringValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            guard let replacement = args.labeled("with")?.stringValue,
                  let range = args.positional(0)?.rangeValue else {
                throw error(call, "replaceSubrange needs a range and 'with:'")
            }
            text.replaceSubrange(try stringSlice(range, in: text, node: call), with: replacement)
            try relocating(call) { try target.writeOwned(.native(text), self) }
            return .void
        }

        // Mutating URL members write through the lvalue (value semantics):
        // `url.append(path:)` / `url.appendPathComponent(_:)`.
        if name == "append" || name == "appendPathComponent",
           case .host(let existingAny) = baseValue,
           let url = existingAny as? URL,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            guard let component = (args.labeled("path") ?? args.labeled("component")
                ?? args.positional(0))?.stringValue else {
                throw error(call, "append needs a path component")
            }
            var updated = url
            updated.append(path: component)
            try relocating(call) { try target.writeOwned(.native(updated), self) }
            return .void
        }

        // Data mutations write through the lvalue (value semantics):
        // `data.append(other)` / `data.append(byte)`.
        if name == "append",
           case .host(let existingAny) = baseValue,
           var bytes = existingAny as? Data,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            guard let value = args.positional(0) else {
                throw error(call, "append needs a value")
            }
            if case .host(let addAny) = value, let more = addAny as? Data {
                bytes.append(more)
            } else if let byte = value.intValue {
                bytes.append(UInt8(truncatingIfNeeded: byte))
            } else if let array = value.arrayValue {
                bytes.append(contentsOf: array.compactMap { $0.intValue.map { UInt8(truncatingIfNeeded: $0) } })
            } else {
                throw error(call, "cannot append \(value.stringified) to Data")
            }
            try relocating(call) { try target.writeOwned(.native(bytes), self) }
            return .void
        }

        // `str.size(withAttributes:)` — the NSString measurement API, served
        // by the bridge (real font metrics). Dispatch is call-label-aware
        // because user extensions commonly define their own `size(_ font:)`
        // wrapper around it, and plain member access must keep resolving to
        // that extension.
        if name == "size", call.arguments.first?.label?.text == "withAttributes" {
            if let string = baseValue.stringValue,
               case .hostFunction(let measure)? = try readHostMember(
                "sizeWithAttributes", on: string as Any) {
                let args = try collectArguments(of: call, in: env)
                do {
                    return try measure.invoke(args, self)
                } catch let e as RuntimeError where e.line == 0 {
                    throw error(call, locating: e)
                }
            }
        }

        // `text.count(where: { … })` — count-as-function (the property wins
        // for plain `.count`; the call form is label-dispatched here).
        if name == "count", call.arguments.first?.label?.text == "where" {
            let args = try collectArguments(of: call, in: env)
            guard let closure = args.closure(labeled: "where") else {
                throw error(call, "count(where:) needs a closure")
            }
            var elements: [RuntimeValue] = []
            if let string = baseValue.stringValue {
                elements = string.map { .native(String($0)) }
            } else if let array = baseValue.arrayValue {
                elements = array
            }
            var matched = 0
            for element in elements where try callClosure(closure, arguments: [element]).boolValue == true {
                matched += 1
            }
            return .native(matched)
        }

        // `code.append("7")` / `append(contentsOf:)` — mutating String
        // append through the lvalue.
        if name == "append",
           let current = baseValue.stringValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            guard let argument = args.labeled("contentsOf") ?? args.positional(0), !argument.isNil else {
                throw error(call, "String.append needs a value")
            }
            let suffix = argument.stringValue ?? argument.stringified
            try relocating(call) { try target.writeOwned(.native(current + suffix), self) }
            return .void
        }
        // `text.insert(char, at: index)` — String insertion at a String.Index.
        if name == "insert",
           call.arguments.contains(where: { $0.label?.text == "at" }),
           let current = baseValue.stringValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            guard let element = args.positional(0), !element.isNil,
                  case .host(let idxAny)? = args.labeled("at"),
                  let index = idxAny as? Swift.String.Index else {
                throw error(call, "String.insert needs a value and an at: String.Index")
            }
            var copy = current
            let clamped = min(index, copy.endIndex)
            copy.insert(contentsOf: element.stringValue ?? element.stringified, at: clamped)
            try relocating(call) { try target.writeOwned(.native(copy), self) }
            return .void
        }

        // An interface-derived mutable-buffer callback is a scoped
        // read-modify-write transaction. Pointer writes mutate an
        // interpreter-owned carrier; copy its final elements back through the
        // original array lvalue even when the callback throws, matching Swift's
        // inout writeback.
        if let callbackLabel = GeneratedUnsafeMemorySurface
            .mutableBufferCallbackArgumentLabel(for: name),
           let array = baseValue.arrayValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            let body = callbackLabel.isEmpty
                ? args.firstUnlabeledClosure
                : args.closure(labeled: callbackLabel)
            guard let body else {
                throw error(call, "\(name) needs a closure")
            }
            let buffer = RuntimeMutableCollectionBackedBuffer(
                array, elementTypeName: target.annotatedElementType())
            do {
                let result = try callClosure(
                    body, arguments: [.native(buffer)])
                try relocating(call) {
                    try target.writeCanonicalOwned(
                        .native(buffer.elements), self)
                }
                return result
            } catch {
                try relocating(call) {
                    try target.writeCanonicalOwned(
                        .native(buffer.elements), self)
                }
                throw error
            }
        }

        let nativeDictionaryKeyOptionalValueMutation =
            GeneratedCollectionDefaultSurface
                .isNativeDictionaryKeyOptionalValueMutation(named: name)
        if nativeDictionaryKeyOptionalValueMutation,
           var dictionary = baseValue.dictValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            let result = try GeneratedCollectionDefaultSurface
                .invokeNativeDictionaryKeyOptionalValueMutation(
                    named: name,
                    arguments: args,
                    carrier: &dictionary,
                    interpreter: self)
            try relocating(call) {
                try target.writeCanonicalOwned(.native(dictionary), self)
            }
            return result
        }

        let nativeDictionaryCarrierScalarVoidMutation =
            GeneratedCollectionDefaultSurface
                .isNativeCarrierScalarVoidMutation(
                    named: name, carrierKind: .dictionary)
        if nativeDictionaryCarrierScalarVoidMutation,
           var dictionary = baseValue.dictValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            guard try GeneratedCollectionDefaultSurface
                .invokeNativeCarrierScalarVoidMutation(
                    named: name, arguments: args, carrier: &dictionary)
            else {
                return nil
            }
            try relocating(call) {
                try target.writeCanonicalOwned(.native(dictionary), self)
            }
            return .void
        }

        let setMutating = [
            "insert", "update", "remove", "removeAll", "formUnion",
            "formIntersection", "subtract", "formSymmetricDifference",
        ]
        let nativeSetCarrierScalarVoidMutation =
            GeneratedCollectionDefaultSurface
                .isNativeCarrierScalarVoidMutation(
                    named: name, carrierKind: .set)
        if (setMutating.contains(name)
                || nativeSetCarrierScalarVoidMutation),
           var set = baseValue.setValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            let elementType = set.elementTypeName ?? target.annotatedElementType()
            func resolved(_ value: RuntimeValue) throws -> RuntimeValue {
                guard let elementType else { return value }
                return try resolveAnnotated(value, typeName: elementType)
            }
            let result: RuntimeValue
            switch name {
            case "insert":
                guard let member = args.positional(0) else {
                    throw error(call, "Set.insert needs a member")
                }
                let insertion = try set.insert(
                    resolved(member), by: collectionStorageValuesAreEqual)
                result = .native(TupleValue(
                    labels: ["inserted", "memberAfterInsert"],
                    values: [.native(insertion.inserted), insertion.memberAfterInsert]))
            case "update":
                guard let member = args.labeled("with") ?? args.positional(0) else {
                    throw error(call, "Set.update(with:) needs a member")
                }
                let value = try resolved(member)
                let old = try set.remove(
                    value, by: collectionStorageValuesAreEqual)
                _ = try set.insert(
                    value, by: collectionStorageValuesAreEqual)
                result = .optional(old, wrappedTypeName: elementType)
            case "remove":
                guard let member = args.positional(0) else {
                    throw error(call, "Set.remove needs a member")
                }
                result = .optional(
                    try set.remove(
                        resolved(member),
                        by: collectionStorageValuesAreEqual),
                    wrappedTypeName: elementType)
            case "removeAll":
                if let closure = args.closure(labeled: "where")
                    ?? args.firstUnlabeledClosure {
                    _ = closure
                    throw error(call, "Set.removeAll does not accept a predicate")
                }
                set = RuntimeSetValue(elementTypeName: set.elementTypeName)
                result = .void
            default:
                if nativeSetCarrierScalarVoidMutation,
                   try GeneratedCollectionDefaultSurface
                    .invokeNativeCarrierScalarVoidMutation(
                        named: name, arguments: args, carrier: &set) {
                    result = .void
                    break
                }
                guard let otherValue = args.positional(0) else {
                    throw error(call, "Set.\(name) needs a sequence")
                }
                let other = try setOperationElements(otherValue)
                switch name {
                case "formUnion":
                    set = try set.union(
                        other, by: collectionStorageValuesAreEqual)
                case "formIntersection":
                    set = try set.intersection(
                        other, by: collectionStorageValuesAreEqual)
                case "subtract":
                    set = try set.subtracting(
                        other, by: collectionStorageValuesAreEqual)
                default:
                    set = try set.symmetricDifference(
                        other, by: collectionStorageValuesAreEqual)
                }
                result = .void
            }
            try relocating(call) {
                try target.writeCanonicalOwned(.native(set), self)
            }
            return result
        }

        let mutating = ["append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "sort"]
        let removesRange = GeneratedRangeMutationSurface.removesRange(
            named: name)
        let optionallyRemovesLast = GeneratedCollectionDefaultSurface
            .optionallyRemovesLast(named: name)
        let nativeArrayCarrierScalarVoidMutation =
            GeneratedCollectionDefaultSurface
                .isNativeCarrierScalarVoidMutation(
                    named: name, carrierKind: .array)
        if (mutating.contains(name) || removesRange || optionallyRemovesLast
                || requiredEndpointRemoval != nil
                || nativeArrayCarrierScalarVoidMutation),
           var array = baseValue.arrayValue,
           let target = try? resolveLValue(base, in: env) {
            let args = try collectArguments(of: call, in: env)
            // `items.append(.init())` — the element type comes from the
            // target property's `[Type]` annotation.
            let elementType = target.annotatedElementType()
            func resolved(_ value: RuntimeValue) throws -> RuntimeValue {
                guard let elementType else { return value }
                return try resolveAnnotated(value, typeName: elementType)
            }
            if let endpoint = requiredEndpointRemoval,
               args.arguments.isEmpty {
                guard !array.isEmpty else {
                    throw error(call, "endpoint removal on an empty Array")
                }
                let removed: RuntimeValue
                switch endpoint {
                case .first: removed = array.removeFirst()
                case .last: removed = array.removeLast()
                }
                try relocating(call) {
                    try target.writeCanonicalOwned(.native(array), self)
                }
                return removed
            }
            switch name {
            case "append":
                if let source = args.labeled("contentsOf"),
                   let contents = try materializedCollectionElements(source) {
                    array.append(contentsOf: try contents.map(resolved))
                } else if let value = args.positional(0) {
                    array.append(try resolved(value))
                } else {
                    throw error(call, "append needs a value")
                }
            case "insert":
                if let source = args.labeled("contentsOf"),
                   let contents = try materializedCollectionElements(source),
                   let index = args.labeled("at")?.intValue,
                   index >= 0, index <= array.count {
                    array.insert(contentsOf: try contents.map(resolved), at: index)
                    break
                }
                guard let value = args.positional(0), let index = args.labeled("at")?.intValue,
                      index >= 0, index <= array.count else {
                    throw error(call, "insert needs a value and a valid at: index")
                }
                array.insert(try resolved(value), at: index)
            case "remove":
                // `remove(atOffsets:)` — SwiftUI's IndexSet form (arrives as
                // an index array): delete DESCENDING so offsets stay valid.
                if let offsets = args.labeled("atOffsets")?.arrayValue {
                    let indices = offsets.compactMap(\.intValue).sorted(by: >)
                    for index in indices where array.indices.contains(index) {
                        array.remove(at: index)
                    }
                    try relocating(call) {
                        try target.writeCanonicalOwned(.native(array), self)
                    }
                    return .void
                }
                guard let index = args.labeled("at")?.intValue, array.indices.contains(index) else {
                    throw error(call, "remove(at:) index out of range")
                }
                let removed = array.remove(at: index)
                try relocating(call) {
                    try target.writeCanonicalOwned(.native(array), self)
                }
                return removed
            case "removeAll":
                if let closure = args.closure(labeled: "where") {
                    var kept: [RuntimeValue] = []
                    for element in array where try callClosure(closure, arguments: [element]).boolValue != true {
                        kept.append(element)
                    }
                    array = kept
                } else {
                    array = []
                }
            case "removeFirst":
                guard let count = args.positional(0)?.intValue,
                      count >= 0, count <= array.count else {
                    throw error(call, "invalid Array prefix removal count")
                }
                array.removeFirst(count)
            case "removeLast":
                guard let count = args.positional(0)?.intValue,
                      count >= 0, count <= array.count else {
                    throw error(call, "invalid Array suffix removal count")
                }
                array.removeLast(count)
            case "sort":
                let comparatorClosure = args.closure(labeled: "by")
                    ?? args.firstUnlabeledClosure
                let comparatorValue = args.labeled("by")
                    ?? args.positional(0)
                var failure: Error?
                array.sort { a, b in
                    if failure != nil { return false }
                    do {
                        if let comparatorClosure {
                            return try callClosure(
                                comparatorClosure,
                                arguments: [a, b]).boolValue == true
                        }
                        if let comparatorValue {
                            let comparison = try invoke(
                                comparatorValue,
                                with: CallArguments(arguments: [
                                    .init(label: nil, value: a),
                                    .init(label: nil, value: b),
                                ]),
                                node: call)
                            return comparison.boolValue == true
                        }
                        // The argument-free Comparable form dispatches a
                        // declared `static func <`, like infix expressions
                        // and assertion gateways.
                        return try evaluateBinary("<", a, b).boolValue == true
                    } catch {
                        failure = error
                        return false
                    }
                }
                if let failure { throw failure }
            default:
                if nativeArrayCarrierScalarVoidMutation,
                   try GeneratedCollectionDefaultSurface
                    .invokeNativeCarrierScalarVoidMutation(
                        named: name, arguments: args, carrier: &array) {
                    break
                }
                if optionallyRemovesLast {
                    guard args.arguments.isEmpty else {
                        throw error(
                            call,
                            "generated optional last removal takes no arguments")
                    }
                    guard let removed = array.popLast() else {
                        return .none(wrappedTypeName: elementType)
                    }
                    try relocating(call) {
                        try target.writeCanonicalOwned(.native(array), self)
                    }
                    return removed.liftedToOptional(
                        wrappedTypeName: elementType)
                }
                guard removesRange,
                      args.arguments.count == 1,
                      let range = args.positional(0)?.rangeValue?
                        .halfOpenIntRange,
                      range.lowerBound >= 0,
                      range.lowerBound <= range.upperBound,
                      range.upperBound <= array.count else {
                    throw error(
                        call,
                        "generated range removal needs valid Array indices")
                }
                array.removeSubrange(range)
            }
            try relocating(call) {
                try target.writeCanonicalOwned(.native(array), self)
            }
            return .void
        }

        if name == "first" || name == "last" {
            let array = baseValue.arrayValue ?? baseValue.rangeValue?.integerValues()
            if let array {
                let args = try collectArguments(of: call, in: env)
                if let closure = args.closure(labeled: "where") ?? args.firstUnlabeledClosure {
                    let ordered = name == "last" ? Array(array.reversed()) : array
                    for element in ordered where try callClosure(closure, arguments: [element]).boolValue == true {
                        return .some(element)
                    }
                    return .none()
                }
            }
        }
        return nil
    }
}
