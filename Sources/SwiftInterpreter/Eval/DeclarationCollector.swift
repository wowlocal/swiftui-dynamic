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
            typeAliasTargets[metadata.name] = metadata.targetTypeName
            if metadata.isNominalTarget {
                aliasHeads[metadata.name] = metadata.lookupTargetName
                let sourceModuleName = currentProgramMetadata?.sourceModuleName(
                    at: alias.positionAfterSkippingLeadingTrivia)
                let isExported = metadata.modifierNames.contains("public")
                    || metadata.modifierNames.contains("open")
                    || metadata.modifierNames.contains("package")
                topLevelTypeAliasBindings[
                    metadata.name, default: []
                ].append(.init(
                    targetName: metadata.lookupTargetName,
                    sourceModuleName: sourceModuleName,
                    isExported: isExported))
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
                        typeName: bindingMetadata.typeName)),
                    declaredTypeName: bindingMetadata.typeName,
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
                        typeName: bindingMetadata.typeName)),
                    declaredTypeName: bindingMetadata.typeName)
            } else {
                globals.define(
                    name,
                    .native(LazyGlobal(
                        initializer: bindingMetadata.initializer,
                        typeName: bindingMetadata.typeName)),
                    declaredTypeName: bindingMetadata.typeName,
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
            // A flattened compiler graph can contain an unrelated nominal
            // with the same spelling as an imported host type (`SQLite.View`
            // beside an extension of SwiftUI.View). Collection records the
            // lexical proof; never migrate those host/protocol members by a
            // bare-name coincidence during the late repair pass.
            guard !nonNominalExtensionTypeNames.contains(typeName) else {
                continue
            }
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
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, declaration) in stranded.taskLocalProperties
                where symbol.taskLocalProperties[name] == nil {
                    symbol.taskLocalProperties[name] = declaration
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, computed) in stranded.staticComputedProperties
                where symbol.staticComputedProperties[name] == nil {
                    if let id = computed.declarationID { declLexicalOwners[id] = symbol }
                    symbol.staticComputedProperties[name] = computed
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, nested) in stranded.nestedTypes
                where symbol.nestedTypes[name] == nil {
                    bindLexicalOwner(of: nested, to: symbol)
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
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, declaration) in stranded.taskLocalProperties
                where symbol.taskLocalProperties[name] == nil {
                    symbol.taskLocalProperties[name] = declaration
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, policy) in stranded.staticStoragePolicies
                where symbol.staticStoragePolicies[name] == nil {
                    symbol.staticStoragePolicies[name] = policy
                }
                for name in stranded.staticUninitialized
                where !symbol.staticUninitialized.contains(name) {
                    symbol.staticUninitialized.insert(name)
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, computed) in stranded.staticComputedProperties
                where symbol.staticComputedProperties[name] == nil {
                    if let id = computed.declarationID { declLexicalOwners[id] = symbol }
                    symbol.staticComputedProperties[name] = computed
                    symbol.fileScopedStaticMemberOrigins[name] =
                        stranded.fileScopedStaticMemberOrigins[name]
                }
                for (name, nested) in stranded.nestedTypes
                where symbol.nestedTypes[name] == nil {
                    bindLexicalOwner(of: nested, to: symbol)
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
        buildConfiguration.ifConfigConditionHolds(condition)
    }

    /// The first clause whose condition holds (`#else` always does).
    func activeIfConfigClause(_ node: IfConfigDeclSyntax) -> IfConfigClauseSyntax? {
        node.clauses.first { ifConfigConditionHolds($0.condition) }
    }

    // MARK: - Structs

    private func collectStruct(_ node: StructDeclSyntax) throws {
        let symbol = try makeStructSymbol(node)
        registerTypeSymbol(symbol)
        registerSourceModuleType(.type(symbol), declaration: node)
    }

    /// Build-material provenance, rather than a framework/type-name list,
    /// owns qualified source declarations after multiple modules are flattened
    /// into one interpreter program.
    private func registerSourceModuleType(
        _ value: RuntimeValue,
        declaration: some SyntaxProtocol
    ) {
        guard let moduleName = currentProgramMetadata?.sourceModuleName(
            at: declaration.positionAfterSkippingLeadingTrivia)
        else { return }
        let typeName: String
        switch value {
        case .type(let symbol): typeName = symbol.name
        case .enumType(let symbol): typeName = symbol.name
        default: return
        }
        registerSourceModuleOwnership(value, moduleName: moduleName)
        globals.define("\(moduleName).\(typeName)", value)
    }

    /// Nested nominals retain their declaring module even though the merged
    /// environment also keeps a bare compatibility binding. Without this
    /// provenance, an unrelated `Outer.Circle` can masquerade as a global
    /// `Circle` in another module and shadow an imported SDK constructor.
    /// Visibility then follows lexical/module structure, not merge order.
    private func registerSourceModuleOwnership(
        _ value: RuntimeValue,
        moduleName: String
    ) {
        let identity: ObjectIdentifier
        let nestedTypes: [RuntimeValue]
        switch value {
        case .type(let symbol):
            identity = ObjectIdentifier(symbol)
            nestedTypes = Array(symbol.nestedTypes.values)
        case .enumType(let symbol):
            identity = ObjectIdentifier(symbol)
            nestedTypes = Array(symbol.nestedTypes.values)
        default:
            return
        }
        // Preserve the declaration path as well as its identity. Imported
        // lookup must be able to ask for `Module.Outer.Inner`; flattening a
        // nested nominal to only `Outer.Inner` cannot prove which imported
        // module supplied it when sibling packages use the same names.
        if let path = sourceQualifiedNominalPath(of: value), path.count > 1 {
            globals.define(
                ([moduleName] + path).joined(separator: "."), value)
        }
        let inserted = sourceModuleNamesByNominalIdentity[
            identity, default: []
        ].insert(moduleName).inserted
        guard inserted else { return }
        for nested in nestedTypes {
            registerSourceModuleOwnership(nested, moduleName: moduleName)
        }
    }

    private func sourceQualifiedNominalPath(
        of value: RuntimeValue
    ) -> [String]? {
        var components: [String] = []
        var current: AnyObject?
        switch value {
        case .type(let symbol):
            components.append(symbol.name)
            current = symbol.lexicalTypeOwner
        case .enumType(let symbol):
            components.append(symbol.name)
            current = symbol.lexicalTypeOwner
        default:
            return nil
        }
        var seen: Set<ObjectIdentifier> = []
        while let owner = current,
              seen.insert(ObjectIdentifier(owner)).inserted {
            if let symbol = owner as? StructSymbol {
                components.append(symbol.name)
                current = symbol.lexicalTypeOwner
            } else if let symbol = owner as? EnumSymbol {
                components.append(symbol.name)
                current = symbol.lexicalTypeOwner
            } else {
                break
            }
        }
        return components.reversed()
    }

    private func inheritSourceModuleOwnership(
        _ nested: RuntimeValue,
        from owner: RuntimeValue
    ) {
        for moduleName in sourceModuleNames(owning: owner) {
            registerSourceModuleOwnership(nested, moduleName: moduleName)
        }
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
        let symbol = try makeClassLikeSymbol(node)
        registerTypeSymbol(symbol)
        registerSourceModuleType(.type(symbol), declaration: node)
    }

    /// Actors share the nominal-member collector with classes but retain their
    /// language kind. Instance allocation assigns the runtime actor identity;
    /// isolated member closures then enter that actor's logical executor.
    private func collectActor(_ node: ActorDeclSyntax) throws {
        let symbol = try makeClassLikeSymbol(node)
        registerTypeSymbol(symbol)
        registerSourceModuleType(.type(symbol), declaration: node)
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

    private func collectStructMembers(
        _ block: MemberBlockSyntax,
        into symbol: StructSymbol
    ) throws {
        for member in memberDeclarations(in: block) {
            switch member {
            case .variable(let varDecl):
                try collectProperties(varDecl, into: symbol)
            case .function(let funcDecl):
                declLexicalOwners[funcDecl.id] = symbol
                let metadata = functionMetadata(for: funcDecl)
                if metadata.isTypeMember {
                    symbol.staticMethods[metadata.name, default: []].append(
                        funcDecl)
                } else {
                    symbol.methods[metadata.name, default: []].append(funcDecl)
                }
            case .initializer(let initDecl):
                declLexicalOwners[initDecl.id] = symbol
                symbol.initializers.append(initDecl)
            case .deinitializer(let deinitDecl):
                let metadata = deinitializerMetadata(for: deinitDecl)
                if metadata.requiresIsolationResolution {
                    pendingDeinitializerIsolationChecks.append((
                        symbol: symbol,
                        declaration: deinitDecl,
                        metadata: metadata))
                }
                symbol.deinitBody = metadata.body
            case .typeAlias(let alias):
                // Member typealiases resolve like nested types (bare name
                // when unclaimed); generic arguments drop.
                let metadata = typeAliasMetadata(for: alias)
                symbol.typeAliases[metadata.name] = metadata.targetTypeName
                typeAliasTargets["\(symbol.name).\(metadata.name)"] =
                    metadata.targetTypeName
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
            case .subscriptDeclaration(let subscriptDecl):
                guard let accessorBlock = subscriptDecl.accessorBlock,
                      let accessors = parseAccessors(of: accessorBlock) else {
                    continue
                }
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
            case .enumeration(let nestedEnum):
                if Self.tracedIdentifier == nestedEnum.name.text {
                    Swift.print("   ⌗ nestedEnum \(symbol.name).\(nestedEnum.name.text) bareTaken=\(enumSymbols[nestedEnum.name.text] != nil)")
                }
                // Nested types register under `Outer.Name` (for annotations)
                // and the bare name when unclaimed (for in-scope references).
                let nested = try makeEnumSymbol(nestedEnum)
                nested.lexicalTypeOwner = symbol
                symbol.nestedTypes[nested.name] = .enumType(nested)
                inheritSourceModuleOwnership(
                    .enumType(nested), from: .type(symbol))
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
            case .structure(let nestedStruct):
                let nestedSymbol = try makeStructSymbol(nestedStruct)
                registerNestedType(nestedSymbol, in: symbol)
            case .classType(let nestedClass):
                // Nested classes (UserPreferences.Storage) register like
                // nested structs — reference-typed.
                let nestedSymbol = try makeClassLikeSymbol(nestedClass)
                registerNestedType(nestedSymbol, in: symbol)
            case .actor(let nestedActor):
                let nestedSymbol = try makeClassLikeSymbol(nestedActor)
                registerNestedType(nestedSymbol, in: symbol)
            case .enumCase, .protocolType, .other:
                continue
            }
        }
    }

    private func registerNestedType(_ nestedSymbol: StructSymbol, in symbol: StructSymbol) {
        nestedSymbol.lexicalTypeOwner = symbol
        symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
        inheritSourceModuleOwnership(
            .type(nestedSymbol), from: .type(symbol))
        structSymbols.append(nestedSymbol)
        globals.define("\(symbol.name).\(nestedSymbol.name)", .type(nestedSymbol))
        if globals.lookup(nestedSymbol.name) == nil {
            globals.define(nestedSymbol.name, .type(nestedSymbol))
        }
    }

    private func bindLexicalOwner(
        of nested: RuntimeValue, to owner: AnyObject
    ) {
        switch nested {
        case .type(let symbol):
            symbol.lexicalTypeOwner = owner
        case .enumType(let symbol):
            symbol.lexicalTypeOwner = owner
        default:
            break
        }
    }

    private func registerNestedType(
        _ nestedSymbol: StructSymbol, in symbol: EnumSymbol
    ) {
        nestedSymbol.lexicalTypeOwner = symbol
        symbol.nestedTypes[nestedSymbol.name] = .type(nestedSymbol)
        inheritSourceModuleOwnership(
            .type(nestedSymbol), from: .enumType(symbol))
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
                        attributeNames: declarationMetadata.attributeNames,
                        isMutable: declarationMetadata.isMutable,
                        isNonisolated: declarationMetadata.isNonisolated
                    ))
                }
                continue
            }
            guard let name = bindingMetadata.identifierName else {
                throw error(binding, "unsupported property pattern")
            }
            if isStaticDecl {
                declLexicalOwners[binding.id] = symbol
            }
            if isStaticDecl,
               declarationMetadata.hasFileScopedReadAccess {
                symbol.fileScopedStaticMemberOrigins[name] = .init(
                    sourceFileIdentity: currentProgramMetadata?
                        .sourceFileIdentity(
                            at: varDecl.positionAfterSkippingLeadingTrivia))
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
            let coroutineErrors = unsupportedCoroutineAccessorErrors(
                for: binding)
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
                    isThrowing: accessors.isGetterThrowing,
                    unsupportedCoroutineReadError:
                        coroutineErrors?.read,
                    unsupportedCoroutineModifyError:
                        coroutineErrors?.modify
                )
                if isStaticDecl {
                    symbol.staticComputedProperties[name] = computed
                } else {
                    symbol.computedProperties[name] = computed
                }
            } else if let coroutineErrors {
                // `_read`/`_modify` declarations are legal Swift even when
                // this run never touches them. Keep an explicit computed
                // member so root synthesis and member lookup stay correct,
                // and surface the ownership limitation only on demand.
                declLexicalOwners[binding.id] = symbol
                let computed = ComputedProperty(
                    accessor: CodeBlockItemListSyntax([]),
                    isBuilder: false,
                    typeAnnotation: bindingMetadata.typeAnnotation,
                    declarationID: binding.id,
                    isNonisolated: declarationMetadata.isNonisolated,
                    unsupportedCoroutineReadError: coroutineErrors.read,
                    unsupportedCoroutineModifyError: coroutineErrors.modify
                )
                if isStaticDecl {
                    symbol.staticComputedProperties[name] = computed
                } else {
                    symbol.computedProperties[name] = computed
                }
            } else if isStaticDecl {
                let referenceOwnership = declarationMetadata.referenceOwnership
                symbol.staticStoragePolicies[name] = .init(
                    typeName: bindingMetadata.typeName,
                    referenceOwnership: referenceOwnership)
                if let initializer = bindingMetadata.initializer {
                    symbol.staticProperties[name] = .init(
                        initializer: initializer,
                        typeAnnotation: bindingMetadata.typeAnnotation,
                        referenceOwnership: referenceOwnership,
                        declarationID: binding.id
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
                   bindingMetadata.typeName == "Bool" {
                    stateLikeDefault = ExprSyntax(BooleanLiteralExprSyntax(literal: .keyword(.false)))
                }
                var stored = StructSymbol.StoredProperty(
                    name: name,
                    wrapper: wrapper,
                    initializer: bindingMetadata.initializer ?? queryDefault ?? stateLikeDefault,
                    typeAnnotation: bindingMetadata.typeAnnotation ?? syntheticAnnotation,
                    isBuilderClosure: hasBuilderAttribute,
                    attributeNames: declarationMetadata.attributeNames,
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
            registerSourceModuleType(.enumType(existing), declaration: node)
            return
        }
        enumSymbols[symbol.name] = symbol
        globals.define(symbol.name, .enumType(symbol))
        registerSourceModuleType(.enumType(symbol), declaration: node)
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
            for decl in overloads { declLexicalOwners[decl.id] = existing }
            existing.staticMethods[name, default: []].append(contentsOf: overloads)
        }
        for (name, property) in symbol.staticProperties
        where existing.staticProperties[name] == nil {
            existing.staticProperties[name] = property
            existing.fileScopedStaticMemberOrigins[name] =
                symbol.fileScopedStaticMemberOrigins[name]
        }
        for (name, declaration) in symbol.taskLocalProperties
        where existing.taskLocalProperties[name] == nil {
            existing.taskLocalProperties[name] = declaration
            existing.fileScopedStaticMemberOrigins[name] =
                symbol.fileScopedStaticMemberOrigins[name]
        }
        for (name, policy) in symbol.staticStoragePolicies
        where existing.staticStoragePolicies[name] == nil {
            existing.staticStoragePolicies[name] = policy
        }
        for name in symbol.staticUninitialized
        where !existing.staticUninitialized.contains(name) {
            existing.staticUninitialized.insert(name)
            existing.fileScopedStaticMemberOrigins[name] =
                symbol.fileScopedStaticMemberOrigins[name]
        }
        for (name, computed) in symbol.computedProperties
        where existing.computedProperties[name] == nil {
            if let id = computed.declarationID { declLexicalOwners[id] = existing }
            existing.computedProperties[name] = computed
        }
        for (name, computed) in symbol.staticComputedProperties
        where existing.staticComputedProperties[name] == nil {
            if let id = computed.declarationID { declLexicalOwners[id] = existing }
            existing.staticComputedProperties[name] = computed
            existing.fileScopedStaticMemberOrigins[name] =
                symbol.fileScopedStaticMemberOrigins[name]
        }
        for (name, nested) in symbol.nestedTypes
        where existing.nestedTypes[name] == nil {
            bindLexicalOwner(of: nested, to: existing)
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
        for member in memberDeclarations(in: node.memberBlock) {
            if case .enumCase(let caseDecl) = member {
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
                try collectEnumMember(member, into: symbol)
            }
        }
        return symbol
    }

    private func collectEnumMember(
        _ member: ParsedMemberDeclaration,
        into symbol: EnumSymbol
    ) throws {
        switch member {
        case .initializer(let initDecl):
            declLexicalOwners[initDecl.id] = symbol
            symbol.initializers.append(initDecl)
        case .variable(let varDecl):
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
                if isStaticDecl {
                    declLexicalOwners[binding.id] = symbol
                }
                if isStaticDecl,
                   declarationMetadata.hasFileScopedReadAccess {
                    symbol.fileScopedStaticMemberOrigins[memberName] = .init(
                        sourceFileIdentity: currentProgramMetadata?
                            .sourceFileIdentity(
                                at: varDecl
                                    .positionAfterSkippingLeadingTrivia))
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
                let coroutineErrors = unsupportedCoroutineAccessorErrors(
                    for: binding)
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
                            isThrowing: accessors.isGetterThrowing,
                            unsupportedCoroutineReadError:
                                coroutineErrors?.read,
                            unsupportedCoroutineModifyError:
                                coroutineErrors?.modify
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
                        isThrowing: accessors.isGetterThrowing,
                        unsupportedCoroutineReadError:
                            coroutineErrors?.read,
                        unsupportedCoroutineModifyError:
                            coroutineErrors?.modify
                    )
                } else if let coroutineErrors {
                    declLexicalOwners[binding.id] = symbol
                    let computed = ComputedProperty(
                        accessor: CodeBlockItemListSyntax([]),
                        isBuilder: false,
                        typeAnnotation: bindingMetadata.typeAnnotation,
                        declarationID: binding.id,
                        unsupportedCoroutineReadError: coroutineErrors.read,
                        unsupportedCoroutineModifyError:
                            coroutineErrors.modify
                    )
                    if isStaticDecl {
                        symbol.staticComputedProperties[memberName] = computed
                    } else {
                        symbol.computedProperties[memberName] = computed
                    }
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
                            referenceOwnership: referenceOwnership,
                            declarationID: binding.id
                        )
                    } else {
                        symbol.staticUninitialized.insert(memberName)
                    }
                }
            }
        case .function(let funcDecl):
            declLexicalOwners[funcDecl.id] = symbol
            let metadata = functionMetadata(for: funcDecl)
            if metadata.isTypeMember {
                symbol.staticMethods[metadata.name, default: []].append(
                    funcDecl)
            } else {
                symbol.methods[metadata.name, default: []].append(funcDecl)
            }
        case .enumeration(let nestedEnum):
            // Enums are namespaces as often as value types
            // (`TestCase.Cases.allCases`) — nested types register under the
            // dotted name and the bare name when unclaimed, mirroring the
            // struct path.
            let nested = try makeEnumSymbol(nestedEnum)
            nested.lexicalTypeOwner = symbol
            symbol.nestedTypes[nested.name] = .enumType(nested)
            inheritSourceModuleOwnership(
                .enumType(nested), from: .enumType(symbol))
            enumSymbols["\(symbol.name).\(nested.name)"] = nested
            if enumSymbols[nested.name] == nil { enumSymbols[nested.name] = nested }
            globals.define("\(symbol.name).\(nested.name)", .enumType(nested))
            if globals.lookup(nested.name) == nil {
                globals.define(nested.name, .enumType(nested))
            }
        case .structure(let nestedStruct):
            let nestedSymbol = try makeStructSymbol(nestedStruct)
            registerNestedType(nestedSymbol, in: symbol)
        case .classType(let nestedClass):
            let nestedSymbol = try makeClassLikeSymbol(nestedClass)
            registerNestedType(nestedSymbol, in: symbol)
        case .typeAlias(let alias):
            let metadata = typeAliasMetadata(for: alias)
            symbol.typeAliases[metadata.name] = metadata.targetTypeName
            typeAliasTargets["\(symbol.name).\(metadata.name)"] =
                metadata.targetTypeName
        case .actor, .deinitializer, .subscriptDeclaration,
             .enumCase, .protocolType, .other:
            return
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
        let position = node.positionAfterSkippingLeadingTrivia
        let sourceModuleName = currentProgramMetadata?.sourceModuleName(
            at: position)
        let sourceImportedModuleNames = currentProgramMetadata?
            .sourceImportedModuleNames(at: position)
        let hasSourceProvenance = sourceModuleName != nil
            || sourceImportedModuleNames != nil

        func visibleTarget(named name: String) -> RuntimeValue? {
            guard hasSourceProvenance else {
                if let exact = globals.lookup(name) { return exact }
                if name.contains("."),
                   let last = name.split(separator: ".").last {
                    return globals.lookup(String(last))
                }
                return nil
            }
            return lexicallyVisibleType(
                named: name,
                from: nil,
                sourceModuleName: sourceModuleName,
                sourceImportedModuleNames: sourceImportedModuleNames)
        }
        // A DOTTED extended type that doesn't resolve yet may be declared
        // by a LATER extension in the same pass (`extension Pixel.Event`
        // in a file sorting before `extension Pixel { enum Event }`) —
        // defer it; the post-pass retries once every type exists.
        if visibleTarget(named: typeName) == nil, typeName.contains("."),
           !deferredExtensionRetry {
            pendingDottedExtensions.append(node)
            return
        }
        // Source-module provenance chooses the nominal exactly as the
        // declaring file can see it. A bare flattened global from another,
        // unimported module is not an extension target.
        let extended = visibleTarget(named: typeName)
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
            for member in memberDeclarations(in: node.memberBlock) {
                try collectEnumMember(member, into: symbol)
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
            if hasSourceProvenance {
                nonNominalExtensionTypeNames.insert(canonical)
            }
            let symbol = mutableHostExtensionSymbol(named: canonical)
            try collectStructMembers(node.memberBlock, into: symbol)
        }
    }

    // MARK: - Functions

    func defineFunction(_ node: FunctionDeclSyntax, in env: Environment) throws {
        let metadata = functionMetadata(for: node)
        guard let body = metadata.body else {
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

    func makeFunctionClosure(
        _ node: FunctionDeclSyntax,
        body: CodeBlockSyntax,
        captured: Environment,
        originProgramState: RuntimeProgramState? = nil
    ) -> ClosureValue {
        let programState = originProgramState
            ?? programStateOwningDeclaration(node.id)
        let programPlan = programState?.programPlan ?? currentProgramPlan
        let programMetadata = programPlan?.metadata ?? currentProgramMetadata
        let metadata = programMetadata?.callableMetadataIndex.metadata(for: node)
            ?? ParsedFunctionMetadata(node)
        let closure = ClosureValue(
            parameters: metadata.parameters,
            body: body.statements,
            captured: captured,
            isBuilder: metadata.isBuilder,
            returnType: metadata.returnType,
            returnTypeName: metadata.returnTypeName,
            programMetadata: programMetadata,
            programPlan: programPlan
        )
        closure.programState = programState
        closure.functionDeclID = node.id
        let lexicalOwner = programState?.declarationLexicalOwners[node.id]
            ?? lexicalOwner(of: node.id)
            // Local declarations are not members in the program index, but
            // they still inherit the nominal lexical context of the running
            // source body (so `Self` keeps its declaration-site meaning).
            ?? lexicalOwnerFrames.last
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
        closure.sourceFunctionTargetDescriptor =
            sourceFunctionTargetDescriptor(
                declarationID: node.id,
                metadata: metadata,
                closure: closure)
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
        let programState = programStateOwningDeclaration(node.id)
        let programPlan = programState?.programPlan ?? currentProgramPlan
        let programMetadata = programPlan?.metadata ?? currentProgramMetadata
        let metadata = programMetadata?.callableMetadataIndex.metadata(for: node)
            ?? ParsedInitializerMetadata(node)
        let closure = ClosureValue(
            parameters: metadata.parameters,
            body: body.statements,
            captured: captured,
            programMetadata: programMetadata,
            programPlan: programPlan)
        closure.programState = programState
        let lexicalOwner = programState?.declarationLexicalOwners[node.id]
            ?? lexicalOwner(of: node.id)
            ?? fallbackLexicalOwner
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

    /// SwiftParser currently represents experimental `read`/`modify`
    /// accessors either as accessor declarations or as getter-body calls with
    /// trailing closures. Preserve both read and modify limitations so an
    /// unused declaration remains legal while an actual access fails with a
    /// stable, located ownership diagnostic.
    private func unsupportedCoroutineAccessorErrors(
        for binding: PatternBindingSyntax
    ) -> (read: RuntimeError?, modify: RuntimeError?)? {
        guard let accessorBlock = binding.accessorBlock else { return nil }
        var readAccessor: String?
        var modifyAccessor: String?

        func classify(_ spelling: String) {
            switch spelling {
            case "read", "_read":
                readAccessor = readAccessor ?? spelling
            case "modify", "_modify":
                modifyAccessor = modifyAccessor ?? spelling
            default:
                break
            }
        }

        switch accessorBlock.accessors {
        case .accessors(let accessors):
            for accessor in accessors {
                classify(accessor.accessorSpecifier.text)
            }
        case .getter(let items):
            for item in items {
                guard case .expr(let expression) = item.item,
                      let call = expression.as(FunctionCallExprSyntax.self),
                      let reference = call.calledExpression
                        .as(DeclReferenceExprSyntax.self),
                      call.arguments.isEmpty,
                      let closure = call.trailingClosure,
                      closure.tokens(viewMode: .sourceAccurate).contains(
                          where: { $0.text == "yield" }) else {
                    continue
                }
                classify(reference.baseName.text)
            }
        }

        guard readAccessor != nil || modifyAccessor != nil else { return nil }
        func demandError(_ accessor: String) -> RuntimeError {
            error(
                binding,
                "coroutine property accessor '\(accessor)' is unsupported; "
                    + "use ordinary get/set or provide a demand citation "
                    + "for suspension-safe coroutine ownership")
        }
        return (
            readAccessor.map(demandError),
            modifyAccessor.map(demandError))
    }

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
