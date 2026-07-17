import SwiftSyntax

/// Immutable, target-neutral classification of nominal and extension member
/// blocks. Every conditional-compilation alternative is indexed once; a
/// runtime session resolves one active declaration sequence using its build
/// identity before materializing mutable symbols.
public nonisolated struct ParsedMemberMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let memberBlockCount: Int
        public let possibleMemberDeclarationCount: Int
        public let conditionalRegionCount: Int
        public let conditionalClauseCount: Int
        public let variableCount: Int
        public let functionCount: Int
        public let initializerCount: Int
        public let deinitializerCount: Int
        public let subscriptCount: Int
        public let typeAliasCount: Int
        public let enumCaseDeclarationCount: Int
        public let nestedNominalCount: Int
        public let otherDeclarationCount: Int

        public init(
            memberBlockCount: Int,
            possibleMemberDeclarationCount: Int,
            conditionalRegionCount: Int,
            conditionalClauseCount: Int,
            variableCount: Int,
            functionCount: Int,
            initializerCount: Int,
            deinitializerCount: Int,
            subscriptCount: Int,
            typeAliasCount: Int,
            enumCaseDeclarationCount: Int,
            nestedNominalCount: Int,
            otherDeclarationCount: Int
        ) {
            self.memberBlockCount = memberBlockCount
            self.possibleMemberDeclarationCount =
                possibleMemberDeclarationCount
            self.conditionalRegionCount = conditionalRegionCount
            self.conditionalClauseCount = conditionalClauseCount
            self.variableCount = variableCount
            self.functionCount = functionCount
            self.initializerCount = initializerCount
            self.deinitializerCount = deinitializerCount
            self.subscriptCount = subscriptCount
            self.typeAliasCount = typeAliasCount
            self.enumCaseDeclarationCount = enumCaseDeclarationCount
            self.nestedNominalCount = nestedNominalCount
            self.otherDeclarationCount = otherDeclarationCount
        }

        fileprivate static let empty = Summary(
            memberBlockCount: 0,
            possibleMemberDeclarationCount: 0,
            conditionalRegionCount: 0,
            conditionalClauseCount: 0,
            variableCount: 0,
            functionCount: 0,
            initializerCount: 0,
            deinitializerCount: 0,
            subscriptCount: 0,
            typeAliasCount: 0,
            enumCaseDeclarationCount: 0,
            nestedNominalCount: 0,
            otherDeclarationCount: 0)

        fileprivate func adding(_ other: Summary) -> Summary {
            Summary(
                memberBlockCount: memberBlockCount + other.memberBlockCount,
                possibleMemberDeclarationCount:
                    possibleMemberDeclarationCount
                        + other.possibleMemberDeclarationCount,
                conditionalRegionCount:
                    conditionalRegionCount + other.conditionalRegionCount,
                conditionalClauseCount:
                    conditionalClauseCount + other.conditionalClauseCount,
                variableCount: variableCount + other.variableCount,
                functionCount: functionCount + other.functionCount,
                initializerCount: initializerCount + other.initializerCount,
                deinitializerCount:
                    deinitializerCount + other.deinitializerCount,
                subscriptCount: subscriptCount + other.subscriptCount,
                typeAliasCount: typeAliasCount + other.typeAliasCount,
                enumCaseDeclarationCount:
                    enumCaseDeclarationCount
                        + other.enumCaseDeclarationCount,
                nestedNominalCount:
                    nestedNominalCount + other.nestedNominalCount,
                otherDeclarationCount:
                    otherDeclarationCount + other.otherDeclarationCount)
        }
    }

    fileprivate let blocks: [SyntaxIdentifier: ParsedMemberBlockMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedMemberMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        blocks = collector.blocks
        summary = collector.summary
    }

    func metadata(
        for block: MemberBlockSyntax
    ) -> ParsedMemberBlockMetadata? {
        blocks[Syntax(block).id]
    }

    nonisolated func resolve(
        conditionHolds: (ExprSyntax?) -> Bool
    ) -> ResolvedMemberPlan {
        var resolved: [SyntaxIdentifier: [ParsedMemberDeclaration]] = [:]
        var resolvedMemberDeclarationCount = 0
        for (identifier, block) in blocks {
            let declarations = block.resolve(conditionHolds: conditionHolds)
            resolved[identifier] = declarations
            resolvedMemberDeclarationCount += declarations.count
        }
        return ResolvedMemberPlan(
            blocks: resolved,
            resolvedMemberDeclarationCount: resolvedMemberDeclarationCount)
    }
}

