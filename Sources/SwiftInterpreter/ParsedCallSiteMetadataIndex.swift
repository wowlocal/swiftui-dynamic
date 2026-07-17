import SwiftSyntax

/// Immutable syntax-derived argument structure for every function call in a
/// folded program. Runtime evaluation still resolves values and overloads in
/// its session; this index only owns stable source facts such as labels,
/// trailing-closure placement, and bare unqualified reference spelling.
public nonisolated struct ParsedCallSiteMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let callCount: Int
        public let ordinaryArgumentCount: Int
        public let trailingClosureCount: Int
        public let additionalTrailingClosureCount: Int
        public let directReferenceArgumentCount: Int

        public init(
            callCount: Int,
            ordinaryArgumentCount: Int,
            trailingClosureCount: Int,
            additionalTrailingClosureCount: Int,
            directReferenceArgumentCount: Int
        ) {
            self.callCount = callCount
            self.ordinaryArgumentCount = ordinaryArgumentCount
            self.trailingClosureCount = trailingClosureCount
            self.additionalTrailingClosureCount =
                additionalTrailingClosureCount
            self.directReferenceArgumentCount = directReferenceArgumentCount
        }
    }

    fileprivate let callSites: [SyntaxIdentifier: ParsedCallSiteMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedCallSiteMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        callSites = collector.callSites
        let arguments = callSites.values.flatMap(\.arguments)
        summary = Summary(
            callCount: callSites.count,
            ordinaryArgumentCount: arguments.count { !$0.isTrailing },
            trailingClosureCount: arguments.count {
                $0.isTrailing && !$0.isAdditionalTrailingClosure
            },
            additionalTrailingClosureCount: arguments.count(
                where: \.isAdditionalTrailingClosure),
            directReferenceArgumentCount: arguments.count {
                $0.directUnqualifiedReferenceName != nil
            })
    }

    func metadata(
        for call: FunctionCallExprSyntax
    ) -> ParsedCallSiteMetadata? {
        callSites[Syntax(call).id]
    }
}

nonisolated struct ParsedCallSiteMetadata: Sendable {
    let arguments: [ParsedCallArgumentMetadata]

    init(_ call: FunctionCallExprSyntax) {
        var arguments = call.arguments.map {
            ParsedCallArgumentMetadata(
                label: $0.label?.text,
                expression: $0.expression)
        }
        if let closure = call.trailingClosure {
            arguments.append(ParsedCallArgumentMetadata(
                label: nil,
                expression: ExprSyntax(closure),
                trailingClosure: closure))
        }
        arguments.append(contentsOf: call.additionalTrailingClosures.map {
            ParsedCallArgumentMetadata(
                label: $0.label.text,
                expression: ExprSyntax($0.closure),
                trailingClosure: $0.closure,
                isAdditionalTrailingClosure: true)
        })
        self.arguments = arguments
    }
}

nonisolated struct ParsedCallArgumentMetadata: Sendable {
    let label: String?
    let expression: ExprSyntax
    let trailingClosure: ClosureExprSyntax?
    let isAdditionalTrailingClosure: Bool
    let directUnqualifiedReferenceName: String?

    var isTrailing: Bool { trailingClosure != nil }

    init(
        label: String?,
        expression: ExprSyntax,
        trailingClosure: ClosureExprSyntax? = nil,
        isAdditionalTrailingClosure: Bool = false
    ) {
        self.label = label
        self.expression = expression
        self.trailingClosure = trailingClosure
        self.isAdditionalTrailingClosure = isAdditionalTrailingClosure
        directUnqualifiedReferenceName = expression
            .as(DeclReferenceExprSyntax.self)?.baseName.text
    }
}

private nonisolated final class ParsedCallSiteMetadataCollector:
    SyntaxVisitor
{
    var callSites: [SyntaxIdentifier: ParsedCallSiteMetadata] = [:]
    private var conditionalPredicateCalls: Set<SyntaxIdentifier> = []

    override func visit(
        _ node: IfConfigClauseSyntax
    ) -> SyntaxVisitorContinueKind {
        if let condition = node.condition {
            let collector = ParsedCallIdentifierCollector(
                viewMode: .sourceAccurate)
            collector.walk(Syntax(condition))
            conditionalPredicateCalls.formUnion(collector.identifiers)
        }
        return .visitChildren
    }

    override func visit(
        _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
        let identifier = Syntax(node).id
        if !conditionalPredicateCalls.contains(identifier) {
            callSites[identifier] = ParsedCallSiteMetadata(node)
        }
        return .visitChildren
    }
}

private nonisolated final class ParsedCallIdentifierCollector: SyntaxVisitor {
    var identifiers: Set<SyntaxIdentifier> = []

    override func visit(
        _ node: FunctionCallExprSyntax
    ) -> SyntaxVisitorContinueKind {
        identifiers.insert(Syntax(node).id)
        return .visitChildren
    }
}
