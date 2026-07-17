import Foundation
import SwiftSyntax

/// Materialize one build-resolved immutable declaration plan into mutable
/// session symbols. Pass 1 hoists nominal/function/global declarations into
/// the global environment; pass 2 merges extensions into those symbols.
/// Top-level `let`/`var` and expressions are executed in source order by
/// `Interpreter.run` afterwards.
extension Interpreter {
    func collectDeclarations(
        from plan: ResolvedDeclarationPlan
    ) throws {
        pendingDeinitializerIsolationChecks.removeAll(keepingCapacity: true)
        for declaration in plan.primaryDeclarations {
            switch declaration {
            case .structure(let declaration):
                try collectStruct(declaration)
            case .classType(let declaration):
                try collectClass(declaration)
            case .actor(let declaration):
                try collectActor(declaration)
            case .enumeration(let declaration):
                try collectEnum(declaration)
            case .protocolType(let declaration):
                // Only the INHERITANCE is recorded (requirements carry no
                // bodies; defaults live in the protocol's extensions).
                let metadata = nominalMetadata(for: declaration)
                protocolInheritance[metadata.name] =
                    metadata.inheritedTypeNames
            case .function(let declaration):
                try defineFunction(declaration, in: globals)
            case .variable(let declaration):
                try collectGlobalVariable(declaration)
            }
        }
        // Alias HEADS first: `typealias LoadableSubject<T> = Binding<…>`
        // makes `extension LoadableSubject` a Binding extension — the
        // mapping must exist before extensions collect.
        for alias in plan.typeAliases {
            let metadata = typeAliasMetadata(for: alias)
            if metadata.isNominalTarget {
                aliasHeads[metadata.name] = metadata.lookupTargetName
            }
        }
        for declaration in plan.extensionDeclarations {
            try collectExtension(declaration)
        }
        // `typealias BlockMatrixType = BlockMatrix<IdentifiedBlock>` — the
        // alias resolves to the target TYPE (generic arguments dropped, like
        // everywhere else). Tuple/function aliases stay inert.
        for alias in plan.typeAliases {
            let metadata = typeAliasMetadata(for: alias)
            let target = metadata.lookupTargetName
            if globals.lookup(metadata.name) == nil,
               let value = globals.lookup(target) {
                globals.define(metadata.name, value)
            }
            if enumSymbols[metadata.name] == nil,
               let enumSymbol = enumSymbols[target] {
                enumSymbols[metadata.name] = enumSymbol
            }
        }
    }

    private func collectGlobalVariable(
        _ declaration: VariableDeclSyntax
    ) throws {
        let declarationMetadata = propertyMetadata(for: declaration)
        if isHoistableGlobal(declaration) {
            // Top-level globals are LAZY (real Swift semantics for non-main
            // files): forward and cross-file references work, initializers
            // run on first read.
            let ownership = declarationMetadata.referenceOwnership
            for binding in declaration.bindings {
                let bindingMetadata = propertyMetadata(for: binding)
                guard let name = bindingMetadata.identifierName else {
                    continue
                }
                globals.define(
                    name,
                    .native(LazyGlobal(
                        initializer: bindingMetadata.initializer,
                        annotation: bindingMetadata.typeAnnotation)),
                    declaredTypeName:
                        bindingMetadata.typeAnnotation?.trimmedDescription,
                    referenceOwnership: ownership)
            }
            return
        }

        // `var uptime: String { … }` at file scope — a computed global; the
        // accessor runs on every read. Observer-only globals (didSet) are
        // stored, with observers currently inert.
        for binding in declaration.bindings {
            let bindingMetadata = propertyMetadata(for: binding)
            guard let name = bindingMetadata.identifierName,
                  let accessorBlock = binding.accessorBlock else { continue }
            if bindingMetadata.isComputed,
               let accessors = parseAccessors(of: accessorBlock) {
                globals.define(
                    name,
                    .native(ComputedGlobal(
                        accessor: accessors.getter,
                        annotation: bindingMetadata.typeAnnotation)),
                    declaredTypeName:
                        bindingMetadata.typeAnnotation?.trimmedDescription)
            } else {
                globals.define(
                    name,
                    .native(LazyGlobal(
                        initializer: bindingMetadata.initializer,
                        annotation: bindingMetadata.typeAnnotation)),
                    declaredTypeName:
                        bindingMetadata.typeAnnotation?.trimmedDescription,
                    referenceOwnership: declarationMetadata.referenceOwnership)
            }
        }
    }

