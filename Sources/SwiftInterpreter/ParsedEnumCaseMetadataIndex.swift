import Foundation
import SwiftSyntax

/// Immutable enum-case headers discovered once from a folded program.
///
/// Every conditional-compilation branch and lexical scope is indexed. A
/// runtime session still chooses the active declarations and evaluates raw
/// value expressions against its own environment.
public nonisolated struct ParsedEnumCaseMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let enumCaseDeclarationCount: Int
        public let caseElementCount: Int
        public let associatedValueCaseCount: Int
        public let associatedValueCount: Int
        public let labeledAssociatedValueCount: Int
        public let explicitRawValueCount: Int
        public let backtickedNameCount: Int

        public init(
            enumCaseDeclarationCount: Int,
            caseElementCount: Int,
            associatedValueCaseCount: Int,
            associatedValueCount: Int,
            labeledAssociatedValueCount: Int,
            explicitRawValueCount: Int,
            backtickedNameCount: Int
        ) {
            self.enumCaseDeclarationCount = enumCaseDeclarationCount
            self.caseElementCount = caseElementCount
            self.associatedValueCaseCount = associatedValueCaseCount
            self.associatedValueCount = associatedValueCount
            self.labeledAssociatedValueCount = labeledAssociatedValueCount
            self.explicitRawValueCount = explicitRawValueCount
            self.backtickedNameCount = backtickedNameCount
        }
    }

    fileprivate let cases: [SyntaxIdentifier: ParsedEnumCaseMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedEnumCaseMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        cases = collector.cases
        let values = Array(cases.values)
        summary = Summary(
            enumCaseDeclarationCount: collector.declarationCount,
            caseElementCount: values.count,
            associatedValueCaseCount: values.count {
                !$0.associatedValues.isEmpty
            },
            associatedValueCount: values.reduce(0) {
                $0 + $1.associatedValues.count
            },
            labeledAssociatedValueCount: values.reduce(0) {
                $0 + $1.associatedValues.count { $0.label != nil }
            },
            explicitRawValueCount: values.count { $0.rawValue != nil },
            backtickedNameCount: values.count(where: \.wasBackticked))
    }

    func metadata(
        for element: EnumCaseElementSyntax
    ) -> ParsedEnumCaseMetadata? {
        cases[Syntax(element).id]
    }
}

nonisolated struct ParsedEnumCaseMetadata: Sendable {
    nonisolated struct AssociatedValue: Sendable, Equatable {
        let label: String?
        let typeName: String
    }

    let name: String
    let wasBackticked: Bool
    let associatedValues: [AssociatedValue]
    let rawValue: ExprSyntax?

    init(_ element: EnumCaseElementSyntax) {
        let sourceName = element.name.trimmedDescription
        wasBackticked = sourceName.hasPrefix("`")
            && sourceName.hasSuffix("`")
        name = element.name.text.trimmingCharacters(
            in: CharacterSet(charactersIn: "`"))
        associatedValues = element.parameterClause?.parameters.map {
            parameter in
            return AssociatedValue(
                // Preserve the collector's existing source-label behavior;
                // underscore/backticked-label semantics are outside this
                // demand-bounded slice.
                label: parameter.firstName?.text,
                typeName: parameter.type.trimmedDescription)
        } ?? []
        rawValue = element.rawValue?.value
    }
}

private nonisolated final class ParsedEnumCaseMetadataCollector:
    SyntaxVisitor
{
    var declarationCount = 0
    var cases: [SyntaxIdentifier: ParsedEnumCaseMetadata] = [:]

    override func visit(
        _ node: EnumCaseDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        declarationCount += 1
        for element in node.elements {
            cases[Syntax(element).id] = ParsedEnumCaseMetadata(element)
        }
        return .visitChildren
    }
}
