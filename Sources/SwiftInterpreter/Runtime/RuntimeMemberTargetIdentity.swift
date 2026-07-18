import SwiftSyntax

/// Stable identities for standard-library properties that a physical source
/// kernel may execute. A source spelling is never sufficient proof: the
/// originating program may declare a same-module extension that shadows the
/// imported member.
nonisolated enum RuntimeStandardLibraryPropertyIdentity: Sendable, Equatable {
    case stringCount

    fileprivate var sourceTypeName: String {
        switch self {
        case .stringCount: "String"
        }
    }

    fileprivate var sourceMemberName: String {
        switch self {
        case .stringCount: "count"
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

    fileprivate var sourceTypeName: String {
        switch self {
        case .stringDistanceFromTo: "String"
        case .arrayMap: "Array"
        }
    }

    fileprivate var sourceMemberName: String {
        switch self {
        case .stringDistanceFromTo: "distance"
        case .arrayMap: "map"
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