    /// Deferred dotted extensions retry after every declaration pass
    /// completed (full name first, then the module-qualified last
    /// component) — declaration order stops mattering.
    func resolvePendingMemberAliases() {
        for (symbol, aliasName, target) in pendingMemberAliases {
            guard symbol.nestedTypes[aliasName] == nil,
                  let value = globals.lookup(target) else { continue }
            symbol.nestedTypes[aliasName] = value
        }
        pendingMemberAliases.removeAll()
    }

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
                    for decl in overloads { declLexicalOwners[decl.id] = symbol }
                    symbol.methods[name, default: []].append(contentsOf: overloads)
                }
                for (name, computed) in stranded.computedProperties
                where symbol.computedProperties[name] == nil {
                    if let id = computed.declarationID { declLexicalOwners[id] = symbol }
                    symbol.computedProperties[name] = computed
                }
                for (name, overloads) in stranded.staticMethods {
                    symbol.staticMethods[name, default: []].append(contentsOf: overloads)
                }
                for (name, property) in stranded.staticProperties
                where symbol.staticProperties[name] == nil {
                    symbol.staticProperties[name] = property
                }
                for (name, declaration) in stranded.taskLocalProperties
                where symbol.taskLocalProperties[name] == nil {
                    symbol.taskLocalProperties[name] = declaration
                }
                for (name, computed) in stranded.staticComputedProperties
                where symbol.staticComputedProperties[name] == nil {
                    if let id = computed.declarationID { declLexicalOwners[id] = symbol }
                    symbol.staticComputedProperties[name] = computed
                }
                for (name, nested) in stranded.nestedTypes
                where symbol.nestedTypes[name] == nil {
                    symbol.nestedTypes[name] = nested
                }
                for initializer in stranded.initializers {
                    declLexicalOwners[initializer.id] = symbol
                }
                symbol.initializers.append(contentsOf: stranded.initializers)
                hostExtensionSymbols[typeName] = nil
            case .enumType(let symbol):
                for (name, overloads) in stranded.methods {
                    for decl in overloads { declLexicalOwners[decl.id] = symbol }
                    symbol.methods[name, default: []].append(contentsOf: overloads)
                }
                for (name, computed) in stranded.computedProperties
                where symbol.computedProperties[name] == nil {
                    if let id = computed.declarationID { declLexicalOwners[id] = symbol }
                    symbol.computedProperties[name] = computed
                }
                for (name, overloads) in stranded.staticMethods {
                    symbol.staticMethods[name, default: []].append(contentsOf: overloads)
                }
                for (name, property) in stranded.staticProperties
                where symbol.staticProperties[name] == nil {
                    symbol.staticProperties[name] = property
                }
                for (name, declaration) in stranded.taskLocalProperties
                where symbol.taskLocalProperties[name] == nil {
                    symbol.taskLocalProperties[name] = declaration
                }
                for (name, policy) in stranded.staticStoragePolicies
                where symbol.staticStoragePolicies[name] == nil {
                    symbol.staticStoragePolicies[name] = policy
                }
                symbol.staticUninitialized.formUnion(stranded.staticUninitialized)
                for (name, computed) in stranded.staticComputedProperties
                where symbol.staticComputedProperties[name] == nil {
                    if let id = computed.declarationID { declLexicalOwners[id] = symbol }
                    symbol.staticComputedProperties[name] = computed
                }
                for (name, nested) in stranded.nestedTypes
                where symbol.nestedTypes[name] == nil {
                    symbol.nestedTypes[name] = nested
                }
                for initializer in stranded.initializers {
                    declLexicalOwners[initializer.id] = symbol
                }
                symbol.initializers.append(contentsOf: stranded.initializers)
                hostExtensionSymbols[typeName] = nil
            default:
                continue // genuine host types (View, String…) stay synthetic
            }
        }
    }

    /// Classify custom actor executors only after extensions and protocol
    /// refinement are available. Merely declaring the actor remains legal;
    /// isolated entry uses this metadata to fail closed instead of replacing
    /// Swift's source-selected executor with the interpreter mailbox.
    func resolveActorExecutorRequirements() {
        for symbol in structSymbols where symbol.isActor {
            var requiresCustomExecutor =
                symbol.storedProperty(named: "unownedExecutor") != nil
                || symbol.computedProperties["unownedExecutor"] != nil
            if !requiresCustomExecutor {
                requiresCustomExecutor = transitiveConformances(of: symbol)
                    .contains { conformance in
                        guard let defaults = hostExtensionSymbols[conformance]
                        else { return false }
                        return defaults.storedProperty(
                            named: "unownedExecutor") != nil
                            || defaults.computedProperties[
                                "unownedExecutor"] != nil
                    }
            }
            symbol.requiresCustomExecutorDispatch = requiresCustomExecutor
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

    /// Target-aware execution must never guess a compiler-owned conditional
    /// answer. Validate the whole syntax tree before declaration collection or
    /// top-level mutation; legacy source-only callers retain their historical
    /// best-effort behavior.
    func validateTargetConditionalCompilationQueries(
        in file: SourceFileSyntax
    ) throws {
        guard let conditionalAnswers =
                buildConfiguration.authoritativeConditionalCompilationQueries,
              let versionedImportAnswers =
                buildConfiguration.authoritativeVersionedImportQueries
        else { return }

        let directlyInterpretedPredicates: Set<String> = [
            "os", "arch", "canImport", "swift", "compiler",
            "targetEnvironment",
        ]
        var pending = [Syntax(file)]
        while let syntax = pending.popLast() {
            if let clause = syntax.as(IfConfigClauseSyntax.self),
               let condition = clause.condition {
                var conditionNodes = [Syntax(condition)]
                while let conditionNode = conditionNodes.popLast() {
                    if let call = conditionNode.as(
                        FunctionCallExprSyntax.self),
                       let callee = call.calledExpression.as(
                        DeclReferenceExprSyntax.self) {
                        let predicate = callee.baseName.text
                        if predicate == "canImport", call.arguments.count == 2,
                           let versionArgument = call.arguments.last,
                           let versionKind = versionArgument.label?.text,
                           versionKind == "_version"
                            || versionKind == "_underlyingVersion" {
                            let module = call.arguments.first?.expression
                                .trimmedDescription ?? ""
                            let version = versionArgument.expression
                                .trimmedDescription
                            let identity = module + "\u{0}" + versionKind
                                + "\u{0}" + version
                            guard versionedImportAnswers[identity] != nil else {
                                throw error(
                                    call,
                                    "target manifest has no authoritative "
                                        + "answer for "
                                        + call.trimmedDescription)
                            }
                        } else if !directlyInterpretedPredicates.contains(
                            predicate) {
                            let argument = call.arguments.count == 1
                                && call.arguments.first?.label == nil
                                ? call.arguments.first?.expression
                                    .trimmedDescription ?? ""
                                : ""
                            let identity = predicate + "\u{0}" + argument
                            guard conditionalAnswers[identity] != nil else {
                                throw error(
                                    call,
                                    "target manifest has no authoritative "
                                        + "answer for "
                                        + call.trimmedDescription)
                            }
                        }
                    }
                    conditionNodes.append(contentsOf:
                        conditionNode.children(viewMode: .sourceAccurate))
                }
            }
            pending.append(contentsOf:
                syntax.children(viewMode: .sourceAccurate))
        }
    }

    /// `#if` conditions under this interpreter's immutable build identity.
    /// Legacy construction remains iOS-shaped with DEBUG enabled; project
    /// construction derives platform, environment, architecture, and active
    /// conditions from the compiler-preflight build target.
    func ifConfigConditionHolds(_ condition: ExprSyntax?) -> Bool {
        guard let condition else { return true } // #else
        if let paren = condition.as(TupleExprSyntax.self), paren.elements.count == 1,
           let only = paren.elements.first {
            return ifConfigConditionHolds(only.expression)
        }
        if let ref = condition.as(DeclReferenceExprSyntax.self) {
            return buildConfiguration.activeCompilationConditions.contains(
                ref.baseName.text)
        }
        if let call = condition.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let argument = call.arguments.first?.expression.trimmedDescription ?? ""
            switch callee.baseName.text {
            case "os":
                return argument == buildConfiguration.platformName
            case "arch":
                return argument == buildConfiguration.architecture
            case "canImport":
                if call.arguments.count == 2,
                   let versionArgument = call.arguments.last,
                   let versionKind = versionArgument.label?.text,
                   versionKind == "_version"
                        || versionKind == "_underlyingVersion" {
                    return buildConfiguration.canImport(
                        argument,
                        versionKind: versionKind,
                        version: versionArgument.expression
                            .trimmedDescription)
                }
                if call.arguments.count != 1,
                   buildConfiguration.authoritativeImportableModules != nil {
                    return false
                }
                return buildConfiguration.canImport(argument)
            case "swift":
                return buildConfiguration.swiftConditionalCompilationVersion?
                    .satisfies(argument) ?? true
            case "compiler":
                return buildConfiguration.compilerVersion?
                    .satisfies(argument) ?? true
            case "targetEnvironment":
                return argument == buildConfiguration.targetEnvironment
            default:
                return buildConfiguration.conditionalCompilationQuery(
                    predicate: callee.baseName.text,
                    argument: argument) ?? false
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

    private func recordGenericParameters(
        _ parameters: [ParsedNominalMetadata.GenericParameter],
        into symbol: StructSymbol
    ) {
        for parameter in parameters {
            symbol.genericParameters[parameter.name] =
                parameter.inheritedTypeName ?? ""
            symbol.orderedGenericParameters.append(parameter.name)
        }
    }

    func makeStructSymbol(_ node: StructDeclSyntax) throws -> StructSymbol {
        let metadata = nominalMetadata(for: node)
        let inherited = metadata.inheritedTypeNames
        let symbol = StructSymbol(
            name: metadata.name,
            conformsToView: inherited.contains("View"))
        recordGenericParameters(metadata.genericParameters, into: symbol)
        symbol.isRepresentable = inherited.contains { $0.hasSuffix("Representable") }
        symbol.conformsToShape = inherited.contains("Shape") || inherited.contains("InsettableShape")
        symbol.conformances = inherited
        symbol.attributeNames = metadata.attributeNames
        symbol.observableViaMacro = symbol.attributeNames.contains("Observable")
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
        registerTypeSymbol(try makeClassLikeSymbol(node))
    }

    /// Actors share the nominal-member collector with classes but retain their
    /// language kind. Instance allocation assigns the runtime actor identity;
    /// isolated member closures then enter that actor's logical executor.
    private func collectActor(_ node: ActorDeclSyntax) throws {
        registerTypeSymbol(try makeClassLikeSymbol(node))
    }

    func makeClassLikeSymbol(
        _ node: ClassDeclSyntax
    ) throws -> StructSymbol {
        try makeClassLikeSymbol(
            metadata: nominalMetadata(for: node),
            memberBlock: node.memberBlock)
    }

    func makeClassLikeSymbol(
        _ node: ActorDeclSyntax
    ) throws -> StructSymbol {
        try makeClassLikeSymbol(
            metadata: nominalMetadata(for: node),
            memberBlock: node.memberBlock)
    }

    private func makeClassLikeSymbol(
        metadata: ParsedNominalMetadata,
        memberBlock: MemberBlockSyntax
    ) throws -> StructSymbol {
        let inherited = metadata.inheritedTypeNames
        let symbol = StructSymbol(
            name: metadata.name,
            conformsToView: inherited.contains("View"))
        symbol.isClass = true
        symbol.isActor = metadata.kind == .actor
        symbol.conformances = inherited
        // A superclass, if present, is first in the clause; protocols follow.
        if let first = inherited.first, !Self.knownProtocols.contains(first),
           !first.hasSuffix("Delegate"), !first.hasSuffix("DataSource") {
            symbol.superclassName = first
        }
        symbol.conformsToObservableObject = inherited.contains("ObservableObject")
        symbol.attributeNames = metadata.attributeNames
        symbol.observableViaMacro = symbol.attributeNames.contains("Observable")
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
                declLexicalOwners[funcDecl.id] = symbol
                let metadata = functionMetadata(for: funcDecl)
                if metadata.isTypeMember {
                    symbol.staticMethods[metadata.name, default: []].append(
                        funcDecl)
                } else {
                    symbol.methods[metadata.name, default: []].append(funcDecl)
                }
            } else if let initDecl = member.decl.as(InitializerDeclSyntax.self) {
                declLexicalOwners[initDecl.id] = symbol
                symbol.initializers.append(initDecl)
            } else if let deinitDecl = member.decl.as(DeinitializerDeclSyntax.self) {
                let metadata = deinitializerMetadata(for: deinitDecl)
                if metadata.requiresIsolationResolution {
                    pendingDeinitializerIsolationChecks.append((
                        symbol: symbol,
                        declaration: deinitDecl,
                        metadata: metadata))
                }
                symbol.deinitBody = metadata.body
            } else if let alias = member.decl.as(TypeAliasDeclSyntax.self) {
                // Member typealiases resolve like nested types (bare name
                // when unclaimed); generic arguments drop.
                let metadata = typeAliasMetadata(for: alias)
                let target = metadata.lookupTargetName
                if let value = globals.lookup(target) {
                    symbol.nestedTypes[metadata.name] = value
                    if globals.lookup(metadata.name) == nil {
                        globals.define(metadata.name, value)
                    }
                } else {
                    // The target may only exist after the extension pass
                    // (`typealias API = TestWebRepository.API` where API is
                    // declared by a LATER `extension TestWebRepository`) —
                    // retry once every type exists.
                    pendingMemberAliases.append((
                        symbol, metadata.name, target))
                }
                if enumSymbols[metadata.name] == nil,
                   let enumSymbol = enumSymbols[target] {
                    enumSymbols[metadata.name] = enumSymbol
                }
            } else if let subscriptDecl = member.decl.as(SubscriptDeclSyntax.self),
                      let accessorBlock = subscriptDecl.accessorBlock,
                      let accessors = parseAccessors(of: accessorBlock) {
                declLexicalOwners[subscriptDecl.id] = symbol
                let metadata = subscriptMetadata(for: subscriptDecl)
                symbol.subscripts.append(.init(
                    parameters: metadata.parameters,
                    getter: accessors.getter,
                    setter: accessors.setter,
                    resultTypeName: metadata.resultTypeName,
                    isNonisolated: metadata.isNonisolated,
                    declarationID: subscriptDecl.id,
                    isAsync: accessors.isGetterAsync,
                    isThrowing: accessors.isGetterThrowing))
            } else if let nestedEnum = member.decl.as(EnumDeclSyntax.self) {
                if Self.tracedIdentifier == nestedEnum.name.text {
                    Swift.print("   ⌗ nestedEnum \(symbol.name).\(nestedEnum.name.text) bareTaken=\(enumSymbols[nestedEnum.name.text] != nil)")
                }
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
                let nestedSymbol = try makeClassLikeSymbol(nestedClass)
                registerNestedType(nestedSymbol, in: symbol)
            } else if let nestedActor = member.decl.as(ActorDeclSyntax.self) {
                let nestedSymbol = try makeClassLikeSymbol(nestedActor)
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
        let declarationMetadata = propertyMetadata(for: varDecl)
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
        let hasBuilderAttribute = declarationMetadata.hasBuilderAttribute
        let isStaticDecl = declarationMetadata.isStatic
        let isTaskLocal = declarationMetadata.isTaskLocal
        if isTaskLocal {
            guard isStaticDecl else {
                throw error(varDecl, "@TaskLocal properties must be static")
            }
            guard declarationMetadata.isMutable else {
                throw error(varDecl, "@TaskLocal properties must be declared with var")
            }
        }

        for binding in varDecl.bindings {
            let bindingMetadata = propertyMetadata(for: binding)
            if isTaskLocal,
               bindingMetadata.patternKind != .identifier {
                throw error(
                    binding,
                    "@TaskLocal requires a single identifier binding")
            }
            // Tuple-pattern stored properties (`let (first, second, third):
            // (A, B, C)`) declare each element; annotations split when the
            // tuple type's arity matches.
            if bindingMetadata.patternKind == .tuple {
                for element in bindingMetadata.tupleElements {
                    symbol.storedProperties.append(StructSymbol.StoredProperty(
                        name: element.name,
                        wrapper: .none,
                        initializer: nil,
                        typeAnnotation: element.typeAnnotation,
                        isBuilderClosure: false,
                        isMutable: declarationMetadata.isMutable,
                        isNonisolated: declarationMetadata.isNonisolated
                    ))
                }
                continue
            }
            guard let name = bindingMetadata.identifierName else {
                throw error(binding, "unsupported property pattern")
            }
            if isTaskLocal {
                guard binding.accessorBlock == nil else {
                    throw error(
                        binding,
                        "@TaskLocal '\(name)' must be a stored property")
                }
                let initializer = bindingMetadata.initializer
                let annotation = bindingMetadata.typeAnnotation
                if initializer == nil,
                   RuntimeOptionalValue.wrappedType(
                    in: annotation?.trimmedDescription ?? "") == nil {
                    throw error(
                        binding,
                        "@TaskLocal '\(name)' must have a default value or be optional")
                }
                symbol.taskLocalProperties[name] = RuntimeTaskLocalDeclaration(
                    declarationID: binding.id,
                    debugName: "\(symbol.name).\(name)",
                    initializer: initializer,
                    typeAnnotation: annotation)
                continue
            }
            // A binding with an accessor block is computed only if it has a
            // getter; willSet/didSet-only observers mean a stored property
            // whose observers run on assignment (see the write funnel).
            if bindingMetadata.isComputed,
               let accessorBlock = binding.accessorBlock,
               let accessors = parseAccessors(of: accessorBlock) {
                declLexicalOwners[binding.id] = symbol
                let returnsView = bindingMetadata.typeAnnotation?
                    .trimmedDescription.contains("some View") ?? false
                let computed = ComputedProperty(
                    accessor: accessors.getter,
                    isBuilder: hasBuilderAttribute || returnsView,
                    setter: accessors.setter,
                    typeAnnotation: bindingMetadata.typeAnnotation,
                    declarationID: binding.id,
                    isNonisolated: declarationMetadata.isNonisolated,
                    isAsync: accessors.isGetterAsync,
                    isThrowing: accessors.isGetterThrowing
                )
                if isStaticDecl {
                    symbol.staticComputedProperties[name] = computed
                } else {
                    symbol.computedProperties[name] = computed
                }
            } else if isStaticDecl {
                let referenceOwnership = declarationMetadata.referenceOwnership
                symbol.staticStoragePolicies[name] = .init(
                    typeName: bindingMetadata.typeAnnotation?.trimmedDescription,
                    referenceOwnership: referenceOwnership)
                if let initializer = bindingMetadata.initializer {
                    symbol.staticProperties[name] = .init(
                        initializer: initializer,
                        typeAnnotation: bindingMetadata.typeAnnotation,
                        referenceOwnership: referenceOwnership
                    )
                } else if let wrapper = varDecl.attributes.compactMap({ $0.as(AttributeSyntax.self) }).first(where: {
                    $0.arguments != nil && $0.attributeName.trimmedDescription.first?.isUppercase == true
                }) {
                    // `@UserDefault("key", defaultValue: …) static var x` —
                    // a CUSTOM wrapper; reads go through wrappedValue.
                    symbol.staticWrapped[name] = wrapper
                    symbol.staticUninitialized.insert(name)
                } else {
                    // `static var shared: ChatClient!` — nil until written.
                    symbol.staticUninitialized.insert(name)
                }
            } else {
                // `@FocusState var focused: Bool` carries no initializer —
                // real SwiftUI defaults it false (optionals stay nil via the
                // uninitialized-optional rule).
                var stateLikeDefault: ExprSyntax?
                if bindingMetadata.initializer == nil,
                   hasAttribute(varDecl.attributes, named: "FocusState"),
                   bindingMetadata.typeAnnotation?.trimmedDescription == "Bool" {
                    stateLikeDefault = ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(.false)))
                }
                var stored = StructSymbol.StoredProperty(
                    name: name,
                    wrapper: wrapper,
                    initializer: bindingMetadata.initializer ?? queryDefault ?? stateLikeDefault,
                    typeAnnotation: bindingMetadata.typeAnnotation ?? syntheticAnnotation,
                    isBuilderClosure: hasBuilderAttribute,
                    isMutable: declarationMetadata.isMutable,
                    isNonisolated: declarationMetadata.isNonisolated
                )
                stored.referenceOwnership = declarationMetadata.referenceOwnership
                stored.isLazy = declarationMetadata.isLazy
                // `var timeline: Filter = .home { didSet { … } }` — the
                // fetch-trigger genre lives in observers.
                if let observer = bindingMetadata.willSet {
                    stored.willSetBody = observer.body
                    stored.willSetParameter = observer.parameterName
                }
                if let observer = bindingMetadata.didSet {
                    stored.didSetBody = observer.body
                    stored.didSetParameter = observer.parameterName
                }
                symbol.storedProperties.append(stored)
            }
        }
    }

    // MARK: - Enums

    private func collectEnum(_ node: EnumDeclSyntax) throws {
        let symbol = try makeEnumSymbol(node)
        if Self.tracedIdentifier == symbol.name {
            Swift.print("   ⌗ collectEnum \(symbol.name) cases=\(symbol.cases.map(\.name).prefix(4).joined(separator: ",")) existing=\(enumSymbols[symbol.name] != nil)")
        }
        if let existing = enumSymbols[symbol.name], existing !== symbol {
            // SIBLING app targets in a monorepo declare the same namespace
            // (Rayon + mRayon both ship `enum UIBridge`): members UNION —
            // separate targets never collide on device.
            union(symbol, into: existing)
            return
        }
        enumSymbols[symbol.name] = symbol
        globals.define(symbol.name, .enumType(symbol))
    }

    /// Union `symbol`'s members into `existing` (sibling-target namespaces).
    func union(_ symbol: EnumSymbol, into existing: EnumSymbol) {
        for enumCase in symbol.cases
        where !existing.cases.contains(where: { $0.name == enumCase.name }) {
            existing.cases.append(enumCase)
        }
        for (name, overloads) in symbol.methods {
            for decl in overloads { declLexicalOwners[decl.id] = existing }
            existing.methods[name, default: []].append(contentsOf: overloads)
        }
        for (name, overloads) in symbol.staticMethods {
            existing.staticMethods[name, default: []].append(contentsOf: overloads)
        }
        for (name, property) in symbol.staticProperties
        where existing.staticProperties[name] == nil {
            existing.staticProperties[name] = property
        }
        for (name, declaration) in symbol.taskLocalProperties
        where existing.taskLocalProperties[name] == nil {
            existing.taskLocalProperties[name] = declaration
        }
        for (name, policy) in symbol.staticStoragePolicies
        where existing.staticStoragePolicies[name] == nil {
            existing.staticStoragePolicies[name] = policy
        }
        existing.staticUninitialized.formUnion(symbol.staticUninitialized)
        for (name, computed) in symbol.computedProperties
        where existing.computedProperties[name] == nil {
            if let id = computed.declarationID { declLexicalOwners[id] = existing }
            existing.computedProperties[name] = computed
        }
        for (name, computed) in symbol.staticComputedProperties
        where existing.staticComputedProperties[name] == nil {
            if let id = computed.declarationID { declLexicalOwners[id] = existing }
            existing.staticComputedProperties[name] = computed
        }
        for (name, nested) in symbol.nestedTypes
        where existing.nestedTypes[name] == nil {
            existing.nestedTypes[name] = nested
        }
        for initializer in symbol.initializers {
            declLexicalOwners[initializer.id] = existing
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
        let metadata = nominalMetadata(for: node)
        let symbol = EnumSymbol(name: metadata.name)
        symbol.conformances = metadata.inheritedTypeNames
        symbol.attributeNames = metadata.attributeNames
        let rawIsString = symbol.conformances.contains("String")

        var nextIntRaw = 0
        for decl in flattenedMemberDecls(node.memberBlock.members) {
            if let caseDecl = decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    let caseMetadata = enumCaseMetadata(for: element)
                    let caseName = caseMetadata.name
                    let labels = caseMetadata.associatedValues.map(\.label)
                    let associatedTypeNames = caseMetadata.associatedValues
                        .map(\.typeName)
                    let raw: RuntimeValue
                    if let rawExpr = caseMetadata.rawValue {
                        raw = try evaluate(rawExpr, in: globals)
                    } else if rawIsString {
                        raw = .native(caseName)
                    } else {
                        raw = .native(nextIntRaw)
                    }
                    if let intRaw = raw.intValue { nextIntRaw = intRaw + 1 }
                    symbol.cases.append(.init(
                        name: caseName, associatedLabels: labels,
                        rawValue: raw,
                        associatedTypeNames: associatedTypeNames))
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
            declLexicalOwners[initDecl.id] = symbol
            symbol.initializers.append(initDecl)
            return
        }
        if let varDecl = decl.as(VariableDeclSyntax.self) {
            let declarationMetadata = propertyMetadata(for: varDecl)
            let hasBuilderAttribute = declarationMetadata.hasBuilderAttribute
            let isStaticDecl = declarationMetadata.isStatic
            let isTaskLocal = declarationMetadata.isTaskLocal
            if isTaskLocal {
                guard isStaticDecl else {
                    throw error(varDecl, "@TaskLocal properties must be static")
                }
                guard declarationMetadata.isMutable else {
                    throw error(
                        varDecl, "@TaskLocal properties must be declared with var")
                }
            }
            for binding in varDecl.bindings {
                let bindingMetadata = propertyMetadata(for: binding)
                guard let memberName = bindingMetadata.identifierName else {
                    if isTaskLocal {
                        throw error(
                            binding,
                            "@TaskLocal requires a single identifier binding")
                    }
                    continue
                }
                if isTaskLocal {
                    guard binding.accessorBlock == nil else {
                        throw error(
                            binding,
                            "@TaskLocal '\(memberName)' must be a stored property")
                    }
                    let initializer = bindingMetadata.initializer
                    let annotation = bindingMetadata.typeAnnotation
                    if initializer == nil,
                       RuntimeOptionalValue.wrappedType(
                        in: annotation?.trimmedDescription ?? "") == nil {
                        throw error(
                            binding,
                            "@TaskLocal '\(memberName)' must have a default value or be optional")
                    }
                    symbol.taskLocalProperties[memberName] =
                        RuntimeTaskLocalDeclaration(
                            declarationID: binding.id,
                            debugName: "\(symbol.name).\(memberName)",
                            initializer: initializer,
                            typeAnnotation: annotation)
                    continue
                }
                if bindingMetadata.isComputed,
                   let accessorBlock = binding.accessorBlock,
                   let accessors = parseAccessors(of: accessorBlock) {
                    declLexicalOwners[binding.id] = symbol
                    let returnsView = bindingMetadata.typeAnnotation?
                        .trimmedDescription.contains("some View") ?? false
                    if isStaticDecl {
                        symbol.staticComputedProperties[memberName] = ComputedProperty(
                            accessor: accessors.getter,
                            isBuilder: hasBuilderAttribute || returnsView,
                            setter: accessors.setter,
                            typeAnnotation: bindingMetadata.typeAnnotation,
                            declarationID: binding.id,
                            isAsync: accessors.isGetterAsync,
                            isThrowing: accessors.isGetterThrowing
                        )
                        continue
                    }
                    symbol.computedProperties[memberName] = ComputedProperty(
                        accessor: accessors.getter,
                        isBuilder: hasBuilderAttribute || returnsView,
                        setter: accessors.setter,
                        typeAnnotation: bindingMetadata.typeAnnotation,
                        declarationID: binding.id,
                        isAsync: accessors.isGetterAsync,
                        isThrowing: accessors.isGetterThrowing
                    )
                } else if isStaticDecl {
                    let referenceOwnership = declarationMetadata.referenceOwnership
                    symbol.staticStoragePolicies[memberName] = .init(
                        typeName: bindingMetadata.typeAnnotation?
                            .trimmedDescription,
                        referenceOwnership: referenceOwnership)
                    if let initializer = bindingMetadata.initializer {
                        symbol.staticProperties[memberName] = .init(
                            initializer: initializer,
                            typeAnnotation: bindingMetadata.typeAnnotation,
                            referenceOwnership: referenceOwnership
                        )
                    } else {
                        symbol.staticUninitialized.insert(memberName)
                    }
                }
            }
        } else if let funcDecl = decl.as(FunctionDeclSyntax.self) {
            declLexicalOwners[funcDecl.id] = symbol
            let metadata = functionMetadata(for: funcDecl)
            if metadata.isTypeMember {
                symbol.staticMethods[metadata.name, default: []].append(
                    funcDecl)
            } else {
                symbol.methods[metadata.name, default: []].append(funcDecl)
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
            let nestedSymbol = try makeClassLikeSymbol(nestedClass)
            symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
            structSymbols.append(nestedSymbol)
            globals.define("\(symbol.name).\(nestedSymbol.name)", .type(nestedSymbol))
            if globals.lookup(nestedSymbol.name) == nil {
                globals.define(nestedSymbol.name, .type(nestedSymbol))
            }
        }
    }

    // MARK: - Extensions

    /// `extension Thing: Marker {}` — RETROACTIVE conformances join the
    /// symbol like declaration-site ones (checked casts and the render
    /// pipeline's view-ness both read symbol.conformances).
    private func mergeExtensionConformances(
        _ metadata: ParsedExtensionMetadata,
        into symbol: StructSymbol
    ) {
        for name in metadata.inheritedTypeNames {
            if !symbol.conformances.contains(name) {
                symbol.conformances.append(name)
            }
            if name == "View" { symbol.conformsToView = true }
            if name == "ObservableObject" { symbol.conformsToObservableObject = true }
            if name == "Shape" || name == "InsettableShape" { symbol.conformsToShape = true }
            if name.hasSuffix("Representable") { symbol.isRepresentable = true }
        }
    }

    private func collectExtension(_ node: ExtensionDeclSyntax) throws {
        let metadata = extensionMetadata(for: node)
        let typeName = metadata.extendedTypeName
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
            mergeExtensionConformances(metadata, into: symbol)
            try collectStructMembers(node.memberBlock, into: symbol)
        case .enumType(let symbol):
            for name in metadata.inheritedTypeNames {
                if !symbol.conformances.contains(name) {
                    symbol.conformances.append(name)
                }
            }
            for decl in flattenedMemberDecls(node.memberBlock.members) {
                try collectEnumMember(decl, into: symbol)
            }
        default:
            // Extensions of host types (`extension View { func … }`) collect
            // into synthetic symbols, resolved on matching host values.
            // Typealias heads canonicalize (`extension LoadableSubject`
            // IS a Binding extension), so candidate walks find them.
            var canonical = typeName
            var hops = 0
            while let target = aliasHeads[canonical], hops < 8 {
                canonical = target
                hops += 1
            }
            let symbol = hostExtensionSymbols[canonical]
                ?? StructSymbol(name: canonical, conformsToView: false)
            try collectStructMembers(node.memberBlock, into: symbol)
            hostExtensionSymbols[canonical] = symbol
        }
    }

    // MARK: - Functions

    func defineFunction(_ node: FunctionDeclSyntax, in env: Environment) throws {
        let metadata = functionMetadata(for: node)
        guard let body = node.body else {
            // Bodyless declarations are extern/C bridges (@_silgen_name
            // Carbon privates): inert absorbers, like the C-interop family.
            let name = metadata.name
            env.define(name, .hostFunction(HostFunction(name: name) { _, _ in
                .native(ChainedImplicitCall(
                    base: .implicitMember(name), member: "call", arguments: CallArguments()))
            }))
            return
        }
        env.define(
            metadata.name,
            .closure(makeFunctionClosure(node, body: body, captured: env)))
        if env === globals {
            globalFunctionOverloads[metadata.name, default: []].append(node)
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
            returnTypeName: metadata.returnTypeName,
            programMetadata: currentProgramMetadata
        )
        closure.functionDeclID = node.id
        let lexicalOwner = declLexicalOwners[node.id]
        closure.lexicalOwner = lexicalOwner
        closure.genericParameters = metadata.genericParameters
        closure.debugName = metadata.name
        closure.sourceFunctionName = metadata.sourceFunctionName
        let isAnyNonisolated = metadata.isAnyNonisolated
        closure.isExplicitlyNonisolated = metadata.isExplicitlyNonisolated
        closure.executorPreference = functionExecutorPreference(
            metadata, lexicalOwner: lexicalOwner)
        if !isAnyNonisolated {
            closure.globalActorAttributeCandidates =
                metadata.attributeNames + lexicalAttributeNames(of: lexicalOwner)
        }
        if closure.executorPreference == nil,
           !isAnyNonisolated,
           let owner = lexicalOwner as? StructSymbol,
           owner.isActor,
           let selfBox = captured.box(for: "self", before: globals),
           case .instance(let actor) = selfBox.value,
           let actorID = actor.actorID {
            closure.executorPreference = .actor(actorID)
        }
        return closure
    }

    /// Build every source initializer body from the same immutable metadata
    /// and declaration-isolation rules. Actor initializers are lexically
    /// nonisolated during initialization; ordinary class/struct/enum
    /// initializers inherit a nominal global actor unless the declaration is
    /// explicitly nonisolated.
    func makeInitializerClosure(
        _ node: InitializerDeclSyntax,
        body: CodeBlockSyntax,
        captured: Environment,
        debugName: String,
        fallbackLexicalOwner: AnyObject? = nil
    ) -> ClosureValue {
        let metadata = initializerMetadata(for: node)
        let closure = ClosureValue(
            parameters: metadata.parameters,
            body: body.statements,
            captured: captured,
            programMetadata: currentProgramMetadata)
        let lexicalOwner = declLexicalOwners[node.id] ?? fallbackLexicalOwner
        let actorInitializer =
            (lexicalOwner as? StructSymbol)?.isActor == true
        closure.functionDeclID = node.id
        closure.lexicalOwner = lexicalOwner
        closure.debugName = debugName
        closure.isExplicitlyNonisolated = metadata.isExplicitlyNonisolated
        closure.executorPreference = initializerExecutorPreference(
            metadata, lexicalOwner: lexicalOwner)
        if !metadata.isAnyNonisolated,
           (!actorInitializer || metadata.isMainActor) {
            closure.globalActorAttributeCandidates =
                metadata.attributeNames + lexicalAttributeNames(of: lexicalOwner)
        }
        return closure
    }

    private func initializerExecutorPreference(
        _ metadata: ParsedInitializerMetadata,
        lexicalOwner: AnyObject?
    ) -> RuntimeExecutorKind? {
        if metadata.isAnyNonisolated {
            return nil
        }
        if metadata.isMainActor {
            return .mainActor
        }
        if let owner = lexicalOwner as? StructSymbol, owner.isActor {
            return nil
        }
        if lexicalAttributeNames(of: lexicalOwner).contains("MainActor") {
            return .mainActor
        }
        return nil
    }

    /// Runtime executor metadata for the function forms established by the
    /// current parity board. `@concurrent` always selects the cooperative
    /// default executor. A `nonisolated` declaration suppresses its lexical
    /// owner's global actor; synchronous nonisolated calls then run inline on
    /// their caller's executor. User-declared global actors are resolved
    /// lazily from `globalActorAttributeCandidates` at invocation.
    private func functionExecutorPreference(
        _ metadata: ParsedFunctionMetadata,
        lexicalOwner: AnyObject?
    ) -> RuntimeExecutorKind? {
        if metadata.isConcurrent {
            return .cooperativeDefault
        }
        if metadata.isAnyNonisolated {
            return nil
        }
        if metadata.isMainActor {
            return .mainActor
        }
        if let owner = lexicalOwner as? StructSymbol,
           owner.attributeNames.contains("MainActor") {
            return .mainActor
        }
        return nil
    }

    private func lexicalAttributeNames(of owner: AnyObject?) -> [String] {
        if let symbol = owner as? StructSymbol {
            return symbol.attributeNames
        }
        if let symbol = owner as? EnumSymbol {
            return symbol.attributeNames
        }
        return []
    }

    // MARK: - Helpers

    /// nil ⇒ no getter (willSet/didSet observers only): treat as stored.
    func parseAccessors(
        of accessorBlock: AccessorBlockSyntax
    ) -> (
        getter: CodeBlockItemListSyntax,
        setter: ComputedProperty.Setter?,
        isGetterAsync: Bool,
        isGetterThrowing: Bool
    )? {
        guard let metadata = accessorMetadata(for: accessorBlock) else {
            return nil
        }
        let setter = metadata.setter.map {
            ComputedProperty.Setter(
                body: $0.body,
                parameterName: $0.parameterName)
        }
        return (
            metadata.getter,
            setter,
            metadata.isAsync,
            metadata.isThrowing)
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
        // Store-query wrappers (@Query — SwiftData, @FetchRequest —
        // CoreData) read the LIVE per-run model store each render — what
        // the UI inserts, its queries show (M3). @ObservedResults stays
        // @State-shaped for Realm's `$results.append/remove` projections.
        for queryLike in ["Query", "FetchRequest", "SectionedFetchRequest"]
        where hasAttribute(attributes, named: queryLike) {
            return (.query, nil)
        }
        if hasAttribute(attributes, named: "ObservedResults") {
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

    /// Resolve explicit deinitializer attributes after collection has made
    /// forward declarations, nested nominals, and typealiases available.
    /// MainActor teardown already owns a real host capability because every
    /// `Instance` is MainActor-isolated. Other actor executors remain an
    /// explicit construction boundary; macros and ordinary declaration
    /// attributes stay inert. Classification is stored on the owning symbol
    /// so unused declarations remain legal in a merged project.
    func resolvePendingDeinitializerIsolation() {
        let pending = pendingDeinitializerIsolationChecks
        pendingDeinitializerIsolationChecks.removeAll(keepingCapacity: true)

        for (symbol, deinitDecl, metadata) in pending {
            if metadata.hasIsolatedModifier {
                if symbol.attributeNames.contains(where: {
                    isMainActorTypeName($0)
                }) {
                    symbol.deinitializerExecutor = .mainActor
                } else {
                    let located = error(
                        deinitDecl,
                        "isolated deinitializer requires a source-actor "
                            + "executor-owned teardown, which is not "
                            + "supported yet")
                    symbol.executorOwnedDeinitializerError = RuntimeError(
                        message: located.message,
                        line: located.line,
                        column: located.column,
                        fatal: true)
                }
                continue
            }

            if metadata.attributeTypeNames.contains(where: {
                isMainActorTypeName($0)
            }) {
                symbol.deinitializerExecutor = .mainActor
                continue
            }
            guard let globalActorName = metadata.attributeTypeNames.first(where: {
                isGlobalActorTypeName($0)
            }) else { continue }

            let located = error(
                deinitDecl,
                "global-actor deinitializer '@\(globalActorName)' requires "
                    + "executor-owned teardown, which is not supported yet")
            symbol.executorOwnedDeinitializerError = RuntimeError(
                message: located.message,
                line: located.line,
                column: located.column,
                fatal: true)
        }
    }

    private func isMainActorTypeName(_ name: String) -> Bool {
        var alias = name.split(separator: ".").last.map(String.init) ?? name
        var seen: Set<String> = []
        while seen.insert(alias).inserted {
            if alias == "MainActor" { return true }
            guard let target = aliasHeads[alias] else { return false }
            alias = target.split(separator: ".").last.map(String.init)
                ?? target
        }
        return false
    }

    private func isGlobalActorTypeName(_ name: String) -> Bool {
        let finalName = name.split(separator: ".").last.map(String.init)
            ?? name
        if isMainActorTypeName(finalName) { return true }

        var alias = finalName
        var seen: Set<String> = []
        while seen.insert(alias).inserted, let target = aliasHeads[alias] {
            alias = target.split(separator: ".").last.map(String.init)
                ?? target
            if isMainActorTypeName(alias) { return true }
        }

        guard let type = typeValueForIsolationAttribute(name) else {
            return false
        }
        let attributes: [String]
        switch type {
        case .type(let symbol):
            attributes = symbol.attributeNames
        case .enumType(let symbol):
            attributes = symbol.attributeNames
        default:
            return false
        }
        return attributes.contains {
            $0 == "globalActor" || $0.hasSuffix(".globalActor")
        }
    }

    private func typeValueForIsolationAttribute(
        _ name: String
    ) -> RuntimeValue? {
        if let direct = globals.lookup(name) { return direct }

        let components = name.split(separator: ".").map(String.init)
        guard let first = components.first,
              var current = globals.lookup(first) else {
            if let final = components.last { return globals.lookup(final) }
            return nil
        }
        for component in components.dropFirst() {
            switch current {
            case .type(let symbol):
                guard let nested = symbol.nestedTypes[component] else {
                    return globals.lookup(components.last ?? component)
                }
                current = nested
            case .enumType(let symbol):
                guard let nested = symbol.nestedTypes[component] else {
                    return globals.lookup(components.last ?? component)
                }
                current = nested
            default:
                return nil
            }
        }
        return current
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        // `class func` members dispatch on the type exactly like statics
        // (URLProtocol's `override class func canInit(with:)`).
        modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
    }
}
