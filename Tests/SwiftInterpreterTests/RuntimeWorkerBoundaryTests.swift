import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Runtime worker boundary")
struct RuntimeWorkerBoundaryTests {
    @Test func copiedEntryCapabilityCrossesDetachedBoundary() async throws {
        let interpreter = Interpreter()
        let session = interpreter.makeSession(
            program: try ParsedProgram(
                source: "let origin = 1",
                fileName: "WorkerOrigin.swift"))
        let capability = try session.runtimeEntry.makeWorkerCapability(
            copying: [
                .init(
                    name: "payload",
                    value: .array([
                        .native(2),
                        .dictionary(DictValue(
                            keys: [.native("three")],
                            values: [.native(3)])),
                        .some(.native(5), wrappedTypeName: "Int"),
                    ])),
            ])

        let observation = await Task.detached {
            let payload = capability.bindings[0].value
            return (
                capability.entryID,
                capability.entryKind,
                capability.programPlan?.fileName,
                payload,
                capability.accessManifest.isWorkerSafe)
        }.value

        #expect(observation.0 == session.id)
        #expect(observation.1 == .program)
        #expect(observation.2 == "WorkerOrigin.swift")
        #expect(observation.3 == .array([
            .int(2),
            .dictionary([
                .init(key: .string("three"), value: .int(3)),
            ]),
            .optional(
                wrapped: .int(5), wrappedTypeName: "Int",
                isImplicitlyUnwrapped: false),
        ]))
        #expect(observation.4)
    }

    @Test func copiedValuesPreserveEveryAdmittedRuntimeShape() throws {
        let interpreter = Interpreter()
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
        let values: [RuntimeValue] = [
            .void,
            .nilValue,
            .native(1),
            .native(2.5),
            .native(true),
            .native("value"),
            .array([.native(3)]),
            .dictionary(DictValue(
                keys: [.native("key")], values: [.native(4)])),
            .tuple(TupleValue(
                labels: ["label", nil],
                values: [.native(5), .native("six")])),
            .range(RuntimeRangeValue(
                lowerBound: .native(6), upperBound: .native(9),
                includesUpperBound: false)),
            .set(RuntimeSetValue(
                uniqueElements: [.native(7), .native(8)],
                elementTypeName: "Int")),
            .some(.native(9), wrappedTypeName: "Int"),
            .implicitMember("automatic"),
        ]

        let capability = try entry.makeWorkerCapability(
            copying: values.enumerated().map {
                .init(name: "value\($0.offset)", value: $0.element)
            })

        #expect(capability.bindings.map(\.value) == [
            .void,
            .nilValue,
            .int(1),
            .double(2.5),
            .bool(true),
            .string("value"),
            .array([.int(3)]),
            .dictionary([.init(key: .string("key"), value: .int(4))]),
            .tuple(labels: ["label", nil], values: [.int(5), .string("six")]),
            .range(lowerBound: .int(6), upperBound: .int(9), includesUpperBound: false),
            .set(elements: [.int(7), .int(8)], elementTypeName: "Int"),
            .optional(
                wrapped: .int(9), wrappedTypeName: "Int",
                isImplicitlyUnwrapped: false),
            .implicitMember("automatic"),
        ])
        #expect(capability.accessManifest.copiedValuePaths.count == 23)
        #expect(capability.accessManifest.excludedEntryEdges == [
            .heap: .mainActorConfined,
            .programState: .mainActorConfined,
            .interpreter: .mainActorConfined,
        ])
        #expect(capability.accessManifest.isWorkerSafe)
        #expect(capability.bindings.map {
            $0.value.materializedRuntimeValue().stringified
        } == values.map(\.stringified))
    }

    @Test func copiedStringIndexRemainsUsableWithItsStringSnapshot()
        async throws
    {
        let interpreter = Interpreter()
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
        let text = "A🛰️BC"
        let index = text.index(text.startIndex, offsetBy: 2)
        let capability = try entry.makeWorkerCapability(copying: [
            .init(name: "text", value: .native(text)),
            .init(name: "index", value: .native(index)),
        ])

        let distance = try await Task.detached {
            guard case .string(let copiedText) = capability.bindings[0].value,
                  case .stringIndex(let copiedIndex) =
                    capability.bindings[1].value else {
                throw RuntimeError(message: "invalid copied index fixture")
            }
            return copiedText.distance(
                from: copiedText.startIndex, to: copiedIndex)
        }.value

        #expect(distance == 2)
        #expect(capability.accessManifest.copiedValuePaths
            == ["input.text", "input.index"])
        #expect(capability.accessManifest.isWorkerSafe)
    }

    @Test func copiedURLRemainsTypedAcrossDetachedBoundary() async throws {
        let interpreter = Interpreter()
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
        let url = URL(fileURLWithPath: "/tmp/worker-url.mp4")
        let capability = try entry.makeWorkerCapability(copying: [
            .init(name: "url", value: .native(url)),
        ])

        let observation = try await Task.detached {
            guard case .url(let copiedURL) = capability.bindings[0].value else {
                throw RuntimeError(message: "invalid copied URL fixture")
            }
            return copiedURL
        }.value

        #expect(observation == url)
        #expect(observation.lastPathComponent == "worker-url.mp4")
        #expect(capability.accessManifest.copiedValuePaths == ["input.url"])
        #expect(capability.accessManifest.isWorkerSafe)
        #expect(capability.bindings[0].value.materializedRuntimeValue()
            .hostPayload as? URL == url)
    }

    @Test func confinedAndOpaqueValuesFailClosedAtTheExactEdge() throws {
        let interpreter = Interpreter()
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)
        let symbol = StructSymbol(name: "Token", conformsToView: false)
        let actorSymbol = StructSymbol(name: "Worker", conformsToView: false)
        actorSymbol.isActor = true
        let enumSymbol = EnumSymbol(name: "State")
        let closure = try #require(try interpreter.run(
            source: "{ 1 }").closureValue)
        let rejected: [(RuntimeValue, RuntimeHeapEdgeDisposition)] = [
            (.host(NSObject()), .rejectedNonSendable),
            (.instance(Instance(symbol: symbol)), .mainActorConfined),
            (.instance(Instance(symbol: actorSymbol)), .actorConfined),
            (.closure(closure), .mainActorConfined),
            (.hostFunction(HostFunction(name: "host") { _, _ in .void }),
             .mainActorConfined),
            (.type(symbol), .mainActorConfined),
            (.enumType(enumSymbol), .mainActorConfined),
            (.enumCase(EnumCaseValue(symbol: enumSymbol, name: "ready")),
             .mainActorConfined),
        ]

        for (index, item) in rejected.enumerated() {
            do {
                _ = try entry.makeWorkerCapability(copying: [
                    .init(
                        name: "payload",
                        value: .array([.native(index), item.0])),
                ])
                Issue.record("worker transfer accepted confined value \(index)")
            } catch let error as RuntimeWorkerTransferError {
                #expect(error.path == "input.payload[1]")
                #expect(error.disposition == item.1)
            }
        }
    }

    @Test func malformedContainersAndUnsafeManifestsFailClosed() throws {
        let interpreter = Interpreter()
        let entry = interpreter.concurrencyRuntime.createEntry(kind: .test)

        do {
            _ = try entry.makeWorkerCapability(copying: [
                .init(
                    name: "payload",
                    value: .dictionary(DictValue(
                        keys: [.native("orphan")], values: []))),
            ])
            Issue.record("worker transfer accepted malformed dictionary")
        } catch let error as RuntimeWorkerTransferError {
            #expect(error.path == "input.payload")
            #expect(error.valueKind == "malformed dictionary storage")
        }

        let valid = try entry.makeWorkerCapability(copying: [])
            .accessManifest
        let heapPolicyIndex = try #require(valid.entryEdges.firstIndex {
            $0.edge == .heap
        })
        var unsafeEntryEdges = valid.entryEdges
        unsafeEntryEdges[heapPolicyIndex] = .init(
            edge: .heap,
            disposition: .mainActorConfined,
            treatment: .retained)
        #expect(!RuntimeWorkerAccessManifest(
            entryEdges: unsafeEntryEdges,
            heapEdges: valid.heapEdges,
            copiedValuePaths: []).isWorkerSafe)
        #expect(!RuntimeWorkerAccessManifest(
            entryEdges: Array(valid.entryEdges.dropLast()),
            heapEdges: valid.heapEdges,
            copiedValuePaths: []).isWorkerSafe)
    }

    @Test func heapStoredRootsHaveACompleteFailClosedInventory() {
        let heap = RuntimeHeap()
        let storedLabels = Set(Mirror(reflecting: heap).children.compactMap(\.label))
        let classifiedLabels = Set(RuntimeWorkerHeapEdge.allCases.map(\.rawValue))

        #expect(storedLabels == classifiedLabels)
    }
}
