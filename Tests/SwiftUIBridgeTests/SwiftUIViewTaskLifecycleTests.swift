import AppKit
import Foundation
import SwiftUI
@testable import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

private struct InterpretedRefreshActionTriggerHost: View {
    @SwiftUI.Environment(\.refresh) private var refresh
    let onReturned: @MainActor @Sendable () -> Void

    var body: some View {
        Text("interpreted-refresh-action-trigger")
            .task {
                if let refresh {
                    await refresh()
                }
                onReturned()
            }
    }
}

private final class WeakLifecycleReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

@Suite(.serialized)
struct SwiftUIViewTaskLifecycleTests {
    @MainActor
    private func makeLifecycleWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        HeadlessWindowTestLifetime.retain(window)
        return window
    }

    @MainActor
    private func retireLifecycleWindow(_ window: NSWindow) async {
        HeadlessWindowTestLifetime.retire(window)
        await Task.yield()
    }

    private func waitUntil(
        timeout: Duration = .seconds(30),
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            // Sleeping, rather than repeatedly yielding, removes this test
            // from the MainActor runnable queue long enough for SwiftUI's
            // view task and the interpreter driver to make progress under the
            // fully parallel repository gate.
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func lifecycleDiagnostics() -> [String] {
        RenderDiagnostics.errors.compactMap { diagnostic in
            guard diagnostic.view == "generated SwiftUI async action" else {
                return nil
            }
            return "\(diagnostic.view): \(diagnostic.error)"
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixture: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/view-task-runtime-entry.swift")
    }

    private var nativeMain: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/ViewTaskLifecycleMain.swift")
    }

    private var cancellationFixture: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/view-task-disappearance-cancellation.swift")
    }

    private var idFixture: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/view-task-id-replacement.swift")
    }

    private var sameIDFixture: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/view-task-same-id-stability.swift")
    }

    private var refreshableFixture: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/view-refreshable-completion.swift")
    }

    private var refreshTriggerSupport: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/ViewRefreshActionTriggerSupport.swift")
    }

    private var teardownFixture: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/NativeProbes/SwiftUI/view-task-teardown-stress.swift")
    }

    private func run(
        _ executable: URL,
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? "",
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? "")
    }

    @Test
    func asyncLifecycleModifierSurfaceComesFromBridgeGen() throws {
        let task = try #require(GeneratedModifiers.table["task"])
        let refreshable = try #require(GeneratedModifiers.table["refreshable"])
        #expect(task.byArity[1]?.contains { overload in
            overload.params.count == 1
                && overload.params[0].label == nil
                && overload.params[0].tag == .asyncAction
        } == true)
        #expect(task.byArity[2]?.contains { overload in
            overload.params.map(\.label) == ["id", nil]
                && overload.params.map(\.tag) == [.equatable, .asyncAction]
        } == true)
        #expect(task.byArity[3]?.contains { overload in
            overload.params.map(\.label) == ["id", "priority", nil]
                && overload.params.first?.tag == .equatable
                && overload.params.last?.tag == .asyncAction
        } == true)
        #expect(refreshable.byArity[1]?.contains { overload in
            overload.params.map(\.label) == ["action"]
                && overload.params.map(\.tag) == [.asyncAction]
        } == true)

        let registry = ViewRegistry()
        #expect(registry.modifiers["task"] == nil)
        #expect(registry.modifiers["refreshable"] == nil)
        #expect(registry.modifier(named: "task") != nil)
        #expect(registry.modifier(named: "refreshable") != nil)
    }

    @Test
    func nativeSwiftUILifecycleGuaranteesRemainStable() throws {
        let binary = FileManager.default.temporaryDirectory
            .appendingPathComponent("view-task-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: binary) }

        let compilation = try run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            [
                "swiftc",
                "-swift-version", "6",
                "-strict-concurrency=complete",
                "-warnings-as-errors",
                "-parse-as-library",
                fixture.path,
                cancellationFixture.path,
                idFixture.path,
                sameIDFixture.path,
                refreshableFixture.path,
                refreshTriggerSupport.path,
                teardownFixture.path,
                nativeMain.path,
                "-o", binary.path,
            ])
        #expect(compilation.status == 0, Comment(rawValue: compilation.stderr))
        guard compilation.status == 0 else { return }

        let observation = try run(binary, [])
        #expect(observation.status == 0, Comment(rawValue: observation.stderr))
        #expect(
            observation.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == "entry=started,value:21|disappearance=started,cancelled|"
                    + "id=cancel:1,cancel:2,start:1,start:2|"
                    + "same-id=finish:first,render:first,render:same,start:first|"
                    + "refreshable=started,finished,returned|"
                    + "teardown=cycles=32,starts=32,cancels=32,exact=true,"
                    + "unexpected=0")
    }

    @Test
    func interpretedSwiftUIStartsAsyncTaskBodyInCanonicalAsyncContext() async throws {
        let source = try String(contentsOf: fixture, encoding: .utf8)
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)

        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("view-task probe did not instantiate")
            return
        }
        let rendered = try interpreter.evaluateBody(of: instance)
        let hostingView = NSHostingView(rootView: try ViewRegistry.anyView(rendered))
        let window = makeLifecycleWindow()
        window.contentView = hostingView
        window.orderFrontRegardless()

        var events: [String] = []
        await waitUntil {
            events = interpreter.globals.lookup("swiftUIViewTaskEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
            return events.count >= 2
        }

        let diagnostics = lifecycleDiagnostics().joined(separator: " | ")
        let runtime = "active=\(interpreter.concurrencyRuntime.activeRecordCount) "
            + interpreter.concurrencyRuntime.records.values.map {
                "\($0.kind.rawValue):\($0.state.rawValue)"
            }.sorted().joined(separator: ",")
        #expect(
            events == ["started", "value:21"],
            Comment(rawValue: diagnostics + " " + runtime))

        await waitUntil {
            interpreter.concurrencyRuntime.activeRecordCount == 0
        }
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(lifecycleDiagnostics().isEmpty)
        await retireLifecycleWindow(window)
    }

    @Test
    func interpretedSwiftUICancelsTaskWhenViewDisappears() async throws {
        let source = try String(contentsOf: cancellationFixture, encoding: .utf8)
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)

        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("view-task cancellation probe did not instantiate")
            return
        }
        let rendered = try interpreter.evaluateBody(of: instance)
        let hostingView = NSHostingView(
            rootView: AnyView(try ViewRegistry.anyView(rendered)))
        let window = makeLifecycleWindow()
        window.contentView = hostingView
        window.orderFrontRegardless()

        var events: [String] = []
        func hasWaitingSwiftUITask() -> Bool {
            interpreter.concurrencyRuntime.records.values.contains {
                $0.kind == .swiftUITask
                    && $0.entry.kind == .swiftUITask
                    && $0.entry.heap === interpreter.runtimeHeap
                    && $0.entry.interpreter === interpreter
                    && $0.entry.programMetadata != nil
                    && $0.state == .waiting
                    && $0.executorPreference == .mainActor
                    && $0.evaluationContext?.currentExecutor == .mainActor
            }
        }
        await waitUntil {
            events = interpreter.globals.lookup("swiftUIViewTaskCancellationEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
            return !events.isEmpty && hasWaitingSwiftUITask()
        }

        #expect(events == ["started"])
        let runtimeSnapshot = interpreter.concurrencyRuntime.records.values
            .map {
                "\($0.kind.rawValue):\($0.state.rawValue):"
                    + "entry=\($0.entry.kind):"
                    + "metadata=\($0.entry.programMetadata != nil):"
                    + "plan=\($0.entry.programPlan != nil):"
                    + "heap=\($0.entry.heap === interpreter.runtimeHeap):"
                    + "interpreter=\($0.entry.interpreter === interpreter):"
                    + "executor=\(String(describing: $0.executorPreference)):"
                    + "context=\(String(describing: $0.evaluationContext?.currentExecutor))"
            }
            .sorted()
            .joined(separator: ",")
        #expect(hasWaitingSwiftUITask(),
            Comment(rawValue: "records=[\(runtimeSnapshot)]"))

        hostingView.rootView = AnyView(EmptyView())
        await waitUntil {
            events = interpreter.globals.lookup("swiftUIViewTaskCancellationEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
            return events.count >= 2
        }

        await waitUntil {
            interpreter.concurrencyRuntime.activeRecordCount == 0
        }
        #expect(events == ["started", "cancelled"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(lifecycleDiagnostics().isEmpty)
        await retireLifecycleWindow(window)
    }

    @Test
    func interpretedSwiftUIReplacesTaskWhenIDChanges() async throws {
        let source = try String(contentsOf: idFixture, encoding: .utf8)
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)

        let symbol = try #require(interpreter.rootViewSymbol())
        func render(id: Int) throws -> AnyView {
            guard case .instance(let instance) = try interpreter.instantiateForBridge(
                symbol,
                arguments: CallArguments(arguments: [
                    .init(label: "id", value: .native(id)),
                ])) else {
                throw RuntimeError(message: "view-task id probe did not instantiate")
            }
            return AnyView(try ViewRegistry.anyView(
                interpreter.evaluateBody(of: instance)))
        }

        let hostingView = NSHostingView(rootView: try render(id: 1))
        let window = makeLifecycleWindow()
        window.contentView = hostingView
        window.orderFrontRegardless()

        func events() -> [String] {
            interpreter.globals.lookup("swiftUIViewTaskIDEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        }
        await waitUntil {
            events().contains("start:1")
        }

        hostingView.rootView = try render(id: 2)
        await waitUntil {
            events().contains("cancel:1") && events().contains("start:2")
        }

        hostingView.rootView = AnyView(EmptyView())
        await waitUntil {
            events().contains("cancel:2")
        }
        await waitUntil {
            interpreter.concurrencyRuntime.activeRecordCount == 0
        }

        #expect(events().sorted() == ["cancel:1", "cancel:2", "start:1", "start:2"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(lifecycleDiagnostics().isEmpty)
        await retireLifecycleWindow(window)
    }

    @Test
    func interpretedSwiftUIPreservesTaskWhenIDDoesNotChange() async throws {
        let source = try String(contentsOf: sameIDFixture, encoding: .utf8)
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)

        let symbol = try #require(interpreter.rootViewSymbol())
        func render(generation: String) throws -> AnyView {
            guard case .instance(let instance) = try interpreter.instantiateForBridge(
                symbol,
                arguments: CallArguments(arguments: [
                    .init(label: "id", value: .native(7)),
                    .init(label: "generation", value: .native(generation)),
                ])) else {
                throw RuntimeError(message:
                    "view-task same-id probe did not instantiate")
            }
            return AnyView(try ViewRegistry.anyView(
                interpreter.evaluateBody(of: instance)))
        }
        func events() -> [String] {
            interpreter.globals.lookup("swiftUIViewTaskSameIDEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        }

        let hostingView = NSHostingView(rootView: try render(generation: "first"))
        let window = makeLifecycleWindow()
        window.contentView = hostingView
        window.orderFrontRegardless()

        await waitUntil {
            events().contains("render:first") && events().contains("start:first")
        }
        hostingView.rootView = try render(generation: "same")
        await waitUntil {
            events().contains("render:same")
        }

        interpreter.globals.box(for: "swiftUIViewTaskSameIDRelease")?.value
            = .native(true)
        await waitUntil {
            events().contains { $0.hasPrefix("finish:") }
        }
        hostingView.rootView = AnyView(EmptyView())
        await waitUntil {
            interpreter.concurrencyRuntime.activeRecordCount == 0
        }

        #expect(events().sorted()
            == ["finish:first", "render:first", "render:same", "start:first"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(lifecycleDiagnostics().isEmpty)
        await retireLifecycleWindow(window)
    }

    @Test
    func interpretedRefreshActionWaitsForAsyncBodyCompletion() async throws {
        let source = try String(contentsOf: refreshableFixture, encoding: .utf8)
        let registry = ViewRegistry()
        registry.constructors["RefreshActionTrigger"] = HostFunction(
            name: "RefreshActionTrigger"
        ) { args, context in
            guard let closure = args.firstUnlabeledClosure else {
                throw RuntimeError(message:
                    "RefreshActionTrigger needs a completion closure")
            }
            let callback = InterpretedHostCallback(
                closure: closure,
                context: context,
                diagnosticContext: "refresh action completion")
            let action = ActionValue(run: { callback.call() })
            return .native(AnyView(InterpretedRefreshActionTriggerHost(
                onReturned: { action.run() })))
        }

        let interpreter = Interpreter(registry: registry)
        try interpreter.run(source: source)
        let symbol = try #require(interpreter.rootViewSymbol())
        guard case .instance(let instance) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("refreshable probe did not instantiate")
            return
        }
        let rendered = try interpreter.evaluateBody(of: instance)
        let hostingView = NSHostingView(
            rootView: AnyView(try ViewRegistry.anyView(rendered)))
        let window = makeLifecycleWindow()
        window.contentView = hostingView
        window.orderFrontRegardless()

        func events() -> [String] {
            interpreter.globals.lookup("swiftUIRefreshableEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        }
        await waitUntil { events() == ["started"] }

        #expect(events() == ["started"])
        #expect(interpreter.concurrencyRuntime.records.values.contains {
            $0.kind == .swiftUITask
                && $0.state == .waiting
                && $0.executorPreference == .mainActor
                && $0.evaluationContext?.currentExecutor == .mainActor
        })

        interpreter.globals.box(for: "swiftUIRefreshableRelease")?.value
            = .native(true)
        await waitUntil { events().count == 3 }
        await waitUntil {
            interpreter.concurrencyRuntime.activeRecordCount == 0
        }

        #expect(events() == ["started", "finished", "returned"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(lifecycleDiagnostics().isEmpty)
        #expect(RenderDiagnostics.errors.contains {
            $0.view == "refresh action completion"
        } == false)
        await retireLifecycleWindow(window)
    }

    @Test
    func repeatedSwiftUITeardownReleasesEveryRuntimeSession() async throws {
        let source = try String(contentsOf: teardownFixture, encoding: .utf8)
        weak var weakInterpreter: Interpreter?
        weak var weakRuntime: CooperativeConcurrencyRuntime?
        var recordReferences: [WeakLifecycleReference<RuntimeTaskRecord>] = []
        var handleReferences: [WeakLifecycleReference<RuntimeTaskHandle>] = []
        var driverReferences: [WeakLifecycleReference<RuntimeNativeTaskDriver>] = []
        var contextReferences: [WeakLifecycleReference<EvaluationTaskContext>] = []
        var storageReferences: [
            WeakLifecycleReference<RuntimeTaskLocalStorage>
        ] = []
        var sessionIDs: Set<RuntimeSessionID> = []
        var taskIDs: Set<RuntimeTaskID> = []

        do {
            var interpreter: Interpreter? = Interpreter(registry: ViewRegistry())
            let liveInterpreter = try #require(interpreter)
            weakInterpreter = liveInterpreter
            weakRuntime = liveInterpreter.concurrencyRuntime
            try liveInterpreter.run(source: source)
            let symbol = try #require(liveInterpreter.rootViewSymbol())

            func render(id: Int) throws -> AnyView {
                guard let interpreter else {
                    throw RuntimeError(message:
                        "teardown probe lost its interpreter")
                }
                guard case .instance(let instance) =
                        try interpreter.instantiateForBridge(
                            symbol,
                            arguments: CallArguments(arguments: [
                                .init(label: "id", value: .native(id)),
                            ])) else {
                    throw RuntimeError(message:
                        "teardown probe did not instantiate")
                }
                return AnyView(try ViewRegistry.anyView(
                    interpreter.evaluateBody(of: instance)))
            }

            func integerEvents(_ name: String) -> [Int] {
                liveInterpreter.globals.lookup(name)?
                    .arrayValue?.compactMap(\.intValue) ?? []
            }

            var hostingView: NSHostingView<AnyView>? = NSHostingView(
                rootView: AnyView(EmptyView()))
            var window: NSWindow? = makeLifecycleWindow()
            window?.contentView = hostingView
            window?.orderFrontRegardless()

            let cycles = 32
            for id in 0..<cycles {
                hostingView?.rootView = try render(id: id)
                await waitUntil {
                    integerEvents("swiftUIViewTaskTeardownStarts").count
                        == id + 1
                }
                try #require(
                    integerEvents("swiftUIViewTaskTeardownStarts").count
                        == id + 1)

                let references = try { () -> (
                    WeakLifecycleReference<RuntimeTaskRecord>,
                    WeakLifecycleReference<RuntimeTaskHandle>,
                    WeakLifecycleReference<RuntimeNativeTaskDriver>,
                    WeakLifecycleReference<EvaluationTaskContext>,
                    WeakLifecycleReference<RuntimeTaskLocalStorage>
                ) in
                    let records = liveInterpreter.concurrencyRuntime.records
                        .values.filter { $0.kind == .swiftUITask }
                    #expect(records.count == 1)
                    let record = try #require(records.first)
                    #expect(sessionIDs.insert(record.sessionID).inserted)
                    #expect(taskIDs.insert(record.id).inserted)
                    return (
                        WeakLifecycleReference(record),
                        WeakLifecycleReference(
                            try #require(record.sourceHandle)),
                        WeakLifecycleReference(
                            try #require(record.nativeDriver)),
                        WeakLifecycleReference(
                            try #require(record.evaluationContext)),
                        WeakLifecycleReference(record.taskLocals))
                }()
                let (
                    recordReference,
                    handleReference,
                    driverReference,
                    contextReference,
                    storageReference
                ) = references
                recordReferences.append(recordReference)
                handleReferences.append(handleReference)
                driverReferences.append(driverReference)
                contextReferences.append(contextReference)
                storageReferences.append(storageReference)

                hostingView?.rootView = AnyView(EmptyView())
                await waitUntil {
                    integerEvents("swiftUIViewTaskTeardownCancellations").count
                        == id + 1
                }
                try #require(
                    integerEvents("swiftUIViewTaskTeardownCancellations").count
                        == id + 1)
                await waitUntil {
                    liveInterpreter.concurrencyRuntime.activeRecordCount == 0
                }
                try #require(
                    liveInterpreter.concurrencyRuntime.activeRecordCount == 0)

                #expect(recordReference.value == nil)
                #expect(handleReference.value == nil)
                #expect(driverReference.value == nil)
                #expect(contextReference.value == nil)
                #expect(storageReference.value == nil)
                #expect(liveInterpreter.concurrencyRuntime
                    .activeStructuredScopeCount == 0)
                #expect(liveInterpreter.concurrencyRuntime
                    .activeTaskGroupCount == 0)
                #expect(liveInterpreter.concurrencyRuntime
                    .activeAsyncStreamCount == 0)
                #expect(liveInterpreter.concurrencyRuntime
                    .activeContinuationCount == 0)
                #expect(liveInterpreter.concurrencyRuntime
                    .activeHostOperationCount == 0)
                #expect(liveInterpreter.scheduledTasks.isEmpty)
            }

            let expectedIDs = Array(0..<cycles)
            #expect(sessionIDs.count == cycles)
            #expect(taskIDs.count == cycles)
            #expect(integerEvents("swiftUIViewTaskTeardownStarts")
                == expectedIDs)
            #expect(integerEvents("swiftUIViewTaskTeardownCancellations")
                == expectedIDs)
            #expect(integerEvents("swiftUIViewTaskTeardownUnexpected").isEmpty)
            #expect(lifecycleDiagnostics().isEmpty)

            hostingView?.rootView = AnyView(EmptyView())
            window?.contentView = nil
            if let window {
                await retireLifecycleWindow(window)
            }
            hostingView = nil
            window = nil
            interpreter = nil
        }

        await waitUntil {
            weakInterpreter == nil && weakRuntime == nil
        }
        #expect(weakInterpreter == nil)
        #expect(weakRuntime == nil)
        #expect(recordReferences.allSatisfy { $0.value == nil })
        #expect(handleReferences.allSatisfy { $0.value == nil })
        #expect(driverReferences.allSatisfy { $0.value == nil })
        #expect(contextReferences.allSatisfy { $0.value == nil })
        #expect(storageReferences.allSatisfy { $0.value == nil })
    }
}
