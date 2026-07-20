import SwiftSyntax

struct IntegerIndexCollectionDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
    let argumentLabel: String?
    let indexOperationName: String
    let indexOperationLabel: String?
    let distance: Int
}

enum OptionalElementCollectionProjection: String, Hashable {
    case first
    case last
}

struct OptionalElementCollectionDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
    let projection: OptionalElementCollectionProjection
}

struct BooleanIndexEndpointEqualityCollectionDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
    let leftEndpointName: String
    let rightEndpointName: String
}

struct OptionalLastRemovalCollectionDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
}

enum RequiredEndpointRemoval: String, Hashable {
    case first
    case last
}

struct RequiredEndpointRemovalCollectionDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
    let endpoint: RequiredEndpointRemoval
}

enum IndexSearchArgumentKind: String, Hashable {
    case element
    case predicate
}

enum IndexSearchDirection: String, Hashable {
    case forward
    case backward
}

struct IndexSearchDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
    let argumentLabel: String?
    let argumentKind: IndexSearchArgumentKind
    let direction: IndexSearchDirection
}

enum NativeIndexMotionKind: String, Hashable {
    case successor
    case predecessor
    case offset
    case limitedOffset
}

struct NativeIndexMotionDefault: Hashable {
    let memberName: String
    let argumentLabels: [String?]
    let kind: NativeIndexMotionKind
}

/// A no-result mutation declared directly by the standard-library nominal
/// that backs one of the interpreter's native collection carriers. The
/// supported argument shape is deliberately structural: BridgeGen can
/// forward every public,
/// synchronous, one-`Int` mutation with no return value without learning an
/// SDK member name.
enum NativeCollectionCarrierKind: String, CaseIterable, Hashable {
    case array
    case dictionary
    case set
}

enum NativeCollectionCarrierScalarArgumentKind: String, Hashable {
    case integer
    case boolean
}

enum NativeCollectionCarrierScalarDefault: Hashable {
    case integer(Int)
    case boolean(Bool)
}

struct NativeCollectionCarrierScalarVoidMutation: Hashable {
    let carrierKind: NativeCollectionCarrierKind
    let memberName: String
    let argumentLabel: String?
    let argumentKind: NativeCollectionCarrierScalarArgumentKind
    let defaultValue: NativeCollectionCarrierScalarDefault?
}

struct NativeDictionaryKeyOptionalValueMutation: Hashable {
    let memberName: String
    let argumentLabel: String?
}

struct NativeCollectionCarrierDefaults {
    let scalarVoidMutations: [NativeCollectionCarrierScalarVoidMutation]
    let dictionaryKeyOptionalValueMutations:
        [NativeDictionaryKeyOptionalValueMutation]
}

/// A nested String collection view whose accessor supports in-place mutation.
/// The element is projected through a public one-argument String initializer;
/// the setter then provides a compiled copy-out path to the owning String.
struct NativeWritableStringCollectionView: Hashable {
    let propertyName: String
    let viewTypeName: String
    let elementTypeName: String
}

/// Discovers String properties that expose a mutable nested collection view.
/// No property identity is authored here: the owner identity comes from the
/// interpreter's native String carrier, while getter/setter/_modify access,
/// RangeReplaceableCollection conformance, Element, and its String projection
/// all come from the active standard-library interface.
func nativeWritableStringCollectionViews(
    in file: SourceFileSyntax?
) -> [NativeWritableStringCollectionView] {
    guard let file else { return [] }

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" }
    }

    let stringName = canonical(String(reflecting: String.self))
    let rangeReplaceableCollectionName = canonical(String(
        reflecting: (any RangeReplaceableCollection).self))
    var stringMemberBlocks: [MemberBlockItemListSyntax] = []
    var extensions: [ExtensionDeclSyntax] = []

    for item in file.statements {
        guard case .decl(let declaration) = item.item else { continue }
        if let nominal = declaration.as(StructDeclSyntax.self),
           canonical(nominal.name.text) == stringName {
            stringMemberBlocks.append(nominal.memberBlock.members)
        } else if let extensionDeclaration = declaration.as(
                    ExtensionDeclSyntax.self) {
            extensions.append(extensionDeclaration)
            if canonical(extensionDeclaration.extendedType
                .trimmedDescription) == stringName {
                stringMemberBlocks.append(
                    extensionDeclaration.memberBlock.members)
            }
        }
    }

    var stringInitializableElementTypes = Set<String>()
    var propertyViews: [(propertyName: String, viewTypeName: String)] = []
    for members in stringMemberBlocks {
        for member in members {
            if let initializer = member.decl.as(
                InitializerDeclSyntax.self),
               isPublic(initializer.modifiers),
               initializer.optionalMark == nil,
               initializer.genericParameterClause == nil,
               initializer.genericWhereClause == nil {
                let parameters = Array(
                    initializer.signature.parameterClause.parameters)
                if parameters.count == 1 {
                    stringInitializableElementTypes.insert(canonical(
                        parameters[0].type.trimmedDescription))
                }
                continue
            }

            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  isPublic(variable.modifiers),
                  !variable.modifiers.contains(where: {
                      $0.name.text == "static" || $0.name.text == "class"
                  }),
                  variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  let identifier = binding.pattern.as(
                      IdentifierPatternSyntax.self),
                  let viewType = binding.typeAnnotation?.type,
                  canonical(viewType.trimmedDescription)
                    .hasPrefix(stringName + "."),
                  let accessorBlock = binding.accessorBlock,
                  case .accessors(let accessors) = accessorBlock.accessors
            else { continue }
            let accessorNames = Set(
                accessors.map(\.accessorSpecifier.text))
            guard accessorNames.isSuperset(of: ["get", "set", "_modify"])
            else { continue }
            propertyViews.append((
                propertyName: identifier.identifier.text,
                viewTypeName: canonical(viewType.trimmedDescription)))
        }
    }

    var rangeReplaceableViewTypes = Set<String>()
    var elementTypesByView: [String: Set<String>] = [:]
    for extensionDeclaration in extensions {
        let viewTypeName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        if extensionDeclaration.inheritanceClause?.inheritedTypes.contains(
            where: {
                canonical($0.type.trimmedDescription)
                    == rangeReplaceableCollectionName
            }) == true {
            rangeReplaceableViewTypes.insert(viewTypeName)
        }
        for member in extensionDeclaration.memberBlock.members {
            guard let alias = member.decl.as(TypeAliasDeclSyntax.self),
                  isPublic(alias.modifiers),
                  alias.name.text == "Element"
            else { continue }
            elementTypesByView[viewTypeName, default: []].insert(canonical(
                alias.initializer.value.trimmedDescription))
        }
    }

    var views = Set<NativeWritableStringCollectionView>()
    for property in propertyViews
    where rangeReplaceableViewTypes.contains(property.viewTypeName) {
        guard let elementTypes = elementTypesByView[property.viewTypeName]
        else { continue }
        for elementType in elementTypes
        where stringInitializableElementTypes.contains(elementType) {
            views.insert(NativeWritableStringCollectionView(
                propertyName: property.propertyName,
                viewTypeName: property.viewTypeName,
                elementTypeName: elementType))
        }
    }

    return views.sorted {
        ($0.propertyName, $0.viewTypeName, $0.elementTypeName)
            < ($1.propertyName, $1.viewTypeName, $1.elementTypeName)
    }
}

