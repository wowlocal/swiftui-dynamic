import SwiftSyntax

/// Pass 1: hoist struct/enum/function declarations from a parsed file into the
/// global environment; pass 2 merges extensions into the collected symbols.
/// Top-level `let`/`var` and expressions are executed in source order by
/// `Interpreter.run` afterwards.
extension Interpreter {
    func collectDeclarations(from file: SourceFileSyntax) throws {
        for item in file.statements {
            guard case .decl(let decl) = item.item else { continue }
            if let structDecl = decl.as(StructDeclSyntax.self) {
                try collectStruct(structDecl)
            } else if let classDecl = decl.as(ClassDeclSyntax.self) {
                try collectClass(classDecl)
            } else if let enumDecl = decl.as(EnumDeclSyntax.self) {
                try collectEnum(enumDecl)
            } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
                try defineFunction(funcDecl, in: globals)
            }
        }
        for item in file.statements {
            guard case .decl(let decl) = item.item,
                  let extensionDecl = decl.as(ExtensionDeclSyntax.self) else { continue }
            try collectExtension(extensionDecl)
        }
    }

    // MARK: - Structs

    private func collectStruct(_ node: StructDeclSyntax) throws {
        let symbol = try makeStructSymbol(node)
        structSymbols.append(symbol)
        globals.define(symbol.name, .type(symbol))
    }

    private func makeStructSymbol(_ node: StructDeclSyntax) throws -> StructSymbol {
        let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let symbol = StructSymbol(name: node.name.text, conformsToView: inherited.contains("View"))
        symbol.isRepresentable = inherited.contains { $0.hasSuffix("Representable") }
        try collectStructMembers(node.memberBlock, into: symbol)
        return symbol
    }

    /// Classes ride the same symbol machinery — Instance is already
    /// reference-backed, which is exactly class semantics. The extra flags
    /// drive observation (`ObservableObject` conformance / `@Observable`).
    private func collectClass(_ node: ClassDeclSyntax) throws {
        let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let symbol = StructSymbol(name: node.name.text, conformsToView: inherited.contains("View"))
        symbol.isClass = true
        symbol.conformsToObservableObject = inherited.contains("ObservableObject")
        symbol.observableViaMacro = node.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Observable"
        }
        try collectStructMembers(node.memberBlock, into: symbol)
        structSymbols.append(symbol)
        globals.define(symbol.name, .type(symbol))
    }

    private func collectStructMembers(_ block: MemberBlockSyntax, into symbol: StructSymbol) throws {
        for member in block.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                try collectProperties(varDecl, into: symbol)
            } else if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                if isStatic(funcDecl.modifiers) {
                    symbol.staticMethods[funcDecl.name.text] = funcDecl
                } else {
                    symbol.methods[funcDecl.name.text] = funcDecl
                }
            } else if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
                symbol.initializers.append(initDecl)
            } else if let nestedEnum = member.decl.as(EnumDeclSyntax.self) {
                // Nested types register under `Outer.Name` (for annotations)
                // and the bare name when unclaimed (for in-scope references).
                let nested = try makeEnumSymbol(nestedEnum)
                symbol.nestedTypes[nested.name] = .enumType(nested)
                enumSymbols["\(symbol.name).\(nested.name)"] = nested
                if enumSymbols[nested.name] == nil { enumSymbols[nested.name] = nested }
            } else if let nestedStruct = member.decl.as(StructDeclSyntax.self) {
                let nestedSymbol = try makeStructSymbol(nestedStruct)
                symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
                structSymbols.append(nestedSymbol)
                globals.define("\(symbol.name).\(nestedSymbol.name)", .type(nestedSymbol))
                if globals.lookup(nestedSymbol.name) == nil {
                    globals.define(nestedSymbol.name, .type(nestedSymbol))
                }
            }
        }
    }

    private func collectProperties(_ varDecl: VariableDeclSyntax, into symbol: StructSymbol) throws {
        let wrapper = propertyWrapper(of: varDecl.attributes)
        let hasBuilderAttribute = hasAttribute(varDecl.attributes, named: "ViewBuilder")
        let isStaticDecl = isStatic(varDecl.modifiers)

        for binding in varDecl.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw error(binding, "unsupported property pattern")
            }
            let name = ident.identifier.text
            // A binding with an accessor block is computed only if it has a
            // getter; willSet/didSet-only observers mean a stored property
            // (observers are inert — documented divergence).
            if let accessorBlock = binding.accessorBlock,
               let accessors = parseAccessors(of: accessorBlock) {
                let returnsView = binding.typeAnnotation?.type.trimmedDescription.contains("some View") ?? false
                symbol.computedProperties[name] = ComputedProperty(
                    accessor: accessors.getter,
                    isBuilder: hasBuilderAttribute || returnsView,
                    setter: accessors.setter
                )
            } else if isStaticDecl {
                if let initializer = binding.initializer?.value {
                    symbol.staticProperties[name] = initializer
                }
            } else {
                symbol.storedProperties.append(.init(
                    name: name,
                    wrapper: wrapper,
                    initializer: binding.initializer?.value,
                    typeAnnotation: binding.typeAnnotation?.type,
                    isBuilderClosure: hasBuilderAttribute
                ))
            }
        }
    }

    // MARK: - Enums

    private func collectEnum(_ node: EnumDeclSyntax) throws {
        let symbol = try makeEnumSymbol(node)
        enumSymbols[symbol.name] = symbol
        globals.define(symbol.name, .enumType(symbol))
    }

    private func makeEnumSymbol(_ node: EnumDeclSyntax) throws -> EnumSymbol {
        let symbol = EnumSymbol(name: node.name.text)
        let rawIsString = node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "String"
        } ?? false

        var nextIntRaw = 0
        for member in node.memberBlock.members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    let labels: [String?] = element.parameterClause?.parameters.map { $0.firstName?.text } ?? []
                    let raw: RuntimeValue
                    if let rawExpr = element.rawValue?.value {
                        raw = try evaluate(rawExpr, in: globals)
                    } else if rawIsString {
                        raw = .native(element.name.text)
                    } else {
                        raw = .native(nextIntRaw)
                    }
                    if let intRaw = raw.intValue { nextIntRaw = intRaw + 1 }
                    symbol.cases.append(.init(name: element.name.text, associatedLabels: labels, rawValue: raw))
                }
            } else {
                try collectEnumMember(member.decl, into: symbol)
            }
        }
        return symbol
    }

    private func collectEnumMember(_ decl: DeclSyntax, into symbol: EnumSymbol) throws {
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            let hasBuilderAttribute = hasAttribute(varDecl.attributes, named: "ViewBuilder")
            let isStaticDecl = isStatic(varDecl.modifiers)
            for binding in varDecl.bindings {
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if let accessorBlock = binding.accessorBlock,
                   let accessors = parseAccessors(of: accessorBlock) {
                    let returnsView = binding.typeAnnotation?.type.trimmedDescription.contains("some View") ?? false
                    symbol.computedProperties[ident.identifier.text] = ComputedProperty(
                        accessor: accessors.getter,
                        isBuilder: hasBuilderAttribute || returnsView,
                        setter: accessors.setter
                    )
                } else if isStaticDecl, let initializer = binding.initializer?.value {
                    symbol.staticProperties[ident.identifier.text] = initializer
                }
            }
        } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            if isStatic(funcDecl.modifiers) {
                symbol.staticMethods[funcDecl.name.text] = funcDecl
            } else {
                symbol.methods[funcDecl.name.text] = funcDecl
            }
        }
    }

    // MARK: - Extensions

    private func collectExtension(_ node: ExtensionDeclSyntax) throws {
        let typeName = node.extendedType.trimmedDescription
        switch globals.lookup(typeName) {
        case .type(let symbol):
            try collectStructMembers(node.memberBlock, into: symbol)
        case .enumType(let symbol):
            for member in node.memberBlock.members {
                try collectEnumMember(member.decl, into: symbol)
            }
        default:
            // Extensions of host types (`extension View { func … }`) collect
            // into synthetic symbols, resolved on matching host values.
            let symbol = hostExtensionSymbols[typeName]
                ?? StructSymbol(name: typeName, conformsToView: false)
            try collectStructMembers(node.memberBlock, into: symbol)
            hostExtensionSymbols[typeName] = symbol
        }
    }

    // MARK: - Functions

    func defineFunction(_ node: FunctionDeclSyntax, in env: Environment) throws {
        guard let body = node.body else {
            throw error(node, "function '\(node.name.text)' has no body")
        }
        env.define(node.name.text, .closure(makeFunctionClosure(node, body: body, captured: env)))
    }

    func makeFunctionClosure(_ node: FunctionDeclSyntax, body: CodeBlockSyntax, captured: Environment) -> ClosureValue {
        let parameters = node.signature.parameterClause.parameters.map { param in
            ClosureValue.Parameter(
                name: (param.secondName ?? param.firstName).text,
                defaultValue: param.defaultValue?.value,
                typeAnnotation: param.type
            )
        }
        let returnType = node.signature.returnClause?.type
        let returnsView = returnType?.trimmedDescription.contains("some View") ?? false
        let isBuilder = returnsView || hasAttribute(node.attributes, named: "ViewBuilder")
        return ClosureValue(
            parameters: parameters,
            body: body.statements,
            captured: captured,
            isBuilder: isBuilder,
            returnType: returnType
        )
    }

    // MARK: - Helpers

    /// nil ⇒ no getter (willSet/didSet observers only): treat as stored.
    private func parseAccessors(
        of accessorBlock: AccessorBlockSyntax
    ) -> (getter: CodeBlockItemListSyntax, setter: ComputedProperty.Setter?)? {
        switch accessorBlock.accessors {
        case .getter(let items):
            return (items, nil)
        case .accessors(let list):
            var getter: CodeBlockItemListSyntax?
            var setter: ComputedProperty.Setter?
            for accessor in list {
                guard let body = accessor.body?.statements else { continue }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.get):
                    getter = body
                case .keyword(.set):
                    setter = .init(body: body, parameterName: accessor.parameters?.name.text ?? "newValue")
                default:
                    break // willSet/didSet observers are inert
                }
            }
            guard let getter else { return nil }
            return (getter, setter)
        }
    }

    private func propertyWrapper(of attributes: AttributeListSyntax) -> StructSymbol.Wrapper {
        if hasAttribute(attributes, named: "State") { return .state }
        if hasAttribute(attributes, named: "Binding") { return .binding }
        if hasAttribute(attributes, named: "Published") { return .published }
        if hasAttribute(attributes, named: "StateObject") { return .stateObject }
        if hasAttribute(attributes, named: "ObservedObject") { return .observedObject }
        if hasAttribute(attributes, named: "EnvironmentObject") { return .environmentObject }
        for attribute in attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  attr.attributeName.trimmedDescription == "Environment",
                  case .argumentList(let arguments)? = attr.arguments,
                  let keyPath = arguments.first?.expression.as(KeyPathExprSyntax.self) else { continue }
            let key = String(keyPath.trimmedDescription.dropFirst(2)) // strip "\."
            return .environment(key)
        }
        return .none
    }

    private func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
        attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name }
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }
}
