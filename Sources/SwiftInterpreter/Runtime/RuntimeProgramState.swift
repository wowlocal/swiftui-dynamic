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
        hostRegistry: HostRegistry? = nil
    ) {
        self.programPlan = programPlan
        self.assumesCompiledImports = assumesCompiledImports
        self.hostRegistry = hostRegistry
    }
}
