import SwiftSyntax

/// Immutable extension headers discovered once from a folded program.
///
/// All conditional-compilation branches are indexed. Runtime sessions still
/// choose the active declarations, resolve the extended symbol, and enforce
/// any supported generic-constraint behavior.
public nonisolated struct ParsedExtensionMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let extensionCount: Int
        public let dottedExtendedTypeCount: Int
        public let inheritedTypeCount: Int
        public let constrainedExtensionCount: Int
        public let genericRequirementCount: Int
        public let attributedExtensionCount: Int
        public let modifiedExtensionCount: Int

        public init(
            extensionCount: Int,
            dottedExtendedTypeCount: Int,
            inheritedTypeCount: Int,
            constrainedExtensionCount: Int,
            genericRequirementCount: Int,
            attributedExtensionCount: Int,
            modifiedExtensionCount: Int
        ) {
            self.extensionCount = extensionCount
            self.dottedExtendedTypeCount = dottedExtendedTypeCount
            self.inheritedTypeCount = inheritedTypeCount
            self.constrainedExtensionCount = constrainedExtensionCount
            self.genericRequirementCount = genericRequirementCount
            self.attributedExtensionCount = attributedExtensionCount
            self.modifiedExtensionCount = modifiedExtensionCount
        }
    }

    fileprivate let extensions: [SyntaxIdentifier: ParsedExtensionMetadata]
    fileprivate let containingExtensionsByFunction:
        [SyntaxIdentifier: ParsedExtensionMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedExtensionMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        extensions = collector.extensions
        containingExtensionsByFunction =
            collector.containingExtensionsByFunction
        let values = Array(extensions.values)
        summary = Summary(
            extensionCount: values.count,
            dottedExtendedTypeCount: values.count {
                $0.extendedTypeName.contains(".")
            },
            inheritedTypeCount: values.reduce(0) {
                $0 + $1.inheritedTypeNames.count
            },
            constrainedExtensionCount: values.count {
                !$0.genericRequirements.isEmpty
            },
            genericRequirementCount: values.reduce(0) {
                $0 + $1.genericRequirements.count
            },
            attributedExtensionCount: values.count {
                !$0.attributeNames.isEmpty
            },
            modifiedExtensionCount: values.count {
                !$0.modifierNames.isEmpty
            })
    }

    func metadata(
        for declaration: ExtensionDeclSyntax
    ) -> ParsedExtensionMetadata? {
        extensions[Syntax(declaration).id]
    }

    func metadata(
        containing declaration: FunctionDeclSyntax
    ) -> ParsedExtensionMetadata? {
        containingExtensionsByFunction[Syntax(declaration).id]
    }
}

nonisolated struct ParsedExtensionMetadata: Sendable {
    let extendedTypeName: String
    let inheritedTypeNames: [String]
    let genericRequirements: [String]
    /// The concrete side of the extension's only generic requirement when
    /// that requirement is structurally `Self == Concrete` (in either
    /// order). Runtime contextual-member lookup can use this compiler-facing
    /// fact without matching an API or reparsing description text.
    let soleSelfSameTypeConcreteTypeName: String?
    let attributeNames: [String]
    let modifierNames: [String]

    init(_ declaration: ExtensionDeclSyntax) {
        extendedTypeName = declaration.extendedType.trimmedDescription
        inheritedTypeNames = declaration.inheritanceClause?.inheritedTypes
            .map { $0.type.trimmedDescription } ?? []
        let requirements = declaration.genericWhereClause?.requirements
        genericRequirements = requirements?.map { requirement in
                switch requirement.requirement {
                case .sameTypeRequirement(let value):
                    value.trimmedDescription
                case .conformanceRequirement(let value):
                    value.trimmedDescription
                case .layoutRequirement(let value):
                    value.trimmedDescription
                }
            } ?? []
        if requirements?.count == 1,
           let requirement = requirements?.first,
           case .sameTypeRequirement(let sameType) = requirement.requirement {
            let left = sameType.leftType.trimmedDescription
            let right = sameType.rightType.trimmedDescription
            if left == "Self", right != "Self" {
                soleSelfSameTypeConcreteTypeName = right
            } else if right == "Self", left != "Self" {
                soleSelfSameTypeConcreteTypeName = left
            } else {
                soleSelfSameTypeConcreteTypeName = nil
            }
        } else {
            soleSelfSameTypeConcreteTypeName = nil
        }
        attributeNames = declaration.attributes.compactMap {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
        }
        modifierNames = declaration.modifiers.map { $0.name.text }
    }
}

private nonisolated final class ParsedExtensionMetadataCollector:
    SyntaxVisitor
{
    var extensions: [SyntaxIdentifier: ParsedExtensionMetadata] = [:]
    var containingExtensionsByFunction:
        [SyntaxIdentifier: ParsedExtensionMetadata] = [:]

    override func visit(
        _ node: ExtensionDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        let metadata = ParsedExtensionMetadata(node)
        extensions[Syntax(node).id] = metadata
        for member in node.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else {
                continue
            }
            containingExtensionsByFunction[Syntax(function).id] = metadata
        }
        return .visitChildren
    }
}
