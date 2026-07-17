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
        public let typeMemberFunctionCount: Int
        public let modifiedFunctionCount: Int
        public let readableAccessorCount: Int
        public let subscriptCount: Int
        public let asyncGetterCount: Int
        public let throwingGetterCount: Int
        public let setterCount: Int

        public init(
            functionCount: Int,
            initializerCount: Int,
            asyncFunctionCount: Int,
            throwingFunctionCount: Int,
            explicitlyNonisolatedFunctionCount: Int,
            mainActorFunctionCount: Int,
            concurrentFunctionCount: Int,
            typeMemberFunctionCount: Int = 0,
            modifiedFunctionCount: Int = 0,
            readableAccessorCount: Int = 0,
            subscriptCount: Int = 0,
            asyncGetterCount: Int = 0,
            throwingGetterCount: Int = 0,
            setterCount: Int = 0
        ) {
            self.functionCount = functionCount
            self.initializerCount = initializerCount
            self.asyncFunctionCount = asyncFunctionCount
            self.throwingFunctionCount = throwingFunctionCount
            self.explicitlyNonisolatedFunctionCount =
                explicitlyNonisolatedFunctionCount
            self.mainActorFunctionCount = mainActorFunctionCount
            self.concurrentFunctionCount = concurrentFunctionCount
            self.typeMemberFunctionCount = typeMemberFunctionCount
            self.modifiedFunctionCount = modifiedFunctionCount
            self.readableAccessorCount = readableAccessorCount
            self.subscriptCount = subscriptCount
            self.asyncGetterCount = asyncGetterCount
            self.throwingGetterCount = throwingGetterCount
            self.setterCount = setterCount
        }
    }

    fileprivate let functions: [SyntaxIdentifier: ParsedFunctionMetadata]
    fileprivate let initializers: [SyntaxIdentifier: ParsedInitializerMetadata]
    fileprivate let accessors: [SyntaxIdentifier: ParsedAccessorMetadata]
    fileprivate let subscripts: [SyntaxIdentifier: ParsedSubscriptMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedCallableMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        functions = collector.functions
        initializers = collector.initializers
        accessors = collector.accessors
        subscripts = collector.subscripts
        let functionValues = Array(functions.values)
        let accessorValues = Array(accessors.values)
        summary = Summary(
            functionCount: functions.count,
            initializerCount: initializers.count,
            asyncFunctionCount: functionValues.count(where: \.isAsync),
            throwingFunctionCount: functionValues.count(where: \.isThrowing),
            explicitlyNonisolatedFunctionCount: functionValues.count(
                where: \.isExplicitlyNonisolated),
            mainActorFunctionCount: functionValues.count(where: \.isMainActor),
            concurrentFunctionCount: functionValues.count(where: \.isConcurrent),
            typeMemberFunctionCount: functionValues.count(
                where: \.isTypeMember),
            modifiedFunctionCount: functionValues.count {
                !$0.modifierNames.isEmpty
            },
            readableAccessorCount: accessors.count,
            subscriptCount: subscripts.count,
            asyncGetterCount: accessorValues.count(where: \.isAsync),
            throwingGetterCount: accessorValues.count(where: \.isThrowing),
            setterCount: accessorValues.count { $0.setter != nil })
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

    func metadata(
        for accessorBlock: AccessorBlockSyntax
    ) -> ParsedAccessorMetadata? {
        accessors[Syntax(accessorBlock).id]
    }

    func metadata(
        for declaration: SubscriptDeclSyntax
    ) -> ParsedSubscriptMetadata? {
        subscripts[Syntax(declaration).id]
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
    let name: String
    let parameters: [ClosureValue.Parameter]
    let shape: ParsedCallableShape
    let returnType: TypeSyntax?
    let returnTypeName: String?
    let isBuilder: Bool
    let genericParameters: [String]
    let attributeNames: [String]
    let modifierNames: [String]
    let sourceFunctionName: String
    let isAsync: Bool
    let isThrowing: Bool
    let isAnyNonisolated: Bool
    let isExplicitlyNonisolated: Bool
    let isMainActor: Bool
    let isConcurrent: Bool
    let isTypeMember: Bool

    init(_ declaration: FunctionDeclSyntax) {
        let parameters = declaration.signature.parameterClause.parameters
        let returnType = declaration.signature.returnClause?.type
        let returnTypeName = returnType?.trimmedDescription
        let attributeNames = parsedAttributeNames(declaration.attributes)
        let modifierNames = declaration.modifiers.map { $0.name.text }
        name = declaration.name.text
        self.parameters = parsedClosureParameters(parameters)
        shape = parsedCallableShape(parameters)
        self.returnType = returnType
        self.returnTypeName = returnTypeName
        isBuilder = returnTypeName?.contains("some View") == true
            || attributeNames.contains(where: { $0.hasSuffix("Builder") })
        genericParameters = declaration.genericParameterClause?.parameters
            .map(\.name.text) ?? []
        self.attributeNames = attributeNames
        self.modifierNames = modifierNames
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
        isTypeMember = modifierNames.contains("static")
            || modifierNames.contains("class")
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

nonisolated struct ParsedAccessorMetadata: Sendable {
    nonisolated struct Setter: Sendable {
        let body: CodeBlockItemListSyntax
        let parameterName: String
    }

    let getter: CodeBlockItemListSyntax
    let setter: Setter?
    let isAsync: Bool
    let isThrowing: Bool

    init?(_ accessorBlock: AccessorBlockSyntax) {
        switch accessorBlock.accessors {
        case .getter(let items):
            getter = items
            setter = nil
            isAsync = false
            isThrowing = false
        case .accessors(let list):
            var getter: CodeBlockItemListSyntax?
            var setter: Setter?
            var isAsync = false
            var isThrowing = false
            for accessor in list {
                guard let body = accessor.body?.statements else { continue }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.get):
                    getter = body
                    isAsync = accessor.effectSpecifiers?.asyncSpecifier != nil
                    isThrowing =
                        accessor.effectSpecifiers?.throwsClause != nil
                case .keyword(.set):
                    setter = Setter(
                        body: body,
                        parameterName: accessor.parameters?.name.text
                            ?? "newValue")
                default:
                    break
                }
            }
            guard let getter else { return nil }
            self.getter = getter
            self.setter = setter
            self.isAsync = isAsync
            self.isThrowing = isThrowing
        }
    }
}

nonisolated struct ParsedSubscriptMetadata: Sendable {
    let parameters: [ClosureValue.Parameter]
    let shape: ParsedCallableShape
    let resultTypeName: String
    let isNonisolated: Bool

    init(_ declaration: SubscriptDeclSyntax) {
        let parameters = declaration.parameterClause.parameters
        let backticks = CharacterSet(charactersIn: "`")
        self.parameters = parameters.map { parameter in
            let firstName = parameter.firstName.text
                .trimmingCharacters(in: backticks)
            return ClosureValue.Parameter(
                name: (parameter.secondName ?? parameter.firstName).text
                    .trimmingCharacters(in: backticks),
                label: firstName == "_" ? nil : firstName,
                defaultValue: parameter.defaultValue?.value,
                typeAnnotation: parameter.type)
        }
        shape = parsedCallableShape(parameters)
        resultTypeName = declaration.returnClause.type.trimmedDescription
        isNonisolated = declaration.modifiers.contains {
            $0.name.text == "nonisolated"
        }
    }
}

private nonisolated final class ParsedCallableMetadataCollector: SyntaxVisitor {
    var functions: [SyntaxIdentifier: ParsedFunctionMetadata] = [:]
    var initializers: [SyntaxIdentifier: ParsedInitializerMetadata] = [:]
    var accessors: [SyntaxIdentifier: ParsedAccessorMetadata] = [:]
    var subscripts: [SyntaxIdentifier: ParsedSubscriptMetadata] = [:]

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

    override func visit(
        _ node: AccessorBlockSyntax
    ) -> SyntaxVisitorContinueKind {
        if let metadata = ParsedAccessorMetadata(node) {
            accessors[Syntax(node).id] = metadata
        }
        return .visitChildren
    }

    override func visit(
        _ node: SubscriptDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        subscripts[Syntax(node).id] = ParsedSubscriptMetadata(node)
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
