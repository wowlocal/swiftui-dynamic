import SwiftSyntax

/// An interpreted function or closure: parameter list, body syntax, and the
/// environment captured at creation. Methods are represented as closures whose
/// captured environment has `self` bound. `isBuilder` marks `@ViewBuilder`
/// functions and `some View` returns — their bodies evaluate in builder mode.
@MainActor
public final class ClosureValue {
    public nonisolated struct Parameter: Sendable {
        public let name: String
        /// External argument label (nil for `_` and closure parameters).
        public let label: String?
        public let defaultValue: ExprSyntax?
        /// Used to resolve `.member` arguments against known enums.
        public let typeAnnotation: TypeSyntax?
        /// Cached textual form of `typeAnnotation`. SwiftSyntax descriptions
        /// are surprisingly expensive to materialize on every invocation.
        public let typeName: String?
        /// Cached return type for function-typed builder parameters.
        public let builderReturnType: TypeSyntax?
        public let builderReturnTypeName: String?
        /// `@ViewBuilder`/custom `@…Builder` parameter: closure arguments
        /// bound here undergo the result-builder transform.
        public let isBuilderAttributed: Bool
        /// `arguments: CVarArg...` — gathers zero-or-more into an array.
        public let isVariadic: Bool
        /// `isolated Actor` / `isolated (any Actor)?` selects the callee's
        /// executor from the runtime argument rather than from the function
        /// declaration or receiver.
        public let isIsolated: Bool

        public init(
            name: String, label: String? = nil, defaultValue: ExprSyntax? = nil,
            typeAnnotation: TypeSyntax? = nil, isBuilderAttributed: Bool = false,
            isVariadic: Bool = false, isIsolated: Bool = false
        ) {
            self.name = name
            self.label = label
            self.defaultValue = defaultValue
            self.typeAnnotation = typeAnnotation
            self.typeName = typeAnnotation?.trimmedDescription
            let builderReturnType = Self.functionReturnType(of: typeAnnotation)
            self.builderReturnType = builderReturnType
            self.builderReturnTypeName = builderReturnType?.trimmedDescription
            self.isBuilderAttributed = isBuilderAttributed
            self.isVariadic = isVariadic
            self.isIsolated = isIsolated
        }

        /// `@FloatingActionBuilder actions: () -> [FloatingAction]` — the
        /// attributes live on the parameter's type node.
        public static func isBuilderAttributedType(_ type: TypeSyntax?) -> Bool {
            guard let attributed = type?.as(AttributedTypeSyntax.self) else { return false }
            return attributed.attributes.contains {
                $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.hasSuffix("Builder") == true
            }
        }

        /// SwiftSyntax represents `isolated` as a type specifier on an
        /// AttributedTypeSyntax. Keep this semantic bit independently from
        /// the textual annotation so invocation does not need string parsing.
        public static func isIsolatedType(_ type: TypeSyntax?) -> Bool {
            guard let attributed = type?.as(AttributedTypeSyntax.self) else {
                return false
            }
            return attributed.specifiers.contains { element in
                guard case .simpleTypeSpecifier(let specifier) = element else {
                    return false
                }
                return specifier.specifier.tokenKind == .keyword(.isolated)
            }
        }

        /// The return type of a function-typed parameter (attributes peeled),
        /// so builder calls know array-annotated blocks collect into arrays.
        public static func functionReturnType(of type: TypeSyntax?) -> TypeSyntax? {
            var base = type
            if let attributed = base?.as(AttributedTypeSyntax.self) { base = attributed.baseType }
            return base?.as(FunctionTypeSyntax.self)?.returnClause.type
        }
    }

