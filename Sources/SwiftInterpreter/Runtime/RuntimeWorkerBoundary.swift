import Foundation

/// The only ways a runtime storage edge may participate in physical-worker
/// execution. This is an audit vocabulary, not a promise that every policy is
/// implemented today: current worker admission retains immutable metadata,
/// copies supported values, and excludes every confined or opaque edge.
nonisolated enum RuntimeHeapEdgeDisposition: String, Sendable, Equatable {
    case immutableSendable
    case actorConfined
    case mainActorConfined
    case synchronized
    case copied
    case rejectedNonSendable
}

/// Every mutable storage root currently owned by `RuntimeHeap`.
///
/// Raw values intentionally match the stored-property labels. The boundary
/// tests compare this inventory with `Mirror(RuntimeHeap)` so adding a new
/// heap root cannot silently bypass worker-policy review.
nonisolated enum RuntimeWorkerHeapEdge: String, CaseIterable, Sendable {
    case globals
    case synthesizedEnvironmentModels
    case viewStateCells
}

nonisolated enum RuntimeWorkerEntryEdge: String, CaseIterable, Sendable {
    case entryIdentity
    case programPlan
    case programMetadata
    case heap
    case programState
    case interpreter
}

nonisolated enum RuntimeWorkerEdgeTreatment: Sendable, Equatable {
    case retained
    case excluded
}

nonisolated struct RuntimeWorkerEntryEdgePolicy: Sendable, Equatable {
    let edge: RuntimeWorkerEntryEdge
    let disposition: RuntimeHeapEdgeDisposition
    let treatment: RuntimeWorkerEdgeTreatment
}

nonisolated struct RuntimeWorkerHeapEdgePolicy: Sendable, Equatable {
    let edge: RuntimeWorkerHeapEdge
    let disposition: RuntimeHeapEdgeDisposition
    let treatment: RuntimeWorkerEdgeTreatment
}

/// Executable proof that a worker capability contains only immutable entry
/// metadata and recursively copied values. Mutable heap, program-state, and
/// facade edges are represented in the manifest but never retained by the
/// capability itself.
nonisolated struct RuntimeWorkerAccessManifest: Sendable, Equatable {
    let entryEdges: [RuntimeWorkerEntryEdgePolicy]
    let heapEdges: [RuntimeWorkerHeapEdgePolicy]
    let copiedValuePaths: [String]

    var excludedEntryEdges:
        [RuntimeWorkerEntryEdge: RuntimeHeapEdgeDisposition] {
        Dictionary(uniqueKeysWithValues: entryEdges.compactMap { policy in
            guard policy.treatment == .excluded else { return nil }
            return (policy.edge, policy.disposition)
        })
    }

    var isWorkerSafe: Bool {
        let entryInventory = Set(entryEdges.map(\.edge))
        let heapInventory = Set(heapEdges.map(\.edge))
        guard entryEdges.count == RuntimeWorkerEntryEdge.allCases.count,
              entryInventory == Set(RuntimeWorkerEntryEdge.allCases),
              heapEdges.count == RuntimeWorkerHeapEdge.allCases.count,
              heapInventory == Set(RuntimeWorkerHeapEdge.allCases) else {
            return false
        }
        guard entryEdges.allSatisfy(Self.isSafe),
              heapEdges.allSatisfy(Self.isSafe) else {
            return false
        }
        return excludedEntryEdges[.heap] == .mainActorConfined
            && excludedEntryEdges[.programState] == .mainActorConfined
            && excludedEntryEdges[.interpreter] == .mainActorConfined
    }

    private static func isSafe(
        _ policy: RuntimeWorkerEntryEdgePolicy
    ) -> Bool {
        isSafe(
            disposition: policy.disposition,
            treatment: policy.treatment)
    }

    private static func isSafe(
        _ policy: RuntimeWorkerHeapEdgePolicy
    ) -> Bool {
        isSafe(
            disposition: policy.disposition,
            treatment: policy.treatment)
    }

    private static func isSafe(
        disposition: RuntimeHeapEdgeDisposition,
        treatment: RuntimeWorkerEdgeTreatment
    ) -> Bool {
        switch (disposition, treatment) {
        case (.immutableSendable, .retained),
             (.copied, .retained),
             (.synchronized, .retained),
             (.actorConfined, .excluded),
             (.mainActorConfined, .excluded),
             (.rejectedNonSendable, .excluded):
            return true
        default:
            return false
        }
    }
}