nonisolated struct ResolvedMemberPlan: Sendable {
    fileprivate let blocks: [
        SyntaxIdentifier: [ParsedMemberDeclaration]
    ]
    let resolvedMemberDeclarationCount: Int

    var memberBlockCount: Int { blocks.count }

    func declarations(
        in block: MemberBlockSyntax
    ) -> [ParsedMemberDeclaration]? {
        blocks[Syntax(block).id]
    }
}

nonisolated struct ParsedMemberBlockMetadata: Sendable {
    fileprivate nonisolated struct ConditionalClause: Sendable {
        let condition: ExprSyntax?
        let entries: [Entry]
    }

    fileprivate nonisolated enum Entry: Sendable {
        case declaration(ParsedMemberDeclaration)
        case conditional([ConditionalClause])
    }

    fileprivate let entries: [Entry]
    fileprivate let summary: ParsedMemberMetadataIndex.Summary

    init(_ block: MemberBlockSyntax) {
        let indexed = Self.index(block.members)
        entries = indexed.entries
        summary = indexed.summary.adding(.init(
            memberBlockCount: 1,
            possibleMemberDeclarationCount: 0,
            conditionalRegionCount: 0,
            conditionalClauseCount: 0,
            variableCount: 0,
            functionCount: 0,
            initializerCount: 0,
            deinitializerCount: 0,
            subscriptCount: 0,
            typeAliasCount: 0,
            enumCaseDeclarationCount: 0,
            nestedNominalCount: 0,
            otherDeclarationCount: 0))
    }

    nonisolated func resolve(
        conditionHolds: (ExprSyntax?) -> Bool
    ) -> [ParsedMemberDeclaration] {
        var declarations: [ParsedMemberDeclaration] = []
        Self.append(
            entries,
            conditionHolds: conditionHolds,
            to: &declarations)
        return declarations
    }

    private static func index(
        _ members: MemberBlockItemListSyntax
    ) -> (entries: [Entry], summary: ParsedMemberMetadataIndex.Summary) {
        var entries: [Entry] = []
        var summary = ParsedMemberMetadataIndex.Summary.empty
        for member in members {
            if let conditional = member.decl.as(IfConfigDeclSyntax.self) {
                var clauses: [ConditionalClause] = []
                var nestedSummary = ParsedMemberMetadataIndex.Summary.empty
                for clause in conditional.clauses {
                    let nested: (
                        entries: [Entry],
                        summary: ParsedMemberMetadataIndex.Summary
                    )
                    if case .decls(let declarations)? = clause.elements {
                        nested = index(declarations)
                    } else {
                        nested = ([], .empty)
                    }
                    clauses.append(ConditionalClause(
                        condition: clause.condition,
                        entries: nested.entries))
                    nestedSummary = nestedSummary.adding(nested.summary)
                }
                entries.append(.conditional(clauses))
                summary = summary.adding(nestedSummary).adding(.init(
                    memberBlockCount: 0,
                    possibleMemberDeclarationCount: 0,
                    conditionalRegionCount: 1,
                    conditionalClauseCount: conditional.clauses.count,
                    variableCount: 0,
                    functionCount: 0,
                    initializerCount: 0,
                    deinitializerCount: 0,
                    subscriptCount: 0,
                    typeAliasCount: 0,
                    enumCaseDeclarationCount: 0,
                    nestedNominalCount: 0,
                    otherDeclarationCount: 0))
                continue
            }

            let declaration = ParsedMemberDeclaration(member.decl)
            entries.append(.declaration(declaration))
            summary = summary.adding(declaration.summary)
        }
        return (entries, summary)
    }

    private nonisolated static func append(
        _ entries: [Entry],
        conditionHolds: (ExprSyntax?) -> Bool,
        to declarations: inout [ParsedMemberDeclaration]
    ) {
        for entry in entries {
            switch entry {
            case .declaration(let declaration):
                declarations.append(declaration)
            case .conditional(let clauses):
                guard let active = clauses.first(where: {
                    conditionHolds($0.condition)
                }) else { continue }
                append(
                    active.entries,
                    conditionHolds: conditionHolds,
                    to: &declarations)
            }
        }
    }
}