/// Builds the refinement closure for protocols declared in an interface. A
/// default declared on a protocol is also eligible for every protocol that
/// transitively refines it, even though interpreted conformers only carry the
/// protocol spelling written in their own inheritance clause.
private func protocolRefinementEligibility(
    in file: SourceFileSyntax
) -> [String: [String]] {
    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func inheritedProtocolName(_ type: TypeSyntax) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return canonical(identifier.name.text)
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return canonical(member.name.text)
        }
        let raw = canonical(type.trimmedDescription)
        return String(raw.prefix { $0 != "<" })
    }

    var parents: [String: Set<String>] = [:]
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                  ProtocolDeclSyntax.self
              ) else { continue }
        let name = canonical(protocolDeclaration.name.text)
        parents[name, default: []].formUnion(
            protocolDeclaration.inheritanceClause?.inheritedTypes.map {
                inheritedProtocolName($0.type)
            } ?? [])
    }

    func refines(
        _ candidate: String,
        _ target: String,
        visited: inout Set<String>
    ) -> Bool {
        if candidate == target { return true }
        guard visited.insert(candidate).inserted else { return false }
        return parents[candidate]?.contains {
            refines($0, target, visited: &visited)
        } == true
    }

    return Dictionary(uniqueKeysWithValues: parents.keys.map { target in
        let eligible = parents.keys.filter { candidate in
            var visited = Set<String>()
            return refines(candidate, target, visited: &visited)
        }.sorted()
        return (target, eligible)
    })
}

/// Protocol constraints that imply Sequence semantics. The root identity and
/// every refining protocol come from the active interface, allowing runtime
/// overload selection to ask whether a native carrier can satisfy the
/// constraint without maintaining an SDK protocol-name ladder.
func materializableSequenceProtocolNames(
    in file: SourceFileSyntax?
) -> [String] {
    guard let file else { return [] }
    let sequenceName = normalize(String(
        reflecting: (any Sequence).self))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return protocolRefinementEligibility(in: file)[sequenceName]
        ?? [sequenceName]
}

