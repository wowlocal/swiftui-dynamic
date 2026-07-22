import Foundation
import SwiftSyntax

/// Immutable variable/property storage headers discovered once from a folded
/// program. The index includes every conditional-compilation branch and every
/// lexical scope; a runtime session only consumes entries from its resolved
/// declarations and active execution path.
public nonisolated struct ParsedPropertyMetadataIndex: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        public let variableDeclarationCount: Int
        public let bindingCount: Int
        public let storedBindingCount: Int
        public let computedBindingCount: Int
        public let observedStoredBindingCount: Int
        public let mutableBindingCount: Int
        public let staticBindingCount: Int
        public let lazyBindingCount: Int
        public let explicitlyNonisolatedBindingCount: Int
        public let taskLocalBindingCount: Int
        public let referenceManagedBindingCount: Int

        public init(
            variableDeclarationCount: Int,
            bindingCount: Int,
            storedBindingCount: Int,
            computedBindingCount: Int,
            observedStoredBindingCount: Int,
            mutableBindingCount: Int,
            staticBindingCount: Int,
            lazyBindingCount: Int,
            explicitlyNonisolatedBindingCount: Int,
            taskLocalBindingCount: Int,
            referenceManagedBindingCount: Int
        ) {
            self.variableDeclarationCount = variableDeclarationCount
            self.bindingCount = bindingCount
            self.storedBindingCount = storedBindingCount
            self.computedBindingCount = computedBindingCount
            self.observedStoredBindingCount = observedStoredBindingCount
            self.mutableBindingCount = mutableBindingCount
            self.staticBindingCount = staticBindingCount
            self.lazyBindingCount = lazyBindingCount
            self.explicitlyNonisolatedBindingCount =
                explicitlyNonisolatedBindingCount
            self.taskLocalBindingCount = taskLocalBindingCount
            self.referenceManagedBindingCount = referenceManagedBindingCount
        }
    }

    fileprivate let declarations:
        [SyntaxIdentifier: ParsedVariablePropertyMetadata]
    fileprivate let bindings:
        [SyntaxIdentifier: ParsedPropertyBindingMetadata]
    public let summary: Summary

    init(file: SourceFileSyntax) {
        let collector = ParsedPropertyMetadataCollector(
            viewMode: .sourceAccurate)
        collector.walk(Syntax(file))
        declarations = collector.declarations
        bindings = collector.bindings

        var storedBindingCount = 0
        var computedBindingCount = 0
        var observedStoredBindingCount = 0
        var mutableBindingCount = 0
        var staticBindingCount = 0
        var lazyBindingCount = 0
        var explicitlyNonisolatedBindingCount = 0
        var taskLocalBindingCount = 0
        var referenceManagedBindingCount = 0
        for (bindingID, binding) in bindings {
            guard let declarationID = collector.bindingDeclarationIDs[
                bindingID],
                  let declaration = declarations[declarationID] else {
                continue
            }
            if binding.isComputed {
                computedBindingCount += 1
            } else {
                storedBindingCount += 1
            }
            if binding.isObservedStored { observedStoredBindingCount += 1 }
            if declaration.isMutable { mutableBindingCount += 1 }
            if declaration.isStatic { staticBindingCount += 1 }
            if declaration.isLazy { lazyBindingCount += 1 }
            if declaration.isNonisolated {
                explicitlyNonisolatedBindingCount += 1
            }
            if declaration.isTaskLocal { taskLocalBindingCount += 1 }
            if declaration.referenceOwnership != .strong {
                referenceManagedBindingCount += 1
            }
        }
        summary = Summary(
            variableDeclarationCount: declarations.count,
            bindingCount: bindings.count,
            storedBindingCount: storedBindingCount,
            computedBindingCount: computedBindingCount,
            observedStoredBindingCount: observedStoredBindingCount,
            mutableBindingCount: mutableBindingCount,
            staticBindingCount: staticBindingCount,
            lazyBindingCount: lazyBindingCount,
            explicitlyNonisolatedBindingCount:
                explicitlyNonisolatedBindingCount,
            taskLocalBindingCount: taskLocalBindingCount,
            referenceManagedBindingCount: referenceManagedBindingCount)
    }

    func metadata(
        for declaration: VariableDeclSyntax
    ) -> ParsedVariablePropertyMetadata? {
        declarations[Syntax(declaration).id]
    }

    func metadata(
        for binding: PatternBindingSyntax
    ) -> ParsedPropertyBindingMetadata? {
        bindings[Syntax(binding).id]
    }
}