    public let parameters: [Parameter]
    public let body: CodeBlockItemListSyntax
    public let captured: Environment
    public let isBuilder: Bool
    /// Used to resolve returned `.member` values against known enums.
    public let returnType: TypeSyntax?
    /// Cached textual form used by return-value coercion.
    public var returnTypeName: String?
    /// `[Element]` result builders collect items into an array.
    public let builderReturnsArray: Bool
    /// Set for host-extension METHOD bodies (`extension View { func … }`):
    /// while this frame is active, a same-named self-call prefers the
    /// registry gateway — real overload resolution for the ubiquitous
    /// "convenience overload of a SwiftUI modifier" pattern.
    public var extensionFrame: ExtensionFrame?
    /// The FunctionDecl this closure wraps (method/function bodies):
    /// self-delegating overload calls exclude the RUNNING declaration.
    public var functionDeclID: SyntaxIdentifier?
    /// The type whose body/extension LEXICALLY declares this function —
    /// bare type names inside it resolve against THIS scope, not the
    /// runtime self (protocol-extension bodies see module scope).
    public var lexicalOwner: AnyObject?
    /// Generic parameter NAMES (`func get<Entity: Decodable>`): return-
    /// position ones bind to the call-site annotation at invocation.
    public var genericParameters: [String] = []
    /// The declared function name, for diagnostics tracing only.
    public var debugName: String?
    /// Native spelling of `#function` for a source function declaration,
    /// including its external argument labels.
    public var sourceFunctionName: String?
    /// A declaration-level source executor hop whose identity is available at
    /// closure formation. `nil` inherits the caller unless lazy global-actor
    /// metadata below resolves an executor at invocation.
    public var executorPreference: RuntimeExecutorKind?
    /// Attribute type names that may denote a user-declared global actor.
    /// Resolution is intentionally lazy: Swift declarations are order
    /// independent, and the global actor's canonical `shared` instance may
    /// not exist until its first invocation. Only a collected type marked
    /// `@globalActor` is accepted; arbitrary attributes remain inert here.
    public internal(set) var globalActorAttributeCandidates: [String] = []
    /// True only when a source function declaration carries a plain explicit
    /// `nonisolated` modifier with no detail argument. This is intentionally
    /// separate from a nil executor preference: nil also represents actor
    /// kinds the incremental runtime cannot identify yet, so it is not proof
    /// of nonisolation.
    public var isExplicitlyNonisolated = false
    /// Statically proven lexical executor inherited by a source closure
    /// expression. This must not be inferred from the dynamic executor on
    /// which a nonisolated factory happened to run. APIs whose parameters
    /// inherit actor context use it independently from task lineage/locals.
    public var lexicalExecutor: RuntimeExecutorKind?
    /// True only for a source closure expression with no authored signature.
    /// Explicit attributes, captures, effects, parameters, or return clauses
    /// remain on the cooperative evaluator until their transfer semantics are
    /// modeled rather than inferred from a literal body.
    var isPhysicalSnapshotKernelCandidate = false
    /// True only for Planet's demand-backed exact `{ @MainActor in ... }`
    /// signature: one imported MainActor attribute and no capture-list,
    /// parameter, effect, return, or additional-attribute surface. The
    /// complete closure remains confined; this flag may unlock only an
    /// entry/handoff wrapper.
    var isPhysicalExplicitMainActorContinuationCandidate = false
    /// True only for Provenance's demand-backed explicit-MainActor weak-self
    /// signature. The complete closure and genuine weak box remain confined;
    /// this flag may unlock only an entry/handoff wrapper, never a snapshot or
    /// source-call route.
    var isPhysicalExplicitMainActorWeakSelfContinuationCandidate = false
    /// True only for the demand-backed capture-only spelling `{ [self] in }`.
    /// This does not admit general capture-list snapshot kernels: it may only
    /// unlock a direct-self source-call wrapper whose confined registration
    /// already owns the strongly captured receiver for the source task.
    var isPhysicalStrongSelfSourceCallCandidate = false
    /// True only for the demand-backed capture-only `[weak self]` signature.
    /// It may unlock an exact optional-self source-call wrapper or a checked
    /// sleep-prefix continuation. The weak box remains in this MainActor-
    /// confined closure and is read only after the physical wrapper reaches
    /// the confined relay; it is never copied to a worker capability.
    var isPhysicalWeakSelfSourceCallCandidate = false
    /// Immutable source-program capability retained by escaped callbacks. A
    /// fresh host/runtime entry can therefore recover every indexed
    /// declaration fact without consulting whichever program the facade ran
    /// most recently.
    public internal(set) var programMetadata: ParsedProgramMetadata?
    /// Immutable target-specific declaration/member selection retained with
    /// the source closure. External callback entries reuse this exact object
    /// rather than resolving branches through current facade state.
    public internal(set) var programPlan: ResolvedProgramPlan?
    /// MainActor-confined mutable declaration materialization associated with
    /// `programPlan`. Escaped host callbacks reuse this exact capability.
    var programState: RuntimeProgramState?
    /// Immutable identity of the exact source declaration represented by this
    /// closure. Anonymous closure expressions and foreign-syntax fallbacks
    /// leave it nil; a selected function/method may project this descriptor
    /// without transferring the closure or its captured environment.
    var sourceFunctionTargetDescriptor:
        RuntimeSourceFunctionTargetDescriptor?
    public var callableMetadataIndex: ParsedCallableMetadataIndex? {
        programMetadata?.callableMetadataIndex
    }

    public init(
        parameters: [Parameter],
        body: CodeBlockItemListSyntax,
        captured: Environment,
        isBuilder: Bool = false,
        returnType: TypeSyntax? = nil,
        returnTypeName: String? = nil,
        programMetadata: ParsedProgramMetadata? = nil,
        programPlan: ResolvedProgramPlan? = nil
    ) {
        self.parameters = parameters
        self.body = body
        self.captured = captured
        self.isBuilder = isBuilder
        self.returnType = returnType
        self.returnTypeName = returnTypeName ?? returnType?.trimmedDescription
        self.builderReturnsArray = self.returnTypeName?.hasPrefix("[") == true
        self.programPlan = programPlan
        self.programMetadata = programPlan?.metadata ?? programMetadata
    }
}

/// Identity of a host-extension method execution (type + member).
public nonisolated struct ExtensionFrame: Hashable, Sendable {
    public let typeName: String
    public let member: String
}
