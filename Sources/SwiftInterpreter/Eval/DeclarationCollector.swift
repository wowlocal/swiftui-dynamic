import Foundation
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
            } else if let actorDecl = decl.as(ActorDeclSyntax.self) {
                try collectActor(actorDecl)
            } else if let enumDecl = decl.as(EnumDeclSyntax.self) {
                try collectEnum(enumDecl)
            } else if let protocolDecl = decl.as(ProtocolDeclSyntax.self) {
                // Only the INHERITANCE is recorded (requirements carry no
                // bodies; defaults live in the protocol's extensions).
                protocolInheritance[protocolDecl.name.text] =
                    protocolDecl.inheritanceClause?.inheritedTypes.map {
                        $0.type.trimmedDescription
                    } ?? []
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
            } else if let varDecl = decl.as(VariableDeclSyntax.self) {
                // `var uptime: String { … }` at file scope — a computed
                // global; the accessor runs on every read. Observer-only
                // globals (didSet) are STORED (observers inert).
                for binding in varDecl.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                          let accessorBlock = binding.accessorBlock else { continue }
                    if let accessors = parseAccessors(of: accessorBlock) {
                        globals.define(ident.identifier.text, .native(ComputedGlobal(
                            accessor: accessors.getter,
                            annotation: binding.typeAnnotation?.type
                        )))
                    } else {
                        globals.define(ident.identifier.text, .native(LazyGlobal(
                            initializer: binding.initializer?.value,
                            annotation: binding.typeAnnotation?.type
                        )))
                    }
                }
            }
        }
        for item in expandedTopLevelItems(file.statements) {
            guard case .decl(let decl) = item.item,
                  let extensionDecl = decl.as(ExtensionDeclSyntax.self) else { continue }
            try collectExtension(extensionDecl)
        }
        // `typealias BlockMatrixType = BlockMatrix<IdentifiedBlock>` — the
        // alias resolves to the target TYPE (generic arguments dropped, like
        // everywhere else). Tuple/function aliases stay inert.
        for item in expandedTopLevelItems(file.statements) {
            guard case .decl(let decl) = item.item,
                  let alias = decl.as(TypeAliasDeclSyntax.self) else { continue }
            var target = alias.initializer.value.trimmedDescription
            if let angle = target.firstIndex(of: "<") { target = String(target[..<angle]) }
            target = target.trimmingCharacters(in: .whitespaces)
            if globals.lookup(alias.name.text) == nil, let value = globals.lookup(target) {
                globals.define(alias.name.text, value)
            }
            if enumSymbols[alias.name.text] == nil, let enumSymbol = enumSymbols[target] {
                enumSymbols[alias.name.text] = enumSymbol
            }
        }
    }

    /// Deferred dotted extensions retry after every declaration pass
    /// completed (full name first, then the module-qualified last
    /// component) — declaration order stops mattering.
    func processDeferredExtensions() {
        deferredExtensionRetry = true
        defer { deferredExtensionRetry = false }
        let pending = pendingDottedExtensions
        pendingDottedExtensions = []
        for node in pending {
            try? collectExtension(node)
        }
    }

    /// Extensions collected BEFORE their extended type existed (an
    /// `extension Pixel.Event` in a file that sorts before the
    /// `extension Pixel { enum Event }` that declares it) strand their
    /// members in a synthetic host-extension symbol. Real Swift is
    /// declaration-order-independent: after all passes, members whose
    /// extended type NOW resolves migrate into the real symbol.
    func reconcileStrandedExtensions() {
        for (typeName, stranded) in hostExtensionSymbols {
            var target = globals.lookup(typeName)
            if target == nil, typeName.contains("."),
               let last = typeName.split(separator: ".").last {
                target = globals.lookup(String(last))
            }
            switch target {
            case .type(let symbol):
                guard symbol !== stranded else { continue }
                for (name, overloads) in stranded.methods {
                    symbol.methods[name, default: []].append(contentsOf: overloads)
                }
                for (name, computed) in stranded.computedProperties
                where symbol.computedProperties[name] == nil {
                    symbol.computedProperties[name] = computed
                }
                for (name, overloads) in stranded.staticMethods {
                    symbol.staticMethods[name, default: []].append(contentsOf: overloads)
                }
                for (name, property) in stranded.staticProperties
                where symbol.staticProperties[name] == nil {
                    symbol.staticProperties[name] = property
                }
                for (name, computed) in stranded.staticComputedProperties
                where symbol.staticComputedProperties[name] == nil {
                    symbol.staticComputedProperties[name] = computed
                }
                for (name, nested) in stranded.nestedTypes
                where symbol.nestedTypes[name] == nil {
                    symbol.nestedTypes[name] = nested
                }
                symbol.initializers.append(contentsOf: stranded.initializers)
                hostExtensionSymbols[typeName] = nil
            case .enumType(let symbol):
                for (name, overloads) in stranded.methods {
                    symbol.methods[name, default: []].append(contentsOf: overloads)
                }
                for (name, computed) in stranded.computedProperties
                where symbol.computedProperties[name] == nil {
                    symbol.computedProperties[name] = computed
                }
                for (name, overloads) in stranded.staticMethods {
                    symbol.staticMethods[name, default: []].append(contentsOf: overloads)
                }
                for (name, property) in stranded.staticProperties
                where symbol.staticProperties[name] == nil {
                    symbol.staticProperties[name] = property
                }
                for (name, computed) in stranded.staticComputedProperties
                where symbol.staticComputedProperties[name] == nil {
                    symbol.staticComputedProperties[name] = computed
                }
                for (name, nested) in stranded.nestedTypes
                where symbol.nestedTypes[name] == nil {
                    symbol.nestedTypes[name] = nested
                }
                symbol.initializers.append(contentsOf: stranded.initializers)
                hostExtensionSymbols[typeName] = nil
            default:
                continue // genuine host types (View, String…) stay synthetic
            }
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
        registerTypeSymbol(symbol)
    }

    /// Duplicate type names (multi-target repos declare ContentView per
    /// platform) resolve LAST-wins consistently: the symbols list — which
    /// picks the root view — must agree with `globals`, or a first-wins
    /// root body binds against last-wins member symbols.
    func registerTypeSymbol(_ symbol: StructSymbol) {
        if let existing = structSymbols.firstIndex(where: { $0.name == symbol.name }) {
            structSymbols[existing] = symbol
        } else {
            structSymbols.append(symbol)
        }
        globals.define(symbol.name, .type(symbol))
    }

    private func recordGenericParameters(_ clause: GenericParameterClauseSyntax?, into symbol: StructSymbol) {
        guard let clause else { return }
        for parameter in clause.parameters {
            symbol.genericParameters[parameter.name.text] =
                parameter.inheritedType?.trimmedDescription ?? ""
        }
    }

    func makeStructSymbol(_ node: StructDeclSyntax) throws -> StructSymbol {
        let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let symbol = StructSymbol(name: node.name.text, conformsToView: inherited.contains("View"))
        recordGenericParameters(node.genericParameterClause, into: symbol)
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
        registerTypeSymbol(try makeClassLikeSymbol(
            name: node.name.text, inheritanceClause: node.inheritanceClause,
            memberBlock: node.memberBlock, attributes: node.attributes))
    }

    /// `actor Store { … }` — collected as a reference-typed class. Isolation
    /// is not enforced: methods run synchronously on the caller (documented
    /// divergence — the interpreter is single-threaded anyway).
    private func collectActor(_ node: ActorDeclSyntax) throws {
        registerTypeSymbol(try makeClassLikeSymbol(
            name: node.name.text, inheritanceClause: node.inheritanceClause,
            memberBlock: node.memberBlock, attributes: node.attributes))
    }

    func makeClassLikeSymbol(
        name: String,
        inheritanceClause: InheritanceClauseSyntax?,
        memberBlock: MemberBlockSyntax,
        attributes: AttributeListSyntax
    ) throws -> StructSymbol {
        let inherited = inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        let symbol = StructSymbol(name: name, conformsToView: inherited.contains("View"))
        symbol.isClass = true
        symbol.conformances = inherited
        // A superclass, if present, is first in the clause; protocols follow.
        if let first = inherited.first, !Self.knownProtocols.contains(first),
           !first.hasSuffix("Delegate"), !first.hasSuffix("DataSource") {
            symbol.superclassName = first
        }
        symbol.conformsToObservableObject = inherited.contains("ObservableObject")
        symbol.observableViaMacro = attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Observable"
        }
        try collectStructMembers(memberBlock, into: symbol)
        return symbol
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
                    symbol.staticMethods[funcDecl.name.text, default: []].append(funcDecl)
                } else {
                    symbol.methods[funcDecl.name.text, default: []].append(funcDecl)
                }
            } else if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
                symbol.initializers.append(initDecl)
            } else if let alias = member.decl.as(TypeAliasDeclSyntax.self) {
                // Member typealiases resolve like nested types (bare name
                // when unclaimed); generic arguments drop.
                var target = alias.initializer.value.trimmedDescription
                if let angle = target.firstIndex(of: "<") { target = String(target[..<angle]) }
                target = target.trimmingCharacters(in: .whitespaces)
                if let value = globals.lookup(target) {
                    symbol.nestedTypes[alias.name.text] = value
                    if globals.lookup(alias.name.text) == nil {
                        globals.define(alias.name.text, value)
                    }
                }
                if enumSymbols[alias.name.text] == nil, let enumSymbol = enumSymbols[target] {
                    enumSymbols[alias.name.text] = enumSymbol
                }
            } else if let subscriptDecl = member.decl.as(SubscriptDeclSyntax.self),
                      let accessorBlock = subscriptDecl.accessorBlock,
                      let accessors = parseAccessors(of: accessorBlock) {
                let parameters = subscriptDecl.parameterClause.parameters.map { param in
                    ClosureValue.Parameter(
                        name: (param.secondName ?? param.firstName).text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                        label: param.firstName.text == "_" ? nil : param.firstName.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                        defaultValue: param.defaultValue?.value,
                        typeAnnotation: param.type
                    )
                }
                symbol.subscripts.append(.init(
                    parameters: parameters, getter: accessors.getter, setter: accessors.setter))
            } else if let nestedEnum = member.decl.as(EnumDeclSyntax.self) {
                // Nested types register under `Outer.Name` (for annotations)
                // and the bare name when unclaimed (for in-scope references).
                let nested = try makeEnumSymbol(nestedEnum)
                symbol.nestedTypes[nested.name] = .enumType(nested)
                enumSymbols["\(symbol.name).\(nested.name)"] = nested
                // Bare-name registration is FIRST-WINS, never a union:
                // sibling nested enums are distinct types (EhPanda's
                // generated-strings namespace vs its settings enum) whose
                // extension members attach to the specific dotted symbol.
                // Inside an enclosing type, its OWN nested enum wins via
                // nestedTypes regardless of the bare claimant.
                if enumSymbols[nested.name] == nil { enumSymbols[nested.name] = nested }
                globals.define("\(symbol.name).\(nested.name)", .enumType(nested))
                if globals.lookup(nested.name) == nil {
                    globals.define(nested.name, .enumType(nested))
                }
            } else if let nestedStruct = member.decl.as(StructDeclSyntax.self) {
                let nestedSymbol = try makeStructSymbol(nestedStruct)
                registerNestedType(nestedSymbol, in: symbol)
            } else if let nestedClass = member.decl.as(ClassDeclSyntax.self) {
                // Nested classes (UserPreferences.Storage) register like
                // nested structs — reference-typed.
                let nestedSymbol = try makeClassLikeSymbol(
                    name: nestedClass.name.text, inheritanceClause: nestedClass.inheritanceClause,
                    memberBlock: nestedClass.memberBlock, attributes: nestedClass.attributes)
                registerNestedType(nestedSymbol, in: symbol)
            } else if let nestedActor = member.decl.as(ActorDeclSyntax.self) {
                let nestedSymbol = try makeClassLikeSymbol(
                    name: nestedActor.name.text, inheritanceClause: nestedActor.inheritanceClause,
                    memberBlock: nestedActor.memberBlock, attributes: nestedActor.attributes)
                registerNestedType(nestedSymbol, in: symbol)
            }
        }
    }

    private func registerNestedType(_ nestedSymbol: StructSymbol, in symbol: StructSymbol) {
        symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
        structSymbols.append(nestedSymbol)
        globals.define("\(symbol.name).\(nestedSymbol.name)", .type(nestedSymbol))
        if globals.lookup(nestedSymbol.name) == nil {
            globals.define(nestedSymbol.name, .type(nestedSymbol))
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
        var queryDefault: ExprSyntax? =
            ["Query", "ObservedResults", "FetchRequest", "SectionedFetchRequest"]
                .contains(where: { hasAttribute(varDecl.attributes, named: $0) })
            ? ExprSyntax(ArrayExprSyntax(elements: ArrayElementListSyntax([])))
            : nil
        // CUSTOM property wrappers carrying their default in the attribute
        // (`@Setting(key:, default_value: .production)`): a fresh store has
        // nothing persisted, so the declared default IS the value.
        if queryDefault == nil {
            for attribute in varDecl.attributes {
                guard let attr = attribute.as(AttributeSyntax.self),
                      case .argumentList(let arguments)? = attr.arguments else { continue }
                for label in ["default_value", "defaultValue", "wrappedValue"] {
                    if let match = arguments.first(where: { $0.label?.text == label }) {
                        queryDefault = match.expression
                        break
                    }
                }
                if queryDefault != nil { break }
            }
        }
        let hasBuilderAttribute = varDecl.attributes.contains {
            // @ViewBuilder plus custom @resultBuilders (@ActionBuilder …).
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
        let isStaticDecl = isStatic(varDecl.modifiers)

        for binding in varDecl.bindings {
            // Tuple-pattern stored properties (`let (first, second, third):
            // (A, B, C)`) declare each element; annotations split when the
            // tuple type's arity matches.
            if let tuplePattern = binding.pattern.as(TuplePatternSyntax.self) {
                let elements = Array(tuplePattern.elements)
                let tupleTypes: [TypeSyntax?]
                if let tupleType = binding.typeAnnotation?.type.as(TupleTypeSyntax.self),
                   tupleType.elements.count == elements.count {
                    tupleTypes = tupleType.elements.map { $0.type }
                } else {
                    tupleTypes = Array(repeating: nil, count: elements.count)
                }
                for (element, elementType) in zip(elements, tupleTypes) {
                    guard let ident = element.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    symbol.storedProperties.append(StructSymbol.StoredProperty(
                        name: ident.identifier.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                        wrapper: .none,
                        initializer: nil,
                        typeAnnotation: elementType,
                        isBuilderClosure: false
                    ))
                }
                continue
            }
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw error(binding, "unsupported property pattern")
            }
            let name = ident.identifier.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            // A binding with an accessor block is computed only if it has a
            // getter; willSet/didSet-only observers mean a stored property
            // whose observers run on assignment (see the write funnel).
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
                } else {
                    // `static var shared: ChatClient!` — nil until written.
                    symbol.staticUninitialized.insert(name)
                }
            } else {
                // `@FocusState var focused: Bool` carries no initializer —
                // real SwiftUI defaults it false (optionals stay nil via the
                // uninitialized-optional rule).
                var stateLikeDefault: ExprSyntax?
                if binding.initializer == nil,
                   hasAttribute(varDecl.attributes, named: "FocusState"),
                   binding.typeAnnotation?.type.trimmedDescription == "Bool" {
                    stateLikeDefault = ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(.false)))
                }
                var stored = StructSymbol.StoredProperty(
                    name: name,
                    wrapper: wrapper,
                    initializer: binding.initializer?.value ?? queryDefault ?? stateLikeDefault,
                    typeAnnotation: binding.typeAnnotation?.type ?? syntheticAnnotation,
                    isBuilderClosure: hasBuilderAttribute
                )
                stored.isLazy = varDecl.modifiers.contains { $0.name.text == "lazy" }
                // `var timeline: Filter = .home { didSet { … } }` — the
                // fetch-trigger genre lives in observers.
                if let accessorBlock = binding.accessorBlock,
                   case .accessors(let list) = accessorBlock.accessors {
                    for accessor in list {
                        guard let body = accessor.body?.statements else { continue }
                        switch accessor.accessorSpecifier.tokenKind {
                        case .keyword(.willSet):
                            stored.willSetBody = body
                            stored.willSetParameter = accessor.parameters?.name.text ?? "newValue"
                        case .keyword(.didSet):
                            stored.didSetBody = body
                            stored.didSetParameter = accessor.parameters?.name.text ?? "oldValue"
                        default:
                            break
                        }
                    }
                }
                symbol.storedProperties.append(stored)
            }
        }
    }

    // MARK: - Enums

    private func collectEnum(_ node: EnumDeclSyntax) throws {
        let symbol = try makeEnumSymbol(node)
        if let existing = enumSymbols[symbol.name], existing !== symbol {
            // SIBLING app targets in a monorepo declare the same namespace
            // (Rayon + mRayon both ship `enum UIBridge`): members UNION —
            // separate targets never collide on device.
            Self.union(symbol, into: existing)
            return
        }
        enumSymbols[symbol.name] = symbol
        globals.define(symbol.name, .enumType(symbol))
    }

    /// Union `symbol`'s members into `existing` (sibling-target namespaces).
    static func union(_ symbol: EnumSymbol, into existing: EnumSymbol) {
        for enumCase in symbol.cases
        where !existing.cases.contains(where: { $0.name == enumCase.name }) {
            existing.cases.append(enumCase)
        }
        for (name, overloads) in symbol.methods {
            existing.methods[name, default: []].append(contentsOf: overloads)
        }
        for (name, overloads) in symbol.staticMethods {
            existing.staticMethods[name, default: []].append(contentsOf: overloads)
        }
        for (name, property) in symbol.staticProperties
        where existing.staticProperties[name] == nil {
            existing.staticProperties[name] = property
        }
        for (name, computed) in symbol.computedProperties
        where existing.computedProperties[name] == nil {
            existing.computedProperties[name] = computed
        }
        for (name, computed) in symbol.staticComputedProperties
        where existing.staticComputedProperties[name] == nil {
            existing.staticComputedProperties[name] = computed
        }
        for (name, nested) in symbol.nestedTypes
        where existing.nestedTypes[name] == nil {
            existing.nestedTypes[name] = nested
        }
        existing.initializers.append(contentsOf: symbol.initializers)
        for conformance in symbol.conformances
        where !existing.conformances.contains(conformance) {
            existing.conformances.append(conformance)
        }
    }

    /// Local enum declarations collect WITHOUT global registration.
    func makeLocalEnumSymbol(_ node: EnumDeclSyntax) throws -> EnumSymbol {
        try makeEnumSymbol(node)
    }

    private func makeEnumSymbol(_ node: EnumDeclSyntax) throws -> EnumSymbol {
        let symbol = EnumSymbol(name: node.name.text)
        symbol.conformances = node.inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription
        } ?? []
        symbol.attributeNames = node.attributes.compactMap {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
        }
        let rawIsString = symbol.conformances.contains("String")

        var nextIntRaw = 0
        for decl in flattenedMemberDecls(node.memberBlock.members) {
            if let caseDecl = decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    // `case \`default\`` — backticks normalize away, like
                    // parameters and labels everywhere else.
                    let caseName = element.name.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                    let labels: [String?] = element.parameterClause?.parameters.map { $0.firstName?.text } ?? []
                    let raw: RuntimeValue
                    if let rawExpr = element.rawValue?.value {
                        raw = try evaluate(rawExpr, in: globals)
                    } else if rawIsString {
                        raw = .native(caseName)
                    } else {
                        raw = .native(nextIntRaw)
                    }
                    if let intRaw = raw.intValue { nextIntRaw = intRaw + 1 }
                    symbol.cases.append(.init(name: caseName, associatedLabels: labels, rawValue: raw))
                }
            } else {
                try collectEnumMember(decl, into: symbol)
            }
        }
        return symbol
    }

    /// Member declarations with `#if` blocks expanded to their active clause
    /// (design-token enums split statics across canImport(UIKit)/AppKit).
    private func flattenedMemberDecls(_ members: MemberBlockItemListSyntax) -> [DeclSyntax] {
        var result: [DeclSyntax] = []
        for member in members {
            if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                if let clause = activeIfConfigClause(ifConfig),
                   case .decls(let nested)? = clause.elements {
                    result.append(contentsOf: flattenedMemberDecls(nested))
                }
                continue
            }
            result.append(member.decl)
        }
        return result
    }

    private func collectEnumMember(_ decl: DeclSyntax, into symbol: EnumSymbol) throws {
        if let initDecl = decl.as(InitializerDeclSyntax.self) {
            symbol.initializers.append(initDecl)
            return
        }
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            let hasBuilderAttribute = varDecl.attributes.contains {
            // @ViewBuilder plus custom @resultBuilders (@ActionBuilder …).
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
        }
            let isStaticDecl = isStatic(varDecl.modifiers)
            for binding in varDecl.bindings {
                guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                // Backticked members (`static var \`default\``) normalize,
                // like cases and struct properties everywhere else.
                let memberName = ident.identifier.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if let accessorBlock = binding.accessorBlock,
                   let accessors = parseAccessors(of: accessorBlock) {
                    let returnsView = binding.typeAnnotation?.type.trimmedDescription.contains("some View") ?? false
                    if isStaticDecl {
                        symbol.staticComputedProperties[memberName] = ComputedProperty(
                            accessor: accessors.getter,
                            isBuilder: hasBuilderAttribute || returnsView,
                            setter: accessors.setter
                        )
                        continue
                    }
                    symbol.computedProperties[memberName] = ComputedProperty(
                        accessor: accessors.getter,
                        isBuilder: hasBuilderAttribute || returnsView,
                        setter: accessors.setter
                    )
                } else if isStaticDecl, let initializer = binding.initializer?.value {
                    symbol.staticProperties[memberName] = .init(
                        initializer: initializer,
                        typeAnnotation: binding.typeAnnotation?.type
                    )
                }
            }
        } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            if isStatic(funcDecl.modifiers) {
                symbol.staticMethods[funcDecl.name.text, default: []].append(funcDecl)
            } else {
                symbol.methods[funcDecl.name.text, default: []].append(funcDecl)
            }
        } else if let nestedEnum = decl.as(EnumDeclSyntax.self) {
            // Enums are namespaces as often as value types
            // (`TestCase.Cases.allCases`) — nested types register under the
            // dotted name and the bare name when unclaimed, mirroring the
            // struct path.
            let nested = try makeEnumSymbol(nestedEnum)
            symbol.nestedTypes[nested.name] = .enumType(nested)
            enumSymbols["\(symbol.name).\(nested.name)"] = nested
            if enumSymbols[nested.name] == nil { enumSymbols[nested.name] = nested }
            globals.define("\(symbol.name).\(nested.name)", .enumType(nested))
            if globals.lookup(nested.name) == nil {
                globals.define(nested.name, .enumType(nested))
            }
        } else if let nestedStruct = decl.as(StructDeclSyntax.self) {
            let nestedSymbol = try makeStructSymbol(nestedStruct)
            symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
            structSymbols.append(nestedSymbol)
            globals.define("\(symbol.name).\(nestedSymbol.name)", .type(nestedSymbol))
            if globals.lookup(nestedSymbol.name) == nil {
                globals.define(nestedSymbol.name, .type(nestedSymbol))
            }
        } else if let nestedClass = decl.as(ClassDeclSyntax.self) {
            let nestedSymbol = try makeClassLikeSymbol(
                name: nestedClass.name.text, inheritanceClause: nestedClass.inheritanceClause,
                memberBlock: nestedClass.memberBlock, attributes: nestedClass.attributes)
            symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
            structSymbols.append(nestedSymbol)
            globals.define("\(symbol.name).\(nestedSymbol.name)", .type(nestedSymbol))
            if globals.lookup(nestedSymbol.name) == nil {
                globals.define(nestedSymbol.name, .type(nestedSymbol))
            }
        }
    }

    // MARK: - Extensions

    private func collectExtension(_ node: ExtensionDeclSyntax) throws {
        let typeName = node.extendedType.trimmedDescription
        // A DOTTED extended type that doesn't resolve yet may be declared
        // by a LATER extension in the same pass (`extension Pixel.Event`
        // in a file sorting before `extension Pixel { enum Event }`) —
        // defer it; the post-pass retries once every type exists.
        if globals.lookup(typeName) == nil, typeName.contains("."),
           !deferredExtensionRetry {
            pendingDottedExtensions.append(node)
            return
        }
        // `extension Models.Visibility` — module-qualified names resolve to
        // the declared bare type when the FULL (possibly nested-dotted)
        // name misses; the merge has no modules.
        var extended = globals.lookup(typeName)
        if extended == nil, typeName.contains("."),
           let last = typeName.split(separator: ".").last {
            switch globals.lookup(String(last)) {
            case .type(let symbol): extended = .type(symbol)
            case .enumType(let symbol): extended = .enumType(symbol)
            default: break
            }
        }
        switch extended {
        case .type(let symbol):
            try collectStructMembers(node.memberBlock, into: symbol)
        case .enumType(let symbol):
            for decl in flattenedMemberDecls(node.memberBlock.members) {
                try collectEnumMember(decl, into: symbol)
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
            // Bodyless declarations are extern/C bridges (@_silgen_name
            // Carbon privates): inert absorbers, like the C-interop family.
            let name = node.name.text
            env.define(name, .hostFunction(HostFunction(name: name) { _, _ in
                .native(ChainedImplicitCall(
                    base: .implicitMember(name), member: "call", arguments: CallArguments()))
            }))
            return
        }
        env.define(node.name.text, .closure(makeFunctionClosure(node, body: body, captured: env)))
        if env === globals {
            globalFunctionOverloads[node.name.text, default: []].append(node)
        }
    }

    func makeFunctionClosure(_ node: FunctionDeclSyntax, body: CodeBlockSyntax, captured: Environment) -> ClosureValue {
        let metadata = functionMetadata(for: node)
        let closure = ClosureValue(
            parameters: metadata.parameters,
            body: body.statements,
            captured: captured,
            isBuilder: metadata.isBuilder,
            returnType: metadata.returnType,
            returnTypeName: metadata.returnTypeName
        )
        closure.functionDeclID = node.id
        closure.genericParameters = metadata.genericParameters
        closure.debugName = node.name.text
        return closure
    }

    // MARK: - Helpers

    /// nil ⇒ no getter (willSet/didSet observers only): treat as stored.
    func parseAccessors(
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
        for stateLike in ["AppStorage", "SceneStorage", "GestureState", "FocusState", "Default"]
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
        // Realm's @StateRealmObject owns its object like @StateObject.
        if hasAttribute(attributes, named: "StateRealmObject") { return (.stateObject, nil) }
        if hasAttribute(attributes, named: "ObservedObject") { return (.observedObject, nil) }
        // @Bindable wraps an observable reference type; `$store.field`
        // projects bindings into the model — @ObservedObject-shaped in our
        // box-level notification model. Realm's @ObservedRealmObject
        // projects member bindings the same way ($task.taskStatus).
        if hasAttribute(attributes, named: "Bindable") { return (.observedObject, nil) }
        if hasAttribute(attributes, named: "ObservedRealmObject") { return (.observedObject, nil) }
        if hasAttribute(attributes, named: "EnvironmentObject") { return (.environmentObject, nil) }
        // DI-container wrappers (FactoryKit's @InjectedObservable/@Injected):
        // a container provides shared instances — environment-object shaped,
        // typed by the annotation or the capitalized keypath component
        // (`\.navigationManager` → NavigationManager).
        for attribute in attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  ["InjectedObservable", "Injected", "LazyInjected", "WeakLazyInjected", "InjectedObject"]
                      .contains(attr.attributeName.trimmedDescription) else { continue }
            var typeName: String?
            if case .argumentList(let arguments)? = attr.arguments,
               let keyPath = arguments.first?.expression.as(KeyPathExprSyntax.self),
               let component = keyPath.components.last?.trimmedDescription
                   .split(separator: ".").last.map(String.init),
               let first = component.first {
                typeName = String(first).uppercased() + component.dropFirst()
            }
            return (.environmentObject, typeName)
        }
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
        attributes.contains {
            guard let text = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription else {
                return false
            }
            // Module-qualified spellings resolve to the same wrapper:
            // @Perception.Bindable ≡ @Bindable, @SwiftUI.State ≡ @State.
            return text == name || text.hasSuffix("." + name)
        }
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }
}
