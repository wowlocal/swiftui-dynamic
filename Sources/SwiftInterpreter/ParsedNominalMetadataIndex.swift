import SwiftSyntax

/// Immutable nominal-declaration headers discovered once from a folded
/// program. All conditional-compilation branches, nested types, and local
/// types are indexed; a runtime session only materializes the declarations in
/// its resolved build plan.
public nonisolated struct ParsedNominalMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let structureCount: Int
        public let classCount: Int
        public let actorCount: Int
        public let enumerationCount: Int
        public let protocolCount: Int
        public let attributedNominalCount: Int
        public let genericNominalCount: Int
        public let inheritedTypeCount: Int

        public init(
            structureCount: Int,
            classCount: Int,
            actorCount: Int,
            enumerationCount: Int,
            protocolCount: Int,
            attributedNominalCount: Int,
            genericNominalCount: Int,
            inheritedTypeCount: Int
        ) {
            self.structureCount = structureCount
            self.classCount = classCount
            self.actorCount = actorCount
            self.enumerationCount = enumerationCount
            self.protocolCount = protocolCount
            self.attributedNominalCount = attributedNominalCount
            self.genericNominalCount = genericNominalCount
            self.inheritedTypeCount = inheritedTypeCount
        }
    }

    fileprivate let nominals: [SyntaxIdentifier: ParsedNominalMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedNominalMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        nominals = collector.nominals
        let values = Array(nominals.values)
        summary = Summary(
            structureCount: values.count { $0.kind == .structure },
            classCount: values.count { $0.kind == .classType },
            actorCount: values.count { $0.kind == .actor },
            enumerationCount: values.count { $0.kind == .enumeration },
            protocolCount: values.count { $0.kind == .protocolType },
            attributedNominalCount: values.count {
                !$0.attributeNames.isEmpty
            },
            genericNominalCount: values.count {
                !$0.genericParameters.isEmpty
            },
            inheritedTypeCount: values.reduce(0) {
                $0 + $1.inheritedTypeNames.count
            })
    }

    func metadata(
        for declaration: StructDeclSyntax
    ) -> ParsedNominalMetadata? {
        nominals[Syntax(declaration).id]
    }

    func metadata(
        for declaration: ClassDeclSyntax
    ) -> ParsedNominalMetadata? {
        nominals[Syntax(declaration).id]
    }

    func metadata(
        for declaration: ActorDeclSyntax
    ) -> ParsedNominalMetadata? {
        nominals[Syntax(declaration).id]
    }

    func metadata(
        for declaration: EnumDeclSyntax
    ) -> ParsedNominalMetadata? {
        nominals[Syntax(declaration).id]
    }

    func metadata(
        for declaration: ProtocolDeclSyntax
    ) -> ParsedNominalMetadata? {
        nominals[Syntax(declaration).id]
    }
}

nonisolated struct ParsedNominalMetadata: Sendable {
    nonisolated enum Kind: Sendable, Equatable {
        case structure
        case classType
        case actor
        case enumeration
        case protocolType
    }

    nonisolated struct GenericParameter: Sendable, Equatable {
        let name: String
        let inheritedTypeName: String?
    }

    let kind: Kind
    let name: String
    let inheritedTypeNames: [String]
    let attributeNames: [String]
    let genericParameters: [GenericParameter]

    init(_ declaration: StructDeclSyntax) {
        self.init(
            kind: .structure,
            name: declaration.name.text,
            inheritanceClause: declaration.inheritanceClause,
            attributes: declaration.attributes,
            genericParameterClause: declaration.genericParameterClause)
    }

    init(_ declaration: ClassDeclSyntax) {
        self.init(
            kind: .classType,
            name: declaration.name.text,
            inheritanceClause: declaration.inheritanceClause,
            attributes: declaration.attributes,
            genericParameterClause: declaration.genericParameterClause)
    }

    init(_ declaration: ActorDeclSyntax) {
        self.init(
            kind: .actor,
            name: declaration.name.text,
            inheritanceClause: declaration.inheritanceClause,
            attributes: declaration.attributes,
            genericParameterClause: declaration.genericParameterClause)
    }

    init(_ declaration: EnumDeclSyntax) {
        self.init(
            kind: .enumeration,
            name: declaration.name.text,
            inheritanceClause: declaration.inheritanceClause,
            attributes: declaration.attributes,
            genericParameterClause: declaration.genericParameterClause)
    }

    init(_ declaration: ProtocolDeclSyntax) {
        self.init(
            kind: .protocolType,
            name: declaration.name.text,
            inheritanceClause: declaration.inheritanceClause,
            attributes: declaration.attributes,
            genericParameterClause: nil)
    }

    private init(
        kind: Kind,
        name: String,
        inheritanceClause: InheritanceClauseSyntax?,
        attributes: AttributeListSyntax,
        genericParameterClause: GenericParameterClauseSyntax?
    ) {
        self.kind = kind
        self.name = name
        inheritedTypeNames = inheritanceClause?.inheritedTypes.map {
            $0.type.trimmedDescription
        } ?? []
        attributeNames = attributes.compactMap {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
        }
        genericParameters = genericParameterClause?.parameters.map {
            GenericParameter(
                name: $0.name.text,
                inheritedTypeName: $0.inheritedType?.trimmedDescription)
        } ?? []
    }
}

private nonisolated final class ParsedNominalMetadataCollector: SyntaxVisitor {
    var nominals: [SyntaxIdentifier: ParsedNominalMetadata] = [:]

    override func visit(
        _ node: StructDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        nominals[Syntax(node).id] = ParsedNominalMetadata(node)
        return .visitChildren
    }

    override func visit(
        _ node: ClassDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        nominals[Syntax(node).id] = ParsedNominalMetadata(node)
        return .visitChildren
    }

    override func visit(
        _ node: ActorDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        nominals[Syntax(node).id] = ParsedNominalMetadata(node)
        return .visitChildren
    }

    override func visit(
        _ node: EnumDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        nominals[Syntax(node).id] = ParsedNominalMetadata(node)
        return .visitChildren
    }

    override func visit(
        _ node: ProtocolDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        nominals[Syntax(node).id] = ParsedNominalMetadata(node)
        return .visitChildren
    }
}
