/// A pre-compiled gateway into host (framework) functionality — the Bitrig
/// trick: instead of reimplementing SwiftUI, gateways accept dynamic arguments
/// and call the real API. Gateways are immutable reference descriptors: this
/// keeps the runtime-value payload small while allowing dual sync/async entry
/// points without exposing their storage layout.
public final class HostFunction {
    public let name: String
    /// Source generic specialization carried by constructor-shaped host
    /// values. Invocation still receives the established hidden argument;
    /// member access (notably `MemoryLayout<T>.stride`) can inspect it too.
    public internal(set) var genericArguments: [String] = []
    public let invoke: @MainActor (CallArguments, EvalContext) throws -> RuntimeValue
    private let suspendingInvoke: @MainActor
        (CallArguments, EvalContext) async throws -> RuntimeValue
    public let canSuspend: Bool
    /// Empty for a legacy dynamic gateway, one element for a typed gateway,
    /// and multiple elements for an overload set.
    public let signatures: [HostSignature]

    public var signature: HostSignature? {
        signatures.count == 1 ? signatures[0] : nil
    }

    public init(name: String, invoke: @escaping @MainActor (CallArguments, EvalContext) throws -> RuntimeValue) {
        self.name = name
        self.invoke = invoke
        self.suspendingInvoke = { arguments, context in
            try invoke(arguments, context)
        }
        self.canSuspend = false
        self.signatures = []
    }

    /// A genuinely asynchronous host gateway. This is deliberately a
    /// distinct label rather than an async overload of `invoke`: hundreds of
    /// existing synchronous gateway literals remain unambiguous.
    public init(
        name: String,
        asyncInvoke: @escaping @MainActor (CallArguments, EvalContext) async throws -> RuntimeValue
    ) {
        self.name = name
        self.invoke = { _, _ in
            throw RuntimeError(
                message: "async host function '\(name)' requires runAsync and await")
        }
        self.suspendingInvoke = asyncInvoke
        self.canSuspend = true
        self.signatures = []
    }

    /// A wrapper can preserve both faces of another gateway (generic
    /// specialization is the main use). The async face may suspend even when
    /// the synchronous compatibility face cannot.
    public init(
        name: String,
        invoke: @escaping @MainActor (CallArguments, EvalContext) throws -> RuntimeValue,
        asyncInvoke: @escaping @MainActor (CallArguments, EvalContext) async throws -> RuntimeValue
    ) {
        self.name = name
        self.invoke = invoke
        self.suspendingInvoke = asyncInvoke
        self.canSuspend = true
        self.signatures = []
    }

    /// Registers a synchronous implementation behind a parsed declaration.
    /// Parsing and effect compatibility are checked once at registration;
    /// arguments and results are checked at every invocation.
    public convenience init(
        declaration: String,
        invoke: @escaping @MainActor
            (CallArguments, EvalContext) throws -> RuntimeValue
    ) throws {
        try self.init(signature: HostSignature(parsing: declaration), invoke: invoke)
    }

    public init(
        signature: HostSignature,
        invoke implementation: @escaping @MainActor
            (CallArguments, EvalContext) throws -> RuntimeValue
    ) throws {
        try Self.validateRegistration(signature, expectsAsync: false)
        self.name = signature.callableName
        self.signatures = [signature]
        self.canSuspend = false
        let checked: @MainActor
            (CallArguments, EvalContext) throws -> RuntimeValue = { arguments, context in
            let match = try signature.validate(arguments: arguments, in: context)
            let result: RuntimeValue
            do {
                result = try implementation(arguments, context)
            } catch {
                throw Self.checkedImplementationError(error, for: signature)
            }
            try signature.validateReturn(result, match: match, in: context)
            return result
        }
        self.invoke = checked
        self.suspendingInvoke = { arguments, context in
            try checked(arguments, context)
        }
    }

    /// Registers a genuinely suspending implementation. The declaration must
    /// contain `async`; synchronous runs retain their explicit error rather
    /// than blocking the main actor.
    public convenience init(
        declaration: String,
        asyncInvoke: @escaping @MainActor
            (CallArguments, EvalContext) async throws -> RuntimeValue
    ) throws {
        try self.init(
            signature: HostSignature(parsing: declaration),
            asyncInvoke: asyncInvoke)
    }

    public init(
        signature: HostSignature,
        asyncInvoke implementation: @escaping @MainActor
            (CallArguments, EvalContext) async throws -> RuntimeValue
    ) throws {
        try Self.validateRegistration(signature, expectsAsync: true)
        self.name = signature.callableName
        self.signatures = [signature]
        self.canSuspend = true
        self.invoke = { _, _ in
            throw RuntimeError(message:
                "async host function '\(signature.callableName)' requires runAsync and await")
        }
        self.suspendingInvoke = { arguments, context in
            let match = try signature.validate(arguments: arguments, in: context)
            let result: RuntimeValue
            do {
                result = try await implementation(arguments, context)
            } catch {
                throw Self.checkedImplementationError(error, for: signature)
            }
            try signature.validateReturn(result, match: match, in: context)
            return result
        }
    }

