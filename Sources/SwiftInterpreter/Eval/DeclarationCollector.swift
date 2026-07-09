import SwiftSyntax

/// Pass 1: hoist struct/enum/function declarations from a parsed file into the
/// global environment; pass 2 merges extensions into the collected symbols.
/// Top-level `let`/`var` and expressions are executed in source order by
/// `Interpreter.run` afterwards.
extension Interpreter {
    /// Flattens active `#if` clauses into the top-level item stream.
    func expandedTopLevelItems(_ items: CodeBlockItemListSyntax) -> [CodeBlockItemSyntax] {
        var out: [CodeBlockItemSyntax] = []
        for item in items {
            if case .decl(let decl) = item.item,
               let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                if let clause = activeIfConfigClause(ifConfig),
                   case .statements(let nested)? = clause.elements {
                    out += expandedTopLevelItems(nested)
                }
                continue
            }
            out.append(item)
        }
        return out
    }

    func collectDeclarations(from file: SourceFileSyntax) throws {
        for item in expandedTopLevelItems(file.statements) {
            guard case .decl(let decl) = item.item else { continue }
            if let structDecl = decl.as(StructDeclSyntax.self) {
                try collectStruct(structDecl)
            } else if let classDecl = decl.as(ClassDeclSyntax.self) {
                try collectClass(classDecl)
            } else if let enumDecl = decl.as(EnumDeclSyntax.self) {
                try collectEnum(enumDecl)
            } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
                try defineFunction(funcDecl, in: globals)
            } else if let varDecl = decl.as(VariableDeclSyntax.self), isHoistableGlobal(varDecl) {
                // Top-level globals are LAZY (real Swift semantics for
                // non-main files): forward and cross-file references work,
                // initializers run on first read.
                for binding in varDecl.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    globals.define(ident.identifier.text, .native(LazyGlobal(
                        initializer: binding.initializer?.value,
                        annotation: binding.typeAnnotation?.type
                    )))
                }
            }
        }
        for item in expandedTopLevelItems(file.statements) {
            guard case .decl(let decl) = item.item,
                  let extensionDecl = decl.as(ExtensionDeclSyntax.self) else { continue }
            try collectExtension(extensionDecl)
        }
    }

    /// Only plain identifier bindings hoist; tuple/computed bindings run
    /// in statement order.
    func isHoistableGlobal(_ varDecl: VariableDeclSyntax) -> Bool {
        varDecl.bindings.allSatisfy {
            $0.pattern.is(IdentifierPatternSyntax.self) && $0.accessorBlock == nil
        }
    }

    // MARK: - Conditional compilation

    /// `#if` conditions under the harness's identity: an iOS-shaped canvas.
    /// os(iOS)/canImport(_)/DEBUG/swift(…) hold; os(macOS)/
    /// targetEnvironment(simulator) and anything unknown don't (documented).
    func ifConfigConditionHolds(_ condition: ExprSyntax?) -> Bool {
        guard let condition else { return true } // #else
        if let paren = condition.as(TupleExprSyntax.self), paren.elements.count == 1,
           let only = paren.elements.first {
            return ifConfigConditionHolds(only.expression)
        }
        if let ref = condition.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text == "DEBUG"
        }
        if let call = condition.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let argument = call.arguments.first?.expression.trimmedDescription ?? ""
            switch callee.baseName.text {
            case "os": return argument == "iOS"
            case "canImport": return true
            case "swift", "compiler": return true
            case "targetEnvironment": return false
            default: return false
            }
        }
        if let prefix = condition.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return !ifConfigConditionHolds(prefix.expression)
        }
        if let infix = condition.as(InfixOperatorExprSyntax.self) {
            let op = infix.operator.trimmedDescription
            if op == "&&" {
                return ifConfigConditionHolds(infix.leftOperand) && ifConfigConditionHolds(infix.rightOperand)
            }
            if op == "||" {
                return ifConfigConditionHolds(infix.leftOperand) || ifConfigConditionHolds(infix.rightOperand)
            }
        }
        if let sequence = condition.as(SequenceExprSyntax.self) {
            // #if conditions aren't operator-folded; handle && / || runs.
            let elements = Array(sequence.elements)
            let operators = stride(from: 1, to: elements.count, by: 2).compactMap {
                elements[$0].as(BinaryOperatorExprSyntax.self)?.operator.text
            }
            let operands = stride(from: 0, to: elements.count, by: 2).map { elements[$0] }
            if operators.allSatisfy({ $0 == "&&" }), !operators.isEmpty {
                return operands.allSatisfy { ifConfigConditionHolds($0) }
            }
            if operators.allSatisfy({ $0 == "||" }), !operators.isEmpty {
                return operands.contains { ifConfigConditionHolds($0) }
            }
        }
        return false
    }

    /// The first clause whose condition holds (`#else` always does).
    func activeIfConfigClause(_ node: IfConfigDeclSyntax) -> IfConfigClauseSyntax? {
        node.clauses.first { ifConfigConditionHolds($0.condition) }
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
        symbol.conformsToShape = inherited.contains("Shape") || inherited.contains("InsettableShape")
        symbol.conformances = inherited
        try collectStructMembers(node.memberBlock, into: symbol)
        return symbol
    }

    /// Classes ride the same symbol machinery — Instance is already
    /// reference-backed, which is exactly class semantics. The extra flags
    /// drive observation (`ObservableObject` conformance / `@Observable`).
    private static let knownProtocols: Set<String> = [
        "View", "ObservableObject", "Identifiable", "Codable", "Decodable",
        "Encodable", "Hashable", "Equatable", "Comparable", "CaseIterable",
        "Shape", "InsettableShape", "ViewModifier", "App", "Scene", "Sendable",
        "Error", "CustomStringConvertible", "RandomAccessCollection",
    ]

    private func collectClass(_ node: ClassDeclSyntax) throws {
        let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let symbol = StructSymbol(name: node.name.text, conformsToView: inherited.contains("View"))
        symbol.isClass = true
        symbol.conformances = inherited
        // A superclass, if present, is first in the clause; protocols follow.
        if let first = inherited.first, !Self.knownProtocols.contains(first),
           !first.hasSuffix("Delegate"), !first.hasSuffix("DataSource") {
            symbol.superclassName = first
        }
        symbol.conformsToObservableObject = inherited.contains("ObservableObject")
        symbol.observableViaMacro = node.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Observable"
        }
        try collectStructMembers(node.memberBlock, into: symbol)
        structSymbols.append(symbol)
        globals.define(symbol.name, .type(symbol))
    }

    private func collectStructMembers(_ block: MemberBlockSyntax, into symbol: StructSymbol) throws {
        try collectMemberItems(block.members, into: symbol)
    }

    private func collectMemberItems(_ members: MemberBlockItemListSyntax, into symbol: StructSymbol) throws {
        for member in members {
            if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                if let clause = activeIfConfigClause(ifConfig),
                   case .decls(let nested)? = clause.elements {
                    try collectMemberItems(nested, into: symbol)
                }
                continue
            }
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
                globals.define("\(symbol.name).\(nested.name)", .enumType(nested))
                if globals.lookup(nested.name) == nil {
                    globals.define(nested.name, .enumType(nested))
                }
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
        let (wrapper, environmentObjectType) = propertyWrapper(of: varDecl.attributes)
        // `@Environment(AppData.self) var appData` carries its type in the
        // attribute, not an annotation — synthesize one so injection-by-type
        // works.
        let syntheticAnnotation = environmentObjectType.map {
            TypeSyntax(IdentifierTypeSyntax(name: .identifier($0)))
        }
        // Query wrappers usually have no initializer; a fresh store is empty.
        let queryDefault: ExprSyntax? =
            ["Query", "ObservedResults", "FetchRequest", "SectionedFetchRequest"]
                .contains(where: { hasAttribute(varDecl.attributes, named: $0) })
            ? ExprSyntax(ArrayExprSyntax(elements: ArrayElementListSyntax([])))
            : nil
        let hasBuilderAttribute = varDecl.attributes.contains {
            // @ViewBuilder plus custom @resultBuilders (@ActionBuilder …).
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
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
                let computed = ComputedProperty(
                    accessor: accessors.getter,
                    isBuilder: hasBuilderAttribute || returnsView,
                    setter: accessors.setter
                )
                if isStaticDecl {
                    symbol.staticComputedProperties[name] = computed
                } else {
                    symbol.computedProperties[name] = computed
                }
            } else if isStaticDecl {
                if let initializer = binding.initializer?.value {
                    symbol.staticProperties[name] = .init(
                        initializer: initializer,
                        typeAnnotation: binding.typeAnnotation?.type
                    )
                }
            } else {
                // `@FocusState var focused: Bool` carries no initializer —
                // real SwiftUI defaults it false (optionals stay nil via the
                // uninitialized-optional rule).
                var stateLikeDefault: ExprSyntax?
                if binding.initializer == nil,
                   hasAttribute(varDecl.attributes, named: "FocusState"),
                   binding.typeAnnotation?.type.trimmedDescription.hasSuffix("?") != true {
                    stateLikeDefault = ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(.false)))
                }
                symbol.storedProperties.append(.init(
                    name: name,
                    wrapper: wrapper,
                    initializer: binding.initializer?.value ?? queryDefault ?? stateLikeDefault,
                    typeAnnotation: binding.typeAnnotation?.type ?? syntheticAnnotation,
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
            let hasBuilderAttribute = varDecl.attributes.contains {
            // @ViewBuilder plus custom @resultBuilders (@ActionBuilder …).
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
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
                    symbol.staticProperties[ident.identifier.text] = .init(
                        initializer: initializer,
                        typeAnnotation: binding.typeAnnotation?.type
                    )
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
                label: param.firstName.text == "_" ? nil : param.firstName.text,
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

    /// Wrapper kind plus, for `@Environment(Type.self)`, the type name that
    /// stands in for the (usually absent) property annotation.
    private func propertyWrapper(
        of attributes: AttributeListSyntax
    ) -> (wrapper: StructSymbol.Wrapper, environmentObjectType: String?) {
        if hasAttribute(attributes, named: "State") { return (.state, nil) }
        if hasAttribute(attributes, named: "Binding") { return (.binding, nil) }
        // State-like wrappers behave as plain @State (documented divergence:
        // no UserDefaults persistence, no gesture-reset, no focus plumbing).
        for stateLike in ["AppStorage", "SceneStorage", "GestureState", "FocusState"]
        where hasAttribute(attributes, named: stateLike) {
            return (.state, nil)
        }
        // Store-query wrappers (@Query — SwiftData, @ObservedResults — Realm,
        // @FetchRequest — CoreData) flatten to @State over a fresh-store
        // default: empty results (documented divergence — no persistence,
        // like the state-like list).
        for queryLike in ["Query", "ObservedResults", "FetchRequest", "SectionedFetchRequest"]
        where hasAttribute(attributes, named: queryLike) {
            return (.state, nil)
        }
        if hasAttribute(attributes, named: "Published") { return (.published, nil) }
        if hasAttribute(attributes, named: "StateObject") { return (.stateObject, nil) }
        if hasAttribute(attributes, named: "ObservedObject") { return (.observedObject, nil) }
        if hasAttribute(attributes, named: "EnvironmentObject") { return (.environmentObject, nil) }
        for attribute in attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  attr.attributeName.trimmedDescription == "Environment",
                  case .argumentList(let arguments)? = attr.arguments,
                  let expr = arguments.first?.expression else { continue }
            if let keyPath = expr.as(KeyPathExprSyntax.self) {
                let key = String(keyPath.trimmedDescription.dropFirst(2)) // strip "\."
                return (.environment(key), nil)
            }
            // `@Environment(AppData.self)` — Observation's typed environment,
            // ≡ @EnvironmentObject keyed by type name (injected via
            // `.environment(model)`).
            if let member = expr.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "self",
               let base = member.base {
                return (.environmentObject, base.trimmedDescription)
            }
        }
        return (.none, nil)
    }

    private func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
        attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name }
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }
}
