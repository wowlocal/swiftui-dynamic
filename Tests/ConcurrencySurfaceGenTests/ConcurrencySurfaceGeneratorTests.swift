import ConcurrencySurfaceGenCore
import Foundation
import SwiftIfConfig
import Testing

@Suite("Concurrency surface generator")
struct ConcurrencySurfaceGeneratorTests {
    @Test
    func syntheticInterfacePreservesOverloadsEffectsAndIsolation() throws {
        let inventory = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: Self.syntheticInterface)

        #expect(inventory.topLevelFunctionDispatch == [
            "async": "unstructuredTask",
            "asyncDetached": "detachedTask",
            "detach": "detachedTask",
            "withDiscardingTaskGroup": "withDiscardingTaskGroup",
            "withTaskCancellationHandler": "withTaskCancellationHandler",
            "withTaskGroup": "withTaskGroup",
            "withThrowingDiscardingTaskGroup":
                "withThrowingDiscardingTaskGroup",
            "withThrowingTaskGroup": "withThrowingTaskGroup",
            "withUnsafeCurrentTask": "withCurrentTaskCapability",
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
        let immediateTask = try #require(taskMembers["addImmediateTask"]?.first)
        #expect(immediateTask.isMutating)
        #expect(immediateTask.parameters.contains { parameter in
            parameter.label == "executorPreference"
                && parameter.name == "taskExecutor"
                && parameter.type.hasPrefix("consuming ")
                && parameter.type.contains("TaskExecutor")
                && parameter.defaultValue == "nil"
        })
        #expect(immediateTask.parameters.contains { parameter in
            parameter.name == "operation"
                && parameter.inheritsActorContext
                && parameter.hasIsolatedFunctionType
                && parameter.attributes.contains("@_implicitSelfCapture")
        })
        #expect(taskMembers["addImmediateTaskUnlessCancelled"]?.first?
            .returnType == "Bool")
        #expect(taskMembers["next"]?.allSatisfy { $0.isAsync } == true)
        #expect(taskMembers["isEmpty"]?.first?.kind == .variable)
        #expect(taskMembers["isEmpty"]?.first?.returnType == "Bool")
        #expect(inventory.taskGroupDispatch["TaskGroup"]?["async"]
            == "addTask")
        #expect(inventory.taskGroupDispatch["TaskGroup"]?["nextResult"] == nil)
        #expect(inventory.taskGroupDispatch["ThrowingTaskGroup"]?["nextResult"]
            == "nextResult")
        #expect(inventory.taskGroupDispatch["TaskGroup"]?["makeAsyncIterator"]
            == "makeAsyncIterator")
        #expect(inventory.taskGroupDispatch["ThrowingTaskGroup"]?["makeAsyncIterator"]
            == "makeAsyncIterator")

        #expect(inventory.taskGroupIteratorDispatch == [
            "TaskGroup": ["cancel": "cancel", "next": "next"],
            "ThrowingTaskGroup": ["cancel": "cancel", "next": "next"],
        ])
        let ordinaryIterator = try #require(
            inventory.taskGroupIteratorMemberDeclarations["TaskGroup"])
        #expect(ordinaryIterator["next"]?.count == 2)
        #expect(ordinaryIterator["next"]?.allSatisfy {
            $0.isAsync && !$0.isThrowing && $0.isMutating
        } == true)
        #expect(ordinaryIterator["next"]?.contains { declaration in
            declaration.parameters.contains {
                $0.label == "isolation" && $0.isIsolated
            }
        } == true)
        #expect(ordinaryIterator["cancel"]?.first?.isAsync == false)
        let throwingIterator = try #require(
            inventory.taskGroupIteratorMemberDeclarations[
                "ThrowingTaskGroup"])
        #expect(throwingIterator["next"]?.count == 2)
        #expect(throwingIterator["next"]?.allSatisfy {
            $0.isAsync && $0.isThrowing && $0.isMutating
        } == true)

        #expect(inventory.taskStaticDispatch == [
            "checkCancellation": "checkCancellation",
            "currentPriority": "currentPriority",
            "detached": "detached",
            "immediate": "immediate",
            "immediateDetached": "immediateDetached",
            "isCancelled": "isCancelled",
            "name": "name",
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

        #expect(inventory.nominalMemberDispatch["UnsafeCurrentTask"] == [
            "==": "currentTaskIdentityEquals",
            "basePriority": "currentTaskBasePriority",
            "cancel": "currentTaskCancel",
            "hashValue": "currentTaskHashValue",
            "isCancelled": "currentTaskIsCancelled",
            "priority": "currentTaskPriority",
        ])
        #expect(inventory.knownNominalMembers["UnsafeCurrentTask"] == [
            "==", "basePriority", "cancel", "escalatePriority", "hash",
            "hashValue", "isCancelled", "priority", "unownedTaskExecutor",
        ])
        let currentTaskMembers = try #require(
            inventory.nominalMemberDeclarations["UnsafeCurrentTask"])
        #expect(currentTaskMembers["priority"]?.first?.returnType
            == "TaskPriority")
        #expect(currentTaskMembers["=="]?.first?.modifiers.contains("static")
            == true)

        for typeName in ConcurrencySurfaceGenerator.taskGroupTypes {
            #expect(Set(inventory.taskGroupMemberDeclarations[
                typeName, default: [:]].keys)
                == inventory.knownTaskGroupMembers[typeName, default: []])
        }
        for typeName in ConcurrencySurfaceGenerator.taskGroupIteratorTypes {
            #expect(Set(inventory.taskGroupIteratorMemberDeclarations[
                typeName, default: [:]].keys)
                == inventory.knownTaskGroupIteratorMembers[
                    typeName, default: []])
        }
    }

    @Test
    func conditionalDeclarationsFollowInjectedCompilerConfiguration() throws {
        let activeConfiguration = StaticBuildConfiguration(
            features: ["AlwaysInheritActorContext"],
            languageVersion: VersionTuple(5, 10),
            compilerVersion: VersionTuple(6, 3, 3))
        let active = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: Self.syntheticInterface,
            configuration: activeConfiguration)

        #expect(active.taskStaticMemberDeclarations["immediate"]?.count == 2)
        #expect(active.taskStaticMemberDeclarations["immediateDetached"]?.count
            == 2)
        #expect(!active.knownTaskStaticMembers.contains(
            "inactiveConditionalProbe"))
        let immediate = try #require(
            active.taskStaticMemberDeclarations["immediate"]?.first)
        #expect(immediate.parameters.contains { parameter in
            parameter.label == "executorPreference"
                && parameter.name == "taskExecutor"
                && parameter.type.hasPrefix("consuming ")
                && parameter.defaultValue == "nil"
        })
        #expect(immediate.parameters.contains { parameter in
            parameter.name == "operation"
                && parameter.inheritsActorContext
                && parameter.hasIsolatedFunctionType
                && parameter.attributes.contains("@_implicitSelfCapture")
        })

        let inactiveConfiguration = StaticBuildConfiguration(
            languageVersion: VersionTuple(5, 10),
            compilerVersion: VersionTuple(6, 3, 3))
        let inactive = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: Self.syntheticInterface,
            configuration: inactiveConfiguration)
        #expect(inactive.taskStaticMemberDeclarations["immediate"] == nil)
        #expect(inactive.taskStaticMemberDeclarations["immediateDetached"]
            == nil)
        #expect(inactive.knownTaskStaticMembers.contains(
            "inactiveConditionalProbe"))
    }

    @Test
    func conditionalCompilationFailsClosedWhenConfigurationCannotAnswer() {
        let source = Self.syntheticInterface + """

            #if canImport(DefinitelyUnavailableConcurrencySurfaceModule)
            public func conditionallyImportedProbe() {}
            #endif
            """
        let staticConfiguration = StaticBuildConfiguration(
            languageVersion: VersionTuple(5, 10),
            compilerVersion: VersionTuple(6, 3, 3))

        #expect(throws: ConcurrencySurfaceGenerationError.self) {
            try ConcurrencySurfaceGenerator.inventory(
                interfaceSource: source,
                configuration: staticConfiguration)
        }
    }

    @Test
    func selectedNominalInventoryFailsClosedWhenTypeDisappears() throws {
        let source = Self.syntheticInterface
            .replacingOccurrences(
                of: "public struct UnsafeCurrentTask",
                with: "public struct MissingCurrentTask")
            .replacingOccurrences(
                of: "extension UnsafeCurrentTask",
                with: "extension MissingCurrentTask")

        do {
            _ = try ConcurrencySurfaceGenerator.inventory(
                interfaceSource: source)
            Issue.record("missing selected nominal unexpectedly generated")
        } catch ConcurrencySurfaceGenerationError
                .missingNominalMemberIntrinsics(let names) {
            #expect(names.contains("UnsafeCurrentTask.<type>"))
            #expect(names.contains(
                "UnsafeCurrentTask.currentTaskIdentityEquals"))
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
        #expect(capabilities.scope.id
            == "top-level-functions-and-task-family-members-v4")
        #expect(!capabilities.scope.adapterRouteIsSupportEvidence)
        #expect(!capabilities.scope.excluded.isEmpty)
        #expect(capabilities.scope.included.contains {
            $0.contains("TaskGroup.Iterator")
        })
        #expect(capabilities.scope.included.contains {
            $0.contains("active compiler conditional-compilation")
        })
        #expect(capabilities.scope.included.contains {
            $0.contains("selected nominal") && $0.contains("UnsafeCurrentTask")
        })
        #expect(capabilities.scope.excluded.contains {
            $0.contains("nested declarations outside")
        })
        #expect(capabilities.summary.declarationCount == 171)
        #expect(capabilities.summary.adapterRoutedDeclarationCount == 119)
        #expect(capabilities.summary.declarationsByDomain == [
            "top-level-function": 49,
            "task-static-member": 25,
            "task-instance-member": 11,
            "task-group-member": 71,
            "task-group-iterator-member": 6,
            "selected-nominal-member": 9,
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
        #expect(capabilities.declarations.filter {
            $0.domain == "top-level-function" && $0.name == "async"
                && $0.adapterIntrinsic == "unstructuredTask"
        }.count == 2)
        #expect(capabilities.declarations.filter {
            $0.domain == "top-level-function"
                && ["asyncDetached", "detach"].contains($0.name)
                && $0.adapterIntrinsic == "detachedTask"
        }.count == 4)
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
            $0.domain == "task-static-member" && $0.name == "name"
                && $0.adapterIntrinsic == "name"
        })
        #expect(capabilities.declarations.filter {
            $0.domain == "task-static-member"
                && ["immediate", "immediateDetached"].contains($0.name)
                && $0.adapterIntrinsic == $0.name
        }.count == 4)
        #expect(capabilities.declarations.contains {
            $0.domain == "task-static-member" && $0.name == "basePriority"
                && $0.adapterIntrinsic == nil
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "task-static-member" && $0.name == "=="
                && $0.adapterIntrinsic == nil
        })
        #expect(capabilities.declarations.filter {
            $0.domain == "selected-nominal-member"
                && $0.container == "UnsafeCurrentTask"
        }.count == 9)
        #expect(capabilities.declarations.contains {
            $0.domain == "selected-nominal-member" && $0.name == "=="
                && $0.adapterIntrinsic == "currentTaskIdentityEquals"
        })
        #expect(capabilities.declarations.contains {
            $0.domain == "selected-nominal-member"
                && $0.name == "unownedTaskExecutor"
                && $0.adapterIntrinsic == nil
        })
        #expect(capabilities.declarations.contains {
            $0.container == "ThrowingTaskGroup" && $0.name == "nextResult"
                && $0.adapterIntrinsic == "nextResult"
        })
        #expect(capabilities.declarations.filter {
            $0.domain == "task-group-iterator-member"
                && $0.name == "next"
        }.count == 4)
        #expect(capabilities.declarations.contains {
            $0.container == "TaskGroup.Iterator" && $0.name == "cancel"
                && $0.adapterIntrinsic == "cancel"
        })
        #expect(capabilities.declarations.contains {
            $0.container == "ThrowingTaskGroup.Iterator"
                && $0.name == "next" && $0.adapterIntrinsic == "next"
        })
        #expect(!generatedCapabilities.contains("implementationStatus"))
        #expect(!generatedCapabilities.contains("verificationStatus"))

        let inventory = try ConcurrencySurfaceGenerator.inventory(
            interfaceSource: interfaceSource)
        #expect(Set(inventory.topLevelFunctionDispatch.keys) == [
            "async", "asyncDetached", "detach", "withDiscardingTaskGroup",
            "withTaskCancellationHandler", "withTaskGroup",
            "withThrowingDiscardingTaskGroup",
            "withThrowingTaskGroup", "withUnsafeCurrentTask",
        ])
        #expect(inventory.knownTopLevelFunctions.contains("withUnsafeCurrentTask"))
        #expect(inventory.nominalMemberDeclarations["UnsafeCurrentTask"]?.values
            .flatMap { $0 }.count == 9)
        #expect(inventory.nominalMemberDispatch["UnsafeCurrentTask"]?["=="]
            == "currentTaskIdentityEquals")
        #expect(inventory.nominalMemberDispatch["UnsafeCurrentTask"]?["hash"]
            == nil)
        #expect(inventory.nominalMemberDispatch["UnsafeCurrentTask"]?[
            "escalatePriority"] == nil)
        #expect(inventory.nominalMemberDispatch["UnsafeCurrentTask"]?[
            "unownedTaskExecutor"] == nil)
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
        #expect(group["makeAsyncIterator"]?.contains {
            !$0.isAsync && !$0.isThrowing
        } == true)
        #expect(group["addTask"]?.contains { declaration in
            declaration.parameters.contains {
                $0.name == "operation" && $0.hasIsolatedFunctionType
            }
        } == true)
        #expect(group["addImmediateTask"]?.contains { declaration in
            declaration.parameters.contains {
                $0.label == "executorPreference"
                    && $0.name == "taskExecutor"
                    && $0.type.hasPrefix("consuming ")
                    && $0.defaultValue == "nil"
            } && declaration.parameters.contains {
                $0.name == "operation" && $0.inheritsActorContext
                    && $0.hasIsolatedFunctionType
            }
        } == true)
        #expect(group["addImmediateTaskUnlessCancelled"]?.contains {
            $0.returnType == "Swift.Bool"
        } == true)

        let taskGroupIterator = try #require(
            inventory.taskGroupIteratorMemberDeclarations["TaskGroup"])
        #expect(taskGroupIterator["next"]?.count == 2)
        #expect(taskGroupIterator["next"]?.contains { declaration in
            declaration.isAsync && !declaration.isThrowing
                && declaration.isMutating
                && declaration.parameters.contains {
                    $0.label == "isolation" && $0.isIsolated
                }
        } == true)
        #expect(taskGroupIterator["cancel"]?.contains {
            !$0.isAsync && !$0.isThrowing && $0.isMutating
        } == true)
        let throwingTaskGroupIterator = try #require(
            inventory.taskGroupIteratorMemberDeclarations[
                "ThrowingTaskGroup"])
        #expect(throwingTaskGroupIterator["next"]?.count == 2)
        #expect(throwingTaskGroupIterator["next"]?.allSatisfy {
            $0.isAsync && $0.isThrowing && $0.isMutating
        } == true)
        #expect(throwingTaskGroupIterator["next"]?.contains { declaration in
            declaration.thrownErrorType == "Failure"
                && declaration.parameters.contains {
                    $0.label == "isolation" && $0.isIsolated
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
        for name in ["immediate", "immediateDetached"] {
            let declarations = try #require(taskStatics[name])
            #expect(declarations.count == 2)
            #expect(declarations.allSatisfy { declaration in
                declaration.parameters.contains {
                    $0.label == "executorPreference"
                        && $0.name == "taskExecutor"
                        && $0.type.hasPrefix("consuming ")
                        && $0.defaultValue == "nil"
                } && declaration.parameters.contains {
                    $0.name == "operation"
                        && $0.inheritsActorContext
                        && $0.hasIsolatedFunctionType
                }
            })
        }
        #expect(taskStatics["name"]?.contains {
            $0.kind == .variable && $0.returnType == "Swift.String?"
                && !$0.isAsync && !$0.isThrowing
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
    public func withUnsafeCurrentTask<Result>(
        body: (UnsafeCurrentTask?) throws -> Result
    ) rethrows -> Result { fatalError() }
    public func withUnsafeCurrentTask<Result>(
        body: (UnsafeCurrentTask?) async throws -> Result
    ) async rethrows -> Result { fatalError() }
    public func async<Success>(
        priority: TaskPriority? = nil,
        @_inheritActorContext
        operation: @escaping @isolated(any) @Sendable () async -> Success
    ) -> Task<Success, Never> where Success: Sendable { fatalError() }
    public func async<Success>(
        priority: TaskPriority? = nil,
        @_inheritActorContext
        operation: @escaping @isolated(any) @Sendable () async throws -> Success
    ) -> Task<Success, any Error> where Success: Sendable { fatalError() }
    public func asyncDetached<Success>(
        priority: TaskPriority? = nil,
        @_inheritActorContext
        operation: @escaping @isolated(any) @Sendable () async -> Success
    ) -> Task<Success, Never> where Success: Sendable { fatalError() }
    public func asyncDetached<Success>(
        priority: TaskPriority? = nil,
        @_inheritActorContext
        operation: @escaping @isolated(any) @Sendable () async throws -> Success
    ) -> Task<Success, any Error> where Success: Sendable { fatalError() }
    public func detach<Success>(
        priority: TaskPriority? = nil,
        @_inheritActorContext
        operation: @escaping @isolated(any) @Sendable () async -> Success
    ) -> Task<Success, Never> where Success: Sendable { fatalError() }
    public func detach<Success>(
        priority: TaskPriority? = nil,
        @_inheritActorContext
        operation: @escaping @isolated(any) @Sendable () async throws -> Success
    ) -> Task<Success, any Error> where Success: Sendable { fatalError() }
    public func interfaceOnlyProbe() async {}

    public struct UnsafeCurrentTask {
        public var isCancelled: Bool { false }
        public var priority: TaskPriority { fatalError() }
        public var basePriority: TaskPriority { fatalError() }
        public func cancel() {}
    }
    extension UnsafeCurrentTask {
        public func hash(into hasher: inout Hasher) {}
        public var hashValue: Int { 0 }
        public static func == (
            lhs: UnsafeCurrentTask, rhs: UnsafeCurrentTask
        ) -> Bool { false }
        public func escalatePriority(to newPriority: TaskPriority) {}
        public var unownedTaskExecutor: UnownedTaskExecutor? { nil }
    }

    public struct TaskGroup<Child> {
        public mutating func addImmediateTask(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async -> Child
        ) {}
        public mutating func addImmediateTaskUnlessCancelled(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async -> Child
        ) -> Bool { true }
        public mutating func addTask(operation: () async -> Child) {}
        public mutating func addTask(operation: () async throws -> Child) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async -> Child
        ) -> Bool { true }
        public mutating func waitForAll() async {}
        public mutating func next() async -> Child? { nil }
        public func makeAsyncIterator() -> TaskGroup<Child>.Iterator {
            fatalError()
        }
        public struct Iterator {
            public mutating func next() async -> Child? { nil }
            public mutating func next(
                isolation actor: isolated (any Actor)?
            ) async -> Child? { nil }
            public mutating func cancel() {}
        }
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
        public mutating func addImmediateTask(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async throws -> Child
        ) {}
        public mutating func addImmediateTaskUnlessCancelled(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async throws -> Child
        ) -> Bool { true }
        public mutating func addTask(operation: () async throws -> Child) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async throws -> Child
        ) -> Bool { true }
        public mutating func waitForAll() async throws {}
        public mutating func next() async throws -> Child? { nil }
        public mutating func nextResult() async -> Result<Child, Failure>? { nil }
        public func makeAsyncIterator() -> ThrowingTaskGroup<Child, Failure>.Iterator {
            fatalError()
        }
        public struct Iterator {
            public mutating func next() async throws -> Child? { nil }
            public mutating func next(
                isolation actor: isolated (any Actor)?
            ) async throws(Failure) -> Child? { nil }
            public mutating func cancel() {}
        }
        public func cancelAll() {}
        public var isCancelled: Bool { false }
        public var isEmpty: Bool { true }
    }

    public struct DiscardingTaskGroup {
        public mutating func addImmediateTask(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async -> Void
        ) {}
        public mutating func addImmediateTaskUnlessCancelled(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async -> Void
        ) -> Bool { true }
        public mutating func addTask(operation: () async -> Void) {}
        public mutating func addTaskUnlessCancelled(
            operation: () async -> Void
        ) -> Bool { true }
        public func cancelAll() {}
        public var isCancelled: Bool { false }
        public var isEmpty: Bool { true }
    }

    public struct ThrowingDiscardingTaskGroup<Failure> {
        public mutating func addImmediateTask(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async throws -> Void
        ) {}
        public mutating func addImmediateTaskUnlessCancelled(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_inheritActorContext @_implicitSelfCapture
            operation: sending @escaping @isolated(any) () async throws -> Void
        ) -> Bool { true }
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
        public static var name: Swift.String? { nil }
        public static func checkCancellation() throws {}
        public static func yield() async {}
        public static func sleep(nanoseconds duration: UInt64) async throws {}
    }
    extension Task where Failure == Never {
        public static func detached(
            operation: @escaping @isolated(any) () async -> Success
        ) -> Task<Success, Never> { fatalError() }
    }
    extension Task where Failure == any Error {
        #if compiler(>=5.3)
        #if $AlwaysInheritActorContext
        public static func immediate(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_implicitSelfCapture @_inheritActorContext(always)
            operation: sending @escaping @isolated(any) () async throws -> Success
        ) -> Task<Success, any Error> { fatalError() }
        public static func immediateDetached(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_implicitSelfCapture @_inheritActorContext(always)
            operation: sending @escaping @isolated(any) () async throws -> Success
        ) -> Task<Success, any Error> { fatalError() }
        #else
        public static func inactiveConditionalProbe() {}
        #endif
        #endif
    }
    extension Task where Failure == Never {
        #if compiler(>=5.3) && $AlwaysInheritActorContext
        public static func immediate(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_implicitSelfCapture @_inheritActorContext(always)
            operation: sending @escaping @isolated(any) () async -> Success
        ) -> Task<Success, Never> { fatalError() }
        public static func immediateDetached(
            name: String? = nil,
            priority: TaskPriority? = nil,
            executorPreference taskExecutor: consuming (any TaskExecutor)? = nil,
            @_implicitSelfCapture @_inheritActorContext(always)
            operation: sending @escaping @isolated(any) () async -> Success
        ) -> Task<Success, Never> { fatalError() }
        #endif
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
    let id: String
    let complete: Bool
    let included: [String]
    let excluded: [String]
    let adapterRouteIsSupportEvidence: Bool
}

private struct CapabilitySummary: Decodable {
    let declarationCount: Int
    let declarationsByDomain: [String: Int]
    let adapterRoutedDeclarationCount: Int
}

private struct CapabilityDeclaration: Decodable, Equatable {
    let id: String
    let domain: String
    let container: String
    let name: String
    let declaration: String
    let adapterIntrinsic: String?
}
