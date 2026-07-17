import SwiftSyntax

/// Mutable declaration materialization for one resolved source program.
///
/// This capability is deliberately MainActor-confined. It groups the symbol
/// and resolution registries that used to live directly on `Interpreter`
/// without pretending that `StructSymbol`, `EnumSymbol`, `RuntimeValue`,
/// or their storage graphs are safe for physical workers. A session, its
/// runtime entries, and escaped source closures retain the same state object.
@MainActor
final class RuntimeProgramState {
    typealias PendingMemberAlias = (StructSymbol, String, String)
    typealias PendingDeinitializerIsolationCheck = (
        symbol: StructSymbol,
        declaration: DeinitializerDeclSyntax,
        metadata: ParsedDeinitializerMetadata
    )

    /// `nil` belongs only to the empty pre-run compatibility state.
    let programPlan: ResolvedProgramPlan?
    let assumesCompiledImports: Bool
    /// Older host-extension state visible only to compatibility lookup from
    /// this newer program. Empty intermediate programs are skipped, and the
    /// edge is one-way: an escaped closure from the older state can never
    /// observe declarations prepared later on the facade.
    let hostExtensionParent: RuntimeProgramState?
    /// Host APIs are part of the prepared program capability. Escaped source
    /// closures retain this state, so later facade reconfiguration cannot
    /// redirect an old callback into a different bridge registry.
    let hostRegistry: HostRegistry?

    var structSymbols: [StructSymbol] = []
    var enumSymbols: [String: EnumSymbol] = [:]
    var hostExtensionSymbols: [String: StructSymbol] = [:]
    var protocolInheritance: [String: [String]] = [:]
    var dependencyCache: [String: RuntimeValue] = [:]
    var globalFunctionOverloads: [String: [FunctionDeclSyntax]] = [:]
    var declarationLexicalOwners: [SyntaxIdentifier: AnyObject] = [:]
    var pendingDottedExtensions: [ExtensionDeclSyntax] = []
    var aliasHeads: [String: String] = [:]
    var pendingMemberAliases: [PendingMemberAlias] = []
    var pendingDeinitializerIsolationChecks:
        [PendingDeinitializerIsolationCheck] = []

    init(
        programPlan: ResolvedProgramPlan? = nil,
        assumesCompiledImports: Bool = false,
        hostRegistry: HostRegistry? = nil,
        hostExtensionParent: RuntimeProgramState? = nil
    ) {
        self.programPlan = programPlan
        self.assumesCompiledImports = assumesCompiledImports
        self.hostRegistry = hostRegistry
        self.hostExtensionParent = hostExtensionParent
        precondition(hostExtensionParent !== self)
    }

    /// Do not retain one state object for every expression-only compatibility
    /// run. Only states that contribute a host extension participate in this
    /// lookup lineage.
    var hostExtensionLineageAnchor: RuntimeProgramState? {
        hostExtensionSymbols.isEmpty ? hostExtensionParent : self
    }

    /// Host values have no interpreted nominal symbol carrying lexical
    /// provenance. A later compatibility run therefore searches the
    /// one-way state lineage, with the newest declaration winning.
    var visibleHostExtensionSymbols: [String: StructSymbol] {
        var lineage: [RuntimeProgramState] = []
        var cursor: RuntimeProgramState? = self
        while let state = cursor {
            lineage.append(state)
            cursor = state.hostExtensionParent
        }
        var result: [String: StructSymbol] = [:]
        for state in lineage.reversed() {
            result.merge(state.hostExtensionSymbols) { _, newer in newer }
        }
        return result
    }

    var visibleDeclarationLexicalOwners: [SyntaxIdentifier: AnyObject] {
        var lineage: [RuntimeProgramState] = []
        var cursor: RuntimeProgramState? = self
        while let state = cursor {
            lineage.append(state)
            cursor = state.hostExtensionParent
        }
        var result: [SyntaxIdentifier: AnyObject] = [:]
        for state in lineage.reversed() {
            result.merge(state.declarationLexicalOwners) { _, newer in newer }
        }
        return result
    }

    func stateOwningDeclaration(
        _ declarationID: SyntaxIdentifier
    ) -> RuntimeProgramState? {
        var cursor: RuntimeProgramState? = self
        while let state = cursor {
            if state.declarationLexicalOwners[declarationID] != nil {
                return state
            }
            cursor = state.hostExtensionParent
        }
        return nil
    }
}
