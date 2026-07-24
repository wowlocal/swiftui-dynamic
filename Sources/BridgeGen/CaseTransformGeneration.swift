import Foundation
import SwiftSyntax

enum CaseTransformApplication: String, Hashable {
    /// The callback result replaces the selected case's associated value.
    case payload
    /// The callback itself returns the transformed enum carrier.
    case carrier
}

struct CaseTransformOperation: Hashable {
    let nominalName: String
    let memberName: String
    let selectedCaseName: String
    let argumentLabel: String?
    let application: CaseTransformApplication
}

/// Derive case-selective transforms from generic enum method signatures.
///
/// A qualifying enum has one single-payload case per generic parameter. A
/// qualifying method accepts one callback whose input is one of those generic
/// parameters and returns the same enum with exactly that generic slot
/// replaced. The callback either returns the replacement payload (`map` shape)
/// or the complete replacement enum (`flatMap` shape). No nominal, case, or
/// member spelling participates in the classification.
func caseTransformOperations(
    in file: SourceFileSyntax?
) -> [CaseTransformOperation] {
    guard let file else { return [] }

    struct EnumShape {
        let name: String
        let genericParameters: [String]
        let caseByGenericParameter: [String: String]
    }

    func canonical(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Swift.", with: "")
            .filter { !$0.isWhitespace }
    }

    func nominalName(_ raw: String) -> String {
        let value = canonical(raw)
        let head = value.firstIndex(of: "<").map {
            String(value[..<$0])
        } ?? value
        return head.split(separator: ".").last.map(String.init) ?? head
    }

    func splitTopLevel(_ raw: Substring) -> [String] {
        var result: [String] = []
        var start = raw.startIndex
        var angleDepth = 0
        var parenDepth = 0
        var bracketDepth = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            switch raw[index] {
            case "<": angleDepth += 1
            case ">": angleDepth -= 1
            case "(": parenDepth += 1
            case ")": parenDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            case "," where angleDepth == 0 && parenDepth == 0
                    && bracketDepth == 0:
                result.append(String(raw[start..<index]))
                start = raw.index(after: index)
            default:
                break
            }
            index = raw.index(after: index)
        }
        result.append(String(raw[start..<raw.endIndex]))
        return result
    }

    func genericApplication(
        _ raw: String
    ) -> (nominal: String, arguments: [String])? {
        let value = canonical(raw)
        guard let opening = value.firstIndex(of: "<"),
              value.last == ">" else { return nil }
        let argumentsStart = value.index(after: opening)
        let argumentsEnd = value.index(before: value.endIndex)
        return (
            nominalName(String(value[..<opening])),
            splitTopLevel(value[argumentsStart..<argumentsEnd]).map(canonical)
        )
    }

    var enumShapes: [String: EnumShape] = [:]
    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let enumeration = declaration.as(EnumDeclSyntax.self),
              enumeration.modifiers.contains(where: {
                  $0.name.text == "public"
              }),
              let genericClause = enumeration.genericParameterClause else {
            continue
        }
        let genericParameters = genericClause.parameters.map {
            canonical($0.name.text)
        }
        guard !genericParameters.isEmpty else { continue }

        var caseByGenericParameter: [String: String] = [:]
        for member in enumeration.memberBlock.members {
            guard let caseDeclaration = member.decl.as(
                EnumCaseDeclSyntax.self
            ) else { continue }
            for element in caseDeclaration.elements {
                guard let parameters = element.parameterClause?.parameters,
                      parameters.count == 1,
                      let parameter = parameters.first else { continue }
                let payloadType = canonical(
                    parameter.type.trimmedDescription)
                guard genericParameters.contains(payloadType),
                      caseByGenericParameter[payloadType] == nil else {
                    continue
                }
                caseByGenericParameter[payloadType] =
                    element.name.text.trimmingCharacters(
                        in: CharacterSet(charactersIn: "`"))
            }
        }
        guard caseByGenericParameter.count == genericParameters.count else {
            continue
        }
        let name = nominalName(enumeration.name.text)
        enumShapes[name] = EnumShape(
            name: name,
            genericParameters: genericParameters,
            caseByGenericParameter: caseByGenericParameter)
    }

    var operations = Set<CaseTransformOperation>()

    func functions(
        in members: MemberBlockItemListSyntax
    ) -> [FunctionDeclSyntax] {
        var declarations: [FunctionDeclSyntax] = []
        for member in members {
            if let function = member.decl.as(FunctionDeclSyntax.self) {
                declarations.append(function)
                continue
            }
            guard let conditional = member.decl.as(
                IfConfigDeclSyntax.self
            ) else { continue }
            for clause in conditional.clauses {
                guard case .decls(let nestedMembers) = clause.elements else {
                    continue
                }
                declarations.append(contentsOf: functions(in: nestedMembers))
            }
        }
        return declarations
    }

    for item in file.statements {
        guard case .decl(let declaration) = item.item,
              let extensionDeclaration = declaration.as(
                ExtensionDeclSyntax.self
              ) else { continue }
        let extendedName = nominalName(
            extensionDeclaration.extendedType.trimmedDescription)
        guard let shape = enumShapes[extendedName] else { continue }

        for function in functions(
            in: extensionDeclaration.memberBlock.members
        ) {
            guard function.modifiers.contains(where: {
                      $0.name.text == "public"
                  }),
                  !function.modifiers.contains(where: {
                      $0.name.text == "static" || $0.name.text == "class"
                  }),
                  function.signature.parameterClause.parameters.count == 1,
                  let parameter =
                    function.signature.parameterClause.parameters.first,
                  let callback = parameter.type.as(FunctionTypeSyntax.self),
                  callback.parameters.count == 1,
                  let callbackParameter = callback.parameters.first,
                  let returnType =
                    function.signature.returnClause?.type,
                  let returnedApplication = genericApplication(
                    returnType.trimmedDescription),
                  returnedApplication.nominal == shape.name,
                  returnedApplication.arguments.count
                    == shape.genericParameters.count else {
                continue
            }

            let callbackInput = canonical(
                callbackParameter.type.trimmedDescription)
            guard let selectedIndex = shape.genericParameters.firstIndex(
                of: callbackInput),
                  let selectedCaseName =
                    shape.caseByGenericParameter[callbackInput] else {
                continue
            }

            let changedIndices = shape.genericParameters.indices.filter {
                shape.genericParameters[$0]
                    != returnedApplication.arguments[$0]
            }
            guard changedIndices == [selectedIndex] else { continue }

            let callbackResult = canonical(
                callback.returnClause.type.trimmedDescription)
            let application: CaseTransformApplication
            if callbackResult
                == returnedApplication.arguments[selectedIndex] {
                application = .payload
            } else if let callbackApplication = genericApplication(
                callbackResult),
                callbackApplication.nominal == returnedApplication.nominal,
                callbackApplication.arguments
                    == returnedApplication.arguments {
                application = .carrier
            } else {
                continue
            }

            operations.insert(CaseTransformOperation(
                nominalName: shape.name,
                memberName: function.name.text,
                selectedCaseName: selectedCaseName,
                argumentLabel: parameter.firstName.text == "_"
                    ? nil : parameter.firstName.text,
                application: application))
        }
    }

    return operations.sorted {
        ($0.nominalName, $0.memberName, $0.selectedCaseName,
         $0.application.rawValue)
            < ($1.nominalName, $1.memberName, $1.selectedCaseName,
               $1.application.rawValue)
    }
}
