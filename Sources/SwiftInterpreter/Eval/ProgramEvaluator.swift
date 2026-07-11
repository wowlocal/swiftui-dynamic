import Foundation
import SwiftSyntax

extension Interpreter {
    // MARK: - Running programs

    /// Parse and run a whole program: type/function declarations are hoisted,
    /// then top-level statements execute in order. Returns the value of the
    /// last top-level expression (handy for tests and for `ContentView()` as
    /// an explicit root).
    @discardableResult
    /// `lazyTopLevelGlobals`: multi-file merges (ProjectCheck units) have
    /// no main.swift — every top-level global is a LIBRARY global, which
    /// real Swift initializes lazily on first use. Single-source programs
    /// keep eager main.swift semantics (statement order matters in tests).
    public func run(source: String, lazyTopLevelGlobals: Bool = false) throws -> RuntimeValue {
        let file = try parse(source: source)
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
