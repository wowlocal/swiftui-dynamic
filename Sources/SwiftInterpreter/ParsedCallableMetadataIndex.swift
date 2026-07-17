import Foundation
import SwiftSyntax

/// Immutable call-shape, effect, and declared-isolation metadata discovered
/// once from a folded program. Runtime symbol materialization consumes this
/// index instead of rebuilding mutable facade-owned caches per invocation.
public nonisolated struct ParsedCallableMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let functionCount: Int
        public let initializerCount: Int
        public let asyncFunctionCount: Int
        public let throwingFunctionCount: Int
        public let explicitlyNonisolatedFunctionCount: Int
        public let mainActorFunctionCount: Int
        public let concurrentFunctionCount: Int

        public init(
            functionCount: Int,
            initializerCount: Int,
            asyncFunctionCount: Int,
            throwingFunctionCount: Int,
            explicitlyNonisolatedFunctionCount: Int,
            mainActorFunctionCount: Int,
            concurrentFunctionCount: Int
        ) {
            self.functionCount = functionCount
            self.initializerCount = initializerCount
            self.asyncFunctionCount = asyncFunctionCount
            self.throwingFunctionCount = throwingFunctionCount
            self.explicitlyNonisolatedFunctionCount =
                explicitlyNonisolatedFunctionCount
            self.mainActorFunctionCount = mainActorFunctionCount
            self.concurrentFunctionCount = concurrentFunctionCount
        }
    }

    fileprivate let functions: [SyntaxIdentifier: ParsedFunctionMetadata]
    fileprivate let initializers: [SyntaxIdentifier: ParsedInitializerMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedCallableMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        functions = collector.functions
        initializers = collector.initializers
        let functionValues = Array(functions.values)
        summary = Summary(
            functionCount: functions.count,
            initializerCount: initializers.count,
            asyncFunctionCount: functionValues.count(where: \.isAsync),
            throwingFunctionCount: functionValues.count(where: \.isThrowing),
            explicitlyNonisolatedFunctionCount: functionValues.count(
                where: \.isExplicitlyNonisolated),
            mainActorFunctionCount: functionValues.count(where: \.isMainActor),
            concurrentFunctionCount: functionValues.count(where: \.isConcurrent))
    }

    func metadata(
        for declaration: FunctionDeclSyntax
    ) -> ParsedFunctionMetadata? {
        functions[Syntax(declaration).id]
    }

    func metadata(
        for declaration: InitializerDeclSyntax
    ) -> ParsedInitializerMetadata? {
        initializers[Syntax(declaration).id]
    }
}

nonisolated struct ParsedCallableShape: Sendable {
    let parameterCount: Int
    let labels: Set<String>
    let wildcardCount: Int
    let requiredLabels: [String]

    func matches(_ arguments: Interpreter.ArgumentShape) -> Bool {
        guard arguments.count <= parameterCount,
              arguments.labels.isSubset(of: labels),
              arguments.unlabeledCount <= wildcardCount else { return false }
        var missingRequired = 0
        for label in requiredLabels where !arguments.labels.contains(label) {
            missingRequired += 1
            if missingRequired > arguments.unlabeledTrailingCount {
                return false
            }
        }
        return true
    }
}

