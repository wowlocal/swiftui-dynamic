import SwiftParser
import SwiftSyntax

/// One `Module.member` reference proven by a matching import in the same
/// source file. Build-material adapters use this syntax-derived property to
/// load source modules that supply free globals without naming packages.
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

    public init(
        importedModuleNames: Set<String>,
        qualifiedReferences: Set<SourceModuleReference>
    ) {
        self.importedModuleNames = importedModuleNames
        self.qualifiedReferences = qualifiedReferences
    }
}

private final class SourceModuleUsageCollector: SyntaxVisitor {
    var importedModuleNames: Set<String> = []
    var candidateReferences: Set<SourceModuleReference> = []

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
        if let module = node.base?.as(DeclReferenceExprSyntax.self)?
            .baseName.text,
           !module.isEmpty
        {
            candidateReferences.insert(SourceModuleReference(
                moduleName: module,
                memberName: node.declName.baseName.text))
        }
        return .visitChildren
    }
}

public extension Interpreter {
    /// Extract imported module names and root-qualified member references from
    /// a real Swift file. Comments and string literals cannot create usage.
    nonisolated static func sourceModuleUsage(in source: String) -> SourceModuleUsage {
        let file = Parser.parse(source: source)
        let collector = SourceModuleUsageCollector(viewMode: .sourceAccurate)
        collector.walk(file)
        return SourceModuleUsage(
            importedModuleNames: collector.importedModuleNames,
            qualifiedReferences: collector.candidateReferences.filter {
                collector.importedModuleNames.contains($0.moduleName)
            })
    }

    /// Names introduced at module scope, including declarations inside
    /// conditional-compilation branches. A `Module.member` reference requests
    /// source material only when that module actually exports `member` at the
    /// top level; same-named namespace types therefore remain type accesses.
    nonisolated static func topLevelDeclarationNames(
        in source: String
    ) -> Set<String> {
        let file = Parser.parse(source: source)
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
        return names
    }
}
