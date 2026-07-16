import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Running programs

    /// Evaluate a program in an async session. Source `Task {}` bodies are
    /// scheduled as real Swift tasks and this call waits for the complete
    /// task tree, including child tasks spawned by interpreted task bodies.
    ///
    /// The async session has a genuine suspension-aware evaluator and host
    /// gateway path. SwiftUI rendering remains synchronous; script execution
    /// crosses into this path only at source `await` boundaries.
    @discardableResult
    public func runAsync(
        source: String,
        lazyTopLevelGlobals: Bool = false,
        completionPolicy: SessionCompletionPolicy = .drainOwnedTasks
    ) async throws -> RuntimeValue {
        try await runAsync(
            source: source,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            completionPolicy: completionPolicy,
            compilerPreflightSources: nil)
    }

    /// Preserve native source-file boundaries during compiler preflight while
    /// executing the interpreter's merged representation of the same module.
    @discardableResult
    public func runAsync(
        source: String,
        lazyTopLevelGlobals: Bool,
        completionPolicy: SessionCompletionPolicy,
        compilerPreflightSources: [CompilerPreflightSource]?
    ) async throws -> RuntimeValue {
        try performCompilerPreflightIfNeeded(
            source: source,
            sources: compilerPreflightSources)
        let sessionID = concurrencyRuntime.createSession()
        let taskLocals = RuntimeTaskLocalStorage()
        let root = concurrencyRuntime.createTask(
            sessionID: sessionID, kind: .root, parent: nil,
            priority: RuntimeTaskPriority(Task.currentPriority),
            executorPreference: .mainActor,
            taskLocals: taskLocals,
            name: nil)
        _ = concurrencyRuntime.begin(root)
        let context = makeEvaluationTaskContext(
            runtimeTaskID: root.id,
            runtimeSessionID: sessionID,
            isAsyncSession: true,
            priority: root.effectivePriority,
            executor: root.executorPreference,
            taskLocals: taskLocals)
        concurrencyRuntime.bind(context, to: root)
        defer { concurrencyRuntime.release(root.id) }
        return try await EvaluationTaskContext.$current.withValue(context) {
            defer { context.removeAllDynamicState() }
            do {
                let value = try await runAsyncInCurrentTaskContext(
                    source: source,
                    lazyTopLevelGlobals: lazyTopLevelGlobals,
                    completionPolicy: completionPolicy,
                    sessionID: sessionID)
                concurrencyRuntime.succeed(root, with: value)
                return value
            } catch is InterpreterSessionAbort {
                concurrencyRuntime.requestCancellation(
                    root, source: .hostTask)
                concurrencyRuntime.completeCancellation(root)
                throw CancellationError()
            } catch is CancellationError {
                concurrencyRuntime.requestCancellation(
                    root, source: .hostTask)
                concurrencyRuntime.completeCancellation(root)
                throw CancellationError()
            } catch {
                concurrencyRuntime.fail(root, with: error)
                throw error
            }
        }
    }

    private func runAsyncInCurrentTaskContext(
        source: String,
        lazyTopLevelGlobals: Bool,
        completionPolicy: SessionCompletionPolicy,
        sessionID: RuntimeSessionID
    ) async throws -> RuntimeValue {
        try checkRuntimeCancellation()

        let result: RuntimeValue
        do {
            result = try await runProgramSuspending(
                source: source, lazyTopLevelGlobals: lazyTopLevelGlobals)
        } catch {
            await cancelOwnedTasks(in: sessionID)
            throw error
        }

        do {
            switch completionPolicy {
            case .topLevel:
                break
            case .drainOwnedTasks:
                try await drainOwnedTasks(in: sessionID)
            case .cancelRemainingTasks:
                await cancelOwnedTasks(in: sessionID)
            }
            try checkRuntimeCancellation()
        } catch {
            await cancelOwnedTasks(in: sessionID)
            throw error
        }
        return result
    }

    private func runProgramSuspending(
        source: String, lazyTopLevelGlobals: Bool
    ) async throws -> RuntimeValue {
        let file = try parse(source: source)
        try validateTargetConditionalCompilationQueries(in: file)
        steps = 0
        assumesCompiledImports = lazyTopLevelGlobals
        try collectDeclarations(from: file)
        processDeferredExtensions()
        resolvePendingMemberAliases()
        reconcileStrandedExtensions()
        resolveTransitiveViewConformance()

        var last: RuntimeValue = .void
        for item in expandedTopLevelItems(file.statements) {
            try checkRuntimeCancellation()
            if case .stmt(let statement) = item.item,
               statement.is(DeferStmtSyntax.self) {
                continue
            }
            if case .decl(let declaration) = item.item,
               declaration.is(StructDeclSyntax.self)
                    || declaration.is(ClassDeclSyntax.self)
                    || declaration.is(ActorDeclSyntax.self)
                    || declaration.is(ImportDeclSyntax.self)
                    || declaration.is(FunctionDeclSyntax.self)
                    || declaration.is(ProtocolDeclSyntax.self)
                    || declaration.is(OperatorDeclSyntax.self)
                    || declaration.is(PrecedenceGroupDeclSyntax.self)
                    || declaration.is(TypeAliasDeclSyntax.self)
                    || declaration.is(EnumDeclSyntax.self)
                    || declaration.is(ExtensionDeclSyntax.self) {
                continue
            }
            if lazyTopLevelGlobals,
               case .decl(let declaration) = item.item,
               let variable = declaration.as(VariableDeclSyntax.self),
               isHoistableGlobal(variable) {
                continue
            }
            if case .decl(let declaration) = item.item,
               let variable = declaration.as(VariableDeclSyntax.self),
               variable.bindings.allSatisfy({ $0.accessorBlock != nil }) {
                continue
            }
            if case .decl(let declaration) = item.item,
               let variable = declaration.as(VariableDeclSyntax.self),
               isHoistableGlobal(variable) {
                let alreadyForced = variable.bindings.contains { binding in
                    guard let identifier = binding.pattern
                        .as(IdentifierPatternSyntax.self),
                          let box = globals.box(for: identifier.identifier.text)
                    else { return false }
                    if case .host(let any) = box.value, any is LazyGlobal {
                        return false
                    }
                    return true
                }
                if alreadyForced { continue }
            }

            let result: StatementResult
            do {
                result = try await executeSuspending(item, in: globals)
            } catch is InterpretedThrow where assumesCompiledImports {
                continue
            } catch let scriptError as RuntimeError
                where assumesCompiledImports && !scriptError.fatal {
                continue
            }
            switch result {
            case .normal(let value):
                last = value
            case .returnValue(let value):
                return value
            case .breakLoop, .continueLoop:
                throw RuntimeError(
                    message: "break/continue outside a loop", line: 1, column: 1)
            }
        }
        return last
    }

    private func drainOwnedTasks(
        in sessionID: RuntimeSessionID
    ) async throws {
        while let handle = scheduledTasks.first(where: {
            $0.sessionID == sessionID
        }) {
            try checkRuntimeCancellation()
            await handle.wait()
            releaseScheduledTask(handle)
        }
    }

    private func cancelOwnedTasks(in sessionID: RuntimeSessionID) async {
        while let handle = scheduledTasks.first(where: {
            $0.sessionID == sessionID
        }) {
            handle.cancel(source: .sessionPolicy)
            await handle.wait()
            releaseScheduledTask(handle)
        }
    }

    /// Parse and run a whole program: type/function declarations are hoisted,
    /// then top-level statements execute in order. Returns the value of the
    /// last top-level expression (handy for tests and for `ContentView()` as
    /// an explicit root).
    @discardableResult
    /// `lazyTopLevelGlobals`: multi-file merges (ProjectCheck units) have
    /// no main.swift — every top-level global is a LIBRARY global, which
    /// real Swift initializes lazily on first use. Single-source programs
    /// keep eager main.swift semantics (statement order matters in tests).
    public func run(
        source: String,
        lazyTopLevelGlobals: Bool = false
    ) throws -> RuntimeValue {
        try run(
            source: source,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            compilerPreflightSources: nil)
    }

    /// Preserve native source-file boundaries during compiler preflight while
    /// executing the interpreter's merged representation of the same module.
    @discardableResult
    public func run(
        source: String,
        lazyTopLevelGlobals: Bool,
        compilerPreflightSources: [CompilerPreflightSource]?
    ) throws -> RuntimeValue {
        try performCompilerPreflightIfNeeded(
            source: source,
            sources: compilerPreflightSources)
        let file = try parse(source: source)
        try validateTargetConditionalCompilationQueries(in: file)
        steps = 0
        // Merged multi-file units COMPILE on device: an unresolved
        // identifier there is an unmerged import, never a typo.
        assumesCompiledImports = lazyTopLevelGlobals
        try collectDeclarations(from: file)
        processDeferredExtensions()
        resolvePendingMemberAliases()
        reconcileStrandedExtensions()
        resolveTransitiveViewConformance()

        var last: RuntimeValue = .void
        for item in expandedTopLevelItems(file.statements) {
            if case .stmt(let stmt) = item.item, stmt.is(DeferStmtSyntax.self) {
                // Top-level `defer` runs at PROCESS exit on device — the
                // harness has no such moment; cleanup-at-exit is invisible
                // to rendering, so the body is honestly skipped.
                continue
            }
            if case .decl(let decl) = item.item,
               decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self)
                || decl.is(ActorDeclSyntax.self) || decl.is(ImportDeclSyntax.self)
                || decl.is(FunctionDeclSyntax.self) || decl.is(ProtocolDeclSyntax.self)
                || decl.is(OperatorDeclSyntax.self) || decl.is(PrecedenceGroupDeclSyntax.self)
                || decl.is(TypeAliasDeclSyntax.self)
                || decl.is(EnumDeclSyntax.self) || decl.is(ExtensionDeclSyntax.self) {
                continue // already collected (protocols: requirements carry
                // no bodies; defaults live in their extensions)
            }
            if lazyTopLevelGlobals, case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self), isHoistableGlobal(varDecl) {
                continue // library globals: initialize on first reference
            }
            if case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self),
               varDecl.bindings.allSatisfy({ $0.accessorBlock != nil }) {
                continue // computed globals were collected; accessors run on read
            }
            if case .decl(let decl) = item.item,
               let varDecl = decl.as(VariableDeclSyntax.self), isHoistableGlobal(varDecl) {
                // Hoisted as lazy for FORWARD references; still executed
                // eagerly in statement order (main.swift semantics) unless a
                // forward reference already forced it — then re-running would
                // clobber mutations and repeat side effects.
                let alreadyForced = varDecl.bindings.contains { binding in
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                          let box = globals.box(for: ident.identifier.text) else { return false }
                    if case .host(let any) = box.value, any is LazyGlobal { return false }
                    return true
                }
                if alreadyForced { continue }
            }
            let result: StatementResult
            if Self.traceStateCells {
                let head = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                FileHandle.standardError.write(Data("   ⊤ \(head.prefix(90))\n".utf8))
            }
            do {
                result = try execute(item, in: globals)
            } catch is InterpretedThrow where assumesCompiledImports {
                // A top-level statement's uncaught throw crashes only the
                // SCRIPT file that threw on device (session-ios ships repo
                // tooling whose file reads legitimately fail in the
                // sandbox); the merged unit's other files are independent.
                continue
            } catch let scriptError as RuntimeError
                where assumesCompiledImports && !scriptError.fatal {
                // Same doctrine for trap guards (`fatalError("Source file
                // had no content")` in tooling): the script's crash is its
                // own; budget/stack trips stay fatal.
                continue
            }
            switch result {
            case .normal(let value):
                last = value
            case .returnValue(let value):
                return value
            case .breakLoop, .continueLoop:
                throw RuntimeError(message: "break/continue outside a loop", line: 1, column: 1)
            }
        }
        return last
    }
}
