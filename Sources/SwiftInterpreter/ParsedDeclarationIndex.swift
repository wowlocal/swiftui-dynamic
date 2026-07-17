import SwiftSyntax

/// Immutable, target-neutral discovery of declarations in a parsed source
/// file. All conditional-compilation alternatives are indexed once; a
/// session resolves exactly one active plan using its build identity.
public nonisolated struct ParsedDeclarationIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let possiblePrimaryDeclarationCount: Int
        public let possibleTypeAliasCount: Int
        public let possibleExtensionCount: Int
        public let conditionalRegionCount: Int

        public init(
            possiblePrimaryDeclarationCount: Int,
            possibleTypeAliasCount: Int,
            possibleExtensionCount: Int,
            conditionalRegionCount: Int
        ) {
            self.possiblePrimaryDeclarationCount =
                possiblePrimaryDeclarationCount
            self.possibleTypeAliasCount = possibleTypeAliasCount
            self.possibleExtensionCount = possibleExtensionCount
            self.conditionalRegionCount = conditionalRegionCount
        }

        fileprivate static let empty = Summary(
            possiblePrimaryDeclarationCount: 0,
            possibleTypeAliasCount: 0,
            possibleExtensionCount: 0,
            conditionalRegionCount: 0)

        fileprivate func adding(_ other: Summary) -> Summary {
            Summary(
                possiblePrimaryDeclarationCount:
                    possiblePrimaryDeclarationCount
                        + other.possiblePrimaryDeclarationCount,
                possibleTypeAliasCount:
                    possibleTypeAliasCount + other.possibleTypeAliasCount,
                possibleExtensionCount:
                    possibleExtensionCount + other.possibleExtensionCount,
                conditionalRegionCount:
                    conditionalRegionCount + other.conditionalRegionCount)
        }
    }

    fileprivate nonisolated struct ConditionalClause: Sendable {
        let condition: ExprSyntax?
        let entries: [Entry]
    }

    fileprivate nonisolated enum Entry: Sendable {
        case primary(CodeBlockItemSyntax, ParsedPrimaryDeclaration)
        case typeAlias(CodeBlockItemSyntax, TypeAliasDeclSyntax)
        case extensionDeclaration(CodeBlockItemSyntax, ExtensionDeclSyntax)
        case ordinary(CodeBlockItemSyntax)
        case conditional([ConditionalClause])
    }

    fileprivate let entries: [Entry]
    public let summary: Summary

    init(statements: CodeBlockItemListSyntax) {
        let indexed = Self.index(statements)
        entries = indexed.entries
        summary = indexed.summary
    }

    private static func index(
        _ statements: CodeBlockItemListSyntax
    ) -> (entries: [Entry], summary: Summary) {
        var entries: [Entry] = []
        var summary = Summary.empty

        for item in statements {
            guard case .decl(let declaration) = item.item else {
                entries.append(.ordinary(item))
                continue
            }
            if let conditional = declaration.as(IfConfigDeclSyntax.self) {
                var clauses: [ConditionalClause] = []
                var nestedSummary = Summary.empty
                for clause in conditional.clauses {
                    let nested: (entries: [Entry], summary: Summary)
                    if case .statements(let statements)? = clause.elements {
                        nested = index(statements)
                    } else {
                        nested = ([], .empty)
                    }
                    clauses.append(ConditionalClause(
                        condition: clause.condition,
                        entries: nested.entries))
                    nestedSummary = nestedSummary.adding(nested.summary)
                }
                entries.append(.conditional(clauses))
                summary = summary.adding(nestedSummary).adding(Summary(
                    possiblePrimaryDeclarationCount: 0,
                    possibleTypeAliasCount: 0,
                    possibleExtensionCount: 0,
                    conditionalRegionCount: 1))
                continue
            }
            if let primary = ParsedPrimaryDeclaration(declaration) {
                entries.append(.primary(item, primary))
                summary = summary.adding(Summary(
                    possiblePrimaryDeclarationCount: 1,
                    possibleTypeAliasCount: 0,
                    possibleExtensionCount: 0,
                    conditionalRegionCount: 0))
            } else if let alias = declaration.as(TypeAliasDeclSyntax.self) {
                entries.append(.typeAlias(item, alias))
                summary = summary.adding(Summary(
                    possiblePrimaryDeclarationCount: 0,
                    possibleTypeAliasCount: 1,
                    possibleExtensionCount: 0,
                    conditionalRegionCount: 0))
            } else if let extensionDeclaration =
                        declaration.as(ExtensionDeclSyntax.self) {
                entries.append(.extensionDeclaration(
                    item, extensionDeclaration))
                summary = summary.adding(Summary(
                    possiblePrimaryDeclarationCount: 0,
                    possibleTypeAliasCount: 0,
                    possibleExtensionCount: 1,
                    conditionalRegionCount: 0))
            } else {
                entries.append(.ordinary(item))
            }
        }
        return (entries, summary)
    }

    nonisolated func resolve(
        conditionHolds: (ExprSyntax?) -> Bool
    ) -> ResolvedDeclarationPlan {
        var builder = ResolutionBuilder()
        append(entries, conditionHolds: conditionHolds, to: &builder)
        return builder.build()
    }

    private nonisolated func append(
        _ entries: [Entry],
        conditionHolds: (ExprSyntax?) -> Bool,
        to builder: inout ResolutionBuilder
    ) {
        for entry in entries {
            switch entry {
            case .primary(let item, let declaration):
                builder.topLevelItems.append(item)
                builder.primaryDeclarations.append(declaration)
            case .typeAlias(let item, let declaration):
                builder.topLevelItems.append(item)
                builder.typeAliases.append(declaration)
            case .extensionDeclaration(let item, let declaration):
                builder.topLevelItems.append(item)
                builder.extensionDeclarations.append(declaration)
            case .ordinary(let item):
                builder.topLevelItems.append(item)
            case .conditional(let clauses):
                guard let active = clauses.first(where: {
                    conditionHolds($0.condition)
                }) else { continue }
                append(
                    active.entries,
                    conditionHolds: conditionHolds,
                    to: &builder)
            }
        }
    }
}

