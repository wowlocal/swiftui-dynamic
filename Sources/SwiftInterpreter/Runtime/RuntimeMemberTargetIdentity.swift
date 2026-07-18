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
}
