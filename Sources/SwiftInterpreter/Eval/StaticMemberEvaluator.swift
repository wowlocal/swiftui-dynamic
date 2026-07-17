import SwiftSyntax

extension Interpreter {
    private func staticInitEnvironment(for symbol: StructSymbol) -> Environment {
        selfEnvironment(.type(symbol))
    }

    private func staticInitEnvironment(for symbol: EnumSymbol) -> Environment {
        selfEnvironment(.enumType(symbol))
    }

    private func sourceTaskLocalMember(
        _ rawName: String,
        declarations: [String: RuntimeTaskLocalDeclaration],
        environment: Environment
    ) throws -> RuntimeValue? {
        let isProjection = rawName.hasPrefix("$") && rawName.count > 1
        let name = isProjection ? String(rawName.dropFirst()) : rawName
        guard let declaration = declarations[name] else { return nil }

        if isProjection {
            let defaultValue = try sourceTaskLocalDefault(
                declaration, environment: environment)
            return .native(RuntimeTaskLocalProjection(
                key: declaration.key,
                defaultValue: defaultValue,
                valueTypeName: declaration.typeAnnotation?.trimmedDescription
                    ?? HostRuntimeTypeSystem.typeName(of: defaultValue)))
        }
        if let bound = evaluationTaskContext.taskLocals.value(
            for: declaration.key) {
            return bound.copiedForValueSemantics()
        }
        return try sourceTaskLocalDefault(
            declaration, environment: environment)
    }

    private func sourceTaskLocalDefault(
        _ declaration: RuntimeTaskLocalDeclaration,
        environment: Environment
    ) throws -> RuntimeValue {
        if let cached = declaration.cachedDefault {
            return cached.copiedForValueSemantics()
        }

        let raw: RuntimeValue
        if let initializer = declaration.initializer {
            raw = try evaluate(initializer, in: environment)
        } else {
            raw = .none(forTypeAnnotation:
                declaration.typeAnnotation?.trimmedDescription ?? "")
        }
        let resolved = try resolveAnnotated(
            raw, annotation: declaration.typeAnnotation)
            .copiedForValueSemantics()
        declaration.cachedDefault = resolved
        return resolved.copiedForValueSemantics()
    }

    func staticMember(_ name: String, of symbol: StructSymbol) throws -> RuntimeValue? {
        if let taskLocal = try sourceTaskLocalMember(
            name,
            declarations: symbol.taskLocalProperties,
            environment: staticInitEnvironment(for: symbol)) {
            return taskLocal
        }
        if let nested = symbol.nestedTypes[name] { return nested }
        if let box = symbol.staticReferenceBoxes[name] { return try box.load() }
        if let cached = symbol.staticCache[name] { return cached }
        if let property = symbol.staticProperties[name] {
            var raw = try evaluate(property.initializer, in: staticInitEnvironment(for: symbol))
            var value = try resolveAnnotated(raw, annotation: property.typeAnnotation)
                .copiedForValueSemantics()
            if property.referenceOwnership != .strong {
                let box = Box(
                    value,
                    declaredTypeName: property.typeAnnotation?.trimmedDescription,
                    referenceOwnership: property.referenceOwnership)
                symbol.staticReferenceBoxes[name] = box
                // The initializer result has no source-level strong owner.
                // Release evaluator temporaries before the first weak read.
                raw = .void
                value = .void
                return try box.load()
            }
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
            if let body = functionMetadata(for: method).body {
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
        if symbol.staticUninitialized.contains(name) {
            if let policy = symbol.staticStoragePolicies[name],
               policy.referenceOwnership != .strong {
                let box = Box(
                    .none(forTypeAnnotation: policy.typeName ?? ""),
                    declaredTypeName: policy.typeName,
                    referenceOwnership: policy.referenceOwnership)
                symbol.staticReferenceBoxes[name] = box
                return try box.load()
            }
            return .nilValue
        }
        return nil
    }

    func staticMember(_ name: String, of symbol: EnumSymbol) throws -> RuntimeValue? {
        if let taskLocal = try sourceTaskLocalMember(
            name,
            declarations: symbol.taskLocalProperties,
            environment: staticInitEnvironment(for: symbol)) {
            return taskLocal
        }
        // Own nested types shadow same-named globals inside the body —
        // the struct-path doctrine applied to enum namespaces.
        if let nested = symbol.nestedTypes[name] { return nested }
        if let box = symbol.staticReferenceBoxes[name] { return try box.load() }
        if let cached = symbol.staticCache[name] { return cached }
        if let property = symbol.staticProperties[name] {
            var raw = try evaluate(property.initializer, in: staticInitEnvironment(for: symbol))
            var value = try resolveAnnotated(raw, annotation: property.typeAnnotation)
                .copiedForValueSemantics()
            if property.referenceOwnership != .strong {
                let box = Box(
                    value,
                    declaredTypeName: property.typeAnnotation?.trimmedDescription,
                    referenceOwnership: property.referenceOwnership)
                symbol.staticReferenceBoxes[name] = box
                raw = .void
                value = .void
                return try box.load()
            }
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
            guard let body = functionMetadata(for: method).body else {
                return nil
            }
            return .closure(makeFunctionClosure(method, body: body, captured: selfEnvironment(.enumType(symbol))))
        }
        if name == "allCases", symbol.conformances.contains("CaseIterable") {
            let all = symbol.cases.filter { !$0.hasAssociatedValues }.map {
                RuntimeValue.enumCase(EnumCaseValue(symbol: symbol, name: $0.name))
            }
            return .native(all)
        }
        if symbol.staticUninitialized.contains(name) {
            if let policy = symbol.staticStoragePolicies[name],
               policy.referenceOwnership != .strong {
                let box = Box(
                    .none(forTypeAnnotation: policy.typeName ?? ""),
                    declaredTypeName: policy.typeName,
                    referenceOwnership: policy.referenceOwnership)
                symbol.staticReferenceBoxes[name] = box
                return try box.load()
            }
            return .nilValue
        }
        return nil
    }
}
