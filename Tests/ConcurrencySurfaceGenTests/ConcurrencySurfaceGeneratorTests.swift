import ConcurrencySurfaceGenCore
import Foundation
import Testing

@Suite("Concurrency surface generator")
struct ConcurrencySurfaceGeneratorTests {
    @Test
    func syntheticInterfacePreservesOverloadsEffectsAndIsolation() throws {
        let inventory = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: Self.syntheticInterface)

        #expect(inventory.topLevelFunctionDispatch == [
            "withDiscardingTaskGroup": "withDiscardingTaskGroup",
            "withTaskCancellationHandler": "withTaskCancellationHandler",
            "withTaskGroup": "withTaskGroup",
            "withThrowingDiscardingTaskGroup":
                "withThrowingDiscardingTaskGroup",
            "withThrowingTaskGroup": "withThrowingTaskGroup",
        ])
        #expect(inventory.knownTopLevelFunctions.contains("interfaceOnlyProbe"))
        let cancellationHandler = try #require(
            inventory.topLevelFunctionDeclarations[
                "withTaskCancellationHandler"]?.first)
        #expect(cancellationHandler.isAsync)
        #expect(cancellationHandler.throwsKind == .rethrowing)
        #expect(cancellationHandler.parameters.contains {
            $0.label == "onCancel" && $0.isSendableFunction
        })

        let withTaskGroup = try #require(
            inventory.topLevelFunctionDeclarations["withTaskGroup"]?.first)
        #expect(withTaskGroup.isAsync)
        #expect(withTaskGroup.throwsKind == .nonThrowing)
        #expect(withTaskGroup.globalActor == "ProbeActor")
        let isolation = try #require(withTaskGroup.parameters.first {
            $0.label == "isolation"
        })
        #expect(isolation.isIsolated)
        #expect(isolation.defaultValue == "#isolation")
        let body = try #require(withTaskGroup.parameters.first {
            $0.label == "body"
        })
        #expect(body.inheritsActorContext)
        #expect(body.isSendableFunction)

        let throwing = try #require(
            inventory.topLevelFunctionDeclarations[
                "withThrowingTaskGroup"]?.first)
        #expect(throwing.isAsync)
        #expect(throwing.throwsKind == .rethrowing)

        let taskMembers = try #require(
            inventory.taskGroupMemberDeclarations["TaskGroup"])
        let addTask = try #require(taskMembers["addTask"])
        #expect(addTask.count == 2)
        #expect(addTask.allSatisfy { $0.isMutating })
        #expect(addTask.allSatisfy { !$0.isAsync })
        #expect(addTask.contains { declaration in
            declaration.parameters.contains {
                $0.name == "operation" && $0.type.contains("async throws")
            }
        })
        #expect(taskMembers["next"]?.allSatisfy { $0.isAsync } == true)
        #expect(taskMembers["isEmpty"]?.first?.kind == .variable)
        #expect(taskMembers["isEmpty"]?.first?.returnType == "Bool")
        #expect(inventory.taskGroupDispatch["TaskGroup"]?["async"]
            == "addTask")

        #expect(inventory.taskStaticDispatch == [
            "checkCancellation": "checkCancellation",
            "currentPriority": "currentPriority",
            "detached": "detached",
            "isCancelled": "isCancelled",
            "sleep": "sleep",
            "yield": "yield",
        ])
        #expect(inventory.knownTaskStaticMembers.contains("basePriority"))
        let staticTaskMembers = inventory.taskStaticMemberDeclarations
        #expect(staticTaskMembers["yield"]?.first?.isAsync == true)
        #expect(staticTaskMembers["checkCancellation"]?.first?.throwsKind
            == .throwing)
        #expect(staticTaskMembers["sleep"]?.contains {
            $0.isAsync && $0.throwsKind == .throwing
                && $0.parameters.first?.label == "nanoseconds"
        } == true)
        #expect(staticTaskMembers["detached"]?.contains { declaration in
            declaration.parameters.contains {
                $0.name == "operation" && $0.hasIsolatedFunctionType
            }
        } == true)

        #expect(inventory.taskInstanceDispatch == [
            "cancel": "cancel",
            "isCancelled": "isCancelled",
            "result": "result",
            "value": "value",
        ])
        #expect(inventory.knownTaskInstanceMembers.contains("hash"))
        let instanceTaskMembers = inventory.taskInstanceMemberDeclarations
        #expect(instanceTaskMembers["value"]?.contains {
            $0.kind == .variable && $0.isAsync && $0.isThrowing
        } == true)
        #expect(instanceTaskMembers["value"]?.contains {
            $0.kind == .variable && $0.isAsync && !$0.isThrowing
        } == true)
        #expect(instanceTaskMembers["result"]?.first?.isAsync == true)
        #expect(instanceTaskMembers["result"]?.first?.isThrowing == false)
        #expect(instanceTaskMembers["cancel"]?.first?.isAsync == false)
        #expect(instanceTaskMembers["isCancelled"]?.first?.kind == .variable)

        for typeName in ConcurrencySurfaceGenerator.taskGroupTypes {
            #expect(Set(inventory.taskGroupMemberDeclarations[
                typeName, default: [:]].keys)
                == inventory.knownTaskGroupMembers[typeName, default: []])
        }
    }

    @Test
    func checkedInSurfaceMatchesActiveSDKAndRetainsCoreEffects() throws {
        let interfacePath = try ConcurrencySurfaceGenerator.activeInterfacePath()
        let interfaceSource = try String(
            contentsOfFile: interfacePath, encoding: .utf8)
        let generated = try ConcurrencySurfaceGenerator.generatedSource(
            interfacePath: interfacePath,
            interfaceSource: interfaceSource)
        let checkedInURL = Self.packageRoot.appendingPathComponent(
            "Sources/SwiftInterpreter/Generated/GeneratedConcurrencySurface.swift")
        let checkedIn = try String(contentsOf: checkedInURL, encoding: .utf8)
        #expect(checkedIn == generated,
            "generated concurrency surface is stale; run swift run ConcurrencySurfaceGen")

        let generatedCapabilities = try ConcurrencySurfaceGenerator
            .generatedCapabilityInventory(
                interfacePath: interfacePath,
                interfaceSource: interfaceSource,
            )
        let capabilityURL = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json")
        let checkedInCapabilities = try String(
            contentsOf: capabilityURL, encoding: .utf8,
        )
        #expect(checkedInCapabilities == generatedCapabilities,
                "generated concurrency capability inventory is stale; run swift run ConcurrencySurfaceGen")
        let capabilities = try JSONDecoder().decode(
            CapabilityInventory.self, from: Data(generatedCapabilities.utf8),
        )
        #expect(capabilities.schemaVersion == 1)
        #expect(capabilities.generator == "ConcurrencySurfaceGen")
        #expect(capabilities.source.interface.hasPrefix("<macOS SDK>"))
        #expect(!capabilities.source.interface.contains("/Applications/"))
        #expect(capabilities.source.interfaceFormatVersion == "1.0")
        #expect(capabilities.source.targetTriple.contains("apple-macosx"))
        #expect(!capabilities.scope.complete)
        #expect(!capabilities.scope.adapterRouteIsSupportEvidence)
        #expect(!capabilities.scope.excluded.isEmpty)
        #expect(capabilities.summary.declarationCount == 150)
        #expect(capabilities.summary.declarationsByDomain == [
            "top-level-function": 47,
            "task-static-member": 21,
            "task-instance-member": 11,
            "task-group-member": 71,
        ])
        #expect(capabilities.declarations.count
            == capabilities.summary.declarationCount)
        #expect(Set(capabilities.declarations.map(\.id)).count
            == capabilities.declarations.count)
        #expect(capabilities.declarations.allSatisfy {
            $0.id.range(
                of: #"^swift-concurrency-api-v1:[0-9a-f]{64}$"#,
                options: .regularExpression,
            ) != nil
        })
        #expect(capabilities.declarations == capabilities.declarations.sorted {
            ($0.domain, $0.container, $0.name, $0.declaration, $0.id)
                < ($1.domain, $1.container, $1.name, $1.declaration, $1.id)
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "top-level-function" && $0.name == "withTaskGroup"
                && $0.adapterIntrinsic == "withTaskGroup"
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "top-level-function"
                && $0.name == "withCheckedContinuation"
                && $0.adapterIntrinsic == nil
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "task-static-member" && $0.name == "sleep"
                && $0.adapterIntrinsic == "sleep"
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "task-static-member" && $0.name == "basePriority"
                && $0.adapterIntrinsic == nil
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "task-static-member" && $0.name == "=="
                && $0.adapterIntrinsic == nil
        })
        #expect(capabilities.declarations.contains {
            $0.container == "ThrowingTaskGroup" && $0.name == "nextResult"
                && $0.adapterIntrinsic == nil
        })
        #expect(!generatedCapabilities.contains("implementationStatus"))
        #expect(!generatedCapabilities.contains("verificationStatus"))

        let inventory = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: interfaceSource)
        #expect(Set(inventory.topLevelFunctionDispatch.keys) == [
            "withDiscardingTaskGroup", "withTaskCancellationHandler",
            "withTaskGroup", "withThrowingDiscardingTaskGroup",
            "withThrowingTaskGroup",
        ])
        #expect(inventory.knownTopLevelFunctions.contains("withUnsafeCurrentTask"))
        let cancellationHandler = try #require(
            inventory.topLevelFunctionDeclarations[
                "withTaskCancellationHandler"])
        #expect(cancellationHandler.contains { declaration in
            declaration.isAsync && declaration.throwsKind == .rethrowing
                && declaration.parameters.contains {
                    $0.name == "handler" && $0.isSendableFunction
                }
        })
        let ordinary = try #require(
            inventory.topLevelFunctionDeclarations["withTaskGroup"]?.first)
        #expect(ordinary.isAsync)
        #expect(ordinary.throwsKind == .nonThrowing)
        #expect(ordinary.parameters.contains {
            $0.label == "isolation" && $0.isIsolated
                && $0.defaultValue == "#isolation"
        })

        let throwing = try #require(
            inventory.topLevelFunctionDeclarations[
                "withThrowingTaskGroup"]?.first)
        #expect(throwing.isAsync)
        #expect(throwing.throwsKind == .rethrowing)

        let group = try #require(
            inventory.taskGroupMemberDeclarations["ThrowingTaskGroup"])
        #expect(group["next"]?.contains {
            $0.isAsync && $0.throwsKind == .throwing
                && $0.parameters.contains {
                    $0.label == "isolation" && $0.isIsolated
                }
        } == true)
        #expect(group["nextResult"]?.contains {
            $0.isAsync && !$0.isThrowing
        } == true)
        #expect(group["addTask"]?.contains { declaration in
            declaration.parameters.contains {
                $0.name == "operation" && $0.hasIsolatedFunctionType
            }
        } == true)

        let taskStatics = inventory.taskStaticMemberDeclarations
        #expect(taskStatics["yield"]?.contains {
            $0.isAsync && !$0.isThrowing
        } == true)
        #expect(taskStatics["checkCancellation"]?.contains {
            !$0.isAsync && $0.throwsKind == .throwing
        } == true)
        #expect(taskStatics["sleep"]?.contains {
            $0.isAsync && $0.throwsKind == .throwing
                && $0.parameters.contains { $0.label == "nanoseconds" }
        } == true)
        #expect(taskStatics["detached"]?.contains { declaration in
            declaration.parameters.contains {
                $0.name == "operation" && $0.hasIsolatedFunctionType
            }
        } == true)

        #expect(inventory.taskInstanceDispatch == [
            "cancel": "cancel",
            "isCancelled": "isCancelled",
            "result": "result",
            "value": "value",
        ])
        let taskInstances = inventory.taskInstanceMemberDeclarations
        #expect(taskInstances["value"]?.contains {
            $0.kind == .variable && $0.isAsync && $0.isThrowing
        } == true)
        #expect(taskInstances["value"]?.contains {
            $0.kind == .variable && $0.isAsync && !$0.isThrowing
        } == true)
        #expect(taskInstances["result"]?.contains {
            $0.kind == .variable && $0.isAsync && !$0.isThrowing
        } == true)
        #expect(taskInstances["isCancelled"]?.contains {
            $0.kind == .variable && !$0.isAsync && !$0.isThrowing
        } == true)
    }

    @Test
    func capabilityIDsArePathIndependentAndSignatureSensitive() throws {
        let first = try ConcurrencySurfaceGenerator.generatedCapabilityInventory(
            interfacePath: "/first/First.swiftinterface",
            interfaceSource: Self.syntheticInterface,
        )
        let second = try ConcurrencySurfaceGenerator.generatedCapabilityInventory(
            interfacePath: "/second/Second.swiftinterface",
            interfaceSource: Self.syntheticInterface,
        )
        let originalDocument = try JSONDecoder().decode(
            CapabilityInventory.self, from: Data(first.utf8),
        )
        let secondDocument = try JSONDecoder().decode(
            CapabilityInventory.self, from: Data(second.utf8),
        )
        #expect(originalDocument.source.interface != secondDocument.source.interface)
        #expect(originalDocument.declarations.map(\.id)
            == secondDocument.declarations.map(\.id))

        let changed = try ConcurrencySurfaceGenerator
            .generatedCapabilityInventory(
                interfacePath: "/second/_Concurrency.swiftinterface",
                interfaceSource: Self.syntheticInterface.replacingOccurrences(
                    of: "public func interfaceOnlyProbe() async {}",
                    with: "public func interfaceOnlyProbe() async throws {}",
                ),
            )
        let changedDocument = try JSONDecoder().decode(
            CapabilityInventory.self, from: Data(changed.utf8),
        )
        let originalID = try #require(originalDocument.declarations.first {
            $0.name == "interfaceOnlyProbe"
        }?.id)
        let changedID = try #require(changedDocument.declarations.first {
            $0.name == "interfaceOnlyProbe"
        }?.id)
        #expect(originalID != changedID)
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let syntheticInterface = """
    // swift-compiler-version: synthetic Swift 6
    @globalActor public actor ProbeActor {}

    @ProbeActor
    public func withTaskGroup<Child, Result>(
        isolation actor: isolated (any Actor)? = #isolation,
        @_inheritActorContext body: @Sendable () async -> Result
    ) async -> Result { fatalError() }
    public func withThrowingTaskGroup<Child, Result>(
        isolation actor: isolated (any Actor)? = #isolation,
        body: () async throws -> Result
    ) async rethrows -> Result { fatalError() }
    public func withDiscardingTaskGroup<Result>(
        body: () async -> Result
    ) async -> Result { fatalError() }
    public func withThrowingDiscardingTaskGroup<Result>(
        body: () async throws -> Result
    ) async throws -> Result { fatalError() }
    public func withTaskCancellationHandler<Result>(
        operation: () async throws -> Result,
        onCancel handler: @Sendable () -> Void
    ) async rethrows -> Result { fatalError() }
    public func interfaceOnlyProbe() async {}

    public struct TaskGroup<Child> {
        public mutating func addTask(operation: () async -> Child) {}
        public mutating func addTask(operation: () async throws -> Child) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async -> Child
        ) -> Bool { true }
        public mutating func waitForAll() async {}
        public mutating func next() async -> Child? { nil }
        public func cancelAll() {}
        public var isCancelled: Bool { false }
        public var isEmpty: Bool { true }
    }
    extension TaskGroup {
        public mutating func async(operation: () async -> Child) {
            addTask(operation: operation)
        }
    }

    public struct ThrowingTaskGroup<Child, Failure> {
        public mutating func addTask(operation: () async throws -> Child) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async throws -> Child
        ) -> Bool { true }
        public mutating func waitForAll() async throws {}
        public mutating func next() async throws -> Child? { nil }
        public func cancelAll() {}
        public var isCancelled: Bool { false }
        public var isEmpty: Bool { true }
    }

    public struct DiscardingTaskGroup {
        public mutating func addTask(operation: () async -> Void) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async -> Void
        ) -> Bool { true }
        public func cancelAll() {}
        public var isCancelled: Bool { false }
        public var isEmpty: Bool { true }
    }

    public struct ThrowingDiscardingTaskGroup<Failure> {
        public mutating func addTask(operation: () async throws -> Void) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async throws -> Void
        ) -> Bool { true }
        public func cancelAll() {}
        public var isCancelled: Bool { false }
        public var isEmpty: Bool { true }
    }

    public struct Task<Success, Failure> {}
    extension Task {
        public var value: Success { get async throws }
        public var result: Result<Success, Failure> { get async }
        public var isCancelled: Bool { get }
        public func cancel() {}
        public func hash(into hasher: inout Hasher) {}
    }
    extension Task where Failure == Never {
        public var value: Success { get async }
    }
    extension Task where Success == Never, Failure == Never {
        public static var currentPriority: TaskPriority { fatalError() }
        public static var basePriority: TaskPriority? { nil }
        public static var isCancelled: Bool { false }
        public static func checkCancellation() throws {}
        public static func yield() async {}
        public static func sleep(nanoseconds duration: UInt64) async throws {}
    }
    extension Task where Failure == Never {
        public static func detached(
            operation: @escaping @isolated(any) () async -> Success
        ) -> Task<Success, Never> { fatalError() }
    }
    """
}

private struct CapabilityInventory: Decodable {
    let schemaVersion: Int
    let generator: String
    let source: CapabilitySource
    let scope: CapabilityScope
    let summary: CapabilitySummary
    let declarations: [CapabilityDeclaration]
}

private struct CapabilitySource: Decodable {
    let interface: String
    let interfaceFormatVersion: String
    let targetTriple: String
}

private struct CapabilityScope: Decodable {
    let complete: Bool
    let excluded: [String]
    let adapterRouteIsSupportEvidence: Bool
}

private struct CapabilitySummary: Decodable {
    let declarationCount: Int
    let declarationsByDomain: [String: Int]
}

private struct CapabilityDeclaration: Decodable, Equatable {
    let id: String
    let domain: String
    let container: String
    let name: String
    let declaration: String
    let adapterIntrinsic: String?
}