/// Finds constrained protocol-extension defaults whose returned index is
/// computed solely by invoking an integer-distance operation on the supplied
/// index. The active stdlib currently uses this shape to synthesize index
/// motion for integer-indexed random-access collections.
///
/// Runtime values cannot conform an interpreted nominal to a compiled generic
/// protocol. BridgeGen therefore preserves the interface-derived eligibility,
/// call labels, and returned-index expression in a small generated adapter.
func integerIndexCollectionDefaults(
    in file: SourceFileSyntax?
) -> [IntegerIndexCollectionDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" }
    }

    let protocolNames = Set(file.statements.compactMap { item -> String? in
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                  ProtocolDeclSyntax.self
              ) else { return nil }
        return canonical(protocolDeclaration.name.text)
    })

    func constraintsPermitIntegerIndexDefault(
        _ whereClause: GenericWhereClauseSyntax?
    ) -> Bool {
        guard let whereClause else { return false }
        var conformances = Set<Set<String>>()
        var equalities = Set<Set<String>>()
        for requirement in whereClause.requirements {
            if let conformance = requirement.requirement.as(
                ConformanceRequirementSyntax.self
            ) {
                conformances.insert(Set([
                    canonical(conformance.leftType.trimmedDescription),
                    canonical(conformance.rightType.trimmedDescription),
                ]))
            } else if let sameType = requirement.requirement.as(
                SameTypeRequirementSyntax.self
            ) {
                equalities.insert(Set([
                    canonical(sameType.leftType.trimmedDescription),
                    canonical(sameType.rightType.trimmedDescription),
                ]))
            }
        }
        return conformances.contains(Set(["Self.Index", "Strideable"]))
            && equalities.contains(Set(["Self.Index.Stride", "Int"]))
            && equalities.contains(Set([
                "Self.Indices", "Range<Self.Index>",
            ]))
    }

    func integerLiteral(_ expression: ExprSyntax) -> Int? {
        if let literal = expression.as(IntegerLiteralExprSyntax.self) {
            return Int(literal.literal.text.replacingOccurrences(
                of: "_", with: ""))
        }
        guard let prefix = expression.as(PrefixOperatorExprSyntax.self),
              prefix.operator.text == "-",
              let magnitude = prefix.expression.as(
                  IntegerLiteralExprSyntax.self
              ),
              let value = Int(magnitude.literal.text.replacingOccurrences(
                  of: "_", with: "")) else { return nil }
        return -value
    }

    func rule(
        protocolName: String,
        function: FunctionDeclSyntax
    ) -> IntegerIndexCollectionDefault? {
        guard isPublic(function.modifiers),
              canonical(function.signature.returnClause?.type
                  .trimmedDescription ?? "") == "Self.Index"
        else { return nil }

        let parameters = Array(
            function.signature.parameterClause.parameters)
        guard parameters.count == 1,
              let body = function.body,
              let returnExpression = body.statements.reversed().compactMap({
                  item -> ExprSyntax? in
                  guard case .stmt(let statement) = item.item else {
                      return nil
                  }
                  return statement.as(ReturnStmtSyntax.self)?.expression
              }).first,
              let call = returnExpression.as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              let operation = call.calledExpression.as(
                  MemberAccessExprSyntax.self
              ),
              let base = operation.base?.as(DeclReferenceExprSyntax.self),
              call.arguments.count == 1,
              let distance = integerLiteral(
                  call.arguments[call.arguments.startIndex].expression)
        else { return nil }

        let parameter = parameters[0]
        let localName = parameter.secondName?.text
            ?? parameter.firstName.text
        guard base.baseName.text == localName else { return nil }

        return IntegerIndexCollectionDefault(
            protocolName: protocolName,
            eligibleProtocolNames: refinementEligibility[protocolName]
                ?? [protocolName],
            memberName: function.name.text,
            argumentLabel: parameter.firstName.text == "_"
                ? nil : parameter.firstName.text,
            indexOperationName: operation.declName.baseName.text,
            indexOperationLabel: call.arguments[call.arguments.startIndex]
                .label?.text,
            distance: distance)
    }

    var defaults = Set<IntegerIndexCollectionDefault>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              ) else { continue }
        let protocolName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        guard protocolNames.contains(protocolName),
              constraintsPermitIntegerIndexDefault(
                  extensionDeclaration.genericWhereClause)
        else { continue }
        for member in extensionDeclaration.memberBlock.members {
            guard let function = member.decl.as(
                FunctionDeclSyntax.self
            ), let discovered = rule(
                protocolName: protocolName, function: function)
            else { continue }
            defaults.insert(discovered)
        }
    }

    return defaults.sorted {
        ($0.protocolName, $0.memberName, $0.argumentLabel ?? "")
            < ($1.protocolName, $1.memberName, $1.argumentLabel ?? "")
    }
}

/// Finds the index-returning requirements of the protocol that structurally
/// owns a collection index (an associated Index, index-typed endpoints, and an
/// Index-to-Element subscript), plus the reverse step introduced by its
/// refinements. Native carriers can then preserve their real index
/// representation while member names and labels continue to come from the
/// active standard-library interface.
func nativeIndexMotionDefaults(
    in file: SourceFileSyntax?
) -> [NativeIndexMotionDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let protocols = file.statements.compactMap {
        item -> ProtocolDeclSyntax? in
        guard case .decl(let declaration) = item.item else { return nil }
        return declaration.as(ProtocolDeclSyntax.self)
    }

    func structurallyOwnsCollectionIndex(
        _ declaration: ProtocolDeclSyntax
    ) -> Bool {
        let members = declaration.memberBlock.members
        let ownsIndex = members.contains { member in
            guard let associated = member.decl.as(
                AssociatedTypeDeclSyntax.self
            ) else { return false }
            return associated.name.text == "Index"
                && !associated.modifiers.contains {
                    $0.name.text == "override"
                }
        }
        let ownsElement = members.contains { member in
            guard let associated = member.decl.as(
                AssociatedTypeDeclSyntax.self
            ) else { return false }
            return associated.name.text == "Element"
        }
        let indexEndpoints = members.reduce(into: 0) { count, member in
            guard let variable = member.decl.as(VariableDeclSyntax.self)
            else { return }
            count += variable.bindings.filter {
                canonical($0.typeAnnotation?.type.trimmedDescription ?? "")
                    == "Self.Index"
            }.count
        }
        let indexedElementSubscript = members.contains { member in
            guard let subscriptDeclaration = member.decl.as(
                SubscriptDeclSyntax.self
            ) else { return false }
            let parameters = Array(
                subscriptDeclaration.parameterClause.parameters)
            return parameters.count == 1
                && canonical(parameters[0].type.trimmedDescription)
                    == "Self.Index"
                && canonical(subscriptDeclaration.returnClause.type
                    .trimmedDescription) == "Self.Element"
        }
        return ownsIndex && ownsElement && indexEndpoints >= 2
            && indexedElementSubscript
    }

    func labels(
        _ parameters: [FunctionParameterSyntax]
    ) -> [String?] {
        parameters.map {
            $0.firstName.text == "_" ? nil : $0.firstName.text
        }
    }

    var defaults = Set<NativeIndexMotionDefault>()
    for root in protocols where structurallyOwnsCollectionIndex(root) {
        let rootName = canonical(root.name.text)
        let eligible = Set(refinementEligibility[rootName] ?? [rootName])
        for declaration in protocols
        where eligible.contains(canonical(declaration.name.text)) {
            let isRoot = canonical(declaration.name.text) == rootName
            for member in declaration.memberBlock.members {
                guard let function = member.decl.as(FunctionDeclSyntax.self)
                else { continue }
                let parameters = Array(
                    function.signature.parameterClause.parameters)
                let parameterTypes = parameters.map {
                    canonical($0.type.trimmedDescription)
                }
                let returnType = canonical(
                    function.signature.returnClause?.type
                        .trimmedDescription ?? "")
                let kind: NativeIndexMotionKind?
                switch (parameterTypes, returnType) {
                case (["Self.Index"], "Self.Index"):
                    if isRoot {
                        kind = .successor
                    } else if !function.modifiers.contains(where: {
                        $0.name.text == "override"
                    }) {
                        kind = .predecessor
                    } else {
                        kind = nil
                    }
                case (["Self.Index", "Int"], "Self.Index"):
                    kind = .offset
                case (["Self.Index", "Int", "Self.Index"], "Self.Index?"):
                    kind = .limitedOffset
                default:
                    kind = nil
                }
                guard let kind else { continue }
                defaults.insert(NativeIndexMotionDefault(
                    memberName: function.name.text,
                    argumentLabels: labels(parameters),
                    kind: kind))
            }
        }
    }

    return defaults.sorted {
        ($0.memberName, $0.kind.rawValue, $0.argumentLabels
            .map { $0 ?? "" }.joined(separator: ":"))
            < ($1.memberName, $1.kind.rawValue, $1.argumentLabels
                .map { $0 ?? "" }.joined(separator: ":"))
    }
}