/// A recursively immutable, checked-Sendable copy of the RuntimeValue subset
/// that may cross a physical-worker boundary. There is deliberately no host
/// `Any`, interpreted reference, closure, symbol, or mutable storage case.
nonisolated indirect enum RuntimeWorkerValueSnapshot: Sendable, Equatable {
    nonisolated struct DictionaryEntry: Sendable, Equatable {
        let key: RuntimeWorkerValueSnapshot
        let value: RuntimeWorkerValueSnapshot

        init(
            key: RuntimeWorkerValueSnapshot,
            value: RuntimeWorkerValueSnapshot
        ) {
            self.key = key
            self.value = value
        }
    }

    case void
    case nilValue
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case stringIndex(String.Index)
    case url(URL)
    case array([RuntimeWorkerValueSnapshot])
    case dictionary([DictionaryEntry])
    case tuple(labels: [String?], values: [RuntimeWorkerValueSnapshot])
    case range(
        lowerBound: RuntimeWorkerValueSnapshot?,
        upperBound: RuntimeWorkerValueSnapshot?,
        includesUpperBound: Bool)
    case set(
        elements: [RuntimeWorkerValueSnapshot],
        elementTypeName: String?)
    case optional(
        wrapped: RuntimeWorkerValueSnapshot?,
        wrappedTypeName: String?,
        isImplicitlyUnwrapped: Bool)
    case implicitMember(String)

    /// Copy a result while still on the evaluator's owning actor. Physical
    /// source-call re-entry uses the same structural boundary as captured
    /// worker inputs; an interpreted reference, closure, symbol, or opaque
    /// host value therefore fails closed before control returns to a worker.
    @MainActor
    static func copying(
        _ value: RuntimeValue,
        path: String = "output"
    ) throws -> RuntimeWorkerValueSnapshot {
        var copier = RuntimeWorkerValueCopier()
        return try copier.copy(value, path: path)
    }

    /// Re-enter the interpreter only on its owning actor. This is the inverse
    /// boundary needed when a future pure worker kernel returns a snapshot.
    @MainActor
    func materializedRuntimeValue() -> RuntimeValue {
        switch self {
        case .void:
            return .void
        case .nilValue:
            return .nilValue
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .string(let value):
            return .string(value)
        case .stringIndex(let value):
            return .native(value)
        case .url(let value):
            return .native(value)
        case .array(let values):
            return .array(values.map { $0.materializedRuntimeValue() })
        case .dictionary(let entries):
            return .dictionary(DictValue(
                keys: entries.map { $0.key.materializedRuntimeValue() },
                values: entries.map { $0.value.materializedRuntimeValue() }))
        case .tuple(let labels, let values):
            return .tuple(TupleValue(
                labels: labels,
                values: values.map { $0.materializedRuntimeValue() }))
        case .range(let lower, let upper, let includesUpperBound):
            return .range(RuntimeRangeValue(
                lowerBound: lower?.materializedRuntimeValue(),
                upperBound: upper?.materializedRuntimeValue(),
                includesUpperBound: includesUpperBound))
        case .set(let elements, let elementTypeName):
            return .set(RuntimeSetValue(
                uniqueElements: elements.map {
                    $0.materializedRuntimeValue()
                },
                elementTypeName: elementTypeName))
        case .optional(
            let wrapped, let wrappedTypeName, let isImplicitlyUnwrapped):
            return .optional(
                wrapped?.materializedRuntimeValue(),
                wrappedTypeName: wrappedTypeName,
                isImplicitlyUnwrapped: isImplicitlyUnwrapped)
        case .implicitMember(let name):
            return .implicitMember(name)
        }
    }
}

@MainActor
struct RuntimeWorkerSourceBinding {
    let name: String
    let value: RuntimeValue

    init(name: String, value: RuntimeValue) {
        self.name = name
        self.value = value
    }
}

nonisolated struct RuntimeWorkerCopiedBinding: Sendable, Equatable {
    let name: String
    let value: RuntimeWorkerValueSnapshot
}

/// The complete capability accepted by future physical-worker schedulers.
/// Its checked `Sendable` conformance is structural: no unchecked escape hatch
/// can smuggle `RuntimeHeap`, `RuntimeProgramState`, or `Interpreter` across.
nonisolated struct RuntimeWorkerCapability: Sendable {
    let entryID: RuntimeSessionID
    let entryKind: RuntimeEntry.Kind
    let programPlan: ResolvedProgramPlan?
    let programMetadata: ParsedProgramMetadata?
    let bindings: [RuntimeWorkerCopiedBinding]
    let accessManifest: RuntimeWorkerAccessManifest

    fileprivate init(
        entryID: RuntimeSessionID,
        entryKind: RuntimeEntry.Kind,
        programPlan: ResolvedProgramPlan?,
        programMetadata: ParsedProgramMetadata?,
        bindings: [RuntimeWorkerCopiedBinding],
        accessManifest: RuntimeWorkerAccessManifest
    ) {
        precondition(accessManifest.isWorkerSafe)
        self.entryID = entryID
        self.entryKind = entryKind
        self.programPlan = programPlan
        self.programMetadata = programMetadata
        self.bindings = bindings
        self.accessManifest = accessManifest
    }
}

nonisolated struct RuntimeWorkerTransferError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    let path: String
    let disposition: RuntimeHeapEdgeDisposition
    let valueKind: String

    var description: String {
        "worker transfer rejected \(valueKind) at \(path) "
            + "(\(disposition.rawValue))"
    }
}

@MainActor
private struct RuntimeWorkerValueCopier {
    private(set) var copiedPaths: [String] = []

