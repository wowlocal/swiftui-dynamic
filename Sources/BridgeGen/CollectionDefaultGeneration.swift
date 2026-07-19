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

struct OptionalLastRemovalCollectionDefault: Hashable {
    let protocolName: String
    let eligibleProtocolNames: [String]
    let memberName: String
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