/// Finds Collection-extension searches that walk between the collection's
/// endpoints, return the current index on the first match, and otherwise
/// return nil. The direction comes from `formIndex(after:)` or
/// `formIndex(before:)`; both an equatable element and a throwing predicate
/// are structural argument shapes. Declaration spellings remain generated
/// metadata.
func indexSearchDefaults(
    in file: SourceFileSyntax?
) -> [IndexSearchDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsSubsequence(
        _ sequence: [String], in tokens: [String]
    ) -> Bool {
        guard !sequence.isEmpty, sequence.count <= tokens.count else {
            return false
        }
        for start in 0...(tokens.count - sequence.count)
        where Array(tokens[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    let protocolNames = Set(file.statements.compactMap { item -> String? in
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                ProtocolDeclSyntax.self
              ) else { return nil }
        return canonical(protocolDeclaration.name.text)
    })

    func argumentKind(
        _ parameter: FunctionParameterSyntax
    ) -> IndexSearchArgumentKind? {
        if canonical(parameter.type.trimmedDescription) == "Self.Element" {
            return .element
        }
        guard let functionType = parameter.type.as(FunctionTypeSyntax.self),
              functionType.parameters.count == 1,
              let input = functionType.parameters.first,
              canonical(input.type.trimmedDescription) == "Self.Element",
              canonical(functionType.returnClause.type.trimmedDescription)
                == "Bool"
        else { return nil }
        return .predicate
    }

    func rule(
        protocolName: String,
        function: FunctionDeclSyntax
    ) -> IndexSearchDefault? {
        let parameters = Array(
            function.signature.parameterClause.parameters)
        guard function.modifiers.contains(where: {
                  $0.name.text == "public"
              }),
              !function.modifiers.contains(where: {
                  $0.name.text == "mutating"
              }),
              parameters.count == 1,
              let parameter = parameters.first,
              let kind = argumentKind(parameter),
              canonical(function.signature.returnClause?.type
                  .trimmedDescription ?? "") == "Self.Index?",
              let body = function.body
        else { return nil }

        let tokens = body.tokens(viewMode: .sourceAccurate).map(\.text)
        let localName = parameter.secondName?.text
            ?? parameter.firstName.text
        let advances = containsSubsequence(
            ["formIndex", "(", "after", ":"], in: tokens)
        let retreats = containsSubsequence(
            ["formIndex", "(", "before", ":"], in: tokens)
        guard tokens.contains("startIndex"),
              tokens.contains("endIndex"),
              tokens.contains(localName),
              advances != retreats,
              containsSubsequence(["return", "nil"], in: tokens)
        else { return nil }
        if kind == .element, !tokens.contains("==") {
            return nil
        }

        return IndexSearchDefault(
            protocolName: protocolName,
            eligibleProtocolNames: refinementEligibility[protocolName]
                ?? [protocolName],
            memberName: function.name.text,
            argumentLabel: parameter.firstName.text == "_"
                ? nil : parameter.firstName.text,
            argumentKind: kind,
            direction: advances ? .forward : .backward)
    }

    var defaults = Set<IndexSearchDefault>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              ) else { continue }
        let protocolName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        guard protocolNames.contains(protocolName) else { continue }
        for member in extensionDeclaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  let discovered = rule(
                    protocolName: protocolName, function: function)
            else { continue }
            defaults.insert(discovered)
        }
    }

    return defaults.sorted {
        (
            $0.protocolName, $0.memberName, $0.direction.rawValue,
            $0.argumentKind.rawValue,
            $0.argumentLabel ?? ""
        ) < (
            $1.protocolName, $1.memberName, $1.direction.rawValue,
            $1.argumentKind.rawValue,
            $1.argumentLabel ?? ""
        )
    }
}

