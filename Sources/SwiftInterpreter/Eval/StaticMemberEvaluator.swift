import SwiftSyntax

extension Interpreter {
    private func staticInitEnvironment(for symbol: StructSymbol) -> Environment {
        selfEnvironment(.type(symbol))
    }

    private func staticInitEnvironment(for symbol: EnumSymbol) -> Environment {
        selfEnvironment(.enumType(symbol))
    }

    func staticMember(_ name: String, of symbol: StructSymbol) throws -> RuntimeValue? {
        if let nested = symbol.nestedTypes[name] { return nested }
        if let cached = symbol.staticCache[name] { return cached }
        if let property = symbol.staticProperties[name] {
            let raw = try evaluate(property.initializer, in: staticInitEnvironment(for: symbol))
            let value = try resolveAnnotated(raw, annotation: property.typeAnnotation)
                .copiedForValueSemantics()
            symbol.staticCache[name] = value
            return value
        }
        if let computed = symbol.staticComputedProperties[name] {
            // `static var currentMonth: Date { … }` — evaluated fresh each
            // read (no caching: getters may depend on time or other state);
            // self is the TYPE, so bare sibling statics resolve.
            return try evaluateComputed(computed, selfValue: .type(symbol), name: name)
        }
        if let overloads = symbol.staticMethods[name], let first = overloads.first {
            // Static context: `self`/`Self` and bare sibling statics
            // resolve. Within an overload SET the running declaration never
            // re-enters itself (Logger.log's autoclosure convenience
            // delegating to its closure-taking sibling).
            let method = overloads.count > 1
                ? (overloads.first { !activeFunctionBodies.contains($0.id) } ?? first)
                : first
            if let body = method.body {
                return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.type(symbol))))
            }
        }
        if let attribute = symbol.staticWrapped[name],
           case .type(let wrapperSymbol)? = globals.lookup(attribute.attributeName.trimmedDescription),
           wrapperSymbol.computedProperties["wrappedValue"] != nil
               || wrapperSymbol.storedProperty(named: "wrappedValue") != nil {
            // Custom-wrapper static: the backing wrapper instance builds
            // once from the attribute's arguments; every read runs its
            // wrappedValue getter (AppUserDefaults.alwaysOriginalTitle).
            let backingKey = "__wrapper_" + name
            let backing: RuntimeValue
            if let cached = symbol.staticCache[backingKey] {
                backing = cached
            } else {
                var arguments: [CallArguments.Argument] = []
                if case .argumentList(let list)? = attribute.arguments {
                    for element in list {
                        arguments.append(.init(
                            label: element.label?.text,
                            value: try evaluate(element.expression, in: globals)))
                    }
                }
                backing = try instantiate(
                    wrapperSymbol, with: CallArguments(arguments: arguments), node: nil)
                    .copiedForValueSemantics()
                symbol.staticCache[backingKey] = backing
            }
            if case .instance(let wrapper) = backing {
                return try instanceMember("wrappedValue", on: wrapper)
            }
        }
        if symbol.staticUninitialized.contains(name) { return .nilValue }
        return nil
    }

    func staticMember(_ name: String, of symbol: EnumSymbol) throws -> RuntimeValue? {
        // Own nested types shadow same-named globals inside the body —
        // the struct-path doctrine applied to enum namespaces.
        if let nested = symbol.nestedTypes[name] { return nested }
        if let cached = symbol.staticCache[name] { return cached }
        if let property = symbol.staticProperties[name] {
            let raw = try evaluate(property.initializer, in: staticInitEnvironment(for: symbol))
            let value = try resolveAnnotated(raw, annotation: property.typeAnnotation)
                .copiedForValueSemantics()
            symbol.staticCache[name] = value
            return value
        }
        if let computed = symbol.staticComputedProperties[name] {
            return try evaluateComputed(computed, selfValue: .enumType(symbol), name: name)
        }
        if let overloads = symbol.staticMethods[name], let first = overloads.first {
            // A bare reference from INSIDE the running argful method reads
            // past it — `static func allCases(for:)` whose body says
            // `allCases.filter` means the SYNTHESIZED CaseIterable array.
            let method = overloads.first { !activeFunctionBodies.contains($0.id) } ?? first
            if activeFunctionBodies.contains(method.id), name == "allCases" {
                let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                    RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
                }
                return .native(all)
            }
            guard let body = method.body else { return nil }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumType(symbol))))
        }
        if name == "allCases", symbol.conformances.contains("CaseIterable") {
            let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
            }
            return .native(all)
        }
        return nil
    }
}
