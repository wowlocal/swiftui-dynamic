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
        let program = try makeParsedProgram(source: source)
        return try await runPreparedProgramAsync(
            program,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            completionPolicy: completionPolicy)
    }

    /// Execute an immutable parsed program in a fresh async runtime session.
    /// The syntax tree may be shared by independent interpreters. Mutable
    /// declaration registries are session-owned; globals, task records, and
    /// host state remain confined to the owning interpreter/runtime.
    @discardableResult
    public func runAsync(
        program: ParsedProgram,
        lazyTopLevelGlobals: Bool = false,
        completionPolicy: SessionCompletionPolicy = .drainOwnedTasks
    ) async throws -> RuntimeValue {
        try await runAsync(
            program: program,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            completionPolicy: completionPolicy,
            compilerPreflightSources: nil)
    }

    /// Preserve native source-file boundaries during compiler preflight while
    /// executing a reusable parsed representation of the merged module.
    @discardableResult
    public func runAsync(
        program: ParsedProgram,
        lazyTopLevelGlobals: Bool,
        completionPolicy: SessionCompletionPolicy,
        compilerPreflightSources: [CompilerPreflightSource]?
    ) async throws -> RuntimeValue {
        try performCompilerPreflightIfNeeded(
            source: program.source,
            sources: compilerPreflightSources)
        return try await runPreparedProgramAsync(
            program,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            completionPolicy: completionPolicy)
    }

    /// Bind an immutable program to this facade's explicit heap and
    /// cooperative runtime. The returned session is single-use; preflight
    /// occurs when `runAsync(session:)` starts it.
    public func makeSession(
        program: ParsedProgram,
        lazyTopLevelGlobals: Bool = false,
        completionPolicy: SessionCompletionPolicy = .drainOwnedTasks
    ) -> InterpreterSession {
        let programPlan = program.resolve(
            buildConfiguration: buildConfiguration)
        let programState = RuntimeProgramState(
            programPlan: programPlan,
            assumesCompiledImports: lazyTopLevelGlobals,
            hostRegistry: registry,
            hostExtensionParent: compatibilityProgramState?
                .hostExtensionLineageAnchor)
        compatibilityProgramPlan = programPlan
        compatibilityProgramMetadata = program.metadata
        compatibilityProgramState = programState
        compatibilityLocationConverter = program.locationConverter
        return InterpreterSession(
            program: program,
            heap: runtimeHeap,
            concurrencyRuntime: concurrencyRuntime,
            programState: programState,
            programPlan: programPlan,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            completionPolicy: completionPolicy,
            owner: self)
    }

    /// Execute a previously-created single-use session. Ownership validation
    /// rejects accidental execution through another interpreter facade.
    @discardableResult
    public func runAsync(
        session: InterpreterSession,
        compilerPreflightSources: [CompilerPreflightSource]? = nil
    ) async throws -> RuntimeValue {
        try session.validateExecution(on: self)
        try performCompilerPreflightIfNeeded(
            source: session.program.source,
            sources: compilerPreflightSources)
        return try await runPreparedSessionAsync(session)
    }

    private func runPreparedProgramAsync(
        _ program: ParsedProgram,
        lazyTopLevelGlobals: Bool,
        completionPolicy: SessionCompletionPolicy
    ) async throws -> RuntimeValue {
        let session = makeSession(
            program: program,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            completionPolicy: completionPolicy)
        return try await runPreparedSessionAsync(session)
    }

    private func runPreparedSessionAsync(
        _ session: InterpreterSession
    ) async throws -> RuntimeValue {
        try session.beginExecution(on: self)
        defer { session.finishExecution() }

        let runtime = session.concurrencyRuntime
        let taskLocals = RuntimeTaskLocalStorage()
        let root = runtime.createTask(
            entry: session.runtimeEntry, kind: .root, parent: nil,
            priority: RuntimeTaskPriority(Task.currentPriority),
            executorPreference: .mainActor,
            taskLocals: taskLocals,
            name: nil)
        _ = runtime.begin(root)
        let context = runtime.makeEvaluationTaskContext(
            runtimeTaskID: root.id,
            runtimeEntry: session.runtimeEntry,
            isAsyncSession: true,
            priority: root.effectivePriority,
            executor: root.executorPreference,
            taskLocals: taskLocals)
        runtime.bind(context, to: root)
        defer { runtime.release(root.id) }
        return try await EvaluationTaskContext.$current.withValue(context) {
            defer { context.removeAllDynamicState() }
            do {
                let value = try await runAsyncInCurrentTaskContext(
                    session: session)
                runtime.succeed(root, with: value)
                return value
            } catch is InterpreterSessionAbort {
                runtime.requestCancellation(
                    root, source: .hostTask)
                runtime.completeCancellation(root)
                throw CancellationError()
            } catch is CancellationError {
                runtime.requestCancellation(
                    root, source: .hostTask)
                runtime.completeCancellation(root)
                throw CancellationError()
            } catch {
                runtime.fail(root, with: error)
                throw error
            }
        }
    }

    private func runAsyncInCurrentTaskContext(
        session: InterpreterSession
    ) async throws -> RuntimeValue {
        try checkRuntimeCancellation()

        let result: RuntimeValue
        do {
            result = try await runProgramSuspending(
                program: session.program,
                executionPlan: session.executionPlan,
                lazyTopLevelGlobals: session.lazyTopLevelGlobals)
        } catch {
            await cancelOwnedTasks(in: session.id)
            throw error
        }

        do {
            switch session.completionPolicy {
            case .topLevel:
                break
            case .drainOwnedTasks:
                try await drainOwnedTasks(in: session.id)
            case .cancelRemainingTasks:
                await cancelOwnedTasks(in: session.id)
            }
            try checkRuntimeCancellation()
        } catch {
            await cancelOwnedTasks(in: session.id)
            throw error
        }
        return result
    }

    private func runProgramSuspending(
        program: ParsedProgram,
        executionPlan: ResolvedDeclarationPlan,
        lazyTopLevelGlobals: Bool
    ) async throws -> RuntimeValue {
        let file = program.syntax
        compatibilityLocationConverter = program.locationConverter
        try validateTargetConditionalCompilationQueries(in: file)
        steps = 0
        try collectDeclarations(from: executionPlan)
        processDeferredExtensions()
        resolvePendingMemberAliases()
        reconcileStrandedExtensions()
        resolveActorExecutorRequirements()
        resolvePendingDeinitializerIsolation()
        resolveTransitiveViewConformance()

        return try await withTopLevelStructuredScopeSuspending(in: globals) {
            try await executeTopLevelStatementsSuspending(
                executionPlan.topLevelItems,
                lazyTopLevelGlobals: lazyTopLevelGlobals)
        }
    }

    private func executeTopLevelStatementsSuspending(
        _ topLevelItems: [CodeBlockItemSyntax],
        lazyTopLevelGlobals: Bool
    ) async throws -> RuntimeValue {
        var last: RuntimeValue = .void
        for item in topLevelItems {
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
        while let handle = concurrencyRuntime.firstScheduledTask(
            in: sessionID
        ) {
            try checkRuntimeCancellation()
            await handle.wait()
            concurrencyRuntime.releaseScheduledTask(handle)
        }
    }

    private func cancelOwnedTasks(in sessionID: RuntimeSessionID) async {
        while let handle = concurrencyRuntime.firstScheduledTask(
            in: sessionID
        ) {
            handle.cancel(source: .sessionPolicy)
            await handle.wait()
            concurrencyRuntime.releaseScheduledTask(handle)
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
        let program = try makeParsedProgram(source: source)
        return try runPreparedProgram(
            program, lazyTopLevelGlobals: lazyTopLevelGlobals)
    }

    /// Execute an immutable parsed program using synchronous top-level
    /// semantics. Mutable evaluator state is owned by this interpreter, not
    /// by the shared program.
    @discardableResult
    public func run(
        program: ParsedProgram,
        lazyTopLevelGlobals: Bool = false
    ) throws -> RuntimeValue {
        try run(
            program: program,
            lazyTopLevelGlobals: lazyTopLevelGlobals,
            compilerPreflightSources: nil)
    }

    /// Preserve native source-file boundaries during compiler preflight while
    /// executing a reusable parsed representation of the merged module.
    @discardableResult
    public func run(
        program: ParsedProgram,
        lazyTopLevelGlobals: Bool,
        compilerPreflightSources: [CompilerPreflightSource]?
    ) throws -> RuntimeValue {
        try performCompilerPreflightIfNeeded(
            source: program.source,
            sources: compilerPreflightSources)
        return try runPreparedProgram(
            program, lazyTopLevelGlobals: lazyTopLevelGlobals)
    }

    private func runPreparedProgram(
        _ program: ParsedProgram,
        lazyTopLevelGlobals: Bool
    ) throws -> RuntimeValue {
        let programPlan = program.resolve(
            buildConfiguration: buildConfiguration)
        let programState = RuntimeProgramState(
            programPlan: programPlan,
            assumesCompiledImports: lazyTopLevelGlobals,
            hostRegistry: registry,
            hostExtensionParent: compatibilityProgramState?
                .hostExtensionLineageAnchor)
        compatibilityProgramPlan = programPlan
        compatibilityProgramMetadata = program.metadata
        compatibilityProgramState = programState
        let file = program.syntax
        let executionPlan = programPlan.declarationPlan
        compatibilityLocationConverter = program.locationConverter
        try validateTargetConditionalCompilationQueries(in: file)
        steps = 0
        // Merged multi-file units COMPILE on device: an unresolved
        // identifier there is an unmerged import, never a typo.
        try collectDeclarations(from: executionPlan)
        processDeferredExtensions()
        resolvePendingMemberAliases()
        reconcileStrandedExtensions()
        resolveActorExecutorRequirements()
        resolvePendingDeinitializerIsolation()
        resolveTransitiveViewConformance()

        var last: RuntimeValue = .void
        for item in executionPlan.topLevelItems {
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
                where assumesCompiledImports && !scriptError.budgetTrip {
                // Same doctrine for trap guards (`fatalError("Source file
                // had no content")` in tooling): the script's crash is its
                // own. Traps stay FATAL across gateway boundaries (the
                // located-rewrap invariant) — this top-level script arm is
                // the documented tolerance exception. Budget/stack trips
                // (budgetTrip) still abort the whole unit.
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