/// Finds public Boolean protocol requirements whose unconstrained default
/// getter compares two distinct Index-typed endpoint requirements for
/// equality. The declaration supplies every member spelling; the generated
/// adapter retains only the endpoint-equality semantic shape.
func booleanIndexEndpointEqualityCollectionDefaults(
    in file: SourceFileSyntax?
) -> [BooleanIndexEndpointEqualityCollectionDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" }
    }

    struct ProtocolShape {
        let booleanRequirements: Set<String>
        let indexEndpoints: Set<String>
    }

    var protocolShapes: [String: ProtocolShape] = [:]
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                  ProtocolDeclSyntax.self),
              isPublic(protocolDeclaration.modifiers)
        else { continue }

        let ownsIndex = protocolDeclaration.memberBlock.members.contains {
            member in
            guard let associated = member.decl.as(
                AssociatedTypeDeclSyntax.self)
            else { return false }
            return associated.name.text == "Index"
                && !associated.modifiers.contains {
                    $0.name.text == "override"
                }
        }
        guard ownsIndex else { continue }

        var booleanRequirements = Set<String>()
        var indexEndpoints = Set<String>()
        for member in protocolDeclaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self)
            else { continue }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(
                    IdentifierPatternSyntax.self)
                else { continue }
                switch canonical(
                    binding.typeAnnotation?.type.trimmedDescription ?? ""
                ) {
                case "Bool":
                    booleanRequirements.insert(identifier.identifier.text)
                case "Self.Index":
                    indexEndpoints.insert(identifier.identifier.text)
                default:
                    break
                }
            }
        }
        guard !booleanRequirements.isEmpty, indexEndpoints.count >= 2
        else { continue }
        protocolShapes[canonical(protocolDeclaration.name.text)] =
            ProtocolShape(
                booleanRequirements: booleanRequirements,
                indexEndpoints: indexEndpoints)
    }

    var defaults = Set<BooleanIndexEndpointEqualityCollectionDefault>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self),
              extensionDeclaration.genericWhereClause == nil
        else { continue }
        let protocolName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        guard let shape = protocolShapes[protocolName] else { continue }

        for member in extensionDeclaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  isPublic(variable.modifiers),
                  variable.bindings.count == 1,
                  let binding = variable.bindings.first,
                  let identifier = binding.pattern.as(
                      IdentifierPatternSyntax.self),
                  shape.booleanRequirements.contains(
                      identifier.identifier.text),
                  canonical(binding.typeAnnotation?.type
                      .trimmedDescription ?? "") == "Bool",
                  let accessorBlock = binding.accessorBlock
            else { continue }

            let tokens = accessorBlock.tokens(viewMode: .sourceAccurate)
                .map(\.text)
            guard tokens.count == 9,
                  tokens[0] == "{", tokens[1] == "get",
                  tokens[2] == "{", tokens[3] == "return",
                  tokens[5] == "==", tokens[7] == "}",
                  tokens[8] == "}", tokens[4] != tokens[6],
                  shape.indexEndpoints.contains(tokens[4]),
                  shape.indexEndpoints.contains(tokens[6])
            else { continue }

            defaults.insert(
                BooleanIndexEndpointEqualityCollectionDefault(
                    protocolName: protocolName,
                    eligibleProtocolNames:
                        refinementEligibility[protocolName]
                            ?? [protocolName],
                    memberName: identifier.identifier.text,
                    leftEndpointName: tokens[4],
                    rightEndpointName: tokens[6]))
        }
    }

    return defaults.sorted {
        (
            $0.protocolName, $0.memberName, $0.leftEndpointName,
            $0.rightEndpointName
        ) < (
            $1.protocolName, $1.memberName, $1.leftEndpointName,
            $1.rightEndpointName
        )
    }
}

/// Finds protocol-extension getters whose interface body implements an
/// optional endpoint projection. A start projection captures `startIndex`,
/// checks it against `endIndex`, and subscripts `self`; an end projection
/// checks emptiness and subscripts at the predecessor of `endIndex`.
/// Member spellings are captured from declarations; runtime behavior comes
/// solely from the protocol and getter structure.
func optionalElementCollectionDefaults(
    in file: SourceFileSyntax?
) -> [OptionalElementCollectionDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "public" }
    }

    let protocolNames = Set(file.statements.compactMap { item -> String? in
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                  ProtocolDeclSyntax.self
              ) else { return nil }
        return canonical(protocolDeclaration.name.text)
    })

    func rule(
        protocolName: String,
        variable: VariableDeclSyntax
    ) -> OptionalElementCollectionDefault? {
        guard isPublic(variable.modifiers),
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              let identifier = binding.pattern.as(
                  IdentifierPatternSyntax.self),
              canonical(binding.typeAnnotation?.type.trimmedDescription ?? "")
                == "Self.Element?",
              let accessorBlock = binding.accessorBlock
        else { return nil }

        let tokens = accessorBlock.tokens(viewMode: .sourceAccurate).map(\.text)
        let projection: OptionalElementCollectionProjection
        if tokens.count == 25 {
            let local = tokens[4]
            let expected = [
                "{", "get", "{", "let", local, "=", "startIndex",
                "if", local, "!=", "endIndex", "{", "return", "self",
                "[", local, "]", "}", "else", "{", "return", "nil",
                "}", "}", "}",
            ]
            guard tokens == expected else { return nil }
            projection = .first
        } else {
            let expected = [
                "{", "get", "{", "return", "isEmpty", "?", "nil",
                ":", "self", "[", "index", "(", "before", ":",
                "endIndex", ")", "]", "}", "}",
            ]
            guard tokens == expected else { return nil }
            projection = .last
        }
        return OptionalElementCollectionDefault(
            protocolName: protocolName,
            eligibleProtocolNames: refinementEligibility[protocolName]
                ?? [protocolName],
            memberName: identifier.identifier.text,
            projection: projection)
    }

    var defaults = Set<OptionalElementCollectionDefault>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              ) else { continue }
        let protocolName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        guard protocolNames.contains(protocolName) else { continue }
        for member in extensionDeclaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  let discovered = rule(
                    protocolName: protocolName, variable: variable)
            else { continue }
            defaults.insert(discovered)
        }
    }

    return defaults.sorted {
        ($0.protocolName, $0.memberName, $0.projection.rawValue)
            < ($1.protocolName, $1.memberName, $1.projection.rawValue)
    }
}

