import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SwiftInterpreter

private enum ParityMode: String, Decodable {
    case runtime
    case diagnostic
}

private enum ParityAssertionKind: String, Decodable {
    case exact
    case allowedSet = "allowed-set"
    case partialOrder = "partial-order"
    case predicate
    case runtimeTrap = "runtime-trap"
    case diagnostic
    case interpreterDiagnostic = "interpreter-diagnostic"
    case stress
}

private struct ConcurrencyParityCase: Decodable {
    let id: String
    let fixture: String
    let mode: ParityMode
    let assertion: ParityAssertionKind
    let repetitions: Int
    let timeoutSeconds: TimeInterval
    let interpreterEntry: String?
    let interpreterProjection: String?
    let allowedOutputs: [String]?
    let requiredEvents: [String]?
    let precedes: [[String]]?
    let predicate: String?
    let nativeTrapContains: [String]?
    let interpreterTrapContains: [String]?
    let diagnosticContains: [String]?
    let diagnosticLine: Int?
    let interpreterDiagnosticContains: [String]?
    let nativeFact: String
    let notes: String
}

private struct ParityProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool
}

private struct InterpretedParityObservation: Codable, Equatable {
    enum Kind: String, Codable {
        case value
        case runtimeError
    }

    let kind: Kind
    let text: String
}

private struct InterpretedParityChildReceipt: Codable, Equatable {
    let version: Int
    let caseID: String
    let processIdentifier: Int32
    let observation: InterpretedParityObservation
}

private struct ConcurrencyParityShard {
    let index: Int
    let count: Int
    let cases: [ConcurrencyParityCase]
}

private struct ConcurrencyParityShardReceipt: Encodable {
    let version: Int
    let shardIndex: Int
    let shardCount: Int
    let selectedCount: Int
    let completedCount: Int
    let selectedIDs: [String]
    let completedIDs: [String]
    let selectedRepetitionsByCase: [String: Int]
    let completedRepetitionsByCase: [String: Int]
    let nativeObservationSHA256ByCase: [String: String]
}

private struct RecordedOpenConcurrencyGap: Decodable {
    let id: String
    let requirementRef: String
    let kind: String
    let expectedObservation: String
    let currentObservation: String
    let reproductionTest: String?
    let parityCase: ConcurrencyParityCase?
}

private struct ParityProcessIdentity: Equatable {
    let identifier: pid_t
    let startToken: String
}

private struct ConcurrencyToolchainFingerprint: CustomStringConvertible {
    let swiftcPath: String
    let swiftVersion: String
    let sdkPath: String
    let sdkVersion: String

    var description: String {
        "swiftc=\(swiftcPath) | \(swiftVersion) | sdk=\(sdkVersion) \(sdkPath)"
    }
}

/// Test host carrier: the callback payload is consumed only by its MainActor
/// method. `Task.detached` crosses the native task-local boundary while all
/// interpreter access remains actor-confined.
private struct DetachedHostCallback: @unchecked Sendable {
    let context: EvalContext
    let closure: ClosureValue

    @MainActor
    func call() async throws -> RuntimeValue {
        try await context.callClosureAsync(closure, arguments: [])
    }
}

/// Opaque test carriers stand in for an SDK-owned AsyncSequence and iterator.
/// Their only source-visible surface is the typed HostRegistry contract below.
private final class ParityHostAsyncSequenceCarrier {}

private final class ParityHostAsyncIteratorCarrier {
    var index = 0
}

private final class ParityHostAsyncSequenceRegistry: HostRegistry {
    weak var interpreter: Interpreter?
    private let makeIteratorSignature: HostSignature
    private let nextSignature: HostSignature
    private(set) var nextCallCount = 0
    private(set) var trackedNextCallCount = 0

    init() throws {
        makeIteratorSignature = try HostSignature(parsing:
            "func ParityHostAsyncSequence.makeAsyncIterator() -> ParityHostAsyncIterator")
        nextSignature = try HostSignature(parsing:
            "mutating func ParityHostAsyncIterator.next() async -> Int?")
    }

    func hostMember(_ name: String, on value: Any) -> RuntimeValue? {
        if name == "makeAsyncIterator",
           value is ParityHostAsyncSequenceCarrier,
           let function = try? HostFunction(
                signature: makeIteratorSignature,
                invoke: { _, _ in
                    .native(ParityHostAsyncIteratorCarrier())
                }) {
            return .hostFunction(function)
        }
        if name == "next",
           let iterator = value as? ParityHostAsyncIteratorCarrier,
           let function = try? HostFunction(
                signature: nextSignature,
                asyncInvoke: { [weak self] _, _ in
                    guard let self, let interpreter = self.interpreter else {
                        throw RuntimeError(message:
                            "host AsyncSequence registry lost its interpreter")
                    }
                    self.nextCallCount += 1
                    if interpreter.concurrencyRuntime
                        .activeHostOperationCount == 1 {
                        self.trackedNextCallCount += 1
                    }
                    await Task.yield()
                    let values = [2, 4, 6]
                    guard iterator.index < values.count else {
                        return .none(wrappedTypeName: "Int")
                    }
                    let value = values[iterator.index]
                    iterator.index += 1
                    return .some(.native(value), wrappedTypeName: "Int")
                }) {
            return .hostFunction(function)
        }
        return nil
    }

    func hostMethod(_ name: String, on value: Any) -> RuntimeValue? {
        hostMember(name, on: value)
    }

    func hostTypeName(of value: Any) -> String? {
        if value is ParityHostAsyncSequenceCarrier {
            return "ParityHostAsyncSequence"
        }
        if value is ParityHostAsyncIteratorCarrier {
            return "ParityHostAsyncIterator"
        }
        return nil
    }

