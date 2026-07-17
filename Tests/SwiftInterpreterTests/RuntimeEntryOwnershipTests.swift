import Testing
@testable import SwiftInterpreter

@Suite("Runtime entry ownership")
struct RuntimeEntryOwnershipTests {
    @Test func hostCallbackAndSpawnedTaskShareOneOwnedEntry() async throws {
        let interpreter = Interpreter()
        var observedIDs: [RuntimeSessionID] = []
        var observedKinds: [RuntimeEntry.Kind] = []
        var observedHeapMatches: [Bool] = []
        var observedMetadata: [ParsedCallableMetadataIndex.Summary?] = []
        var observedCallSiteCounts: [Int?] = []
        var observedMemberBlockCounts: [Int?] = []
        var observedTypeMemberFunctionCounts: [Int?] = []
        var observedBodylessFunctionCounts: [Int?] = []
        var observedInitializerCounts: [Int?] = []
        var observedFailableInitializerCounts: [Int?] = []
        var observedDeclarationCounts: [Int?] = []
        var observedNominalCounts: [Int?] = []
        var observedPropertyBindingCounts: [Int?] = []
        var observedEnumCaseCounts: [Int?] = []
        var observedExtensionCounts: [Int?] = []
        var observedTypeAliasCounts: [Int?] = []
        var observedDeinitializerCounts: [Int?] = []
        var observedProgramPlans: [ResolvedProgramPlan?] = []
        var observedProgramStates: [RuntimeProgramState?] = []
        weak var observedEntry: RuntimeEntry?
        interpreter.globals.define(
            "captureRuntimeEntry",
            .hostFunction(HostFunction(
                name: "captureRuntimeEntry",
                invoke: { _, _ in
                    guard let entry = interpreter.evaluationTaskContext.runtimeEntry else {
                        throw RuntimeError(message: "missing runtime entry")
                    }
                    observedEntry = entry
                    observedIDs.append(entry.id)
                    observedKinds.append(entry.kind)
                    observedHeapMatches.append(entry.heap === interpreter.runtimeHeap)
                    observedMetadata.append(entry.callableMetadataIndex?.summary)
                    observedCallSiteCounts.append(entry.programMetadata?
                        .callSiteMetadataIndex.summary.callCount)
                    observedMemberBlockCounts.append(entry.programMetadata?
                        .memberMetadataIndex.summary.memberBlockCount)
                    observedTypeMemberFunctionCounts.append(
                        entry.callableMetadataIndex?.summary
                            .typeMemberFunctionCount)
                    observedBodylessFunctionCounts.append(
                        entry.callableMetadataIndex?.summary
                            .bodylessFunctionCount)
                    observedInitializerCounts.append(
                        entry.callableMetadataIndex?.summary.initializerCount)
                    observedFailableInitializerCounts.append(
                        entry.callableMetadataIndex?.summary
                            .failableInitializerCount)
                    observedDeclarationCounts.append(entry.programMetadata?
                        .declarationIndex.summary
                        .possiblePrimaryDeclarationCount)
                    observedNominalCounts.append(entry.programMetadata?
                        .nominalMetadataIndex.summary.structureCount)
                    observedPropertyBindingCounts.append(entry.programMetadata?
                        .propertyMetadataIndex.summary.bindingCount)
                    observedEnumCaseCounts.append(entry.programMetadata?
                        .enumCaseMetadataIndex.summary.caseElementCount)
                    observedExtensionCounts.append(entry.programMetadata?
                        .extensionMetadataIndex.summary.extensionCount)
                    observedTypeAliasCounts.append(entry.programMetadata?
                        .typeAliasMetadataIndex.summary.typeAliasCount)
                    observedDeinitializerCounts.append(entry.programMetadata?
                        .deinitializerMetadataIndex.summary.deinitializerCount)
                    observedProgramPlans.append(entry.programPlan)
                    observedProgramStates.append(entry.programState)
                    return .void
                })))
        let value = try interpreter.run(source: """
        struct OriginMarker {
            let value = 1
            final class Lifetime { deinit {} }
            static func origin() {}
            init?(originValue: Int) { return nil }
        }
        enum OriginState { case ready }
        protocol OriginAPI { func requiredValue() }
        extension OriginMarker {}
        typealias OriginAlias = OriginMarker
        func makeCallback() -> () -> Void {
            {
                captureRuntimeEntry()
                Task {
                    captureRuntimeEntry()
                }
            }
        }
        makeCallback()
        """)
        let closure = try #require(value.closureValue)
        let originatingPlan = try #require(closure.programPlan)
        let originatingState = try #require(closure.programState)
        let newerSession = interpreter.makeSession(
            program: try ParsedProgram(source: """
        struct NewerMarker {
            let value = 1
            final class Lifetime { deinit {} }
            static func newerTypeValue() {}
            init(newerValue: Int) {}
        }
        struct NewestMarker {
            let value = 2
            final class Lifetime { deinit {} }
            static func newestTypeValue() {}
            init(newestValue: Int) {}
        }
        enum NewerState { case first; case second }
        extension NewerMarker {}
        extension NewestMarker {}
        typealias NewerAlias = NewerMarker
        typealias NewestAlias = NewestMarker
        func newer() {}
        func newest() {}
        """))
        #expect(newerSession.programState !== originatingState)
        #expect(originatingState.programPlan === originatingPlan)
        #expect(originatingState.structSymbols.contains {
            $0.name == "OriginMarker"
        })

        _ = try interpreter.callHostCallback(closure, arguments: [])

        #expect(observedIDs.count == 1)
        #expect(observedEntry != nil,
            "the spawned task record must retain its callback entry")
        for _ in 0..<10_000
        where !interpreter.scheduledTasks.isEmpty
            || interpreter.concurrencyRuntime.activeRecordCount != 0 {
            await Task.yield()
        }
        #expect(observedIDs.count == 2)
        #expect(Set(observedIDs).count == 1)
        #expect(observedKinds == [.hostCallback, .hostCallback])
        #expect(observedHeapMatches == [true, true])
        #expect(observedMetadata.map { $0?.functionCount } == [3, 3])
        #expect(observedCallSiteCounts == [4, 4])
        #expect(observedMemberBlockCounts == [5, 5])
        #expect(observedTypeMemberFunctionCounts == [1, 1])
        #expect(observedBodylessFunctionCounts == [1, 1])
        #expect(observedInitializerCounts == [1, 1])
        #expect(observedFailableInitializerCounts == [1, 1])
        #expect(observedDeclarationCounts == [4, 4])
        #expect(observedNominalCounts == [1, 1])
        #expect(observedPropertyBindingCounts == [1, 1])
        #expect(observedEnumCaseCounts == [1, 1])
        #expect(observedExtensionCounts == [1, 1])
        #expect(observedTypeAliasCounts == [1, 1])
        #expect(observedDeinitializerCounts == [1, 1])
        #expect(observedProgramPlans.count == 2)
        #expect(observedProgramPlans.allSatisfy { $0 === originatingPlan })
        #expect(observedProgramStates.count == 2)
        #expect(observedProgramStates.allSatisfy {
            $0 === originatingState
        })
        #expect(observedEntry == nil,
            "the runtime entry must release after its final task record")
    }

    @Test func separateCallbacksUseDistinctEntriesAgainstTheSameHeap() throws {
        let interpreter = Interpreter()
        var observedIDs: [RuntimeSessionID] = []
        var observedHeapMatches: [Bool] = []
        interpreter.globals.define(
            "captureRuntimeEntry",
            .hostFunction(HostFunction(
                name: "captureRuntimeEntry",
                invoke: { _, _ in
                    guard let entry = interpreter.evaluationTaskContext.runtimeEntry else {
                        throw RuntimeError(message: "missing runtime entry")
                    }
                    observedIDs.append(entry.id)
                    observedHeapMatches.append(entry.heap === interpreter.runtimeHeap)
                    return .void
                })))
        let value = try interpreter.run(source: """
        func makeCallback() -> () -> Void {
            { captureRuntimeEntry() }
        }
        makeCallback()
        """)
        let closure = try #require(value.closureValue)

        _ = try interpreter.callHostCallback(closure, arguments: [])
        _ = try interpreter.callHostCallback(closure, arguments: [])

        #expect(observedIDs.count == 2)
        #expect(Set(observedIDs).count == 2)
        #expect(observedHeapMatches == [true, true])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }
}