/// Finds zero-argument mutating protocol defaults that return an optional
/// element, return nil for an empty receiver, and remove the element at the
/// predecessor of `endIndex`. The declaration's spelling remains generated
/// data; runtime dispatch keys on this semantic shape rather than an authored
/// collection API name.
func optionalLastRemovalCollectionDefaults(
    in file: SourceFileSyntax?
) -> [OptionalLastRemovalCollectionDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsSubsequence(
        _ sequence: [String], in tokens: [String]
    ) -> Bool {
        guard !sequence.isEmpty, sequence.count <= tokens.count else {
            return false
        }
        for start in 0...(tokens.count - sequence.count)
        where Array(tokens[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    let protocolNames = Set(file.statements.compactMap { item -> String? in
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                  ProtocolDeclSyntax.self
              ) else { return nil }
        return canonical(protocolDeclaration.name.text)
    })

    func rule(
        protocolName: String,
        function: FunctionDeclSyntax
    ) -> OptionalLastRemovalCollectionDefault? {
        guard function.modifiers.contains(where: {
                  $0.name.text == "public"
              }),
              function.modifiers.contains(where: {
                  $0.name.text == "mutating"
              }),
              function.signature.parameterClause.parameters.isEmpty,
              canonical(function.signature.returnClause?.type
                  .trimmedDescription ?? "") == "Self.Element?",
              let body = function.body
        else { return nil }

        let tokens = body.tokens(viewMode: .sourceAccurate).map(\.text)
        let returnsNilWhenEmpty = tokens.contains("isEmpty")
            && containsSubsequence(["return", "nil"], in: tokens)
        let addressesPredecessorOfEnd = containsSubsequence(
            ["index", "(", "before", ":", "endIndex", ")"],
            in: tokens)
        let replacesSelfWithPrefix = containsSubsequence(
            ["self", "=", "self", "["], in: tokens)
        let returnsEndRelativeMutation = body.statements.contains { item in
            guard case .stmt(let statement) = item.item,
                  let returned = statement.as(ReturnStmtSyntax.self)?.expression,
                  let call = returned.as(FunctionCallExprSyntax.self)
            else { return false }
            return containsSubsequence(
                ["index", "(", "before", ":", "endIndex", ")"],
                in: call.tokens(viewMode: .sourceAccurate).map(\.text))
        }
        guard returnsNilWhenEmpty,
              addressesPredecessorOfEnd,
              replacesSelfWithPrefix || returnsEndRelativeMutation
        else { return nil }

        return OptionalLastRemovalCollectionDefault(
            protocolName: protocolName,
            eligibleProtocolNames: refinementEligibility[protocolName]
                ?? [protocolName],
            memberName: function.name.text)
    }

    var defaults = Set<OptionalLastRemovalCollectionDefault>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              ) else { continue }
        let protocolName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        guard protocolNames.contains(protocolName) else { continue }
        for member in extensionDeclaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  let discovered = rule(
                    protocolName: protocolName, function: function)
            else { continue }
            defaults.insert(discovered)
        }
    }

    return defaults.sorted {
        ($0.protocolName, $0.memberName) < ($1.protocolName, $1.memberName)
    }
}

/// Finds zero-argument mutating protocol defaults that return a required
/// endpoint element and remove that same endpoint from the receiver. The
/// generated endpoint property lets every native indexed carrier share one
/// adapter without teaching the evaluator collection method spellings.
func requiredEndpointRemovalCollectionDefaults(
    in file: SourceFileSyntax?
) -> [RequiredEndpointRemovalCollectionDefault] {
    guard let file else { return [] }
    let refinementEligibility = protocolRefinementEligibility(in: file)

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsSubsequence(
        _ sequence: [String], in tokens: [String]
    ) -> Bool {
        guard !sequence.isEmpty, sequence.count <= tokens.count else {
            return false
        }
        for start in 0...(tokens.count - sequence.count)
        where Array(tokens[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    let protocolNames = Set(file.statements.compactMap { item -> String? in
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                  ProtocolDeclSyntax.self
              ) else { return nil }
        return canonical(protocolDeclaration.name.text)
    })

    func rule(
        protocolName: String,
        function: FunctionDeclSyntax
    ) -> RequiredEndpointRemovalCollectionDefault? {
        guard function.modifiers.contains(where: {
                  $0.name.text == "public"
              }),
              function.modifiers.contains(where: {
                  $0.name.text == "mutating"
              }),
              function.signature.parameterClause.parameters.isEmpty,
              canonical(function.signature.returnClause?.type
                  .trimmedDescription ?? "") == "Self.Element",
              let body = function.body
        else { return nil }

        let tokens = body.tokens(viewMode: .sourceAccurate).map(\.text)
        let removesFirst = containsSubsequence(
            ["index", "(", "after", ":", "startIndex", ")"],
            in: tokens)
            || (tokens.contains("first") && containsSubsequence(
                ["removeFirst", "(", "1", ")"], in: tokens))
        let removesLast = containsSubsequence(
            ["index", "(", "before", ":", "endIndex", ")"],
            in: tokens)
        guard removesFirst != removesLast else { return nil }

        return RequiredEndpointRemovalCollectionDefault(
            protocolName: protocolName,
            eligibleProtocolNames: refinementEligibility[protocolName]
                ?? [protocolName],
            memberName: function.name.text,
            endpoint: removesFirst ? .first : .last)
    }

    var defaults = Set<RequiredEndpointRemovalCollectionDefault>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              ) else { continue }
        let protocolName = canonical(
            extensionDeclaration.extendedType.trimmedDescription)
        guard protocolNames.contains(protocolName) else { continue }
        for member in extensionDeclaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  let discovered = rule(
                    protocolName: protocolName, function: function)
            else { continue }
            defaults.insert(discovered)
        }
    }

    return defaults.sorted {
        ($0.protocolName, $0.memberName, $0.endpoint.rawValue)
            < ($1.protocolName, $1.memberName, $1.endpoint.rawValue)
    }
}