    /// A dual implementation is useful when an async declaration has an
    /// intentional inline compatibility face for synchronous renderers.
    public convenience init(
        declaration: String,
        invoke: @escaping @MainActor
            (CallArguments, EvalContext) throws -> RuntimeValue,
        asyncInvoke: @escaping @MainActor
            (CallArguments, EvalContext) async throws -> RuntimeValue
    ) throws {
        try self.init(
            signature: HostSignature(parsing: declaration),
            invoke: invoke, asyncInvoke: asyncInvoke)
    }

    public init(
        signature: HostSignature,
        invoke synchronousImplementation: @escaping @MainActor
            (CallArguments, EvalContext) throws -> RuntimeValue,
        asyncInvoke asynchronousImplementation: @escaping @MainActor
            (CallArguments, EvalContext) async throws -> RuntimeValue
    ) throws {
        try Self.validateRegistration(signature, expectsAsync: true)
        self.name = signature.callableName
        self.signatures = [signature]
        self.canSuspend = true
        self.invoke = { arguments, context in
            let match = try signature.validate(arguments: arguments, in: context)
            let result: RuntimeValue
            do {
                result = try synchronousImplementation(arguments, context)
            } catch {
                throw Self.checkedImplementationError(error, for: signature)
            }
            try signature.validateReturn(result, match: match, in: context)
            return result
        }
        self.suspendingInvoke = { arguments, context in
            let match = try signature.validate(arguments: arguments, in: context)
            let result: RuntimeValue
            do {
                result = try await asynchronousImplementation(arguments, context)
            } catch {
                throw Self.checkedImplementationError(error, for: signature)
            }
            try signature.validateReturn(result, match: match, in: context)
            return result
        }
    }

    /// Creates one callable from typed overloads. Selection is type-directed,
    /// deterministic, and rejects equal-score ambiguity instead of silently
    /// choosing registration order.
    public init(overloads: [HostFunction]) throws {
        guard !overloads.isEmpty else {
            throw HostSignatureError.invalidRegistration(
                declaration: "<overload set>", reason: "the set is empty")
        }
        guard overloads.allSatisfy({ !$0.signatures.isEmpty }) else {
            throw HostSignatureError.invalidRegistration(
                declaration: "<overload set>",
                reason: "every overload must have a parsed signature")
        }
        let name = overloads[0].name
        guard overloads.allSatisfy({ $0.name == name }) else {
            throw HostSignatureError.invalidRegistration(
                declaration: "<overload set>",
                reason: "all overloads must share one lookup name")
        }
        let declarations = overloads.flatMap(\.signatures)
        guard Set(declarations.map(\.declaration)).count == declarations.count else {
            throw HostSignatureError.invalidRegistration(
                declaration: name,
                reason: "duplicate declarations make overload selection ambiguous")
        }

        self.name = name
        self.signatures = declarations
        self.canSuspend = overloads.contains(where: \.canSuspend)
        self.invoke = { arguments, context in
            let selected = try Self.select(
                from: overloads, arguments: arguments, context: context)
            return try selected.invoke(arguments, context)
        }
        self.suspendingInvoke = { arguments, context in
            let selected = try Self.select(
                from: overloads, arguments: arguments, context: context)
            return try await selected.invokeSuspending(arguments, context)
        }
    }

    public func invokeSuspending(
        _ arguments: CallArguments, _ context: EvalContext
    ) async throws -> RuntimeValue {
        try await suspendingInvoke(arguments, context)
    }

    private static func validateRegistration(
        _ signature: HostSignature, expectsAsync: Bool
    ) throws {
        guard signature.isCallable else {
            throw HostSignatureError.invalidRegistration(
                declaration: signature.declaration,
                reason: "properties must use HostProperty")
        }
        guard signature.isAsync == expectsAsync else {
            let expected = expectsAsync ? "an async declaration" : "a synchronous declaration"
            throw HostSignatureError.invalidRegistration(
                declaration: signature.declaration,
                reason: "this implementation requires \(expected)")
        }
    }

    private static func checkedImplementationError(
        _ error: Error, for signature: HostSignature
    ) -> Error {
        if signature.isThrowing || error is CancellationError { return error }
        if let runtime = error as? RuntimeError, runtime.fatal { return runtime }
        return RuntimeError(message:
            "host contract violation: nonthrowing '\(signature.declaration)' threw \(String(describing: error))")
    }