nonisolated enum ParsedMemberDeclaration: Sendable {
    nonisolated enum Kind: Sendable, Equatable {
        case variable
        case function
        case initializer
        case deinitializer
        case subscriptDeclaration
        case typeAlias
        case enumCase
        case structure
        case classType
        case actor
        case enumeration
        case protocolType
        case other
    }

    case variable(VariableDeclSyntax)
    case function(FunctionDeclSyntax)
    case initializer(InitializerDeclSyntax)
    case deinitializer(DeinitializerDeclSyntax)
    case subscriptDeclaration(SubscriptDeclSyntax)
    case typeAlias(TypeAliasDeclSyntax)
    case enumCase(EnumCaseDeclSyntax)
    case structure(StructDeclSyntax)
    case classType(ClassDeclSyntax)
    case actor(ActorDeclSyntax)
    case enumeration(EnumDeclSyntax)
    case protocolType(ProtocolDeclSyntax)
    case other(DeclSyntax)

    init(_ declaration: DeclSyntax) {
        if let value = declaration.as(VariableDeclSyntax.self) {
            self = .variable(value)
        } else if let value = declaration.as(FunctionDeclSyntax.self) {
            self = .function(value)
        } else if let value = declaration.as(InitializerDeclSyntax.self) {
            self = .initializer(value)
        } else if let value = declaration.as(DeinitializerDeclSyntax.self) {
            self = .deinitializer(value)
        } else if let value = declaration.as(SubscriptDeclSyntax.self) {
            self = .subscriptDeclaration(value)
        } else if let value = declaration.as(TypeAliasDeclSyntax.self) {
            self = .typeAlias(value)
        } else if let value = declaration.as(EnumCaseDeclSyntax.self) {
            self = .enumCase(value)
        } else if let value = declaration.as(StructDeclSyntax.self) {
            self = .structure(value)
        } else if let value = declaration.as(ClassDeclSyntax.self) {
            self = .classType(value)
        } else if let value = declaration.as(ActorDeclSyntax.self) {
            self = .actor(value)
        } else if let value = declaration.as(EnumDeclSyntax.self) {
            self = .enumeration(value)
        } else if let value = declaration.as(ProtocolDeclSyntax.self) {
            self = .protocolType(value)
        } else {
            self = .other(declaration)
        }
    }

    var kind: Kind {
        switch self {
        case .variable: .variable
        case .function: .function
        case .initializer: .initializer
        case .deinitializer: .deinitializer
        case .subscriptDeclaration: .subscriptDeclaration
        case .typeAlias: .typeAlias
        case .enumCase: .enumCase
        case .structure: .structure
        case .classType: .classType
        case .actor: .actor
        case .enumeration: .enumeration
        case .protocolType: .protocolType
        case .other: .other
        }
    }

    fileprivate var summary: ParsedMemberMetadataIndex.Summary {
        var variableCount = 0
        var functionCount = 0
        var initializerCount = 0
        var deinitializerCount = 0
        var subscriptCount = 0
        var typeAliasCount = 0
        var enumCaseDeclarationCount = 0
        var nestedNominalCount = 0
        var otherDeclarationCount = 0
        switch kind {
        case .variable: variableCount = 1
        case .function: functionCount = 1
        case .initializer: initializerCount = 1
        case .deinitializer: deinitializerCount = 1
        case .subscriptDeclaration: subscriptCount = 1
        case .typeAlias: typeAliasCount = 1
        case .enumCase: enumCaseDeclarationCount = 1
        case .structure, .classType, .actor, .enumeration, .protocolType:
            nestedNominalCount = 1
        case .other: otherDeclarationCount = 1
        }
        return .init(
            memberBlockCount: 0,
            possibleMemberDeclarationCount: 1,
            conditionalRegionCount: 0,
            conditionalClauseCount: 0,
            variableCount: variableCount,
            functionCount: functionCount,
            initializerCount: initializerCount,
            deinitializerCount: deinitializerCount,
            subscriptCount: subscriptCount,
            typeAliasCount: typeAliasCount,
            enumCaseDeclarationCount: enumCaseDeclarationCount,
            nestedNominalCount: nestedNominalCount,
            otherDeclarationCount: otherDeclarationCount)
    }
}

private nonisolated final class ParsedMemberMetadataCollector: SyntaxVisitor {
    var blocks: [SyntaxIdentifier: ParsedMemberBlockMetadata] = [:]
    var summary = ParsedMemberMetadataIndex.Summary.empty

    override func visit(
        _ node: MemberBlockSyntax
    ) -> SyntaxVisitorContinueKind {
        let metadata = ParsedMemberBlockMetadata(node)
        blocks[Syntax(node).id] = metadata
        summary = summary.adding(metadata.summary)
        return .visitChildren
    }
}
