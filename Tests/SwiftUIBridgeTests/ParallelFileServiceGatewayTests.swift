import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// The declarative file-service table (FileServiceOperations) drives BOTH
/// execution faces of every forwarded FileManager member. These tests pin:
/// exact source-visible behavior in cooperative AND parallel modes (the two
/// faces can never disagree — they share one prepared kernel), physical
/// submission/execution receipts, argument-shape behavior, source-shadow
/// rejection, and the route-metadata mirror.
///
/// Serialized: the probes perform real file operations against the shared
/// per-process sandbox; overlap belongs to the corpus/gate stages, not here.
@Suite("Parallel file service gateways", .serialized)
struct ParallelFileServiceGatewayTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runFixture(
        named fixtureName: String,
        entry: String,
        expected: String,
        parallelSubmissions: Int,
        parallelExecutions: Int
    ) async throws {
        let fixture = repositoryRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Fixtures/\(fixtureName).swift")
        let source = try String(contentsOf: fixture, encoding: .utf8)
            + "\n\(entry)\n"
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == expected)
        #expect(parallelValue.stringValue == expected)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(cooperative.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == parallelSubmissions)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == parallelExecutions)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func detachedFileManagerMoveUsesAWorkerAndPropagatesFailure()
        async throws
    {
        try await runFixture(
            named: "parallel-detached-file-manager-move",
            entry: "await parallelDetachedFileManagerMoveProbe()",
            expected:
                "worker|source:false|destination:true|copy:true|missing:error",
            parallelSubmissions: 4,
            parallelExecutions: 3)
    }

    @Test
    func detachedFileManagerRemoveUsesAWorkerAndPropagatesFailure()
        async throws
    {
        try await runFixture(
            named: "parallel-detached-file-manager-remove",
            entry: "await parallelDetachedFileManagerRemoveProbe()",
            expected: "url:true|path:true|missing:error",
            parallelSubmissions: 3,
            parallelExecutions: 2)
    }

    @Test
    func detachedFileManagerExistsUsesAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-exists",
            entry: "await parallelDetachedFileManagerExistsProbe()",
            expected: "present:true|missing:false",
            parallelSubmissions: 2,
            parallelExecutions: 2)
    }

    @Test
    func detachedFileManagerCreateDirectoryUsesAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-create-directory",
            entry: "await parallelDetachedFileManagerCreateDirectoryProbe()",
            expected: "url:true|path:true",
            parallelSubmissions: 2,
            parallelExecutions: 2)
    }

    @Test
    func detachedFileManagerListUsesAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-list",
            entry: "await parallelDetachedFileManagerListProbe()",
            expected: "alpha|beta|gamma",
            parallelSubmissions: 1,
            parallelExecutions: 1)
    }

    @Test
    func sourceShadowedFileManagerStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func moveItem(at: String, to: String) -> String {
                "source:\\(at):\\(to)"
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.moveItem(at: "a", to: "b")
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "source:a:b")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceShadowedFileManagerRemoveStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func removeItem(at: String) -> String {
                "removed:" + at
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.removeItem(at: "source")
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "removed:source")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceShadowedFileManagerExistsStaysOnTheConfinedEvaluator()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func fileExists(atPath: String) -> String {
                "source:" + atPath
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.fileExists(atPath: "path")
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "source:path")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func sourceShadowedFileManagerCreateDirectoryStaysConfined()
        async throws
    {
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        struct FileManager {
            static let `default` = FileManager()

            func createDirectory(
                at: String, withIntermediateDirectories: Bool
            ) -> String {
                "source:" + at
            }
        }

        func probe() async -> String {
            await Task.detached {
                FileManager.default.createDirectory(
                    at: "path", withIntermediateDirectories: true)
            }.value
        }

        await probe()
        """)

        #expect(value.stringValue == "source:path")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func createDirectoryArgumentShapesShareTheRowSemantics()
        async throws
    {
        // One table row serves every accepted argument shape, so the
        // uncited spellings (withIntermediateDirectories: false, explicit
        // attributes) cross like the cited ones and produce the identical
        // sandbox-lenient effect on both faces.
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        func probe() async -> String {
            let root = FileManager.default.temporaryDirectory
            let first = root.appendingPathComponent("without-intermediates")
            let second = root.appendingPathComponent("with-attributes")
            try? await Task.detached {
                try FileManager.default.createDirectory(
                    at: first, withIntermediateDirectories: false)
            }.value
            try? await Task.detached {
                try FileManager.default.createDirectory(
                    at: second,
                    withIntermediateDirectories: true,
                    attributes: nil)
            }.value
            let created = FileManager.default.fileExists(atPath: first.path)
                && FileManager.default.fileExists(atPath: second.path)
            return created ? "created" : "missing"
        }

        await probe()
        """)

        #expect(value.stringValue == "created")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 2)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 2)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func fileManagerExistsIsDirectoryShapeSharesTheRowSemantics()
        async throws
    {
        // The confined face has always answered the isDirectory: spelling
        // by reading atPath and ignoring the out-parameter; the worker face
        // shares that row, so the shape crosses with the same answer.
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let interpreter = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let value = try await interpreter.runAsync(source: """
        func probe() async -> String {
            let path = FileManager.default.temporaryDirectory.path
            let exists = await Task.detached {
                FileManager.default.fileExists(
                    atPath: path, isDirectory: nil)
            }.value
            return exists ? "exists" : "missing"
        }

        await probe()
        """)

        #expect(value.stringValue == "exists")
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(interpreter.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func routeMetadataMirrorsTheOperationTable() async {
        let registry = ViewRegistry()

        await MainActor.run {
            #expect(FileServiceRouting.workerRoutedMembers
                == Set(FileServiceOperations.all.map(\.member)))
        }
        #expect(registry.hostMemberHasWorkerOperation(
            "removeItem", onStaticMember: "default", ofType: "FileManager"))
        #expect(registry.hostMemberHasWorkerOperation(
            "contentsOfDirectory",
            onStaticMember: "default",
            ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "enumerator", onStaticMember: "default", ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "temporaryDirectory",
            onStaticMember: "default",
            ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "removeItem", onStaticMember: "shared", ofType: "FileManager"))
        #expect(!registry.hostMemberHasWorkerOperation(
            "removeItem", onStaticMember: "default", ofType: "Bundle"))
    }

    @Test
    func detachedFileManagerPathFormsUseAWorker() async throws {
        try await runFixture(
            named: "parallel-detached-file-manager-path-forms",
            entry: "await parallelDetachedFileManagerPathFormsProbe()",
            expected: "copied:true|moved:true|names:inner",
            parallelSubmissions: 3,
            parallelExecutions: 3)
    }

    @Test
    func sandboxEscapeIsRejectedIdenticallyOnBothFaces() async throws {
        // The confinement policy is part of the row's prepare, so a
        // detached escape attempt fails exactly like a cooperative one —
        // before any job is submitted — and the mapped error is
        // source-catchable.
        let source = """
        func probe() async -> String {
            do {
                try await Task.detached {
                    try FileManager.default.removeItem(
                        atPath: "/tmp/dynamic-swiftui-escape-probe")
                }.value
                return "accepted"
            } catch {
                let text = "\\(error)"
                return text.contains("outside the app sandbox")
                    ? "confined" : "other:" + text
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "confined")
        #expect(parallelValue.stringValue == "confined")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func mappedFailureDescriptionAgreesAcrossFaces() async throws {
        // A missing-item removal inside the sandbox fails during kernel
        // execution: cooperatively on the owning actor, physically on a
        // worker. The mapped error must read identically from source in
        // both modes.
        let source = """
        func probe() async -> String {
            let victim = FileManager.default.temporaryDirectory
                .appendingPathComponent("never-created-item")
            do {
                try await Task.detached {
                    try FileManager.default.removeItem(at: victim)
                }.value
                return "accepted"
            } catch {
                return error.localizedDescription
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        let cooperativeText = cooperativeValue.stringValue ?? ""
        #expect(cooperativeText.hasPrefix("removeItem:"))
        #expect(cooperativeValue.stringValue == parallelValue.stringValue)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func workerListedURLsBehaveAsOrdinaryArraysInSource() async throws {
        // The widened value vocabulary must round-trip a URL array into an
        // ordinary source array: count, iteration, and member projection.
        let source = """
        func probe() async -> String {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
                .appendingPathComponent("round-trip", isDirectory: true)
            try? manager.createDirectory(
                at: root.appendingPathComponent("a", isDirectory: true),
                withIntermediateDirectories: true)
            try? manager.createDirectory(
                at: root.appendingPathComponent("b", isDirectory: true),
                withIntermediateDirectories: true)
            let listed = try! await Task.detached {
                try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil)
            }.value
            var names: [String] = []
            for url in listed { names.append(url.lastPathComponent) }
            let first = names.sorted().first ?? "none"
            return "count:\\(listed.count)|first:\\(first)"
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "count:2|first:a")
        #expect(parallelValue.stringValue == "count:2|first:a")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func detachedCancellationDoesNotSuppressFileOperations() async throws {
        // Native semantics: a detached body always runs; a synchronous
        // file operation inside it does not observe cancellation. The
        // physical face must not turn a cancelled handle into a skipped
        // or failed operation.
        let source = """
        func probe() async -> String {
            let manager = FileManager.default
            let victim = manager.temporaryDirectory
                .appendingPathComponent("cancelled-remove", isDirectory: true)
            try? manager.createDirectory(
                at: victim, withIntermediateDirectories: true)
            let handle = Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: victim)
            }
            handle.cancel()
            do {
                try await handle.value
            } catch {
                return "threw"
            }
            let removed = !manager.fileExists(atPath: victim.path)
            return removed ? "removed" : "survived"
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "removed")
        #expect(parallelValue.stringValue == "removed")
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func outsideSandboxQueriesPassThroughOnBothFaces() async throws {
        // The stated policy: non-throwing queries are unrestricted. A
        // detached existence read of a real system path crosses and
        // answers truthfully, exactly like the confined face always has.
        let source = """
        func probe() async -> String {
            let exists = await Task.detached {
                FileManager.default.fileExists(atPath: "/")
            }.value
            return exists ? "true" : "false"
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "true")
        #expect(parallelValue.stringValue == "true")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func contendingDetachedRemovalsDrainDeterministically() async throws {
        // Two detached removals of the same item under a one-permit pool:
        // FIFO order makes the first succeed and the second fail with the
        // mapped missing-item error; the failed job still drains its
        // permit and record. Cooperative mode serializes identically.
        let source = """
        func probe() async -> String {
            let manager = FileManager.default
            let victim = manager.temporaryDirectory
                .appendingPathComponent("contended-remove", isDirectory: true)
            try? manager.createDirectory(
                at: victim, withIntermediateDirectories: true)
            let first = Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: victim)
            }
            let second = Task.detached(priority: .userInitiated) {
                try FileManager.default.removeItem(at: victim)
            }
            var outcomes: [String] = []
            do { try await first.value; outcomes.append("ok") }
            catch { outcomes.append("error") }
            do { try await second.value; outcomes.append("ok") }
            catch { outcomes.append("error") }
            return outcomes.joined(separator: "|")
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "ok|error")
        #expect(parallelValue.stringValue == "ok|error")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 2)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func createDirectoryExplicitAttributesAreSandboxInert() async throws {
        // The sandbox-analog row ignores explicit attributes (a fresh
        // container accepts permissive creation); this pins the divergence
        // deliberately: the directory exists, creation succeeded, and both
        // faces agree. Attribute application remains a documented
        // non-goal of the fresh-container reading.
        let source = """
        func probe() async -> String {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("attributed", isDirectory: true)
            do {
                try await Task.detached {
                    try FileManager.default.createDirectory(
                        at: target,
                        withIntermediateDirectories: true,
                        attributes: [FileAttributeKey.posixPermissions: 448])
                }.value
            } catch {
                return "threw"
            }
            let created = FileManager.default.fileExists(atPath: target.path)
            return created ? "created" : "missing"
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "created")
        #expect(parallelValue.stringValue == "created")
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func symlinkedParentCannotSmuggleMutationsOutside() async throws {
        // Admission resolves the directory chain: a link inside the
        // container pointing outside must not carry a mutation out, on
        // either face, and the outside target stays untouched.
        let registry = ViewRegistry()
        let box = registry.fileManagerBox
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "outside-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: box.sandboxRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: box.sandboxRoot.appendingPathComponent("escape"),
            withDestinationURL: outside)

        let source = """
        func probe() async -> String {
            let link = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("escape", isDirectory: true)
                .appendingPathComponent("smuggled", isDirectory: true)
            do {
                try await Task.detached {
                    try FileManager.default.createDirectory(
                        at: link, withIntermediateDirectories: true)
                }.value
                return "accepted"
            } catch {
                let text = "\\(error)"
                return text.contains("outside the app sandbox")
                    ? "confined" : "other:" + text
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let parallel = Interpreter(
            registry: registry,
            executionMode: .parallel(parallelism))

        let parallelValue = try await parallel.runAsync(source: source)

        #expect(parallelValue.stringValue == "confined")
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("smuggled").path))
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func removingASymlinkInsideTheSandboxStaysLegal() async throws {
        // The leaf stays unresolved: native removeItem on a link removes
        // the LINK. Deleting an in-container link is an ordinary mutation
        // and must not be rejected because its target lives outside.
        let registry = ViewRegistry()
        let box = registry.fileManagerBox
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "outside-survivor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: box.sandboxRoot, withIntermediateDirectories: true)
        let link = box.sandboxRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside)

        let source = """
        func probe() async -> String {
            let link = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("escape")
            do {
                try await Task.detached {
                    try FileManager.default.removeItem(at: link)
                }.value
                return "removed"
            } catch {
                return "threw"
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let parallel = Interpreter(
            registry: registry,
            executionMode: .parallel(parallelism))

        let parallelValue = try await parallel.runAsync(source: source)

        #expect(parallelValue.stringValue == "removed")
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: link.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func moveOntoExistingDestinationFailsAlikeOnBothFaces() async throws {
        let source = """
        func probe() async -> String {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
            let a = root.appendingPathComponent("occupant-a", isDirectory: true)
            let b = root.appendingPathComponent("occupant-b", isDirectory: true)
            try? manager.createDirectory(at: a, withIntermediateDirectories: true)
            try? manager.createDirectory(at: b, withIntermediateDirectories: true)
            do {
                try await Task.detached {
                    try FileManager.default.moveItem(at: a, to: b)
                }.value
                return "accepted"
            } catch {
                let text = error.localizedDescription
                return text.hasPrefix("moveItem:") ? "mapped-error" : "other"
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "mapped-error")
        #expect(parallelValue.stringValue == "mapped-error")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func emptyPathQueriesAnswerFalseOnBothFaces() async throws {
        let source = """
        func probe() async -> String {
            let exists = await Task.detached {
                FileManager.default.fileExists(atPath: "")
            }.value
            return exists ? "true" : "false"
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "false")
        #expect(parallelValue.stringValue == "false")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func existenceReadsFollowDanglingLinksLikeNative() async throws {
        // Native fileExists follows links: a dangling link answers false
        // even though the link entry itself exists. The kernel calls the
        // real API, so both faces inherit exactly that.
        let registry = ViewRegistry()
        let box = registry.fileManagerBox
        try FileManager.default.createDirectory(
            at: box.sandboxRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: box.sandboxRoot.appendingPathComponent("dangling"),
            withDestinationURL: box.sandboxRoot
                .appendingPathComponent("never-created"))

        let source = """
        func probe() async -> String {
            let link = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("dangling")
            let exists = await Task.detached {
                FileManager.default.fileExists(atPath: link.path)
            }.value
            return exists ? "true" : "false"
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let parallel = Interpreter(
            registry: registry,
            executionMode: .parallel(parallelism))

        let parallelValue = try await parallel.runAsync(source: source)

        #expect(parallelValue.stringValue == "false")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 1)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 1)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func unicodePathComponentsRoundTripThroughWorkers() async throws {
        let source = """
        func probe() async -> String {
            let manager = FileManager.default
            let root = manager.temporaryDirectory
                .appendingPathComponent("üñïçødé-🚚", isDirectory: true)
            do {
                try await Task.detached {
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent("ïnner-🍩", isDirectory: true),
                        withIntermediateDirectories: true)
                }.value
                let names = try await Task.detached {
                    try FileManager.default.contentsOfDirectory(atPath: root.path)
                }.value
                try await Task.detached {
                    try FileManager.default.removeItem(at: root)
                }.value
                let gone = !manager.fileExists(atPath: root.path)
                return "names:\\(names.joined(separator: ","))|gone:\\(gone)"
            } catch {
                return "threw"
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "names:ïnner-🍩|gone:true")
        #expect(parallelValue.stringValue == "names:ïnner-🍩|gone:true")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 3)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 3)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func relativePathMutationsAreRejectedOnBothFaces() async throws {
        // A relative path resolves against the process CWD — outside the
        // container by construction. Admission rejects it identically on
        // both faces before any submission.
        let source = """
        func probe() async -> String {
            do {
                try await Task.detached {
                    try FileManager.default.removeItem(
                        atPath: "relative/never-here")
                }.value
                return "accepted"
            } catch {
                let text = "\\(error)"
                return text.contains("outside the app sandbox")
                    ? "confined" : "other:" + text
            }
        }

        await probe()
        """
        let parallelism = try RuntimeParallelismConfiguration(
            maximumParallelism: 1)
        let cooperative = Interpreter(registry: ViewRegistry())
        let parallel = Interpreter(
            registry: ViewRegistry(),
            executionMode: .parallel(parallelism))

        let cooperativeValue = try await cooperative.runAsync(source: source)
        let parallelValue = try await parallel.runAsync(source: source)

        #expect(cooperativeValue.stringValue == "confined")
        #expect(parallelValue.stringValue == "confined")
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationSubmissions == 0)
        #expect(parallel.concurrencyRuntime
            .totalPhysicalHostOperationExecutions == 0)
        #expect(parallel.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(parallel.concurrencyRuntime.activeRecordCount == 0)
    }

    @Test
    func fileManagerSandboxIsOwnedByItsRegistry() throws {
        // The parallel-worker sandbox race: a process-global root let any
        // concurrent verification reset delete or redirect an in-flight
        // interpreter's files. Each registry owns its container now, and
        // the bridge-environment reset must not touch it.
        let firstRegistry = ViewRegistry()
        let secondRegistry = ViewRegistry()
        let firstRoot = firstRegistry.fileManagerBox.sandboxRoot
        let secondRoot = secondRegistry.fileManagerBox.sandboxRoot
        let sentinel = firstRoot.appendingPathComponent("sentinel.txt")

        #expect(firstRoot != secondRoot)
        try FileManager.default.createDirectory(
            at: firstRoot,
            withIntermediateDirectories: true)
        try Data("alive".utf8).write(to: sentinel)

        secondRegistry.storeBlob(.native("other-registry"), at: sentinel.path)
        HeadlessVerifier.resetBridgeEnvironment()

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "alive")
        #expect(firstRegistry.fileManagerBox.blobStore[sentinel.path] == nil)
        #expect(secondRegistry.fileManagerBox.blobStore[sentinel.path]?.stringValue
            == "other-registry")
    }
}
