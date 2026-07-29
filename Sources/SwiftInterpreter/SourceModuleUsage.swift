import SwiftParser
import SwiftSyntax

/// One `Module.member` reference proven by a matching import in the same
/// source file. Build-material adapters combine this with unqualified nominal
/// references to load source modules without naming packages.
public nonisolated struct SourceModuleReference: Sendable, Hashable {
    public let moduleName: String
    public let memberName: String

    public init(moduleName: String, memberName: String) {
        self.moduleName = moduleName
        self.memberName = memberName
    }
}

public nonisolated struct SourceModuleUsage: Sendable, Equatable {
    public let importedModuleNames: Set<String>
    public let qualifiedReferences: Set<SourceModuleReference>
    public let unqualifiedReferences: Set<String>

    public init(
        importedModuleNames: Set<String>,
        qualifiedReferences: Set<SourceModuleReference>,
        unqualifiedReferences: Set<String> = []
    ) {
        self.importedModuleNames = importedModuleNames
        self.qualifiedReferences = qualifiedReferences
        self.unqualifiedReferences = unqualifiedReferences
    }
}

/// The source facts needed to derive a SwiftPM module slice. Keeping both
/// projections on one parsed syntax tree prevents build-material consumers
/// from reparsing every dependency file independently for references and
/// declarations.
public nonisolated struct SourceModuleAnalysis: Sendable, Equatable {
    public let usage: SourceModuleUsage
    public let topLevelDeclarationNames: Set<String>

    public init(
        usage: SourceModuleUsage,
        topLevelDeclarationNames: Set<String>
    ) {
        self.usage = usage
        self.topLevelDeclarationNames = topLevelDeclarationNames
    }
}

private final class SourceModuleUsageCollector: SyntaxVisitor {
    var importedModuleNames: Set<String> = []
    var candidateReferences: Set<SourceModuleReference> = []
    var unqualifiedReferenceNames: [SyntaxIdentifier: String] = [:]
    var possibleModuleQualifierNames: [SyntaxIdentifier: String] = [:]

    override init(viewMode: SyntaxTreeViewMode) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let module = node.path.first?.name.text, !module.isEmpty {
            importedModuleNames.insert(module)
        }
        return .skipChildren
    }

    override func visit(
        _ node: MemberAccessExprSyntax
    ) -> SyntaxVisitorContinueKind {
        if let reference = node.base?.as(DeclReferenceExprSyntax.self) {
            let module = reference.baseName.text
            candidateReferences.insert(SourceModuleReference(
                moduleName: module,
                memberName: node.declName.baseName.text))
            possibleModuleQualifierNames[Syntax(reference).id] = module
        }
        return .visitChildren
    }

    override func visit(
        _ node: MemberTypeSyntax
    ) -> SyntaxVisitorContinueKind {
        if let reference = node.baseType.as(IdentifierTypeSyntax.self) {
            possibleModuleQualifierNames[Syntax(reference).id]
                = reference.name.text
        }
        return .visitChildren
    }

    override func visit(
        _ node: DeclReferenceExprSyntax
    ) -> SyntaxVisitorContinueKind {
        if let member = node.parent?.as(MemberAccessExprSyntax.self),
           Syntax(member.declName).id == Syntax(node).id {
            return .skipChildren
        }
        let name = node.baseName.text
        if !name.isEmpty {
            unqualifiedReferenceNames[Syntax(node).id] = name
        }
        return .visitChildren
    }

    override func visit(
        _ node: IdentifierTypeSyntax
    ) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        if !name.isEmpty {
            unqualifiedReferenceNames[Syntax(node).id] = name
        }
        return .visitChildren
    }
}

public extension Interpreter {
    /// Extract module references and top-level declarations from one syntax
    /// tree. Comments and string literals cannot create usage.
    nonisolated static func sourceModuleAnalysis(
        in source: String
    ) -> SourceModuleAnalysis {
        let file = Parser.parse(source: source)
        let collector = SourceModuleUsageCollector(viewMode: .sourceAccurate)
        collector.walk(file)
        let moduleQualifierIDs = Set(
            collector.possibleModuleQualifierNames.compactMap { id, name in
                collector.importedModuleNames.contains(name) ? id : nil
            })
        let usage = SourceModuleUsage(
            importedModuleNames: collector.importedModuleNames,
            qualifiedReferences: collector.candidateReferences.filter {
                collector.importedModuleNames.contains($0.moduleName)
            },
            unqualifiedReferences: Set(
                collector.unqualifiedReferenceNames.compactMap { id, name in
                    moduleQualifierIDs.contains(id) ? nil : name
                }))

        var names: Set<String> = []

        func collect(_ statements: CodeBlockItemListSyntax) {
            for statement in statements {
                guard case .decl(let declaration) = statement.item else {
                    continue
                }
                if let function = declaration.as(FunctionDeclSyntax.self) {
                    names.insert(function.name.text)
                } else if let variable = declaration.as(VariableDeclSyntax.self) {
                    for binding in variable.bindings {
                        if let identifier = binding.pattern.as(
                            IdentifierPatternSyntax.self) {
                            names.insert(identifier.identifier.text)
                        }
                    }
                } else if let type = declaration.as(StructDeclSyntax.self) {
                    names.insert(type.name.text)
                } else if let type = declaration.as(ClassDeclSyntax.self) {
                    names.insert(type.name.text)
                } else if let type = declaration.as(EnumDeclSyntax.self) {
                    names.insert(type.name.text)
                } else if let type = declaration.as(ActorDeclSyntax.self) {
                    names.insert(type.name.text)
                } else if let type = declaration.as(ProtocolDeclSyntax.self) {
                    names.insert(type.name.text)
                } else if let alias = declaration.as(TypeAliasDeclSyntax.self) {
                    names.insert(alias.name.text)
                } else if let conditional = declaration.as(
                    IfConfigDeclSyntax.self) {
                    for clause in conditional.clauses {
                        if case .statements(let nested)? = clause.elements {
                            collect(nested)
                        }
                    }
                }
            }
        }

        collect(file.statements)
        return SourceModuleAnalysis(
            usage: usage, topLevelDeclarationNames: names)
    }

    /// Extract imports plus qualified and unqualified symbol references from
    /// a real Swift file. Comments and string literals cannot create usage.
    nonisolated static func sourceModuleUsage(
        in source: String
    ) -> SourceModuleUsage {
        sourceModuleAnalysis(in: source).usage
    }

    /// Names introduced at module scope, including declarations inside
    /// conditional-compilation branches. A `Module.member` reference requests
    /// source material only when that module actually exports `member` at the
    /// top level; same-named namespace types therefore remain type accesses.
    nonisolated static func topLevelDeclarationNames(
        in source: String
    ) -> Set<String> {
        sourceModuleAnalysis(in: source).topLevelDeclarationNames
    }
}
