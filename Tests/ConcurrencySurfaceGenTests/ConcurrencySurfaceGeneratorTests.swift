import ConcurrencySurfaceGenCore
import Foundation
import Testing

@Suite("Concurrency surface generator")
struct ConcurrencySurfaceGeneratorTests {
    @Test
    func syntheticInterfacePreservesOverloadsEffectsAndIsolation() throws {
        let inventory = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: Self.syntheticInterface)

        let withTaskGroup = try #require(
            inventory.taskGroupFunctionDeclarations["withTaskGroup"]?.first)
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
            inventory.taskGroupFunctionDeclarations[
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

        let inventory = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: interfaceSource)
        let ordinary = try #require(
            inventory.taskGroupFunctionDeclarations["withTaskGroup"]?.first)
        #expect(ordinary.isAsync)
        #expect(ordinary.throwsKind == .nonThrowing)
        #expect(ordinary.parameters.contains {
            $0.label == "isolation" && $0.isIsolated
                && $0.defaultValue == "#isolation"
        })

        let throwing = try #require(
            inventory.taskGroupFunctionDeclarations[
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
