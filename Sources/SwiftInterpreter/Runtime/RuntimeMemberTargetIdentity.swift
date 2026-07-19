import Foundation
import SwiftSyntax

/// Source type spelling retained at an evaluator storage edge. RuntimeValue
/// intentionally erases String versus Substring, so consumers that resolve a
/// context-inferred key path must use this static fact instead of guessing
/// from the payload shape.
nonisolated enum RuntimeDeclaredType {
    static func arrayElementTypeName(
        in declaredTypeName: String?
    ) -> String? {
        guard let declaredTypeName else { return nil }
        let text = declaredTypeName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if text.hasPrefix("["), text.hasSuffix("]"),
           !text.contains(":") {
            return String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["Array<", "Swift.Array<"]
        where text.hasPrefix(prefix) && text.hasSuffix(">") {
            return String(text.dropFirst(prefix.count).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Element type retained by a runtime array payload. Besides the literal
    /// `Array` spellings admitted by physical-worker checks, interpreted
    /// collection operations can materialize other nominal collection shells
    /// into the same payload. BridgeGen proves which one-argument nominals use
    /// that argument as `Collection.Element` from the active swiftinterface.
    static func arrayPayloadElementTypeName(
        in declaredTypeName: String?
    ) -> String? {
        if let element = arrayElementTypeName(in: declaredTypeName) {
            return element
        }
        guard let declaredTypeName,
              let application = singleGenericApplication(declaredTypeName),
              let nominalName = nominalTypeName(application.nominal),
              GeneratedCollectionDefaultSurface.usesElementGenericParameter(
                nominalName: nominalName)
        else { return nil }
        return application.argument
    }

    private static func singleGenericApplication(
        _ rawTypeName: String
    ) -> (nominal: String, argument: String)? {
        let text = rawTypeName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let opening = text.firstIndex(of: "<"),
              text.last == ">"
        else { return nil }

        let nominal = String(text[..<opening]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let argumentStart = text.index(after: opening)
        let argumentEnd = text.index(before: text.endIndex)
        let argumentText = String(text[argumentStart..<argumentEnd])
        var angleDepth = 0
        var squareDepth = 0
        var parenthesisDepth = 0
        for character in argumentText {
            switch character {
            case "<": angleDepth += 1
            case ">":
                guard angleDepth > 0 else { return nil }
                angleDepth -= 1
            case "[": squareDepth += 1
            case "]":
                guard squareDepth > 0 else { return nil }
                squareDepth -= 1
            case "(": parenthesisDepth += 1
            case ")":
                guard parenthesisDepth > 0 else { return nil }
                parenthesisDepth -= 1
            case "," where angleDepth == 0 && squareDepth == 0
                && parenthesisDepth == 0:
                return nil
            default: break
            }
        }
        guard !nominal.isEmpty,
              angleDepth == 0,
              squareDepth == 0,
              parenthesisDepth == 0
        else { return nil }
        let argument = argumentText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return argument.isEmpty ? nil : (nominal, argument)
    }

    static func nominalTypeName(_ typeName: String?) -> String? {
        guard let typeName else { return nil }
        var text = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("?") || text.hasSuffix("!") {
            text = String(text.dropLast()).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        while text.hasPrefix("Optional<"), text.hasSuffix(">") {
            text = String(text.dropFirst("Optional<".count).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            return text.contains(":") ? "Dictionary" : "Array"
        }
        if let generic = text.firstIndex(of: "<") {
            text = String(text[..<generic])
        }
        return text.split(separator: ".").last.map(String.init)
    }
}

/// Stable identities for standard-library properties that a physical source
/// kernel may execute. A source spelling is never sufficient proof: the
/// originating program may declare a same-module extension that shadows the
/// imported member.
nonisolated enum RuntimeStandardLibraryPropertyIdentity: Sendable, Equatable {
    case stringCount
    case substringCount

    fileprivate var sourceTypeName: String {
        switch self {
        case .stringCount: "String"
        case .substringCount: "Substring"
        }
    }

    fileprivate var sourceMemberName: String {
        switch self {
        case .stringCount, .substringCount: "count"
        }
    }
}

/// The declaration identity selected for a property in one resolved source
/// program. Source declarations stay MainActor-confined; only this immutable
/// identity is compared while deciding whether worker lowering is legal.
nonisolated enum RuntimePropertyTargetIdentity: Sendable, Equatable {
    case standardLibrary(RuntimeStandardLibraryPropertyIdentity)
    case sourceExtension(declarationID: SyntaxIdentifier?)
}

/// Stable identities for standard-library methods that a physical source
/// kernel may execute. Until session-owned overload resolution can publish an
/// exact declaration, every same-base source overload makes admission fail
/// closed; labels alone are not a declaration identity because defaults,
/// generics, and parameter types also participate.
nonisolated enum RuntimeStandardLibraryMethodIdentity: Sendable, Equatable {
    case stringDistanceFromTo
    case arrayMap
    case arrayReduce

    fileprivate var sourceTypeName: String {
        switch self {
        case .stringDistanceFromTo: "String"
        case .arrayMap, .arrayReduce: "Array"
        }
    }

    fileprivate var sourceMemberName: String {
        switch self {
        case .stringDistanceFromTo: "distance"
        case .arrayMap: "map"
        case .arrayReduce: "reduce"
        }
    }
}

nonisolated enum RuntimeMethodTargetProof: Sendable, Equatable {
    case standardLibrary(RuntimeStandardLibraryMethodIdentity)
    case unresolvedSourceExtensionOverloads(
        declarationIDs: [SyntaxIdentifier])
}

extension RuntimeProgramState {
    func propertyTargetIdentity(
        for standardLibraryProperty: RuntimeStandardLibraryPropertyIdentity
    ) -> RuntimePropertyTargetIdentity {
        let typeName = standardLibraryProperty.sourceTypeName
        let memberName = standardLibraryProperty.sourceMemberName
        if let sourceProperty = visibleHostExtensionSymbols[typeName]?
            .computedProperties[memberName] {
            return .sourceExtension(
                declarationID: sourceProperty.declarationID)
        }
        return .standardLibrary(standardLibraryProperty)
    }

    func methodTargetProof(
        for standardLibraryMethod: RuntimeStandardLibraryMethodIdentity
    ) -> RuntimeMethodTargetProof {
        let typeName = standardLibraryMethod.sourceTypeName
        let memberName = standardLibraryMethod.sourceMemberName
        if let sourceMethods = visibleHostExtensionSymbols[typeName]?
            .methods[memberName],
           !sourceMethods.isEmpty {
            return .unresolvedSourceExtensionOverloads(
                declarationIDs: sourceMethods.map(\.id))
        }
        return .standardLibrary(standardLibraryMethod)
    }
}