nonisolated struct ParsedVariablePropertyMetadata: Sendable {
    let isMutable: Bool
    let isStatic: Bool
    let isLazy: Bool
    let isNonisolated: Bool
    let isTaskLocal: Bool
    /// A plain `private`/`fileprivate` access modifier restricts both reads
    /// and writes to the declaring compiler input. Setter-only modifiers such
    /// as `private(set)` intentionally do not restrict reads.
    let hasFileScopedReadAccess: Bool
    let referenceOwnership: ReferenceOwnership
    let attributeNames: [String]
    let hasBuilderAttribute: Bool

    init(_ declaration: VariableDeclSyntax) {
        isMutable = declaration.bindingSpecifier.text == "var"
        isStatic = declaration.modifiers.contains {
            $0.name.tokenKind == .keyword(.static)
                || $0.name.tokenKind == .keyword(.class)
        }
        isLazy = declaration.modifiers.contains { $0.name.text == "lazy" }
        isNonisolated = declaration.modifiers.contains {
            $0.name.text == "nonisolated"
        }
        referenceOwnership = ReferenceOwnership(
            modifiers: declaration.modifiers)
        attributeNames = declaration.attributes.compactMap {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription
                .split(separator: ".").last.map(String.init)
        }
        isTaskLocal = attributeNames.contains("TaskLocal")
        hasFileScopedReadAccess = declaration.modifiers.contains {
            ($0.name.text == "private" || $0.name.text == "fileprivate")
                && $0.detail == nil
        }
        hasBuilderAttribute = attributeNames.contains {
            $0.hasSuffix("Builder")
        }
    }
}

nonisolated struct ParsedPropertyBindingMetadata: Sendable {
    nonisolated enum PatternKind: Sendable, Equatable {
        case identifier
        case tuple
        case wildcard
        case unsupported
    }

    nonisolated struct TupleElement: Sendable {
        let name: String
        let typeAnnotation: TypeSyntax?
    }

    nonisolated struct Observer: Sendable {
        let body: CodeBlockItemListSyntax
        let parameterName: String
    }

    let patternKind: PatternKind
    let identifierName: String?
    let tupleElements: [TupleElement]
    let initializer: ExprSyntax?
    let typeAnnotation: TypeSyntax?
    /// Immutable spelling used by hot declaration/coercion paths without
    /// rebuilding a detached syntax tree at every execution.
    let typeName: String?
    let isComputed: Bool
    let willSet: Observer?
    let didSet: Observer?

    var isObservedStored: Bool {
        !isComputed && (willSet != nil || didSet != nil)
    }

    init(_ binding: PatternBindingSyntax) {
        let backticks = CharacterSet(charactersIn: "`")
        if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
            patternKind = .identifier
            identifierName = identifier.identifier.text
                .trimmingCharacters(in: backticks)
            tupleElements = []
        } else if let tuple = binding.pattern.as(TuplePatternSyntax.self) {
            patternKind = .tuple
            identifierName = nil
            let elements = Array(tuple.elements)
            let tupleTypes: [TypeSyntax?]
            if let tupleType = binding.typeAnnotation?.type.as(
                TupleTypeSyntax.self),
               tupleType.elements.count == elements.count {
                tupleTypes = tupleType.elements.map(\.type)
            } else {
                tupleTypes = Array(repeating: nil, count: elements.count)
            }
            tupleElements = zip(elements, tupleTypes).compactMap {
                element, type in
                guard let identifier = element.pattern.as(
                    IdentifierPatternSyntax.self) else { return nil }
                return TupleElement(
                    name: identifier.identifier.text
                        .trimmingCharacters(in: backticks),
                    typeAnnotation: type)
            }
        } else if binding.pattern.is(WildcardPatternSyntax.self) {
            patternKind = .wildcard
            identifierName = nil
            tupleElements = []
        } else {
            patternKind = .unsupported
            identifierName = nil
            tupleElements = []
        }

        initializer = binding.initializer?.value
        let parsedTypeAnnotation = binding.typeAnnotation?.type
        typeAnnotation = parsedTypeAnnotation
        typeName = parsedTypeAnnotation?.trimmedDescription
        isComputed = binding.accessorBlock.flatMap {
            ParsedAccessorMetadata($0)
        } != nil

        var parsedWillSet: Observer?
        var parsedDidSet: Observer?
        if let accessorBlock = binding.accessorBlock,
           case .accessors(let accessors) = accessorBlock.accessors {
            for accessor in accessors {
                guard let body = accessor.body?.statements else { continue }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.willSet):
                    parsedWillSet = Observer(
                        body: body,
                        parameterName: accessor.parameters?.name.text
                            ?? "newValue")
                case .keyword(.didSet):
                    parsedDidSet = Observer(
                        body: body,
                        parameterName: accessor.parameters?.name.text
                            ?? "oldValue")
                default:
                    break
                }
            }
        }
        willSet = parsedWillSet
        didSet = parsedDidSet
    }
}

private nonisolated final class ParsedPropertyMetadataCollector:
    SyntaxVisitor
{
    var declarations: [SyntaxIdentifier: ParsedVariablePropertyMetadata] = [:]
    var bindings: [SyntaxIdentifier: ParsedPropertyBindingMetadata] = [:]
    var bindingDeclarationIDs: [SyntaxIdentifier: SyntaxIdentifier] = [:]

    override func visit(
        _ node: VariableDeclSyntax
    ) -> SyntaxVisitorContinueKind {
        let declarationID = Syntax(node).id
        declarations[declarationID] = ParsedVariablePropertyMetadata(node)
        for binding in node.bindings {
            let bindingID = Syntax(binding).id
            bindings[bindingID] = ParsedPropertyBindingMetadata(binding)
            bindingDeclarationIDs[bindingID] = declarationID
        }
        return .visitChildren
    }
}