    mutating func copy(
        _ value: RuntimeValue,
        path: String
    ) throws -> RuntimeWorkerValueSnapshot {
        copiedPaths.append(path)
        switch value {
        case .void:
            return .void
        case .nilValue:
            return .nilValue
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(try values.enumerated().map { index, value in
                try copy(value, path: "\(path)[\(index)]")
            })
        case .dictionary(let dictionary):
            guard dictionary.keys.count == dictionary.values.count else {
                throw rejection(
                    path: path, disposition: .rejectedNonSendable,
                    kind: "malformed dictionary storage")
            }
            return .dictionary(try zip(dictionary.keys, dictionary.values)
                .enumerated().map { index, pair in
                    let (key, value) = pair
                    return .init(
                        key: try copy(
                            key, path: "\(path).keys[\(index)]"),
                        value: try copy(
                            value, path: "\(path).values[\(index)]"))
                })
        case .tuple(let tuple):
            return .tuple(
                labels: tuple.labels,
                values: try tuple.values.enumerated().map { index, value in
                    try copy(value, path: "\(path)[\(index)]")
                })
        case .range(let range):
            return .range(
                lowerBound: try range.lowerBound.map {
                    try copy($0, path: "\(path).lowerBound")
                },
                upperBound: try range.upperBound.map {
                    try copy($0, path: "\(path).upperBound")
                },
                includesUpperBound: range.includesUpperBound)
        case .set(let set):
            return .set(
                elements: try set.elements.enumerated().map { index, value in
                    try copy(value, path: "\(path)[\(index)]")
                },
                elementTypeName: set.elementTypeName)
        case .optional(let optional):
            return .optional(
                wrapped: try optional.wrapped.map {
                    try copy($0, path: "\(path).some")
                },
                wrappedTypeName: optional.wrappedTypeName,
                isImplicitlyUnwrapped: optional.isImplicitlyUnwrapped)
        case .implicitMember(let name):
            return .implicitMember(name)
        case .host(let value):
            if let index = value as? String.Index {
                return .stringIndex(index)
            }
            if let url = value as? URL {
                return .url(url)
            }
            throw rejection(
                path: path, disposition: .rejectedNonSendable,
                kind: "opaque host value")
        case .instance(let instance):
            throw rejection(
                path: path,
                disposition: instance.symbol.isActor
                    ? .actorConfined : .mainActorConfined,
                kind: instance.symbol.isActor
                    ? "interpreted actor instance" : "interpreted instance")
        case .closure:
            throw rejection(
                path: path, disposition: .mainActorConfined,
                kind: "source closure")
        case .hostFunction:
            throw rejection(
                path: path, disposition: .mainActorConfined,
                kind: "host function")
        case .type:
            throw rejection(
                path: path, disposition: .mainActorConfined,
                kind: "interpreted nominal symbol")
        case .enumType:
            throw rejection(
                path: path, disposition: .mainActorConfined,
                kind: "interpreted enum symbol")
        case .enumCase:
            throw rejection(
                path: path, disposition: .mainActorConfined,
                kind: "interpreted enum value")
        }
    }

    private func rejection(
        path: String,
        disposition: RuntimeHeapEdgeDisposition,
        kind: String
    ) -> RuntimeWorkerTransferError {
        RuntimeWorkerTransferError(
            path: path, disposition: disposition, valueKind: kind)
    }
}

extension RuntimeEntry {
    /// Project one MainActor-confined entry into a checked-Sendable worker
    /// capability. Failure is atomic: no capability is returned unless every
    /// nested RuntimeValue edge has been copied successfully.
    func makeWorkerCapability(
        copying sourceBindings: [RuntimeWorkerSourceBinding]
    ) throws -> RuntimeWorkerCapability {
        var copier = RuntimeWorkerValueCopier()
        let bindings = try sourceBindings.map { binding in
            RuntimeWorkerCopiedBinding(
                name: binding.name,
                value: try copier.copy(
                    binding.value, path: "input.\(binding.name)"))
        }
        let manifest = RuntimeWorkerAccessManifest(
            entryEdges: [
                .init(
                    edge: .entryIdentity,
                    disposition: .immutableSendable,
                    treatment: .retained),
                .init(
                    edge: .programPlan,
                    disposition: .immutableSendable,
                    treatment: .retained),
                .init(
                    edge: .programMetadata,
                    disposition: .immutableSendable,
                    treatment: .retained),
                .init(
                    edge: .heap,
                    disposition: .mainActorConfined,
                    treatment: .excluded),
                .init(
                    edge: .programState,
                    disposition: .mainActorConfined,
                    treatment: .excluded),
                .init(
                    edge: .interpreter,
                    disposition: .mainActorConfined,
                    treatment: .excluded),
            ],
            heapEdges: RuntimeWorkerHeapEdge.allCases.map {
                .init(
                    edge: $0,
                    disposition: .mainActorConfined,
                    treatment: .excluded)
            },
            copiedValuePaths: copier.copiedPaths)
        return RuntimeWorkerCapability(
            entryID: id,
            entryKind: kind,
            programPlan: programPlan,
            programMetadata: programMetadata,
            bindings: bindings,
            accessManifest: manifest)
    }
}