private nonisolated struct ResolutionBuilder {
    var topLevelItems: [CodeBlockItemSyntax] = []
    var primaryDeclarations: [ParsedPrimaryDeclaration] = []
    var typeAliases: [TypeAliasDeclSyntax] = []
    var extensionDeclarations: [ExtensionDeclSyntax] = []

    nonisolated func build() -> ResolvedDeclarationPlan {
        ResolvedDeclarationPlan(
            topLevelItems: topLevelItems,
            primaryDeclarations: primaryDeclarations,
            typeAliases: typeAliases,
            extensionDeclarations: extensionDeclarations)
    }
}

nonisolated enum ParsedPrimaryDeclaration: Sendable {
    case structure(StructDeclSyntax)
    case classType(ClassDeclSyntax)
    case actor(ActorDeclSyntax)
    case enumeration(EnumDeclSyntax)
    case protocolType(ProtocolDeclSyntax)
    case function(FunctionDeclSyntax)
    case variable(VariableDeclSyntax)

    init?(_ declaration: DeclSyntax) {
        if let value = declaration.as(StructDeclSyntax.self) {
            self = .structure(value)
        } else if let value = declaration.as(ClassDeclSyntax.self) {
            self = .classType(value)
        } else if let value = declaration.as(ActorDeclSyntax.self) {
            self = .actor(value)
        } else if let value = declaration.as(EnumDeclSyntax.self) {
            self = .enumeration(value)
        } else if let value = declaration.as(ProtocolDeclSyntax.self) {
            self = .protocolType(value)
        } else if let value = declaration.as(FunctionDeclSyntax.self) {
            self = .function(value)
        } else if let value = declaration.as(VariableDeclSyntax.self) {
            self = .variable(value)
        } else {
            return nil
        }
    }
}

nonisolated struct ResolvedDeclarationPlan: Sendable {
    let topLevelItems: [CodeBlockItemSyntax]
    let primaryDeclarations: [ParsedPrimaryDeclaration]
    let typeAliases: [TypeAliasDeclSyntax]
    let extensionDeclarations: [ExtensionDeclSyntax]
}