    func hostProtocolCandidates(of value: Any) -> [String] {
        if value is ParityHostAsyncSequenceCarrier {
            return ["AsyncSequence"]
        }
        if value is ParityHostAsyncIteratorCarrier {
            return ["AsyncIteratorProtocol"]
        }
        return []
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private enum ConcurrencyParityHarness {
    private static let childCaseEnvironmentVariable =
        "DYNAMIC_SWIFT_PARITY_CHILD_CASE_ID"
    private static let childOutputEnvironmentVariable =
        "DYNAMIC_SWIFT_PARITY_CHILD_OUTPUT_PATH"
    private static let focusedRepetitionsEnvironmentVariable =
        "DYNAMIC_SWIFT_PARITY_FOCUSED_REPETITIONS"
    private static let shardSummaryPrefix = "@@concurrency-parity-summary "

    static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static let parityRoot = packageRoot
        .appendingPathComponent("Tests/ConcurrencyParity", isDirectory: true)

    static func loadCases() throws -> [ConcurrencyParityCase] {
        let url = parityRoot.appendingPathComponent(
            "Manifests/parity-cases.json")
        return try JSONDecoder().decode(
            [ConcurrencyParityCase].self, from: Data(contentsOf: url))
    }

    static func loadOpenGaps() throws -> [RecordedOpenConcurrencyGap] {
        let url = parityRoot.appendingPathComponent(
            "Manifests/open-gaps.json")
        return try JSONDecoder().decode(
            [RecordedOpenConcurrencyGap].self, from: Data(contentsOf: url))
    }

    /// `Scripts/gate.sh` runs this long native/interpreter differential test
    /// in independent processes. A normal focused `swift test` has no shard
    /// environment and continues to cover the complete manifest.
    static func selectRuntimeShard(
        from cases: [ConcurrencyParityCase]
    ) throws -> [ConcurrencyParityCase] {
        try runtimeShard(from: cases).cases
    }

    static func runtimeShard(
        from cases: [ConcurrencyParityCase]
    ) throws -> ConcurrencyParityShard {
        let environment = ProcessInfo.processInfo.environment
        let rawIndex = environment["DYNAMIC_SWIFT_PARITY_SHARD_INDEX"]
        let rawCount = environment["DYNAMIC_SWIFT_PARITY_SHARD_COUNT"]
        guard rawIndex != nil || rawCount != nil else {
            return ConcurrencyParityShard(index: 0, count: 1, cases: cases)
        }
        guard let rawIndex, let rawCount,
              let index = Int(rawIndex), let count = Int(rawCount),
              count > 0, index >= 0, index < count else {
            throw RuntimeError(message:
                "parity shard environment requires 0 <= index < positive count")
        }
        return ConcurrencyParityShard(
            index: index,
            count: count,
            cases: try selectShard(from: cases, index: index, count: count))
    }

    static func selectShard(
        from cases: [ConcurrencyParityCase],
        index: Int,
        count: Int
    ) throws -> [ConcurrencyParityCase] {
        guard count > 0, index >= 0, index < count else {
            throw RuntimeError(message:
                "parity shard requires 0 <= index < positive count")
        }
        return cases.enumerated().compactMap { offset, parityCase in
            offset % count == index ? parityCase : nil
        }
    }

    static func effectiveRepetitionCount(
        manifestCount: Int,
        overrideValue: String?
    ) throws -> Int {
        let boundedManifestCount = max(1, manifestCount)
        guard let overrideValue else { return boundedManifestCount }
        guard let overrideCount = Int(overrideValue),
              overrideCount > 0,
              overrideCount <= boundedManifestCount else {
            throw RuntimeError(message:
                "focused parity repetitions must be in 1..."
                    + "\(boundedManifestCount), got '\(overrideValue)'")
        }
        return overrideCount
    }

    static func focusedRepetitionCount(
        for parityCase: ConcurrencyParityCase
    ) throws -> Int {
        try effectiveRepetitionCount(
            manifestCount: parityCase.repetitions,
            overrideValue: ProcessInfo.processInfo.environment[
                focusedRepetitionsEnvironmentVariable])
    }

    static var hasFocusedRepetitionOverride: Bool {
        ProcessInfo.processInfo.environment[
            focusedRepetitionsEnvironmentVariable] != nil
    }

    static func fingerprint() throws -> ConcurrencyToolchainFingerprint {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let swiftc = try successful(
            run(xcrun, ["--find", "swiftc"], timeout: 10),
            operation: "locate swiftc").standardOutput.trimmed
        let version = try successful(
            run(URL(fileURLWithPath: swiftc), ["--version"], timeout: 10),
            operation: "read swiftc version").standardOutput.trimmed
        let sdkPath = try successful(
            run(xcrun, ["--show-sdk-path", "--sdk", "macosx"], timeout: 10),
            operation: "locate macOS SDK").standardOutput.trimmed
        let sdkVersion = try successful(
            run(xcrun, ["--show-sdk-version", "--sdk", "macosx"], timeout: 10),
            operation: "read macOS SDK version").standardOutput.trimmed
        return ConcurrencyToolchainFingerprint(
            swiftcPath: swiftc,
            swiftVersion: version.replacingOccurrences(of: "\n", with: " | "),
            sdkPath: sdkPath,
            sdkVersion: sdkVersion)
    }

    static func nativeOutputs(
        for parityCase: ConcurrencyParityCase,
        repetitions: Int? = nil
    ) throws -> [String] {
        let directory = try makeTemporaryDirectory(for: parityCase.id)
        defer { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("probe")
        let fixture = parityRoot.appendingPathComponent(parityCase.fixture)
        let wrapper = parityRoot.appendingPathComponent("Support/NativeMain.swift")
        let compile = run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-parse-as-library",
                fixture.path,
                wrapper.path,
                "-o", binary.path,
            ],
            timeout: 30)
        _ = try successful(compile, operation: "compile \(parityCase.id)")

        var outputs: [String] = []
        let repetitionCount = max(1, repetitions ?? parityCase.repetitions)
        for repetition in 0..<repetitionCount {
            let execution = run(
                binary, [], timeout: parityCase.timeoutSeconds)
            if parityCase.assertion == .runtimeTrap {
                try validateRuntimeTrap(
                    execution,
                    requiredFragments: parityCase.nativeTrapContains,
                    operation: "run native trap \(parityCase.id) repetition "
                        + "\(repetition + 1)/\(repetitionCount)")
                outputs.append("runtime-trap")
                continue
            }
            let successfulExecution = try successful(
                execution,
                operation: "run \(parityCase.id) repetition "
                    + "\(repetition + 1)/\(repetitionCount)")
            outputs.append(successfulExecution.standardOutput.trimmed)
        }
        return outputs
    }

    static func diagnostic(
        for parityCase: ConcurrencyParityCase
    ) -> ParityProcessResult {
        let fixture = parityRoot.appendingPathComponent(parityCase.fixture)
        return run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-typecheck",
                fixture.path,
            ],
            timeout: parityCase.timeoutSeconds)
    }

    static func interpretedOutputs(
        for parityCase: ConcurrencyParityCase,
        repetitions: Int? = nil
    ) throws -> [String] {
        try interpretedObservations(
            for: parityCase,
            repetitions: repetitions).map { observation in
                guard observation.kind == .value else {
                    throw RuntimeError(message:
                        "interpreted parity case '\(parityCase.id)' "
                            + "produced an unexpected runtime diagnostic: "
                            + observation.text)
                }
                return observation.text
            }
    }

    static func interpretedObservations(
        for parityCase: ConcurrencyParityCase,
        repetitions: Int? = nil
    ) throws -> [InterpretedParityObservation] {
        guard !isInterpretedChild else {
            throw RuntimeError(message:
                "an interpreted parity child cannot recursively launch another child")
        }
        let helper = try testingHelperURL()
        let testBundle = try testBundleExecutableURL()
        var observations: [InterpretedParityObservation] = []
        var childProcessIdentifiers: Set<Int32> = []
        let repetitionCount = max(1, repetitions ?? parityCase.repetitions)
        for repetition in 0..<repetitionCount {
            let directory = try makeTemporaryDirectory(
                for: "interpreted-\(parityCase.id)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let receiptURL = directory.appendingPathComponent("receipt.json")
            var environment = ProcessInfo.processInfo.environment
            environment[childCaseEnvironmentVariable] = parityCase.id
            environment[childOutputEnvironmentVariable] = receiptURL.path
            let execution = run(
                helper,
                [
                    "--test-bundle-path", testBundle.path,
                    "--skip-build",
                    "--no-parallel",
                    "--filter",
                    "SwiftInterpreterTests.ConcurrencyParityTests/interpretedParityChild",
                    testBundle.path,
                    "--testing-library", "swift-testing",
                ],
                timeout: parityCase.timeoutSeconds,
                environment: environment)
            if parityCase.assertion == .runtimeTrap {
                try validateRuntimeTrap(
                    execution,
                    requiredFragments: parityCase.interpreterTrapContains,
                    operation: "run interpreted trap \(parityCase.id) repetition "
                        + "\(repetition + 1)/\(repetitionCount)")
                observations.append(.init(
                    kind: .runtimeError,
                    text: "runtime-trap"))
                continue
            }
            _ = try successful(
                execution,
                operation: "run interpreted parity child \(parityCase.id) "
                    + "repetition \(repetition + 1)/\(repetitionCount)")
            guard FileManager.default.fileExists(atPath: receiptURL.path) else {
                throw RuntimeError(message:
                    "interpreted parity child '\(parityCase.id)' exited without a receipt")
            }
            let receipt = try JSONDecoder().decode(
                InterpretedParityChildReceipt.self,
                from: Data(contentsOf: receiptURL))
            guard receipt.version == 2,
                  receipt.caseID == parityCase.id,
                  receipt.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  childProcessIdentifiers.insert(receipt.processIdentifier).inserted else {
                throw RuntimeError(message:
                    "interpreted parity child '\(parityCase.id)' wrote an invalid receipt")
            }
            observations.append(receipt.observation)
        }
        return observations
    }

    static var isInterpretedChild: Bool {
        ProcessInfo.processInfo.environment[childCaseEnvironmentVariable] != nil
            || ProcessInfo.processInfo.environment[childOutputEnvironmentVariable] != nil
    }

    static func interpretedChildRequest() throws -> (
        parityCase: ConcurrencyParityCase,
        outputURL: URL
    )? {
        let environment = ProcessInfo.processInfo.environment
        let caseID = environment[childCaseEnvironmentVariable]
        let outputPath = environment[childOutputEnvironmentVariable]
        guard caseID != nil || outputPath != nil else { return nil }
        guard let caseID, !caseID.isEmpty,
              let outputPath, !outputPath.isEmpty else {
            throw RuntimeError(message:
                "interpreted parity child requires both its case ID and output path")
        }
        let openGapCases = try loadOpenGaps().compactMap(\.parityCase)
        let matches = try (loadCases() + openGapCases).filter {
            $0.mode == .runtime && $0.id == caseID
        }
        guard matches.count == 1, let parityCase = matches.first else {
            throw RuntimeError(message:
                "interpreted parity child requested unknown or duplicate case '\(caseID)'")
        }
        return (parityCase, URL(fileURLWithPath: outputPath))
    }

    static func writeInterpretedChildReceipt(
        caseID: String,
        observation: InterpretedParityObservation,
        to outputURL: URL
    ) throws {
        let receipt = InterpretedParityChildReceipt(
            version: 2,
            caseID: caseID,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            observation: observation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: outputURL, options: .atomic)
    }

    @MainActor
    static func interpretedOutput(
        for parityCase: ConcurrencyParityCase
    ) async throws -> String {
        guard let entry = parityCase.interpreterEntry,
              let projection = parityCase.interpreterProjection else {
            throw RuntimeError(message:
                "runtime parity case '\(parityCase.id)' needs an interpreter entry and projection")
        }
        let fixture = parityRoot.appendingPathComponent(parityCase.fixture)
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\n" + entry + "\n"
        let hostSequenceRegistry = try ParityHostAsyncSequenceRegistry()
        let interpreter = Interpreter(registry: hostSequenceRegistry)
        hostSequenceRegistry.interpreter = interpreter
        var waitStarted = false
        var expectedDetachedContextID: UInt64?
        var hostGatewayEvents: [String] = []
        var hostGatewayStarted = false
        var hostGatewayOpen = false
        var taskValueGateStarted = false
        var taskValueGateOpen = false
        var taskValueWaiterCount = 0
        var registeredTaskValueSource: RuntimeTaskHandle?
        var sleepStarted = false
        var actorMessageSuspended = false
        var actorMessageMayResume = false
        var actorQueueGateActorID: RuntimeActorID?
        var actorQueueGateTask: RuntimeTaskRecord?
        var actorQueueGateLease: RuntimeActorExecutorLease?
        var priorityEscalationEvents: [String] = []
        var taskLocalStorageByTask: [
            RuntimeTaskID: RuntimeTaskLocalStorage
        ] = [:]
        var taskLocalRecordStorageMatched = true
        let parityTaskLocalKey = RuntimeTaskLocalKey(
            rawValue: "ConcurrencyParity.value")
        interpreter.globals.define(
            "parityHostAsyncSequence",
            .hostFunction(try HostFunction(
                declaration:
                    "func parityHostAsyncSequence() -> ParityHostAsyncSequence"
            ) { _, _ in
                .native(ParityHostAsyncSequenceCarrier())
            }))
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, _ in
                await Task.yield()
                return arguments.positional(0) ?? .nilValue
            }
        )))
        interpreter.globals.define(
            "parityRecordPriorityEscalationEvent",
            .hostFunction(HostFunction(
                name: "parityRecordPriorityEscalationEvent"
            ) { arguments, _ in
                priorityEscalationEvents.append(
                    arguments.positional(0)?.stringValue ?? "?")
                return .void
            }))
        interpreter.globals.define(
            "parityPriorityEscalationEvents",
            .hostFunction(HostFunction(
                name: "parityPriorityEscalationEvents"
            ) { _, _ in
                .native(priorityEscalationEvents.sorted().joined(separator: ","))
            }))
        interpreter.globals.define(
            "parityCurrentExecutorLane",
            .hostFunction(HostFunction(
                name: "parityCurrentExecutorLane"
            ) { _, context in
                .native(context.sourceExecutor.isMainActor ? "main" : "worker")
            }))
        interpreter.globals.define(
            "parityCurrentIsolationKind",
            .hostFunction(HostFunction(
                name: "parityCurrentIsolationKind"
            ) { _, _ in
                let isolation = try interpreter.currentSourceIsolationValue()
                return .native(isolation.isNil ? "none" : "actor")
            }))
        interpreter.globals.define(
            "parityCurrentIsolationMatches",
            .hostFunction(HostFunction(
                name: "parityCurrentIsolationMatches"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let expectedID = expected.actorID,
                      let actualID = context.sourceExecutor.actorID else {
                    return .native("none")
                }
                return .native(actualID == expectedID ? "same" : "other")
            }))
        interpreter.globals.define(
            "parityActorSegmentOwnership",
            .hostFunction(HostFunction(
                name: "parityActorSegmentOwnership"
            ) { arguments, context in
                guard case .instance(let expected)? = arguments.positional(0),
                      let actorID = expected.actorID,
                      context.sourceExecutor.actorID == actorID,
                      let taskID = interpreter.evaluationTaskContext
                        .runtimeTaskID else {
                    return .native("unowned")
                }
                let owner = interpreter.concurrencyRuntime.actors[actorID]?
                    .executorOwnerTaskID
                return .native(owner == taskID ? "owned" : "unowned")
            }))
        interpreter.globals.define(
            "paritySuspendActorMessage",
            .hostFunction(HostFunction(
                name: "paritySuspendActorMessage",
                asyncInvoke: { _, _ in
                    actorMessageSuspended = true
                    while !actorMessageMayResume {
                        await Task.yield()
                    }
                    return .void
                })))
        interpreter.globals.define(
            "parityAwaitActorMessageSuspension",
            .hostFunction(HostFunction(
                name: "parityAwaitActorMessageSuspension",
                asyncInvoke: { _, _ in
                    while !actorMessageSuspended {
                        await Task.yield()
                    }
                    return .void
                })))
        interpreter.globals.define(
            "parityResumeActorMessage",
            .hostFunction(HostFunction(
                name: "parityResumeActorMessage",
                asyncInvoke: { _, _ in
                    actorMessageMayResume = true
                    return .void
                })))
        interpreter.globals.define(
            "parityBlockActorUntilReleased",
            .hostFunction(HostFunction(
                name: "parityBlockActorUntilReleased"
            ) { _, context in
                guard let actorID = context.sourceExecutor.actorID else {
                    throw RuntimeError(message:
                        "actor queue gate requires actor-isolated entry")
                }
                guard actorQueueGateActorID == nil
                        || actorQueueGateActorID == actorID else {
                    throw RuntimeError(message:
                        "actor queue gate cannot hold multiple actors")
                }
                actorQueueGateActorID = actorID
                return .void
            }))
        interpreter.globals.define(
            "parityAwaitActorBlockEntered",
            .hostFunction(HostFunction(
                name: "parityAwaitActorBlockEntered",
                asyncInvoke: { _, _ in
                    while actorQueueGateActorID == nil {
                        await Task.yield()
                    }
                    guard actorQueueGateTask == nil,
                          actorQueueGateLease == nil,
                          let actorID = actorQueueGateActorID,
                          let ownerID = interpreter.evaluationTaskContext
                            .runtimeTaskID,
                          let owner = interpreter.concurrencyRuntime
                            .records[ownerID] else {
                        throw RuntimeError(message:
                            "actor queue gate entered an invalid state")
                    }
                    let blocker = interpreter.concurrencyRuntime.createTask(
                        sessionID: owner.sessionID,
                        kind: .unstructured,
                        parent: nil,
                        priority: owner.effectivePriority,
                        executorPreference: .actor(actorID),
                        taskLocals: RuntimeTaskLocalStorage(),
                        name: "parity-actor-queue-blocker")
                    guard interpreter.concurrencyRuntime.begin(blocker) else {
                        throw RuntimeError(message:
                            "actor queue blocker did not start")
                    }
                    actorQueueGateTask = blocker
                    do {
                        actorQueueGateLease = try await interpreter
                            .concurrencyRuntime.acquireActorExecutor(
                                actorID, for: blocker.id)
                    } catch {
                        interpreter.concurrencyRuntime.fail(
                            blocker, with: error)
                        interpreter.concurrencyRuntime.release(blocker.id)
                        actorQueueGateTask = nil
                        throw error
                    }
                    return .void
                })))
        interpreter.globals.define(
            "parityReleaseActorBlock",
            .hostFunction(HostFunction(
                name: "parityReleaseActorBlock"
            ) { _, _ in
                guard let blocker = actorQueueGateTask,
                      let lease = actorQueueGateLease else {
                    throw RuntimeError(message:
                        "actor queue gate was not holding an actor")
                }
                interpreter.concurrencyRuntime.releaseActorExecutor(lease)
                interpreter.concurrencyRuntime.succeed(blocker, with: .void)
                interpreter.concurrencyRuntime.release(blocker.id)
                actorQueueGateLease = nil
                actorQueueGateTask = nil
                return .void
            }))
        interpreter.globals.define(
            "parityRecordHostGatewayEvent",
            .hostFunction(HostFunction(
                name: "parityRecordHostGatewayEvent"
            ) { arguments, _ in
                hostGatewayEvents.append(
                    arguments.positional(0)?.stringValue ?? "?")
                return .void
            }))
        interpreter.globals.define(
            "parityHostGatewayValue",
            .hostFunction(HostFunction(
                name: "parityHostGatewayValue",
                asyncInvoke: { arguments, _ in
                    hostGatewayEvents.append("host-enter")
                    hostGatewayStarted = true
                    while !hostGatewayOpen { await Task.yield() }
                    hostGatewayEvents.append("host-exit")
                    return arguments.positional(0) ?? .nilValue
                })))
        interpreter.globals.define(
            "parityAwaitHostGatewayStarted",
            .hostFunction(HostFunction(
                name: "parityAwaitHostGatewayStarted",
                asyncInvoke: { _, _ in
                    while !hostGatewayStarted { await Task.yield() }
                    return .void
                })))
        interpreter.globals.define(
            "parityOpenHostGateway",
            .hostFunction(HostFunction(
                name: "parityOpenHostGateway"
            ) { _, _ in
                hostGatewayOpen = true
                return .void
            }))
        interpreter.globals.define(
            "parityHostGatewayEvents",
            .hostFunction(HostFunction(
                name: "parityHostGatewayEvents"
            ) { _, _ in
                .native(hostGatewayEvents.joined(separator: ","))
            }))
        interpreter.globals.define("parityReadTaskLocal", .hostFunction(HostFunction(
            name: "parityReadTaskLocal",
            asyncInvoke: { _, context in
                guard let bound = context as? TaskBoundEvalContext,
                      let taskID = bound.evaluationContext.runtimeTaskID,
                      let record = interpreter.concurrencyRuntime
                        .records[taskID] else {
                    throw RuntimeError(message:
                        "task-local read requires a runtime task context")
                }
                let storage = bound.evaluationContext.taskLocals
                taskLocalStorageByTask[taskID] = storage
                taskLocalRecordStorageMatched = taskLocalRecordStorageMatched
                    && record.taskLocals === storage
                return context.taskLocalValue(for: parityTaskLocalKey)
                    ?? .native("default")
            }
        )))
        interpreter.globals.define("parityWithTaskLocalValue", .hostFunction(HostFunction(
            name: "parityWithTaskLocalValue",
            asyncInvoke: { arguments, context in
                guard let operation = arguments.firstUnlabeledClosure else {
                    throw RuntimeError(message:
                        "parityWithTaskLocalValue requires an operation closure")
                }
                guard let value = arguments.positional(0) else {
                    throw RuntimeError(message:
                        "parityWithTaskLocalValue requires a value")
                }
                return try await context.withTaskLocalValue(
                    value,
                    for: parityTaskLocalKey,
                    operation: operation,
                    arguments: [])
            }
        )))
        interpreter.globals.define("parityWaitForever", .hostFunction(HostFunction(
            name: "parityWaitForever",
            asyncInvoke: { _, _ in
                waitStarted = true
                try await Task.sleep(for: .seconds(30))
                return .void
            }
        )))
        interpreter.globals.define("parityAwaitWaitStarted", .hostFunction(HostFunction(
            name: "parityAwaitWaitStarted",
            asyncInvoke: { _, _ in
                while !waitStarted { await Task.yield() }
                return .void
            }
        )))
        interpreter.globals.define("parityDetachedInheritance", .hostFunction(HostFunction(
            name: "parityDetachedInheritance",
            asyncInvoke: { _, _ in
                let inherited = await Task.detached { @MainActor in
                    EvaluationTaskContext.current != nil
                }.value
                return .native(inherited ? "inherited" : "lost")
            }
        )))
        interpreter.globals.define("parityDetachedReentry", .hostFunction(HostFunction(
            name: "parityDetachedReentry",
            asyncInvoke: { arguments, context in
                guard let closure = arguments.firstUnlabeledClosure,
                      let bound = context as? TaskBoundEvalContext else {
                    throw RuntimeError(message:
                        "detached re-entry requires a task-bound closure context")
                }
                expectedDetachedContextID = bound.evaluationTaskContextID
                let callback = DetachedHostCallback(
                    context: context, closure: closure)
                return try await Task.detached {
                    try await callback.call()
                }.value
            }
        )))
        interpreter.globals.define("parityCheckContext", .hostFunction(HostFunction(
            name: "parityCheckContext",
            asyncInvoke: { _, context in
                guard let bound = context as? TaskBoundEvalContext else {
                    return .native("wrong")
                }
                return .native(
                    bound.evaluationTaskContextID == expectedDetachedContextID
                        ? "preserved" : "wrong")
            }
        )))
        interpreter.globals.define("parityWaitTaskValueGate", .hostFunction(HostFunction(
            name: "parityWaitTaskValueGate",
            asyncInvoke: { _, _ in
                taskValueGateStarted = true
                while !taskValueGateOpen { await Task.yield() }
                return .void
            }
        )))
        interpreter.globals.define("parityAwaitTaskValueGateStarted", .hostFunction(HostFunction(
            name: "parityAwaitTaskValueGateStarted",
            asyncInvoke: { _, _ in
                while !taskValueGateStarted { await Task.yield() }
                return .void
            }
        )))
        interpreter.globals.define("parityOpenTaskValueGate", .hostFunction(HostFunction(
            name: "parityOpenTaskValueGate"
        ) { _, _ in
            taskValueGateOpen = true
            return .void
        }))
        interpreter.globals.define("parityRegisterTaskValueSource", .hostFunction(HostFunction(
            name: "parityRegisterTaskValueSource"
        ) { arguments, _ in
            registeredTaskValueSource =
                arguments.positional(0)?.hostPayload as? RuntimeTaskHandle
            return .void
        }))
        interpreter.globals.define("parityMarkTaskValueWaiter", .hostFunction(HostFunction(
            name: "parityMarkTaskValueWaiter"
        ) { _, _ in
            taskValueWaiterCount += 1
            return .void
        }))
        interpreter.globals.define("parityAwaitTaskValueWaiters", .hostFunction(HostFunction(
            name: "parityAwaitTaskValueWaiters",
            asyncInvoke: { _, _ in
                while taskValueWaiterCount < 2
                    || registeredTaskValueSource?.waiterCount != 2 {
                    await Task.yield()
                }
                return .void
            }
        )))
        interpreter.globals.define("parityMarkSleepStarted", .hostFunction(HostFunction(
            name: "parityMarkSleepStarted"
        ) { _, _ in
            sleepStarted = true
            return .void
        }))
        interpreter.globals.define("parityCancelWhenSleepStarted", .hostFunction(HostFunction(
            name: "parityCancelWhenSleepStarted",
            asyncInvoke: { arguments, _ in
                guard let handle = arguments.positional(0)?.hostPayload
                        as? RuntimeTaskHandle else {
                    throw RuntimeError(message:
                        "sleep cancellation helper requires a task handle")
                }
                while !sleepStarted { await Task.yield() }
                handle.cancel()
                return .void
            }
        )))
        let value = try await interpreter.runAsync(source: source)

        var externalProjectionOutput: String?
        if projection.hasPrefix("host-callback-global-string:") {
            let fields = projection.dropFirst(
                "host-callback-global-string:".count
            ).split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2,
                  let closure = value.closureValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' did not return a host callback closure")
            }
            func projectedString() throws -> String {
                guard case .instance(let instance)? = interpreter.globals.lookup(
                    fields[0]),
                      let string = instance.box(for: fields[1])?.value.stringValue else {
                    throw RuntimeError(message:
                        "case '\(parityCase.id)' did not expose String '\(fields[0]).\(fields[1])'")
                }
                return string
            }

            _ = try interpreter.callHostCallback(closure, arguments: [])
            let immediate = try projectedString()
            for _ in 0..<10_000
            where !interpreter.scheduledTasks.isEmpty
                || interpreter.concurrencyRuntime.activeRecordCount != 0 {
                await Task.yield()
            }
            externalProjectionOutput = immediate + "," + (try projectedString())
        }

        guard actorQueueGateTask == nil,
              actorQueueGateLease == nil,
              interpreter.scheduledTasks.isEmpty,
              interpreter.concurrencyRuntime.activeRecordCount == 0,
              interpreter.concurrencyRuntime.activeStructuredScopeCount == 0,
              interpreter.concurrencyRuntime.activeTaskGroupCount == 0,
              interpreter.concurrencyRuntime.activeAsyncStreamCount == 0,
              interpreter.concurrencyRuntime.activeHostOperationCount == 0
        else {
            throw RuntimeError(message:
                "case '\(parityCase.id)' leaked task/scope/group/stream/host runtime ownership")
        }

        if hostSequenceRegistry.nextCallCount > 0 {
            guard hostSequenceRegistry.nextCallCount == 4,
                  hostSequenceRegistry.trackedNextCallCount == 4 else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' did not route every host iterator next() through a tracked suspension")
            }
        }

        if !taskLocalStorageByTask.isEmpty {
            let distinctStorageCount = Set(
                taskLocalStorageByTask.values.map(ObjectIdentifier.init)
            ).count
            guard distinctStorageCount == taskLocalStorageByTask.count,
                  taskLocalRecordStorageMatched,
                  taskLocalStorageByTask.values.allSatisfy({ $0.isEmpty }),
                  interpreter.concurrencyRuntime.activeRecordCount == 0 else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' violated task-local ownership or cleanup")
            }
        }

        if let externalProjectionOutput {
            return externalProjectionOutput
        }

        if projection == "string" {
            guard let string = value.stringValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' returned \(value.stringified), expected String")
            }
            return string
        }
        if projection.hasPrefix("instance-string-array:") {
            let property = String(projection.dropFirst(
                "instance-string-array:".count))
            guard case .instance(let instance) = value,
                  let elements = instance.box(for: property)?.value.arrayValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' did not return an instance [String] property '\(property)'")
            }
            return elements.compactMap(\.stringValue).joined(separator: ",")
        }
        if projection.hasPrefix("instance-task-state-and-string-array:") {
            let fields = projection.dropFirst(
                "instance-task-state-and-string-array:".count)
                .split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2,
                  case .instance(let instance) = value,
                  let taskValue = instance.box(for: fields[0])?.value
                    .unwrappedOptionalOrSelf,
                  case .host(let payload) = taskValue,
                  let handle = payload as? RuntimeTaskHandle,
                  let elements = instance.box(for: fields[1])?.value.arrayValue else {
                throw RuntimeError(message:
                    "case '\(parityCase.id)' did not return the expected task and [String] properties")
            }
            let events = elements.compactMap(\.stringValue).joined(separator: ",")
            return handle.state.rawValue + "," + events
        }
        throw RuntimeError(message:
            "unknown interpreter projection '\(projection)' for '\(parityCase.id)'")
    }

    static func violations(
        assertion: ParityAssertionKind,
        native: [String],
        interpreted: [String],
        allowedOutputs: [String]? = nil,
        requiredEvents: [String]? = nil,
        precedes: [[String]]? = nil,
        predicate: String? = nil
    ) -> [String] {
        switch assertion {
        case .exact:
            guard let first = native.first else { return ["exact assertion needs native output"] }
            guard !interpreted.isEmpty else { return ["exact assertion needs interpreter output"] }
            var problems: [String] = []
            if native.contains(where: { $0 != first }) {
                problems.append("native exact output was unstable: \(native)")
            }
            for output in interpreted where output != first {
                problems.append("native '\(first)' != interpreted '\(output)'")
            }
            return problems

        case .allowedSet:
            guard !interpreted.isEmpty else { return ["allowed-set assertion needs interpreter output"] }
            let allowed = Set(allowedOutputs ?? native)
            guard !allowed.isEmpty else { return ["allowed set is empty"] }
            return (native + interpreted).compactMap { output in
                allowed.contains(output) ? nil : "output '\(output)' is not in \(allowed.sorted())"
            }

        case .partialOrder:
            guard !interpreted.isEmpty else { return ["partial-order assertion needs interpreter output"] }
            return (native + interpreted).flatMap {
                traceViolations(
                    $0, requiredEvents: requiredEvents ?? [],
                    precedes: precedes ?? [])
            }

        case .predicate:
            guard !interpreted.isEmpty else { return ["predicate assertion needs interpreter output"] }
            switch predicate {
            case "nonempty":
                return (native + interpreted).compactMap {
                    $0.isEmpty ? "output is empty" : nil
                }
            case "same-event-multiset":
                guard let first = native.first else {
                    return ["same-event-multiset needs native output"]
                }
                let expected = first.split(separator: ",").sorted()
                return (Array(native.dropFirst()) + interpreted).compactMap { output in
                    output.split(separator: ",").sorted() == expected
                        ? nil : "event multiset differs in '\(output)'"
                }
            default:
                return ["unknown predicate '\(predicate ?? "nil")'"]
            }

        case .stress:
            guard let expected = native.first else {
                return ["stress assertion needs native completion"]
            }
            guard !interpreted.isEmpty else {
                return ["stress assertion needs interpreter completion"]
            }
            return (Array(native.dropFirst()) + interpreted).compactMap { output in
                output == expected
                    ? nil
                    : "stress output '\(output)' differs from native terminal '\(expected)'"
            }
        case .runtimeTrap:
            return ["runtime traps require process-isolated observations"]
        case .diagnostic:
            return ["diagnostics are validated from compiler status/stderr"]
        case .interpreterDiagnostic:
            return [
                "interpreter diagnostics require typed child observations"
            ]
        }
    }

    static func observationViolations(
        for parityCase: ConcurrencyParityCase,
        native: [String],
        interpreted: [InterpretedParityObservation]
    ) -> [String] {
        if parityCase.assertion == .runtimeTrap {
            var problems: [String] = []
            if native.isEmpty
                || native.contains(where: { $0 != "runtime-trap" }) {
                problems.append("native runtime trap was not stable")
            }
            if interpreted.isEmpty
                || interpreted.contains(where: {
                    $0.kind != .runtimeError || $0.text != "runtime-trap"
                }) {
                problems.append("interpreter runtime trap was not stable")
            }
            return problems
        }
        guard parityCase.assertion == .interpreterDiagnostic else {
            var problems = interpreted.compactMap { observation in
                observation.kind == .value ? nil
                    : "unexpected interpreter runtime diagnostic '"
                        + observation.text + "'"
            }
            let values = interpreted.compactMap { observation in
                observation.kind == .value ? observation.text : nil
            }
            problems += violations(
                assertion: parityCase.assertion,
                native: native,
                interpreted: values,
                allowedOutputs: parityCase.allowedOutputs,
                requiredEvents: parityCase.requiredEvents,
                precedes: parityCase.precedes,
                predicate: parityCase.predicate)
            return problems
        }

        guard let expected = native.first else {
            return ["interpreter-diagnostic assertion needs native output"]
        }
        var problems: [String] = []
        if native.contains(where: { $0 != expected }) {
            problems.append(
                "native interpreter-diagnostic output was unstable: \(native)")
        }
        let fragments = parityCase.interpreterDiagnosticContains ?? []
        if fragments.isEmpty {
            problems.append(
                "interpreter-diagnostic assertion needs message fragments")
        }
        for observation in interpreted {
            guard observation.kind == .runtimeError else {
                problems.append(
                    "interpreter unexpectedly returned '"
                        + observation.text + "'")
                continue
            }
            for fragment in fragments where
                !observation.text.contains(fragment) {
                problems.append(
                    "interpreter diagnostic did not contain '"
                        + fragment + "': " + observation.text)
            }
        }
        return problems
    }

    private static func traceViolations(
        _ output: String,
        requiredEvents: [String],
        precedes: [[String]]
    ) -> [String] {
        let events = output.split(separator: ",").map(String.init)
        var problems: [String] = []
        for event in requiredEvents {
            let count = events.count(where: { $0 == event })
            if count != 1 {
                problems.append("trace '\(output)' contains '\(event)' \(count) times")
            }
        }
        for pair in precedes {
            guard pair.count == 2 else {
                problems.append("invalid precedence pair \(pair)")
                continue
            }
            guard let lhs = events.firstIndex(of: pair[0]),
                  let rhs = events.firstIndex(of: pair[1]) else { continue }
            if lhs >= rhs {
                problems.append("trace '\(output)' violates \(pair[0]) < \(pair[1])")
            }
        }
        return problems
    }

    private static func successful(
        _ result: ParityProcessResult, operation: String
    ) throws -> ParityProcessResult {
        if result.timedOut {
            let diagnostics = [result.standardError, result.standardOutput]
                .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
            throw RuntimeError(message:
                "\(operation) timed out"
                    + (diagnostics.isEmpty ? "" : ":\n\(diagnostics)"))
        }
        if result.status != 0 {
            let diagnostics = [result.standardError, result.standardOutput]
                .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
            throw RuntimeError(message:
                "\(operation) failed (\(result.status)):\n\(diagnostics)")
        }
        return result
    }

    private static func validateRuntimeTrap(
        _ result: ParityProcessResult,
        requiredFragments: [String]?,
        operation: String
    ) throws {
        let diagnostics = [result.standardError, result.standardOutput]
            .map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        if result.timedOut {
            throw RuntimeError(message:
                "\(operation) timed out"
                    + (diagnostics.isEmpty ? "" : ":\n\(diagnostics)"))
        }
        guard result.status != 0 else {
            throw RuntimeError(message:
                "\(operation) unexpectedly completed"
                    + (diagnostics.isEmpty ? "" : ":\n\(diagnostics)"))
        }
        guard let requiredFragments, !requiredFragments.isEmpty else {
            throw RuntimeError(message:
                "\(operation) has no required trap diagnostic fragments")
        }
        for fragment in requiredFragments where
            !diagnostics.contains(fragment) {
            throw RuntimeError(message:
                "\(operation) did not contain '\(fragment)'"
                    + (diagnostics.isEmpty ? "" : ":\n\(diagnostics)"))
        }
    }

    static func emitShardReceipt(
        shard: ConcurrencyParityShard,
        selectedRepetitionsByCase: [String: Int],
        completedIDs: [String],
        completedRepetitionsByCase: [String: Int],
        nativeObservationSHA256ByCase: [String: String]
    ) {
        let selectedIDs = shard.cases.map(\.id)
        let receipt = ConcurrencyParityShardReceipt(
            version: 1,
            shardIndex: shard.index,
            shardCount: shard.count,
            selectedCount: selectedIDs.count,
            completedCount: completedIDs.count,
            selectedIDs: selectedIDs,
            completedIDs: completedIDs,
            selectedRepetitionsByCase: selectedRepetitionsByCase,
            completedRepetitionsByCase: completedRepetitionsByCase,
            nativeObservationSHA256ByCase: nativeObservationSHA256ByCase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(receipt),
              let json = String(data: data, encoding: .utf8) else {
            print("\(shardSummaryPrefix){\"encodingError\":true}")
            return
        }
        print(shardSummaryPrefix + json)
    }

    static func nativeObservationDigest(
        caseID: String,
        outputs: [String]
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "caseID": caseID,
                "outputs": outputs.sorted(),
            ],
            options: [.sortedKeys])
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func makeTemporaryDirectory(for id: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-concurrency-\(id)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func loadedImageURLs() -> [URL] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return URL(fileURLWithPath: String(cString: name))
        }
    }

    static func testBundleExecutableURL() throws -> URL {
        guard let url = loadedImageURLs().first(where: {
            $0.path.contains(".xctest/Contents/MacOS/")
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw RuntimeError(message:
                "could not locate the loaded SwiftPM test bundle executable")
        }
        return url
    }

    static func testingHelperURL() throws -> URL {
        if let executable = CommandLine.arguments.first {
            let url = URL(fileURLWithPath: executable)
            if url.lastPathComponent == "swiftpm-testing-helper",
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        for testingLibrary in loadedImageURLs()
        where testingLibrary.lastPathComponent == "libTesting.dylib" {
            var toolchainUSR = testingLibrary
            for _ in 0..<5 { toolchainUSR.deleteLastPathComponent() }
            let helper = toolchainUSR.appendingPathComponent(
                "libexec/swift/pm/swiftpm-testing-helper")
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                return helper
            }
        }
        throw RuntimeError(message:
            "could not locate the active toolchain's swiftpm-testing-helper")
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> ParityProcessResult {
        guard timeout.isFinite, timeout > 0 else {
            return ParityProcessResult(
                status: -1,
                standardOutput: "",
                standardError: "timeout must be a positive finite number",
                timedOut: false)
        }
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-process-\(UUID().uuidString)",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
              let stderr = try? FileHandle(forWritingTo: stderrURL) else {
            return ParityProcessResult(
                status: -1, standardOutput: "", standardError: "could not create output files",
                timedOut: false)
        }
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.standardInput = FileHandle.nullDevice
        process.arguments = arguments
        process.currentDirectoryURL = packageRoot
        if let environment { process.environment = environment }
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ParityProcessResult(
                status: -1, standardOutput: "",
                standardError: String(describing: error), timedOut: false)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            // Capture PID plus process start time before TERM. A parent can
            // exit during the grace period and orphan an uncooperative child;
            // a bare PID is also unsafe because the kernel can reuse it before
            // escalation.
            let identities = (descendantProcessIdentifiers(
                of: process.processIdentifier) + [process.processIdentifier])
                .compactMap { processIdentity(for: $0) }
            for identity in identities {
                signal(SIGTERM, ifStill: identity)
            }
            let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.05
            while identities.contains(where: { isRunning($0) }),
                  ProcessInfo.processInfo.systemUptime < graceDeadline {
                Thread.sleep(forTimeInterval: 0.005)
            }
            for identity in identities {
                signal(SIGKILL, ifStill: identity)
            }
            let terminationDeadline =
                ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning,
                  ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                if let identity = processIdentity(
                    for: process.processIdentifier) {
                    signal(SIGKILL, ifStill: identity)
                }
            }
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        let standardOutput = (try? String(
            contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let standardError = (try? String(
            contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return ParityProcessResult(
            status: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError,
            timedOut: timedOut)
    }

    private static func descendantProcessIdentifiers(
        of parent: pid_t
    ) -> [pid_t] {
        // `proc_listchildpids` returns a PID count, not a byte count.
        let estimatedCount = proc_listchildpids(parent, nil, 0)
        guard estimatedCount > 0 else { return [] }
        var children = [pid_t](
            repeating: 0,
            count: Int(estimatedCount) + 8)
        let returnedCount = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(
                parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard returnedCount > 0 else { return [] }
        return children.prefix(min(children.count, Int(returnedCount)))
            .filter { $0 > 0 }.flatMap {
                descendantProcessIdentifiers(of: $0) + [$0]
            }
    }

    private static func processIdentity(
        for identifier: pid_t
    ) -> ParityProcessIdentity? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(
            identifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize)
        guard actualSize == expectedSize else { return nil }
        return ParityProcessIdentity(
            identifier: identifier,
            startToken: "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)")
    }

    private static func isRunning(_ identity: ParityProcessIdentity) -> Bool {
        processIdentity(for: identity.identifier) == identity
    }

    private static func signal(
        _ signal: Int32,
        ifStill identity: ParityProcessIdentity
    ) {
        guard isRunning(identity) else { return }
        _ = Darwin.kill(identity.identifier, signal)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite("Concurrency native parity", .serialized)
struct ConcurrencyParityTests {
    @Test func toolchainFingerprintIsComplete() throws {
        let fingerprint = try ConcurrencyParityHarness.fingerprint()
        #expect(!fingerprint.swiftcPath.isEmpty)
        #expect(fingerprint.swiftVersion.contains("Swift version 6"))
        #expect(!fingerprint.sdkPath.isEmpty)
        #expect(!fingerprint.sdkVersion.isEmpty)
    }

    @Test func runtimeFixturesMatchNativeGuarantees() async throws {
        // The process-isolated child runner selects only interpretedParityChild,
        // but keep this guard as a second recursion barrier if test filtering
        // behavior changes in a future Testing/SwiftPM release.
        guard !ConcurrencyParityHarness.isInterpretedChild else { return }
        let allCases = try ConcurrencyParityHarness.loadCases()
            .filter { $0.mode == .runtime }
        #expect(!allCases.isEmpty)
        let shard = try ConcurrencyParityHarness.runtimeShard(
            from: allCases)
        if ConcurrencyParityHarness.hasFocusedRepetitionOverride,
           shard.cases.count != 1 {
            throw RuntimeError(message:
                "focused parity repetition override requires exactly one case")
        }
        let selectedRepetitionsByCase = try Dictionary(uniqueKeysWithValues:
            shard.cases.map { parityCase in
                (parityCase.id, try ConcurrencyParityHarness
                    .focusedRepetitionCount(for: parityCase))
            })
        var completedIDs: [String] = []
        var completedRepetitionsByCase: [String: Int] = [:]
        var nativeObservationSHA256ByCase: [String: String] = [:]
        defer {
            ConcurrencyParityHarness.emitShardReceipt(
                shard: shard,
                selectedRepetitionsByCase: selectedRepetitionsByCase,
                completedIDs: completedIDs,
                completedRepetitionsByCase: completedRepetitionsByCase,
                nativeObservationSHA256ByCase: nativeObservationSHA256ByCase)
        }

        for parityCase in shard.cases {
            let expectedRepetitions = try #require(
                selectedRepetitionsByCase[parityCase.id])
            let native = try ConcurrencyParityHarness.nativeOutputs(
                for: parityCase, repetitions: expectedRepetitions)
            let interpreted = try ConcurrencyParityHarness
                .interpretedObservations(
                    for: parityCase, repetitions: expectedRepetitions)
            guard native.count == expectedRepetitions,
                  interpreted.count == expectedRepetitions else {
                throw RuntimeError(message:
                    "\(parityCase.id) did not complete every repetition")
            }
            let problems = ConcurrencyParityHarness.observationViolations(
                for: parityCase,
                native: native,
                interpreted: interpreted)
            if !problems.isEmpty {
                Issue.record("\(parityCase.id): \(problems.joined(separator: "; "))")
            }
            nativeObservationSHA256ByCase[parityCase.id] = try
                ConcurrencyParityHarness.nativeObservationDigest(
                    caseID: parityCase.id, outputs: native)
            completedRepetitionsByCase[parityCase.id] = expectedRepetitions
            completedIDs.append(parityCase.id)
        }
    }

    @Test func interpretedParityChild() async throws {
        guard let request = try ConcurrencyParityHarness
            .interpretedChildRequest() else { return }
        let observation: InterpretedParityObservation
        do {
            observation = .init(
                kind: .value,
                text: try await ConcurrencyParityHarness.interpretedOutput(
                    for: request.parityCase))
        } catch let error as RuntimeError
            where request.parityCase.assertion == .interpreterDiagnostic {
            observation = .init(kind: .runtimeError, text: error.message)
        }
        try ConcurrencyParityHarness.writeInterpretedChildReceipt(
            caseID: request.parityCase.id,
            observation: observation,
            to: request.outputURL)
    }

    @Test func processIsolatedInterpreterChildProducesValidatedReceipt() throws {
        guard !ConcurrencyParityHarness.isInterpretedChild else { return }
        let parityCase = try #require(
            ConcurrencyParityHarness.loadCases().first {
                $0.id == "async-function-exact"
            })
        let outputs = try ConcurrencyParityHarness.interpretedOutputs(
            for: parityCase,
            repetitions: 2)
        #expect(outputs == ["ready", "ready"])
    }

    @Test func parityProcessRunnerEnforcesHardDeadlineForChildTree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-timeout-test-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDURL = directory.appendingPathComponent("child-pid")
        let scriptURL = directory.appendingPathComponent("descendant.sh")
        try """
        #!/bin/sh
        trap '' TERM
        depth="$1"
        pid_file="$2"
        if [ "$depth" -gt 0 ]; then
            /bin/sh "$0" "$((depth - 1))" "$pid_file" &
            child=$!
            if [ "$depth" -eq 1 ]; then
                echo "$child" > "$pid_file"
            fi
            wait "$child"
        else
            while :; do :; done
        fi
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        let result = ConcurrencyParityHarness.run(
            URL(fileURLWithPath: "/bin/sh"),
            [
                scriptURL.path,
                "2",
                childPIDURL.path,
            ],
            timeout: 0.1)
        #expect(result.timedOut)

        let rawChildPID = try String(
            contentsOf: childPIDURL, encoding: .utf8).trimmed
        let childPID = try #require(pid_t(rawChildPID))
        for _ in 0..<25 where Darwin.kill(childPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test func registeredNativeRedGapsAreExecutable() throws {
        guard !ConcurrencyParityHarness.isInterpretedChild else { return }
        let allGaps = try ConcurrencyParityHarness.loadOpenGaps()
        #expect(!allGaps.isEmpty)
        let gaps = allGaps.filter {
            $0.kind == "native-red"
        }

        for gap in gaps {
            let parityCase = try #require(gap.parityCase)
            let native = try ConcurrencyParityHarness.nativeOutputs(
                for: parityCase)
            let interpreted = try ConcurrencyParityHarness.interpretedOutputs(
                for: parityCase)
            #expect(native == [gap.expectedObservation],
                "\(gap.id) native baseline drifted")
            #expect(interpreted == [gap.currentObservation],
                "\(gap.id) interpreter RED changed; close or update the gap")
            #expect(native != interpreted,
                "\(gap.requirementRef) is no longer RED and must be closed")
        }
    }

    @Test func diagnosticFixturesMatchRealCompiler() throws {
        let cases = try ConcurrencyParityHarness.loadCases()
            .filter { $0.mode == .diagnostic }
        #expect(!cases.isEmpty)

        for parityCase in cases {
            let result = ConcurrencyParityHarness.diagnostic(for: parityCase)
            #expect(!result.timedOut, "\(parityCase.id) timed out")
            #expect(result.status != 0, "\(parityCase.id) unexpectedly typechecked")
            for fragment in parityCase.diagnosticContains ?? [] {
                #expect(result.standardError.contains(fragment),
                    "\(parityCase.id) did not contain '\(fragment)': \(result.standardError)")
            }
            if let line = parityCase.diagnosticLine {
                #expect(result.standardError.contains(":\(line):"),
                    "\(parityCase.id) did not diagnose line \(line): \(result.standardError)")
            }
        }
    }

    @Test func runtimeShardPartitionIsCompleteAndDisjoint() throws {
        let cases = try ConcurrencyParityHarness.loadCases()
            .filter { $0.mode == .runtime }
        var selectedIDs: [String] = []
        for index in 0..<4 {
            let shard = try ConcurrencyParityHarness.selectShard(
                from: cases, index: index, count: 4)
            #expect(Set(selectedIDs).isDisjoint(with: shard.map(\.id)))
            selectedIDs.append(contentsOf: shard.map(\.id))
        }
        #expect(selectedIDs.sorted() == cases.map(\.id).sorted())
    }

    @Test func focusedRepetitionOverrideIsBoundedByTheManifest() throws {
        #expect(try ConcurrencyParityHarness.effectiveRepetitionCount(
            manifestCount: 20, overrideValue: nil) == 20)
        #expect(try ConcurrencyParityHarness.effectiveRepetitionCount(
            manifestCount: 20, overrideValue: "5") == 5)
        #expect(throws: RuntimeError.self) {
            try ConcurrencyParityHarness.effectiveRepetitionCount(
                manifestCount: 20, overrideValue: "0")
        }
        #expect(throws: RuntimeError.self) {
            try ConcurrencyParityHarness.effectiveRepetitionCount(
                manifestCount: 20, overrideValue: "21")
        }
        #expect(throws: RuntimeError.self) {
            try ConcurrencyParityHarness.effectiveRepetitionCount(
                manifestCount: 20, overrideValue: "not-a-number")
        }
    }

    @Test
    func assertionEngineDetectsDivergenceAndSupportsNonExactRules() throws {
        let exactMismatch = ConcurrencyParityHarness.violations(
            assertion: .exact,
            native: ["native"],
            interpreted: ["interpreter"])
        #expect(!exactMismatch.isEmpty)

        let unstableNativeExact = ConcurrencyParityHarness.violations(
            assertion: .exact,
            native: ["first", "second"],
            interpreted: ["first"])
        #expect(!unstableNativeExact.isEmpty)

        let allowed = ConcurrencyParityHarness.violations(
            assertion: .allowedSet,
            native: ["a", "b"],
            interpreted: ["b"],
            allowedOutputs: ["a", "b"])
        #expect(allowed.isEmpty)

        let reversedPartialOrder = ConcurrencyParityHarness.violations(
            assertion: .partialOrder,
            native: ["first,second"],
            interpreted: ["second,first"],
            requiredEvents: ["first", "second"],
            precedes: [["first", "second"]])
        #expect(!reversedPartialOrder.isEmpty)

        let missingPartialOrderEvent = ConcurrencyParityHarness.violations(
            assertion: .partialOrder,
            native: ["first,second"],
            interpreted: ["first"],
            requiredEvents: ["first", "second"],
            precedes: [["first", "second"]])
        #expect(!missingPartialOrderEvent.isEmpty)

        let predicate = ConcurrencyParityHarness.violations(
            assertion: .predicate,
            native: ["a,b", "b,a"],
            interpreted: ["b,a"],
            predicate: "same-event-multiset")
        #expect(predicate.isEmpty)

        let emptyStress = ConcurrencyParityHarness.violations(
            assertion: .stress,
            native: [],
            interpreted: [])
        #expect(!emptyStress.isEmpty)

        let matchingStress = ConcurrencyParityHarness.violations(
            assertion: .stress,
            native: ["completed", "completed"],
            interpreted: ["completed", "completed"])
        #expect(matchingStress.isEmpty)

        let unstableStress = ConcurrencyParityHarness.violations(
            assertion: .stress,
            native: ["completed", "unexpected"],
            interpreted: ["arbitrary"])
        #expect(unstableStress.count == 2)

        let diagnosticCase = try #require(
            ConcurrencyParityHarness.loadCases().first {
                $0.id == "actor-global-actor-deinitializer"
            })
        let message = "global-actor deinitializer requires executor-owned teardown"
        let disguisedValue = ConcurrencyParityHarness.observationViolations(
            for: diagnosticCase,
            native: ["deinit"],
            interpreted: [.init(kind: .value, text: message)])
        #expect(!disguisedValue.isEmpty)
        let typedDiagnostic = ConcurrencyParityHarness.observationViolations(
            for: diagnosticCase,
            native: ["deinit"],
            interpreted: [.init(kind: .runtimeError, text: message)])
        #expect(typedDiagnostic.isEmpty)

        let trapCase = try #require(
            ConcurrencyParityHarness.loadCases().first {
                $0.id == "async-throwing-stream-copied-iterators"
            })
        let matchingTrap = ConcurrencyParityHarness.observationViolations(
            for: trapCase,
            native: ["runtime-trap"],
            interpreted: [.init(
                kind: .runtimeError, text: "runtime-trap")])
        #expect(matchingTrap.isEmpty)
        let disguisedTrap = ConcurrencyParityHarness.observationViolations(
            for: trapCase,
            native: ["runtime-trap"],
            interpreted: [.init(kind: .value, text: "runtime-trap")])
        #expect(!disguisedTrap.isEmpty)
    }

    @Test func nativeObservationDigestIsOrderIndependentAndContentSensitive() throws {
        let first = try ConcurrencyParityHarness.nativeObservationDigest(
            caseID: "probe", outputs: ["b", "a", "a"])
        let reordered = try ConcurrencyParityHarness.nativeObservationDigest(
            caseID: "probe", outputs: ["a", "b", "a"])
        let changed = try ConcurrencyParityHarness.nativeObservationDigest(
            caseID: "probe", outputs: ["a", "b"])
        #expect(first.count == 64)
        #expect(first == reordered)
        #expect(first != changed)
    }

    @Test func harnessRejectsIntentionallyBadInterpreterParity() throws {
        let parityCase = try #require(
            ConcurrencyParityHarness.loadCases().first {
                $0.id == "async-function-exact"
            })
        let native = try ConcurrencyParityHarness.nativeOutputs(for: parityCase)
        let problems = ConcurrencyParityHarness.violations(
            assertion: parityCase.assertion,
            native: native,
            interpreted: ["deliberately-wrong"])
        #expect(!problems.isEmpty)
    }

    @Test func sourceTasksOwnDistinctEvaluatorContexts() async throws {
        let fixture = ConcurrencyParityHarness.parityRoot
            .appendingPathComponent(
                "Fixtures/task-owned-evaluator-context.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartTaskContextProbe()\n"
        let interpreter = Interpreter()
        var contextIDs: [UInt64] = []
        var runtimeTaskIDs: Set<RuntimeTaskID> = []
        var retainedContexts: [UInt64: EvaluationTaskContext] = [:]
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, context in
                await Task.yield()
                let contextID: UInt64
                if let bound = context as? TaskBoundEvalContext {
                    contextID = bound.evaluationTaskContextID
                    retainedContexts[contextID] = bound.evaluationContext
                    if let taskID = bound.evaluationContext.runtimeTaskID {
                        runtimeTaskIDs.insert(taskID)
                    }
                } else if let interpreter = context as? Interpreter {
                    contextID = interpreter.currentEvaluationTaskContextID
                } else {
                    throw RuntimeError(message: "unknown EvalContext implementation")
                }
                contextIDs.append(contextID)
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value,
              let values = recorder.box(for: "values")?.value.arrayValue else {
            Issue.record("task-context fixture did not return its recorder")
            return
        }
        #expect(values.count == 100)
        #expect(Set(contextIDs).count == 100)
        #expect(runtimeTaskIDs.count == 100)
        #expect(retainedContexts.count == 100)
        #expect(retainedContexts.values.allSatisfy { $0.isDynamicallyEmpty })
    }

    @Test func asyncInitializersStayInsideTheirOwningTaskContexts() async throws {
        let fixture = ConcurrencyParityHarness.parityRoot
            .appendingPathComponent(
                "Fixtures/async-initializer-context.swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\nstartAsyncInitializerProbe()\n"
        let interpreter = Interpreter()
        var retainedContexts: [UInt64: EvaluationTaskContext] = [:]
        interpreter.globals.define("parityYield", .hostFunction(HostFunction(
            name: "parityYield",
            asyncInvoke: { arguments, context in
                await Task.yield()
                guard let bound = context as? TaskBoundEvalContext else {
                    throw RuntimeError(message:
                        "async initializer lost its task-bound host context")
                }
                retainedContexts[bound.evaluationTaskContextID] =
                    bound.evaluationContext
                return arguments.positional(0) ?? .nilValue
            }
        )))

        let value = try await interpreter.runAsync(source: source)
        guard case .instance(let recorder) = value,
              let values = recorder.box(for: "values")?.value.arrayValue else {
            Issue.record("async-initializer fixture did not return its recorder")
            return
        }
        #expect(values.count == 100)
        #expect(retainedContexts.count == 100)
        #expect(retainedContexts.values.allSatisfy { $0.isDynamicallyEmpty })
    }

}