nonisolated struct ParsedFunctionMetadata: Sendable {
    let parameters: [ClosureValue.Parameter]
    let shape: ParsedCallableShape
    let returnType: TypeSyntax?
    let returnTypeName: String?
    let isBuilder: Bool
    let genericParameters: [String]
    let attributeNames: [String]
    let sourceFunctionName: String
    let isAsync: Bool
    let isThrowing: Bool
    let isAnyNonisolated: Bool
    let isExplicitlyNonisolated: Bool
    let isMainActor: Bool
    let isConcurrent: Bool

    init(_ declaration: FunctionDeclSyntax) {
        let parameters = declaration.signature.parameterClause.parameters
        let returnType = declaration.signature.returnClause?.type
        let returnTypeName = returnType?.trimmedDescription
        let attributeNames = parsedAttributeNames(declaration.attributes)
        self.parameters = parsedClosureParameters(parameters)
        shape = parsedCallableShape(parameters)
        self.returnType = returnType
        self.returnTypeName = returnTypeName
        isBuilder = returnTypeName?.contains("some View") == true
            || attributeNames.contains(where: { $0.hasSuffix("Builder") })
        genericParameters = declaration.genericParameterClause?.parameters
            .map(\.name.text) ?? []
        self.attributeNames = attributeNames
        sourceFunctionName = declaration.name.text + "("
            + parameters.map { $0.firstName.text + ":" }.joined() + ")"
        isAsync = declaration.signature.effectSpecifiers?.asyncSpecifier != nil
        isThrowing = declaration.signature.effectSpecifiers?.throwsClause != nil
        isAnyNonisolated = declaration.modifiers.contains {
            $0.name.text == "nonisolated"
        }
        isExplicitlyNonisolated = declaration.modifiers.contains {
            $0.trimmedDescription == "nonisolated"
        }
        isMainActor = attributeNames.contains("MainActor")
        isConcurrent = attributeNames.contains("concurrent")
    }
}

nonisolated struct ParsedInitializerMetadata: Sendable {
    let parameters: [ClosureValue.Parameter]
    let shape: ParsedCallableShape
    let isAsync: Bool
    let isThrowing: Bool

    init(_ declaration: InitializerDeclSyntax) {
        let parameters = declaration.signature.parameterClause.parameters
        self.parameters = parsedClosureParameters(parameters)
        shape = parsedCallableShape(parameters)
        isAsync = declaration.signature.effectSpecifiers?.asyncSpecifier != nil
        isThrowing = declaration.signature.effectSpecifiers?.throwsClause != nil
    }
}

private nonisolated final class ParsedCallableMetadataCollector: SyntaxVisitor {
    var functions: [SyntaxIdentifier: ParsedFunctionMetadata] = [:]
    var initializers: [SyntaxIdentifier: ParsedInitializerMetadata] = [:]

    override func visit(
        _ node: FunctionDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        functions[Syntax(node).id] = ParsedFunctionMetadata(node)
        return .visitChildren
    }

    override func visit(
        _ node: InitializerDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        initializers[Syntax(node).id] = ParsedInitializerMetadata(node)
        return .visitChildren
    }
}

private nonisolated func parsedAttributeNames(
    _ attributes: AttributeListSyntax
) -> [String] {
    attributes.compactMap {
        $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            .split(separator: ".").last.map(String.init)
    }
}

private nonisolated func parsedClosureParameters(
    _ parameters: FunctionParameterListSyntax
) -> [ClosureValue.Parameter] {
    let backticks = CharacterSet(charactersIn: "`")
    return parameters.map { parameter in
        let firstName = parameter.firstName.text
            .trimmingCharacters(in: backticks)
        return ClosureValue.Parameter(
            name: (parameter.secondName ?? parameter.firstName).text
                .trimmingCharacters(in: backticks),
            label: firstName == "_" ? nil : firstName,
            defaultValue: parameter.defaultValue?.value,
            typeAnnotation: parameter.type,
            isBuilderAttributed: parameter.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName
                    .trimmedDescription.hasSuffix("Builder") == true
            } || ClosureValue.Parameter.isBuilderAttributedType(parameter.type),
            isVariadic: parameter.ellipsis != nil,
            isIsolated: ClosureValue.Parameter.isIsolatedType(parameter.type))
    }
}

private nonisolated func parsedCallableShape(
    _ parameters: FunctionParameterListSyntax
) -> ParsedCallableShape {
    var labels: Set<String> = []
    var wildcardCount = 0
    var requiredLabels: [String] = []
    for parameter in parameters {
        let label = parameter.firstName.text
        labels.insert(label)
        if label == "_" {
            wildcardCount += 1
        } else if parameter.defaultValue == nil {
            requiredLabels.append(label)
        }
    }
    return ParsedCallableShape(
        parameterCount: parameters.count,
        labels: labels,
        wildcardCount: wildcardCount,
        requiredLabels: requiredLabels)
}
