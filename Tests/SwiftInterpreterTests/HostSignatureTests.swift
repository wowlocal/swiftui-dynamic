import Foundation
import Testing
@testable import SwiftInterpreter

@Suite("Parsed host signatures")
struct HostSignatureTests {
    @Test func parserRetainsSwiftCallContract() throws {
        let signature = try HostSignature(parsing: """
        func render<T: CustomStringConvertible>(
            _ value: T,
            prefix: String = "",
            tags: String...
        ) async throws -> String?
        """)

        #expect(signature.kind == .function)
        #expect(signature.name == "render")
        #expect(signature.receiverType == nil)
        #expect(signature.parameters.count == 3)
        #expect(signature.parameters[0].label == nil)
        #expect(signature.parameters[0].name == "value")
        #expect(signature.parameters[0].type == "T")
        #expect(signature.parameters[1].label == "prefix")
        #expect(signature.parameters[1].defaultValue == "\"\"")
        #expect(signature.parameters[2].label == "tags")
        #expect(signature.parameters[2].isVariadic)
        #expect(signature.genericParameters == [
            .init(name: "T", constraints: ["CustomStringConvertible"]),
        ])
        #expect(signature.returnType == "String?")
        #expect(signature.isAsync)
        #expect(signature.isThrowing)
    }

    @Test func parserCoversEveryHostDeclarationKind() throws {
        let initializer = try HostSignature.parse("init URL?(string: String)")
        #expect(initializer.kind == .initializer)
        #expect(initializer.receiverType == "URL")
        #expect(initializer.callableName == "URL")
        #expect(initializer.isFailable)
        #expect(initializer.returnType == "URL?")

        let method = try HostSignature.parse(
            "func URL.appendingPathComponent(_ component: String) -> URL")
        #expect(method.kind == .method)
        #expect(method.receiverType == "URL")
        #expect(method.name == "appendingPathComponent")

        let staticMethod = try HostSignature.parse(
            "static func Int.random(in range: Range<Int>) -> Int")
        #expect(staticMethod.kind == .staticMethod)
        #expect(staticMethod.receiverType == "Int")
        #expect(staticMethod.parameters.first?.name == "range")

        let property = try HostSignature.parse(
            "var DateFormatter.dateFormat: String { get set }")
        #expect(property.kind == .property)
        #expect(property.isSettable)

        let staticValue = try HostSignature.parse("static let Int.max: Int")
        #expect(staticValue.kind == .staticProperty)
        #expect(!staticValue.isSettable)

        let genericMethod = try HostSignature.parse(
            "func JSONDecoder.decode<T: Decodable>(_: T.Type, from data: Data) throws -> T")
        #expect(genericMethod.genericParameters == [
            .init(name: "T", constraints: ["Decodable"]),
        ])
        #expect(genericMethod.parameters.map(\.label) == [nil, "from"])
        #expect(genericMethod.parameters.map(\.type) == ["T.Type", "Data"])
        #expect(genericMethod.returnType == "T")
        #expect(genericMethod.isThrowing)

        let whereConstrained = try HostSignature.parse(
            "func Set.union<S>(_ other: S) -> Set where S: Sequence")
        #expect(whereConstrained.genericParameters == [
            .init(name: "S", constraints: ["Sequence"]),
        ])
    }

    @Test func parserRetainsTopLevelAttributesAndModifiers() throws {
        let signature = try HostSignature.parse("""
        @available(macOS 14, *)
        @MainActor
        public func isolatedHostValue() async throws -> Int
        """)

        #expect(signature.kind == .function)
        #expect(signature.name == "isolatedHostValue")
        #expect(signature.attributes == [
            "@available(macOS 14, *)",
            "@MainActor",
        ])
        #expect(signature.modifiers == ["public"])
        #expect(signature.isAsync)
        #expect(signature.isThrowing)
    }

    @Test func parserRetainsQualifiedMemberAttributesAndModifiers() throws {
        let method = try HostSignature.parse(
            "@MainActor nonisolated func String.syntheticValue() async -> Int")
        #expect(method.kind == .method)
        #expect(method.receiverType == "String")
        #expect(method.name == "syntheticValue")
        #expect(method.attributes == ["@MainActor"])
        #expect(method.modifiers == ["nonisolated"])
        #expect(method.isAsync)

        let property = try HostSignature.parse(
            "@MainActor static var String.syntheticCount: Int { get set }")
        #expect(property.kind == .staticProperty)
        #expect(property.receiverType == "String")
        #expect(property.attributes == ["@MainActor"])
        #expect(property.modifiers == ["static"])
        #expect(property.isSettable)

        let initializer = try HostSignature.parse(
            "@MainActor init String(syntheticValue: Int)")
        #expect(initializer.kind == .initializer)
        #expect(initializer.receiverType == "String")
        #expect(initializer.attributes == ["@MainActor"])
    }

    @Test func parserRejectsRecoveredSyntaxAndUnsupportedShapes() {
        #expect(throws: HostSignatureError.self) {
            _ = try HostSignature.parse("func broken(_ value: ) -> Int")
        }
        #expect(throws: HostSignatureError.self) {
            _ = try HostSignature.parse("subscript Bag(_ index: Int) -> String")
        }
    }

    @Test func defaultsVariadicsAndTrailingClosuresMatchNativeSwift() throws {
        func nativeSummary(prefix: String = "default", values: Int...) -> String {
            "\(prefix):\(values.reduce(0, +))"
        }
        func nativeWithValue(_ value: Int = 3, body: (Int) -> Int) -> Int {
            body(value)
        }

        let interpreter = Interpreter()
        let summary = try HostFunction(
            declaration: "func summary(prefix: String = \"default\", values: Int...) -> String"
        ) { arguments, _ in
            let prefix = arguments.labeled("prefix")?.stringValue ?? "default"
            let sum = arguments.arguments.compactMap { $0.value.intValue }.reduce(0, +)
            return .native("\(prefix):\(sum)")
        }
        let withValue = try HostFunction(
            declaration: "func withValue(_ value: Int = 3, body: (Int) -> Int) -> Int"
        ) { arguments, context in
            guard let body = arguments.firstUnlabeledClosure else {
                throw RuntimeError(message: "missing body")
            }
            return try context.callClosure(
                body, arguments: [arguments.positional(0) ?? .native(3)])
        }
        interpreter.globals.define("summary", .hostFunction(summary))
        interpreter.globals.define("withValue", .hostFunction(withValue))

        let interpreted = try interpreter.run(source: """
        let first = summary(values: 1, 2, 3)
        let second = summary(prefix: "custom", values: 4, 5)
        let third = withValue { value in value * 2 }
        "\\(first)|\\(second)|\\(third)"
        """).stringValue
        let native = "\(nativeSummary(values: 1, 2, 3))|"
            + "\(nativeSummary(prefix: "custom", values: 4, 5))|"
            + "\(nativeWithValue { $0 * 2 })"

        #expect(interpreted == native)
    }

    @Test func keyPathSatisfiesFunctionParameterLikeNativeSwift() throws {
        let interpreter = Interpreter()
        let predicate = try HostFunction(
            declaration:
                "func accepts(_ predicate: (Any) throws -> Bool) rethrows -> Bool"
        ) { _, _ in .native(true) }

        let result = try predicate.invoke(
            CallArguments(arguments: [
                .init(
                    label: nil,
                    value: .native(KeyPathStub(components: ["accepted"])))
            ]),
            interpreter)

        #expect(result.boolValue == true)
    }

    @Test func keyPathSatisfiesConcreteKeyPathParameterLikeNativeSwift() throws {
        let interpreter = Interpreter()
        let predicate = try HostFunction(
            declaration:
                "func accepts(_ keyPath: WritableKeyPath<Root, String>) -> Bool"
        ) { _, _ in .native(true) }

        let result = try predicate.invoke(
            CallArguments(arguments: [
                .init(
                    label: nil,
                    value: .native(KeyPathStub(components: ["name"])))
            ]),
            interpreter)

        #expect(result.boolValue == true)
    }

    @Test func validationRunsBeforeGatewayAndChecksReturnType() throws {
        let interpreter = Interpreter()
        var calls = 0
        let function = try HostFunction(
            declaration: "func checked(value: Int) -> Int"
        ) { arguments, _ in
            calls += 1
            return arguments.labeled("value")!
        }

        do {
            _ = try function.invoke(CallArguments(arguments: [
                .init(label: "value", value: .native("wrong")),
            ]), interpreter)
            Issue.record("wrong argument type should fail")
        } catch let error as RuntimeError {
            #expect(error.message.contains("expected type 'Int'"))
        }
        #expect(calls == 0)

        let wrongReturn = try HostFunction(
            declaration: "func wrongReturn() -> Int"
        ) { _, _ in .native("wrong") }
        do {
            _ = try wrongReturn.invoke(CallArguments(), interpreter)
            Issue.record("wrong return type should fail")
        } catch let error as RuntimeError {
            #expect(error.message.contains("returned 'String', expected 'Int'"))
        }
    }

    @Test func foundationRuntimeAliasesSatisfySourceContractsRecursively() throws {
        let interpreter = Interpreter()
        let decimal = try HostFunction(
            declaration: "func acceptsDecimal(_ value: Decimal) -> Bool"
        ) { _, _ in .native(true) }
        #expect(try decimal.invoke(CallArguments(arguments: [
            .init(label: nil, value: .native(Decimal(3) as Any)),
        ]), interpreter).boolValue == true)

        let comparison = try HostFunction(
            declaration: "func comparison() -> ComparisonResult"
        ) { _, _ in
            .native(Date(timeIntervalSince1970: 0).compare(
                Date(timeIntervalSince1970: 1)) as Any)
        }
        #expect(try comparison.invoke(CallArguments(), interpreter).hostPayload != nil)

        let nestedIndex = try HostFunction(
            declaration: "func indices() -> Range<IndexSet.Index>"
        ) { _, _ in
            let set = IndexSet(integersIn: 1..<5)
            return .native(set.indexRange(in: 1..<3) as Any)
        }
        #expect(try nestedIndex.invoke(CallArguments(), interpreter).hostPayload != nil)

        let request = URLRequest(url: URL(string: "https://example.com")!)
        let policy = try HostFunction(
            declaration: "func policy() -> URLRequest.CachePolicy"
        ) { _, _ in .native(request.cachePolicy as Any) }
        #expect(try policy.invoke(CallArguments(), interpreter).hostPayload != nil)

        let headers = try HostFunction(
            declaration: "func headers() -> [String: String]"
        ) { _, _ in .native(["Accept": "text/plain"] as Any) }
        #expect(try headers.invoke(CallArguments(), interpreter).hostPayload != nil)

        let stream = try HostFunction(
            declaration: "func stream() -> InputStream?"
        ) { _, _ in .native(request.httpBodyStream) }
        #expect(try stream.invoke(CallArguments(), interpreter).isNil)
    }

    @Test func genericBindingConstrainsArgumentsAndReturn() throws {
        let interpreter = Interpreter()
        let identity = try HostFunction(
            declaration: "func identity<T: Equatable>(_ value: T) -> T"
        ) { arguments, _ in arguments.positional(0)! }

        #expect(try identity.invoke(CallArguments(arguments: [
            .init(label: nil, value: .native(42)),
        ]), interpreter).intValue == 42)

        let brokenIdentity = try HostFunction(
            declaration: "func brokenIdentity<T: Equatable>(_ value: T) -> T"
        ) { _, _ in .native("not the bound type") }
        do {
            _ = try brokenIdentity.invoke(CallArguments(arguments: [
                .init(label: nil, value: .native(42)),
            ]), interpreter)
            Issue.record("generic return should retain the argument binding")
        } catch let error as RuntimeError {
            #expect(error.message.contains("expected 'Int'"))
        }

        do {
            _ = try identity.invoke(CallArguments(arguments: [
                .init(label: nil, value: .hostFunction(identity)),
            ]), interpreter)
            Issue.record("a function value is not Equatable")
        } catch let error as RuntimeError {
            #expect(error.message.contains("generic constraints"))
        }
    }

    @Test func genericParameterBindsThroughBindingWrappedValue() throws {
        let interpreter = Interpreter()
        let signature = try HostSignature(
            parsing: "func consume<T>(_ value: Binding<T?>)"
        )
        let binding = BindingStub(box: Box(
            .none(wrappedTypeName: "String")
        ))

        let match = signature.match(
            arguments: CallArguments(arguments: [
                .init(label: nil, value: .native(binding)),
            ]),
            in: interpreter
        )

        #expect(match?.genericBindings["T"] == "String")
    }

    @Test func overloadsPreferExactTypesAndRejectAmbiguity() throws {
        let interpreter = Interpreter()
        let integer = try HostFunction(
            declaration: "func classify(_ value: Int) -> String"
        ) { _, _ in .native("int") }
        let double = try HostFunction(
            declaration: "func classify(_ value: Double) -> String"
        ) { _, _ in .native("double") }
        let overloads = try HostFunction(overloads: [integer, double])

        #expect(try overloads.invoke(CallArguments(arguments: [
            .init(label: nil, value: .native(1)),
        ]), interpreter).stringValue == "int")
        #expect(try overloads.invoke(CallArguments(arguments: [
            .init(label: nil, value: .native(1.5)),
        ]), interpreter).stringValue == "double")

        let equatable = try HostFunction(
            declaration: "func ambiguous<T: Equatable>(_ value: T) -> String"
        ) { _, _ in .native("equatable") }
        let hashable = try HostFunction(
            declaration: "func ambiguous<T: Hashable>(_ value: T) -> String"
        ) { _, _ in .native("hashable") }
        let ambiguous = try HostFunction(overloads: [equatable, hashable])
        do {
            _ = try ambiguous.invoke(CallArguments(arguments: [
                .init(label: nil, value: .native(1)),
            ]), interpreter)
            Issue.record("equal-score overloads must not depend on registration order")
        } catch let error as RuntimeError {
            #expect(error.message.contains("ambiguous host overload"))
        }
    }

    @Test func parsedBuiltinDescriptorsAreCachedAcrossSessions() {
        let first = Interpreter()
        let second = Interpreter()
        guard case .hostFunction(let firstAbs)? = first.globals.lookup("abs"),
              case .hostFunction(let secondAbs)? = second.globals.lookup("abs") else {
            Issue.record("abs should be a registered host overload set")
            return
        }

        #expect(firstAbs === secondAbs)
        #expect(firstAbs.signatures.count == 2)
    }

    @Test func registrationEnforcesEffectsAndThrowingContract() throws {
        #expect(throws: HostSignatureError.self) {
            _ = try HostFunction(
                declaration: "func delayed() async -> Int",
                invoke: { _, _ in .native(1) })
        }
        #expect(throws: HostSignatureError.self) {
            _ = try HostFunction(
                declaration: "func immediate() -> Int",
                asyncInvoke: { _, _ in .native(1) })
        }

        struct ProbeError: Error {}
        let nonthrowing = try HostFunction(
            declaration: "func nonthrowing() -> Int"
        ) { _, _ in throw ProbeError() }
        do {
            _ = try nonthrowing.invoke(CallArguments(), Interpreter())
            Issue.record("nonthrowing declarations must not leak host errors")
        } catch let error as RuntimeError {
            #expect(error.message.contains("nonthrowing"))
            #expect(error.message.contains("threw"))
        }
    }

    @Test func workerGatewaysRequireSynchronousReadOnlyContracts() throws {
        #expect(throws: HostSignatureError.self) {
            _ = try HostFunction(
                declaration: "func workerAsync() async -> Bool",
                invoke: { _, _ in .native(true) },
                workerOperation: { _, _ in
                    HostWorkerOperation { .bool(true) }
                })
        }
        #expect(throws: HostSignatureError.self) {
            _ = try HostProperty(
                declaration:
                    "var String.workerAsync: Bool { get async }",
                get: { _, _ in .native(true) },
                workerGet: { _, _ in
                    HostWorkerOperation { .bool(true) }
                })
        }
        #expect(throws: HostSignatureError.self) {
            _ = try HostProperty(
                declaration:
                    "var String.mutableWorker: Bool { get set }",
                get: { _, _ in .native(true) },
                workerGet: { _, _ in
                    HostWorkerOperation { .bool(true) }
                })
        }

        let function = try HostFunction(
            declaration: "func workerSync() -> Bool",
            invoke: { _, _ in .native(true) },
            workerOperation: { _, _ in
                HostWorkerOperation { .bool(true) }
            })
        let property = try HostProperty(
            declaration: "var String.workerSync: Bool { get }",
            get: { _, _ in .native(true) },
            workerGet: { _, _ in
                HostWorkerOperation { .bool(true) }
            })

        #expect(function.signature?.isAsync == false)
        #expect(function.canSuspend)
        #expect(function.hasWorkerOperation)
        #expect(property.signature.isAsync == false)
        #expect(property.canSuspend)
        #expect(property.hasWorkerOperation)
    }

    @Test func typedAsyncGatewaySuspendsAndValidates() async throws {
        let interpreter = Interpreter()
        var calls = 0
        let delayed = try HostFunction(
            declaration: "func delayed(_ value: String) async -> String",
            asyncInvoke: { arguments, _ in
                calls += 1
                await Task.yield()
                return arguments.positional(0)!
            })
        interpreter.globals.define("delayed", .hostFunction(delayed))

        #expect(try await interpreter.runAsync(
            source: "await delayed(\"ready\")").stringValue == "ready")
        #expect(calls == 1)

        do {
            _ = try await interpreter.runAsync(source: "await delayed(7)")
            Issue.record("async arguments should be checked before suspension")
        } catch let error as RuntimeError {
            #expect(error.message.contains("expected type 'String'"))
        }
        #expect(calls == 1)

        do {
            _ = try interpreter.run(source: "delayed(\"sync\")")
            Issue.record("async-only gateway should require await")
        } catch let error as RuntimeError {
            #expect(error.message.contains("requires runAsync and await"))
        }
    }

    @Test func typedPropertyDrivesInterpreterReadsAndWrites() throws {
        let registry = try CounterRegistry()
        let interpreter = Interpreter(registry: registry)

        #expect(try interpreter.run(source: """
        let counter = CounterBox()
        counter.value = 7
        counter.value
        """).intValue == 7)
        #expect(registry.counter.value == 7)

        do {
            _ = try interpreter.run(source: """
            let other = CounterBox()
            other.value = "wrong"
            """)
            Issue.record("typed setter should reject the wrong value")
        } catch let error as RuntimeError {
            #expect(error.message.contains("expected 'Int'"))
        }
        #expect(registry.counter.value == 7)
    }

    @Test func typedPropertyRejectsNativeIllegalEffectfulSetter() throws {
        #expect(throws: HostSignatureError.self) {
            _ = try HostProperty(
                declaration: "var String.invalid: Int { get throws set }",
                get: { _, _ in .native(1) },
                set: { _, _, _ in })
        }
    }

    @Test func typedAsyncPropertySuspendsAndValidates() async throws {
        let state = AsyncPropertyProbeState()
        let registry = try AsyncPropertyProbeRegistry(state: state)
        let interpreter = Interpreter(registry: registry)
        let evaluation = Task { @MainActor in
            try await interpreter.runAsync(
                source: "try await \"swift\".syntheticAsyncCount")
        }

        while !state.didEnter { await Task.yield() }
        #expect(state.events == ["enter:swift"])
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 1)
        let record = try #require(
            interpreter.concurrencyRuntime.records.values.first)
        #expect(record.state == .waiting)
        if case .awaitingHost? = record.suspension {
            // Expected: an async getter is a first-class host suspension.
        } else {
            Issue.record("async property did not suspend on a host operation")
        }

        state.isOpen = true
        #expect(try await evaluation.value.intValue == 5)
        #expect(state.events == ["enter:swift", "exit:swift"])
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)

        let nested = try await interpreter.runAsync(
            source: "try await \"swift\".syntheticAsyncCount.description")
        #expect(nested.stringValue == "5")
        let optional = try await interpreter.runAsync(source: """
        let text: String? = "swift"
        (try await text?.syntheticAsyncCount) ?? -1
        """)
        #expect(optional.intValue == 5)

        let recovered = try await interpreter.runAsync(source: """
        do {
            _ = try await "fail".syntheticAsyncCount
            return "missed"
        } catch {
            return "caught"
        }
        """)
        #expect(recovered.stringValue == "caught")

        do {
            _ = try interpreter.run(
                source: "try await \"swift\".syntheticAsyncCount")
            Issue.record("synchronous entry accepted an async property")
        } catch let error as RuntimeError {
            #expect(error.message.contains("requires runAsync and await"))
        }

        do {
            _ = try await interpreter.runAsync(
                source: "try await \"wrong\".syntheticAsyncCount")
            Issue.record("async property accepted the wrong result type")
        } catch let error as RuntimeError {
            #expect(error.message.contains("expected 'Int'"))
        }

        let cancellation = Task { @MainActor in
            try await interpreter.runAsync(
                source: "try await \"cancel\".syntheticAsyncCount")
        }
        while !state.events.contains("enter:cancel") { await Task.yield() }
        cancellation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancellation.value
        }
        #expect(interpreter.concurrencyRuntime.activeHostOperationCount == 0)
        #expect(interpreter.concurrencyRuntime.activeRecordCount == 0)

        #expect(throws: HostSignatureError.self) {
            _ = try HostProperty(
                declaration: "var String.notAsync: Int { get }",
                asyncGet: { _, _ in .native(1) })
        }
    }
}

private enum AsyncPropertyProbeError: Error {
    case requested
}

private final class AsyncPropertyProbeState {
    var didEnter = false
    var isOpen = false
    var events: [String] = []
}

private final class AsyncPropertyProbeRegistry: HostRegistry {
    private let property: HostProperty

    init(state: AsyncPropertyProbeState) throws {
        property = try HostProperty(
            declaration:
                "var String.syntheticAsyncCount: Int { get async throws }",
            asyncGet: { receiver, _ in
                guard let string = receiver.stringValue else {
                    throw RuntimeError(message: "expected String receiver")
                }
                state.didEnter = true
                state.events.append("enter:\(string)")
                if string == "cancel" {
                    try await Task.sleep(for: .seconds(30))
                }
                while !state.isOpen { await Task.yield() }
                if string == "fail" {
                    throw AsyncPropertyProbeError.requested
                }
                if string == "wrong" {
                    return .native("wrong")
                }
                state.events.append("exit:\(string)")
                return .native(string.count)
            })
    }

    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        name == "syntheticAsyncCount" && value is String ? property : nil
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? { nil }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(
        instance: Instance, interpreter: Interpreter
    ) -> RuntimeValue { .void }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
}

private final class CounterBox {
    var value = 0
}

private final class CounterRegistry: HostRegistry {
    let counter: CounterBox
    private let counterConstructor: HostFunction
    private let counterValue: HostProperty

    init() throws {
        let counter = CounterBox()
        self.counter = counter
        self.counterConstructor = try HostFunction(
            declaration: "init CounterBox()"
        ) { _, _ in .native(counter) }
        self.counterValue = try HostProperty(
            declaration: "var CounterBox.value: Int",
            get: { receiver, _ in
                guard case .host(let any) = receiver,
                      let counter = any as? CounterBox else {
                    throw RuntimeError(message: "wrong counter receiver")
                }
                return .native(counter.value)
            },
            set: { receiver, value, _ in
                guard case .host(let any) = receiver,
                      let counter = any as? CounterBox,
                      let value = value.intValue else {
                    throw RuntimeError(message: "wrong counter setter")
                }
                counter.value = value
            })
    }

    func cFunction(named name: String) -> HostFunction? { nil }
    func absorbedCValue(named name: String) -> RuntimeValue? { nil }
    func storeBlob(_ value: RuntimeValue, at path: String) {}
    func constructor(named name: String) -> HostFunction? {
        name == "CounterBox" ? counterConstructor : nil
    }
    func modifier(named name: String) -> HostModifier? { nil }
    func isViewValue(_ value: RuntimeValue) -> Bool { false }
    func makeRenderable(instance: Instance, interpreter: Interpreter) -> RuntimeValue {
        .void
    }
    func makeGroup(_ views: [RuntimeValue]) throws -> RuntimeValue { .void }
    func hostTypeName(of value: Any) -> String? {
        value is CounterBox ? "CounterBox" : nil
    }
    func hostProperty(named name: String, on value: Any) -> HostProperty? {
        value is CounterBox && name == "value" ? counterValue : nil
    }
}
