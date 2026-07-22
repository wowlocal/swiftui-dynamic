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
    struct TopLevelTypeAliasBinding {
        let targetName: String
        let sourceModuleName: String?
        let isExported: Bool
    }

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
    /// Compiler-input ownership for nominal identities. One enum identity may
    /// intentionally represent unioned sibling-module namespace declarations,
    /// so ownership is a set rather than a single textual module name.
    var sourceModuleNamesByNominalIdentity:
        [ObjectIdentifier: Set<String>] = [:]
    var hostExtensionSymbols: [String: StructSymbol] = [:] {
        didSet { hostExtensionLocalRevision &+= 1 }
    }
    private var hostExtensionLocalRevision: UInt64 = 0
    private var visibleHostExtensionRevision: UInt64 = 0
    private var visibleHostExtensionCache: (
        localRevision: UInt64,
        parentRevision: UInt64,
        symbols: [String: StructSymbol]
    )?
    private(set) var visibleHostExtensionMaterializationCount = 0
    var protocolInheritance: [String: [String]] = [:]
    var dependencyCache: [String: RuntimeValue] = [:]
    var globalFunctionOverloads: [String: [FunctionDeclSyntax]] = [:]
    var declarationLexicalOwners: [SyntaxIdentifier: AnyObject] = [:]
    /// Free-variable names are a property of the parsed closure site. Cache
    /// only that immutable analysis; every closure formation still builds a
    /// fresh environment and resolves the current boxes and values into it.
    var closureOuterReferenceCache: [SyntaxIdentifier: Set<String>] = [:]
    var preparedScalarFunctions:
        [SyntaxIdentifier: PreparedScalarFunctionCache] = [:]
    var pendingDottedExtensions: [ExtensionDeclSyntax] = []
    /// Extension target names proven by their declaring file's module/import
    /// provenance not to denote an interpreted nominal. These are host types
    /// or protocols, even if an unrelated flattened module declares a
    /// same-spelled nominal.
    var nonNominalExtensionTypeNames: Set<String> = []
    var aliasHeads: [String: String] = [:]
    /// Top-level aliases retain their declaring compiler module instead of
    /// collapsing into the flattened program's last spelling. Free type-name
    /// lookup can then apply the same-module/import visibility rule as
    /// interpreted nominals before following an alias to a host constructor.
    var topLevelTypeAliasBindings:
        [String: [TopLevelTypeAliasBinding]] = [:]
    /// Complete source typealias targets, including tuple and function types.
    /// `aliasHeads` remains the nominal-only extension canonicalization index;
    /// overload matching needs the unabridged spelling to recover call shape.
    var typeAliasTargets: [String: String] = [:]
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
        let parentSymbols = hostExtensionParent?
            .visibleHostExtensionSymbols ?? [:]
        let parentRevision = hostExtensionParent?
            .visibleHostExtensionRevision ?? 0
        if let cached = visibleHostExtensionCache,
           cached.localRevision == hostExtensionLocalRevision,
           cached.parentRevision == parentRevision {
            return cached.symbols
        }

        var result = parentSymbols
        result.merge(hostExtensionSymbols) { _, newer in newer }
        visibleHostExtensionMaterializationCount += 1
        visibleHostExtensionRevision &+= 1
        visibleHostExtensionCache = (
            hostExtensionLocalRevision, parentRevision, result)
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

    /// Resolve one owner without materializing the merged declaration index.
    /// Runtime accessor dispatch is a point lookup and can be substantially
    /// hotter than compatibility code that snapshots the complete lineage.
    func lexicalOwner(
        of declarationID: SyntaxIdentifier
    ) -> AnyObject? {
        var cursor: RuntimeProgramState? = self
        while let state = cursor {
            if let owner = state.declarationLexicalOwners[declarationID] {
                return owner
            }
            cursor = state.hostExtensionParent
        }
        return nil
    }

    /// Point lookup across compatibility-state lineage. Newer declarations
    /// shadow older ones while escaped callbacks retain their exact state.
    func typeAliasTarget(named name: String) -> String? {
        var cursor: RuntimeProgramState? = self
        while let state = cursor {
            if let target = state.typeAliasTargets[name] { return target }
            cursor = state.hostExtensionParent
        }
        return nil
    }
}
