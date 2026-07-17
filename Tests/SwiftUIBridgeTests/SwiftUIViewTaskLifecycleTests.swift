import AppKit
import Foundation
import SwiftUI
@testable import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

@Suite(.serialized)
struct SwiftUIViewTaskLifecycleTests {
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
                    + "id=cancel:1,cancel:2,start:1,start:2")
    }

    @Test
    func interpretedSwiftUIStartsAsyncTaskBodyInCanonicalAsyncContext() async throws {
        RenderDiagnostics.reset()
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.close() }

        let deadline = Date().addingTimeInterval(2)
        var events: [String] = []
        repeat {
            await Task.yield()
            events = interpreter.globals.lookup("swiftUIViewTaskEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        } while events.count < 2 && Date() < deadline

        let diagnostics = RenderDiagnostics.errors.map {
            "\($0.view): \($0.error)"
        }.joined(separator: " | ")
        let runtime = "active=\(interpreter.concurrencyRuntime.activeRecordCount) "
            + interpreter.concurrencyRuntime.records.values.map {
                "\($0.kind.rawValue):\($0.state.rawValue)"
            }.sorted().joined(separator: ",")
        #expect(
            events == ["started", "value:21"],
            Comment(rawValue: diagnostics + " " + runtime))

        while interpreter.concurrencyRuntime.activeRecordCount != 0
            && Date() < deadline {
            await Task.yield()
        }
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    @Test
    func interpretedSwiftUICancelsTaskWhenViewDisappears() async throws {
        RenderDiagnostics.reset()
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.close() }

        let deadline = Date().addingTimeInterval(2)
        var events: [String] = []
        repeat {
            await Task.yield()
            events = interpreter.globals.lookup("swiftUIViewTaskCancellationEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        } while events.isEmpty && Date() < deadline

        #expect(events == ["started"])
        #expect(interpreter.concurrencyRuntime.records.values.contains {
            $0.kind == .swiftUITask
                && $0.state == .waiting
                && $0.executorPreference == .mainActor
                && $0.evaluationContext?.currentExecutor == .mainActor
        })

        hostingView.rootView = AnyView(EmptyView())
        repeat {
            await Task.yield()
            events = interpreter.globals.lookup("swiftUIViewTaskCancellationEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        } while events.count < 2 && Date() < deadline

        while interpreter.concurrencyRuntime.activeRecordCount != 0
            && Date() < deadline {
            await Task.yield()
        }
        #expect(events == ["started", "cancelled"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(RenderDiagnostics.errors.isEmpty)
    }

    @Test
    func interpretedSwiftUIReplacesTaskWhenIDChanges() async throws {
        RenderDiagnostics.reset()
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.close() }

        let deadline = Date().addingTimeInterval(2)
        func events() -> [String] {
            interpreter.globals.lookup("swiftUIViewTaskIDEvents")?
                .arrayValue?.compactMap(\.stringValue) ?? []
        }
        while !events().contains("start:1") && Date() < deadline {
            await Task.yield()
        }

        hostingView.rootView = try render(id: 2)
        while (!events().contains("cancel:1")
            || !events().contains("start:2")) && Date() < deadline {
            await Task.yield()
        }

        hostingView.rootView = AnyView(EmptyView())
        while !events().contains("cancel:2") && Date() < deadline {
            await Task.yield()
        }
        while interpreter.concurrencyRuntime.activeRecordCount != 0
            && Date() < deadline {
            await Task.yield()
        }

        #expect(events().sorted() == ["cancel:1", "cancel:2", "start:1", "start:2"])
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)
        #expect(interpreter.concurrencyRuntime.activeStructuredScopeCount == 0)
        #expect(interpreter.concurrencyRuntime.activeTaskGroupCount == 0)
        #expect(interpreter.concurrencyRuntime.activeContinuationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.scheduledTasks.isEmpty)
        #expect(RenderDiagnostics.errors.isEmpty)
    }
}