/// Finds nominal collection carriers whose sole generic parameter is the
/// primary associated type declared by `Collection`. Runtime collection
/// payloads erase nominal shells, so generated metadata is the reusable proof
/// that a source annotation such as `SomeCollection<T>` carries `T` as its
/// element type. The rule is derived from generic and conformance structure;
/// no concrete standard-library nominal is named here.
func elementGenericCollectionNominals(
    in file: SourceFileSyntax?
) -> [String] {
    guard let file else { return [] }

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nominalName(_ raw: String) -> String {
        var name = canonical(raw)
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name.split(separator: ".").last.map(String.init) ?? name
    }

    let collectionDeclaration = file.statements.lazy.compactMap {
        item -> ProtocolDeclSyntax? in
        guard case .decl(let declaration) = item.item,
              let protocolDeclaration = declaration.as(
                ProtocolDeclSyntax.self),
              canonical(protocolDeclaration.name.text) == "Collection"
        else { return nil }
        return protocolDeclaration
    }.first
    guard let primaryAssociatedTypes = collectionDeclaration?
        .primaryAssociatedTypeClause?.primaryAssociatedTypes
    else { return [] }
    let associatedTypes = Array(primaryAssociatedTypes)
    guard associatedTypes.count == 1 else { return [] }
    let elementParameterName = associatedTypes[0].name.text

    let collectionProtocols = Set(
        protocolRefinementEligibility(in: file)["Collection"]
            ?? ["Collection"])
    var candidates = Set<String>()
    var conformingNominals = Set<String>()

    func recordsCollectionConformance(
        _ inheritanceClause: InheritanceClauseSyntax?,
        for nominal: String
    ) {
        guard inheritanceClause?.inheritedTypes.contains(where: {
            collectionProtocols.contains(nominalName(
                $0.type.trimmedDescription))
        }) == true else { return }
        conformingNominals.insert(nominal)
    }

    func recordCandidate(
        name: String,
        genericParameters: GenericParameterClauseSyntax?,
        inheritanceClause: InheritanceClauseSyntax?
    ) {
        guard let genericParameters else { return }
        let parameters = Array(genericParameters.parameters)
        guard parameters.count == 1,
              parameters[0].name.text == elementParameterName
        else { return }
        let nominal = nominalName(name)
        candidates.insert(nominal)
        recordsCollectionConformance(inheritanceClause, for: nominal)
    }

    for item in file.statements {
        guard case .decl(let declaration) = item.item else { continue }
        if let nominal = declaration.as(StructDeclSyntax.self) {
            recordCandidate(
                name: nominal.name.text,
                genericParameters: nominal.genericParameterClause,
                inheritanceClause: nominal.inheritanceClause)
        } else if let nominal = declaration.as(EnumDeclSyntax.self) {
            recordCandidate(
                name: nominal.name.text,
                genericParameters: nominal.genericParameterClause,
                inheritanceClause: nominal.inheritanceClause)
        } else if let nominal = declaration.as(ClassDeclSyntax.self) {
            recordCandidate(
                name: nominal.name.text,
                genericParameters: nominal.genericParameterClause,
                inheritanceClause: nominal.inheritanceClause)
        } else if let extensionDeclaration = declaration.as(
                    ExtensionDeclSyntax.self) {
            recordsCollectionConformance(
                extensionDeclaration.inheritanceClause,
                for: nominalName(
                    extensionDeclaration.extendedType.trimmedDescription))
        }
    }

    return candidates.intersection(conformingNominals).sorted()
}

