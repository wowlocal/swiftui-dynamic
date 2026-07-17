import SwiftSyntax

/// Immutable deinitializer headers discovered once from a folded program.
///
/// Every conditional-compilation branch is indexed. Runtime sessions still
/// select active nominals, resolve actor aliases, and attach the resulting
/// teardown policy to their own mutable symbol graph.
public nonisolated struct ParsedDeinitializerMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let deinitializerCount: Int
        public let attributedDeinitializerCount: Int
        public let modifiedDeinitializerCount: Int
        public let isolatedModifierCount: Int
        public let nonisolatedModifierCount: Int
        public let bodyStatementCount: Int

        public init(
            deinitializerCount: Int,
            attributedDeinitializerCount: Int,
            modifiedDeinitializerCount: Int,
            isolatedModifierCount: Int,
            nonisolatedModifierCount: Int,
            bodyStatementCount: Int
        ) {
            self.deinitializerCount = deinitializerCount
            self.attributedDeinitializerCount = attributedDeinitializerCount
            self.modifiedDeinitializerCount = modifiedDeinitializerCount
            self.isolatedModifierCount = isolatedModifierCount
            self.nonisolatedModifierCount = nonisolatedModifierCount
            self.bodyStatementCount = bodyStatementCount
        }
    }

    fileprivate let deinitializers:
        [SyntaxIdentifier: ParsedDeinitializerMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedDeinitializerMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        deinitializers = collector.deinitializers
        let values = Array(deinitializers.values)
        summary = Summary(
            deinitializerCount: values.count,
            attributedDeinitializerCount: values.count {
                !$0.attributeTypeNames.isEmpty
            },
            modifiedDeinitializerCount: values.count {
                !$0.modifierNames.isEmpty
            },
            isolatedModifierCount: values.count(where: \.hasIsolatedModifier),
            nonisolatedModifierCount: values.count(
                where: \.hasNonisolatedModifier),
            bodyStatementCount: values.reduce(0) {
                $0 + ($1.body?.statements.count ?? 0)
            })
    }

    func metadata(
        for declaration: DeinitializerDeclSyntax
    ) -> ParsedDeinitializerMetadata? {
        deinitializers[Syntax(declaration).id]
    }
}

nonisolated struct ParsedDeinitializerMetadata: Sendable {
    let body: CodeBlockSyntax?
    let attributeTypeNames: [String]
    let modifierNames: [String]

    var hasIsolatedModifier: Bool {
        modifierNames.contains("isolated")
    }

    var hasNonisolatedModifier: Bool {
        modifierNames.contains("nonisolated")
    }

    var requiresIsolationResolution: Bool {
        hasIsolatedModifier || !attributeTypeNames.isEmpty
    }

    init(_ declaration: DeinitializerDeclSyntax) {
        body = declaration.body
        attributeTypeNames = declaration.attributes.compactMap {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
        }
        modifierNames = declaration.modifiers.map { $0.name.text }
    }
}

private nonisolated final class ParsedDeinitializerMetadataCollector:
    SyntaxVisitor
{
    var deinitializers: [SyntaxIdentifier: ParsedDeinitializerMetadata] = [:]

    override func visit(
        _ node: DeinitializerDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        deinitializers[Syntax(node).id] = ParsedDeinitializerMetadata(node)
        return .visitChildren
    }
}