    private static func select(
        from overloads: [HostFunction],
        arguments: CallArguments,
        context: EvalContext
    ) throws -> HostFunction {
        var candidates: [(function: HostFunction, score: Int)] = []
        for function in overloads {
            for signature in function.signatures {
                if let match = signature.match(arguments: arguments, in: context) {
                    candidates.append((function, match.score))
                }
            }
        }
        guard let bestScore = candidates.map(\.score).max() else {
            let labels = arguments.arguments
                .map { ($0.label ?? "_") + ":" }.joined()
            throw RuntimeError(message:
                "no matching host overload for '\(nameForDiagnostics(overloads))' with labels '(\(labels))'")
        }
        let best = candidates.filter { $0.score == bestScore }
        let identities = Set(best.map { ObjectIdentifier($0.function) })
        guard identities.count == 1, let selected = best.first?.function else {
            let declarations = best.flatMap(\.function.signatures)
                .map(\.declaration).joined(separator: "; ")
            throw RuntimeError(message:
                "ambiguous host overload for '\(nameForDiagnostics(overloads))': \(declarations)")
        }
        return selected
    }

    private static func nameForDiagnostics(_ overloads: [HostFunction]) -> String {
        overloads.first?.name ?? "<unknown>"
    }
}

/// Typed getter/setter descriptor for framework properties. `HostRegistry`
/// performs lookup by receiver and name; this descriptor validates the
/// receiver, getter result, and every assigned value before host code runs.
public final class HostProperty {
    public typealias Getter = @MainActor
        (RuntimeValue, EvalContext) throws -> RuntimeValue
    public typealias Setter = @MainActor
        (RuntimeValue, RuntimeValue, EvalContext) throws -> Void

    public let signature: HostSignature
    public let name: String
    private let getter: Getter
    private let setter: Setter?

    public convenience init(
        declaration: String,
        get: @escaping Getter,
        set: Setter? = nil
    ) throws {
        try self.init(
            signature: HostSignature(parsing: declaration), get: get, set: set)
    }

    public init(
        signature: HostSignature,
        get: @escaping Getter,
        set: Setter? = nil
    ) throws {
        guard signature.kind == .property || signature.kind == .staticProperty else {
            throw HostSignatureError.invalidRegistration(
                declaration: signature.declaration,
                reason: "HostProperty requires a property declaration")
        }
        guard !signature.isAsync else {
            throw HostSignatureError.invalidRegistration(
                declaration: signature.declaration,
                reason: "async property access is not supported by the synchronous member boundary")
        }
        guard signature.isSettable == (set != nil) else {
            throw HostSignatureError.invalidRegistration(
                declaration: signature.declaration,
                reason: signature.isSettable
                    ? "a mutable property requires a setter"
                    : "a read-only property cannot register a setter")
        }
        self.signature = signature
        self.name = signature.name
        self.getter = get
        self.setter = set
    }

    public func read(
        from receiver: RuntimeValue, in context: EvalContext
    ) throws -> RuntimeValue {
        try signature.validateReceiver(receiver, in: context)
        let value: RuntimeValue
        do {
            value = try getter(receiver, context)
        } catch {
            if signature.isThrowing || error is CancellationError { throw error }
            if let runtime = error as? RuntimeError, runtime.fatal { throw runtime }
            throw RuntimeError(message:
                "host contract violation: nonthrowing property '\(signature.declaration)' threw \(String(describing: error))")
        }
        try signature.validatePropertyValue(value, in: context)
        return value
    }

    public func write(
        _ value: RuntimeValue,
        to receiver: RuntimeValue,
        in context: EvalContext
    ) throws {
        try validateWrite(value, to: receiver, in: context)
        guard let setter else {
            preconditionFailure("validateWrite accepted a read-only HostProperty")
        }
        do {
            try setter(receiver, value, context)
        } catch {
            if let runtime = error as? RuntimeError, runtime.fatal { throw runtime }
            throw RuntimeError(message:
                "host contract violation: setter for '\(signature.declaration)' threw \(String(describing: error))")
        }
    }

    /// Validate a write without performing it. Value-type host members use
    /// this before asking their registry for a mutated copy, so assignments
    /// through copy-in/copy-out receive the same contract checks and
    /// read-only diagnostics as reference-backed setters.
    public func validateWrite(
        _ value: RuntimeValue,
        to receiver: RuntimeValue,
        in context: EvalContext
    ) throws {
        guard setter != nil else {
            throw RuntimeError(message:
                "cannot assign to read-only host property '\(signature.declaration)'")
        }
        try signature.validateReceiver(receiver, in: context)
        try signature.validatePropertyValue(
            value, in: context, operation: "was assigned")
    }
}