/// Discovers native operations that can be emitted against the interpreter's
/// array, dictionary, and set carriers. Carrier identities come from their
/// host types. Mutation semantics are admitted by declaration/body shape:
/// scalar no-result operations, or a Dictionary wrapper that forwards one
/// Key through stored backing state and returns an optional Value.
func nativeCollectionCarrierDefaults(
    in file: SourceFileSyntax?
) -> NativeCollectionCarrierDefaults {
    guard let file else {
        return NativeCollectionCarrierDefaults(
            scalarVoidMutations: [],
            dictionaryKeyOptionalValueMutations: [])
    }

    func canonical(_ raw: String) -> String {
        normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nominalName(_ raw: String) -> String {
        var name = canonical(raw)
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name.split(separator: ".").last.map(String.init) ?? name
    }

    func scalarArgument(
        _ parameter: FunctionParameterSyntax
    ) -> (
        kind: NativeCollectionCarrierScalarArgumentKind,
        defaultValue: NativeCollectionCarrierScalarDefault?
    )? {
        let kind: NativeCollectionCarrierScalarArgumentKind
        switch canonical(parameter.type.trimmedDescription) {
        case "Int": kind = .integer
        case "Bool": kind = .boolean
        default: return nil
        }
        guard let expression = parameter.defaultValue?.value else {
            return (kind, nil)
        }
        switch kind {
        case .integer:
            if let literal = expression.as(IntegerLiteralExprSyntax.self),
               let value = Int(literal.literal.text.replacingOccurrences(
                   of: "_", with: "")) {
                return (kind, .integer(value))
            }
            if let prefix = expression.as(PrefixOperatorExprSyntax.self),
               prefix.operator.text == "-",
               let literal = prefix.expression.as(
                   IntegerLiteralExprSyntax.self),
               let value = Int(literal.literal.text.replacingOccurrences(
                   of: "_", with: "")) {
                return (kind, .integer(-value))
            }
        case .boolean:
            if let literal = expression.as(BooleanLiteralExprSyntax.self) {
                return (kind, .boolean(literal.literal.text == "true"))
            }
        }
        return nil
    }

    let carrierKindsByNominal: [String: NativeCollectionCarrierKind] = [
        nominalName(String(reflecting: [Never].self)): .array,
        nominalName(String(reflecting: [Never: Never].self)): .dictionary,
        nominalName(String(reflecting: Set<Never>.self)): .set,
    ]
    var genericParameterNamesByNominal: [String: [String]] = [:]
    var storedPropertyNamesByNominal: [String: Set<String>] = [:]
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let nominal = declaration.as(StructDeclSyntax.self),
              carrierKindsByNominal[nominal.name.text] != nil
        else { continue }
        genericParameterNamesByNominal[nominal.name.text] =
            nominal.genericParameterClause?.parameters.map(\.name.text) ?? []
        for member in nominal.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self)
            else { continue }
            for binding in variable.bindings {
                if let identifier = binding.pattern.as(
                    IdentifierPatternSyntax.self) {
                    storedPropertyNamesByNominal[
                        nominal.name.text, default: []
                    ].insert(identifier.identifier.text)
                }
            }
        }
    }

    func forwardsSingleArgumentThroughStoredProperty(
        _ function: FunctionDeclSyntax,
        parameter: FunctionParameterSyntax,
        storedPropertyNames: Set<String>
    ) -> Bool {
        guard let body = function.body,
              body.statements.count == 1,
              let item = body.statements.first,
              case .stmt(let statement) = item.item,
              let returned = statement.as(ReturnStmtSyntax.self)?.expression,
              let call = returned.as(FunctionCallExprSyntax.self),
              call.trailingClosure == nil,
              call.additionalTrailingClosures.isEmpty,
              call.arguments.count == 1,
              let forwardedArgument = call.arguments.first,
              let member = call.calledExpression.as(
                  MemberAccessExprSyntax.self),
              let storage = member.base?.as(DeclReferenceExprSyntax.self),
              storedPropertyNames.contains(storage.baseName.text),
              member.declName.baseName.text == function.name.text,
              forwardedArgument.label?.text
                == (parameter.firstName.text == "_"
                    ? nil : parameter.firstName.text),
              let forwardedValue = forwardedArgument.expression.as(
                  DeclReferenceExprSyntax.self)
        else { return false }
        let localName = parameter.secondName?.text
            ?? parameter.firstName.text
        return forwardedValue.baseName.text == localName
    }

    var scalarVoidMutations =
        Set<NativeCollectionCarrierScalarVoidMutation>()
    var dictionaryKeyOptionalValueMutations =
        Set<NativeDictionaryKeyOptionalValueMutation>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item else { continue }
        let members: MemberBlockItemListSyntax
        let carrierKind: NativeCollectionCarrierKind
        let carrierNominalName: String
        if let nominal = declaration.as(StructDeclSyntax.self),
           let matchedKind = carrierKindsByNominal[nominal.name.text] {
            members = nominal.memberBlock.members
            carrierKind = matchedKind
            carrierNominalName = nominal.name.text
        } else if let extensionDeclaration = declaration.as(
                    ExtensionDeclSyntax.self) {
            let matchedName = nominalName(
                extensionDeclaration.extendedType.trimmedDescription)
            guard let matchedKind = carrierKindsByNominal[matchedName]
            else { continue }
            members = extensionDeclaration.memberBlock.members
            carrierKind = matchedKind
            carrierNominalName = matchedName
        } else {
            continue
        }

        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self)
            else { continue }
            let returnType = canonical(function.signature.returnClause?.type
                .trimmedDescription ?? "Void")
            guard function.modifiers.contains(where: {
                      $0.name.text == "public"
                  }),
                  function.modifiers.contains(where: {
                      $0.name.text == "mutating"
                  }),
                  !function.modifiers.contains(where: {
                      $0.name.text == "static" || $0.name.text == "class"
                  }),
                  function.genericParameterClause == nil,
                  function.genericWhereClause == nil,
                  function.signature.effectSpecifiers == nil
            else { continue }

            let parameters = Array(
                function.signature.parameterClause.parameters)
            if (returnType == "Void" || returnType == "()"),
               parameters.count == 1,
               let scalar = scalarArgument(parameters[0]) {
                scalarVoidMutations.insert(
                    NativeCollectionCarrierScalarVoidMutation(
                        carrierKind: carrierKind,
                        memberName: function.name.text,
                        argumentLabel: parameters[0].firstName.text == "_"
                            ? nil : parameters[0].firstName.text,
                        argumentKind: scalar.kind,
                        defaultValue: scalar.defaultValue))
            }

            let genericParameters =
                genericParameterNamesByNominal[carrierNominalName] ?? []
            if carrierKind == .dictionary,
               genericParameters.count == 2,
               parameters.count == 1,
               canonical(parameters[0].type.trimmedDescription)
                    == genericParameters[0],
               parameters[0].defaultValue == nil,
               returnType == genericParameters[1] + "?",
               forwardsSingleArgumentThroughStoredProperty(
                   function,
                   parameter: parameters[0],
                   storedPropertyNames:
                    storedPropertyNamesByNominal[carrierNominalName] ?? []) {
                dictionaryKeyOptionalValueMutations.insert(
                    NativeDictionaryKeyOptionalValueMutation(
                        memberName: function.name.text,
                        argumentLabel: parameters[0].firstName.text == "_"
                            ? nil : parameters[0].firstName.text))
            }
        }
    }

    return NativeCollectionCarrierDefaults(
        scalarVoidMutations: scalarVoidMutations.sorted {
            (
                $0.carrierKind.rawValue, $0.memberName,
                $0.argumentLabel ?? "", $0.argumentKind.rawValue
            ) < (
                $1.carrierKind.rawValue, $1.memberName,
                $1.argumentLabel ?? "", $1.argumentKind.rawValue
            )
        },
        dictionaryKeyOptionalValueMutations:
            dictionaryKeyOptionalValueMutations.sorted {
                ($0.memberName, $0.argumentLabel ?? "")
                    < ($1.memberName, $1.argumentLabel ?? "")
            })
}
