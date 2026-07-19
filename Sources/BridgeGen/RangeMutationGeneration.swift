import SwiftSyntax

/// A public protocol-extension method whose interface body replaces one
/// `Range<Self.Index>` with a freshly constructed empty Collection. Runtime
/// arrays can execute that semantic without knowing the method's SDK name.
struct RangeRemovalMutation: Hashable {
    let protocolName: String
    let memberName: String
}

private struct RangeReplacementRequirement: Hashable {
    let memberName: String
    let replacementLabel: String
}

/// Discovers range-removal defaults from the active stdlib interface.
///
/// Classification is structural: the extended declaration must be a
/// protocol, that protocol must require a range replacement accepting a
/// Collection, and the public mutating default must delegate its sole range
/// parameter to that requirement with a zero-argument Collection value.
func rangeRemovalMutations(
    in file: SourceFileSyntax?
) -> [RangeRemovalMutation] {
    guard let file else { return [] }

    func compact(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Swift.", with: "")
            .filter { !$0.isWhitespace }
    }

    func nominalName(_ raw: String) -> String {
        let name = compact(raw)
        return name.firstIndex(of: "<").map {
            String(name[..<$0])
        } ?? name
    }

    func isSelfIndexRange(_ type: TypeSyntax) -> Bool {
        compact(type.trimmedDescription) == "Range<Self.Index>"
    }

    let protocols = file.statements.compactMap {
        item -> ProtocolDeclSyntax? in
        guard case .decl(let declaration) = item.item else { return nil }
        return declaration.as(ProtocolDeclSyntax.self)
    }
    let protocolNames = Set(protocols.map {
        nominalName($0.name.text)
    })

    // A zero-argument replacement is only considered empty-collection
    // construction when its nominal is declared to conform to a Collection
    // protocol in this same interface.
    var collectionConformingTypes = Set<String>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              ),
              extensionDeclaration.inheritanceClause?.inheritedTypes
                .contains(where: {
                    nominalName($0.type.trimmedDescription)
                        .hasSuffix("Collection")
                }) == true
        else { continue }
        collectionConformingTypes.insert(nominalName(
            extensionDeclaration.extendedType.trimmedDescription))
    }

    var requirements: [String: Set<RangeReplacementRequirement>] = [:]
    for declaration in protocols {
        let protocolName = nominalName(declaration.name.text)
        for member in declaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  function.modifiers.contains(where: {
                      $0.name.text == "mutating"
                  }),
                  function.body == nil,
                  function.signature.returnClause == nil,
                  function.signature.parameterClause.parameters.count == 2
            else { continue }
            let parameters = Array(
                function.signature.parameterClause.parameters)
            guard parameters[0].firstName.text == "_",
                  isSelfIndexRange(parameters[0].type),
                  parameters[1].firstName.text != "_",
                  function.genericWhereClause?.requirements.contains(
                    where: { requirement in
                        guard let conformance = requirement.requirement.as(
                            ConformanceRequirementSyntax.self
                        ) else { return false }
                        return nominalName(
                            conformance.rightType.trimmedDescription)
                            .hasSuffix("Collection")
                    }) == true
            else { continue }
            requirements[protocolName, default: []].insert(.init(
                memberName: function.name.text,
                replacementLabel: parameters[1].firstName.text))
        }
    }

    var result = Set<RangeRemovalMutation>()
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                  ExtensionDeclSyntax.self
              )
        else { continue }
        let protocolName = nominalName(
            extensionDeclaration.extendedType.trimmedDescription)
        guard protocolNames.contains(protocolName),
              let protocolRequirements = requirements[protocolName]
        else { continue }

        for member in extensionDeclaration.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  function.modifiers.contains(where: {
                      $0.name.text == "public"
                  }),
                  function.modifiers.contains(where: {
                      $0.name.text == "mutating"
                  }),
                  function.signature.returnClause == nil,
                  function.signature.parameterClause.parameters.count == 1,
                  let parameter = function.signature.parameterClause
                    .parameters.first,
                  parameter.firstName.text == "_",
                  isSelfIndexRange(parameter.type),
                  let body = function.body,
                  body.statements.count == 1,
                  case .expr(let expression) = body.statements.first?.item,
                  let call = expression.as(FunctionCallExprSyntax.self),
                  call.arguments.count == 2,
                  call.trailingClosure == nil,
                  call.additionalTrailingClosures.isEmpty,
                  let callee = call.calledExpression.as(
                      DeclReferenceExprSyntax.self
                  ),
                  let rangeReference = call.arguments.first?.expression.as(
                      DeclReferenceExprSyntax.self
                  ),
                  rangeReference.baseName.text
                    == (parameter.secondName ?? parameter.firstName).text,
                  let replacementArgument = call.arguments.last,
                  let replacementLabel = replacementArgument.label?.text,
                  let emptyConstruction = replacementArgument.expression.as(
                      FunctionCallExprSyntax.self
                  ),
                  emptyConstruction.arguments.isEmpty,
                  emptyConstruction.trailingClosure == nil,
                  emptyConstruction.additionalTrailingClosures.isEmpty,
                  let emptyType = emptyConstruction.calledExpression.as(
                      DeclReferenceExprSyntax.self
                  ),
                  collectionConformingTypes.contains(nominalName(
                      emptyType.baseName.text)),
                  protocolRequirements.contains(.init(
                      memberName: callee.baseName.text,
                      replacementLabel: replacementLabel))
            else { continue }

            result.insert(.init(
                protocolName: protocolName,
                memberName: function.name.text))
        }
    }

    return result.sorted {
        ($0.protocolName, $0.memberName)
            < ($1.protocolName, $1.memberName)
    }
}
