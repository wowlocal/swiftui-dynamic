import Testing
@testable import SwiftInterpreter
import SwiftUIBridge

@Suite struct ProtocolExtensionDispatchTests {
    /// A contextual protocol existential can name a static factory supplied
    /// by a same-type-constrained protocol extension. The constraint proves
    /// the concrete `Self` used to execute the factory.
    @Test func contextualFactoryUsesConstrainedConcreteSelf() throws {
        let source = """
        protocol Processor {
            func process(_ value: Int) -> Int
        }

        struct OffsetProcessor: Processor {
            let amount: Int

            func process(_ value: Int) -> Int {
                value + amount
            }
        }

        extension Processor where Self == OffsetProcessor {
            static func offset(_ amount: Int) -> OffsetProcessor {
                OffsetProcessor(amount: amount)
            }
        }

        let processors: [any Processor] = [.offset(3)]
        processors[0].process(4)
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 7)
    }

    /// A protocol default can adapt a container requirement to a concrete
    /// conformer's same-named scalar requirement. Calls through an existential
    /// must retain the concrete witness while the default body executes.
    @Test func existentialDefaultCallsConcreteOverloadedWitness() throws {
        let source = """
        struct Container {
            var value: Int
        }

        enum ProcessingError: Error {
            case failed
        }

        protocol Processing {
            func process(_ value: Int) -> Int?
            func process(
                _ container: Container, context: Int
            ) throws -> Container
        }

        extension Processing {
            func process(
                _ container: Container, context: Int
            ) throws -> Container {
                guard let output = process(container.value) else {
                    throw ProcessingError.failed
                }
                var container = container
                container.value = output
                return container
            }
        }

        struct Offset: Processing {
            func process(_ value: Int) -> Int? {
                value + 3
            }
        }

        let processors: [any Processing] = [Offset()]
        try processors[0].process(
            Container(value: 4), context: 0
        ).value
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 7)
    }

    @Test func asyncExistentialDefaultCallsConcreteOverloadedWitness() async throws {
        let source = """
        struct Container {
            var value: Int
        }

        enum ProcessingError: Error {
            case failed
        }

        protocol Processing {
            func process(_ value: Int) async -> Int?
            func process(
                _ container: Container, context: Int
            ) async throws -> Container
        }

        extension Processing {
            func process(
                _ container: Container, context: Int
            ) async throws -> Container {
                guard let output = await process(container.value) else {
                    throw ProcessingError.failed
                }
                var container = container
                container.value = output
                return container
            }
        }

        struct Offset: Processing {
            func process(_ value: Int) async -> Int? {
                value + 3
            }
        }

        let processors: [any Processing] = [Offset()]
        try await processors[0].process(
            Container(value: 4), context: 0
        ).value
        """

        let value = try await Interpreter().runAsync(source: source)
        #expect(value.intValue == 7)
    }

    @Test func inheritedInstanceOverloadUsesRuntimeType() throws {
        let source = """
        struct Slice {}

        class Base {
            func matches(_ value: [Int]) -> String { "array" }
            func matches(_ value: Slice) -> String { "slice" }
        }

        final class Child: Base {}
        Child().matches(Slice())
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "slice")
    }

    /// An inherited method's unqualified call is still virtual: runtime
    /// subclass overrides win even though the call is written in the generic
    /// superclass body.
    @Test func genericBaseMethodDispatchesImplicitSelfOverride() throws {
        let source = """
        class PipelineTask<Value> {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }

            func start() -> String { "base" }
            func subscribe() -> String { "\\(value):\\(start())" }
        }

        final class ConcreteTask: PipelineTask<Int> {
            override func start() -> String { "concrete" }
        }

        ConcreteTask(7).subscribe()
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "7:concrete")
    }

    /// A concrete class returned through a generic base-typed closure keeps
    /// its runtime identity when a nested publisher stores it and invokes a
    /// private base method that makes a virtual call.
    @Test func genericPoolPreservesConcreteTaskIdentity() throws {
        let source = """
        class PipelineTask<Value> {
            struct Publisher {
                let task: PipelineTask

                func subscribe(
                    priority: Int = 0, subscriber: AnyObject,
                    _ closure: (String) -> Void
                ) -> String {
                    task.subscribe(
                        priority: priority,
                        subscriber: subscriber,
                        closure)
                }

                func subscribe<NewValue>(
                    _ subscriber: PipelineTask<NewValue>,
                    onValue: (String) -> Void
                ) -> String {
                    subscribe(subscriber: subscriber) { value in
                        onValue(value)
                    }
                }
            }

            let value: Value

            init(_ value: Value) {
                self.value = value
            }

            var publisher: Publisher { Publisher(task: self) }
            func start() -> String { "base" }
            private func subscribe(
                priority: Int = 0, subscriber: AnyObject,
                _ closure: (String) -> Void
            ) -> String {
                let value = start()
                closure(value)
                return value
            }
        }

        final class ConcreteTask: PipelineTask<Int> {
            override func start() -> String { "concrete" }
        }

        final class TaskPool<Key: Hashable, Value> {
            private var map = [Key: PipelineTask<Value>]()

            func publisherForKey(
                _ key: Key, _ make: () -> PipelineTask<Value>
            ) -> PipelineTask<Value>.Publisher {
                if let task = map[key] {
                    return task.publisher
                }

                let task = make()
                map[key] = task
                return task.publisher
            }
        }

        let pool = TaskPool<Int, Int>()
        pool.publisherForKey(1) { ConcreteTask(7) }
            .subscribe(PipelineTask<Int>(0)) { _ in }
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "concrete")
    }

    @Test func inheritedStaticOverloadUsesCallShape() throws {
        let source = """
        class Base {
            static func label() -> String { "empty" }
            static func label(_ value: String) -> String { value }
        }

        final class Child: Base {}
        Child.label("chosen")
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "chosen")
    }

    /// A concrete setter-like overload must not shadow a protocol-extension
    /// convenience method whose zero-argument call shape is the only fit.
    @Test func protocolDefaultWinsWhenConcreteOverloadDoesNotFit() throws {
        let source = """
        protocol TextReadable {
            func text(normalised: Bool) -> String
        }

        extension TextReadable {
            func text() -> String {
                text(normalised: true)
            }
        }

        class Element: TextReadable {
            func text(normalised: Bool) -> String {
                normalised ? "content" : "raw"
            }

            func text(_ replacement: String) -> Element {
                self
            }
        }

        final class Document: Element {
            override func text(_ replacement: String) -> Element {
                self
            }
        }

        Document().text()
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "content")
    }

    /// A refined nonthrowing requirement is a better match for an unmarked
    /// call than its same-shaped throwing ancestor. This is the delegation
    /// pattern used when a throwing protocol default adapts a nonthrowing
    /// conformer to the ancestor requirement.
    @Test func unmarkedCallInThrowingDefaultSelectsNonthrowingWitness() throws {
        let source = """
        protocol ThrowingStore {
            func fetch(forKey key: String) throws -> String?
        }

        protocol Store: ThrowingStore {
            func fetch(forKey key: String) -> String?
        }

        extension Store {
            func fetch(forKey key: String) throws -> String? {
                fetch(forKey: key)
            }
        }

        struct Box: Store {
            func fetch(forKey key: String) -> String? {
                "native-ok"
            }
        }

        func throughThrowing(_ store: any ThrowingStore) throws -> String {
            try store.fetch(forKey: "key") ?? "nil"
        }

        try throughThrowing(Box())
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "native-ok")
    }

    /// The same rule applies when the refined witness is supplied by an SDK
    /// host type rather than an interpreted nominal declaration.
    @Test func unmarkedCallInThrowingDefaultSelectsHostWitness() throws {
        let source = """
        import Foundation

        protocol ThrowingStore {
            func object(forKey key: String) throws -> Any?
        }

        protocol Store: ThrowingStore {
            func object(forKey key: String) -> Any?
        }

        extension Store {
            func object(forKey key: String) throws -> Any? {
                object(forKey: key)
            }
        }

        extension UserDefaults: Store {}

        final class Settings {
            let defaults: Store

            init(defaults: Store = UserDefaults.standard) {
                self.defaults = defaults
            }

            func marker() -> String {
                defaults.object(forKey: "dynamic-swiftui-missing-key") == nil
                    ? "native-ok" : "unexpected"
            }
        }
        """

        let interpreter = Interpreter(registry: ViewRegistry())
        _ = try interpreter.run(
            source: source,
            lazyTopLevelGlobals: true)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Settings" })
        guard case .instance(let settings) = try interpreter.instantiateRoot(
            symbol) else {
            Issue.record("Settings did not instantiate")
            return
        }
        let value = try interpreter.callMethod(
            named: "marker", on: settings, arguments: [])
        #expect(value.stringValue == "native-ok")
    }

    /// Suspending dispatch follows the same inherited-family and
    /// protocol-default rules as eager dispatch.
    @Test func asyncProtocolDefaultWinsWhenConcreteOverloadDoesNotFit() async throws {
        let source = """
        protocol TextReadable {
            func text(normalised: Bool) async -> String
        }

        extension TextReadable {
            func text() async -> String {
                await text(normalised: true)
            }
        }

        class Element: TextReadable {
            func text(normalised: Bool) async -> String {
                normalised ? "content" : "raw"
            }

            func text(_ replacement: String) async -> Element {
                self
            }
        }

        final class Document: Element {
            override func text(_ replacement: String) async -> Element {
                self
            }
        }

        await Document().text()
        """

        let value = try await Interpreter().runAsync(source: source)
        #expect(value.stringValue == "content")
    }

    /// Native Swift selects the one-input closure overload here. The
    /// function type is hidden behind a nested alias, matching scheduler
    /// helpers that distinguish a plain block from a starter callback.
    @Test func nestedFunctionAliasPreservesClosureArityDuringOverloadRanking() throws {
        let source = """
        final class Job {
            typealias Starter = (_ finish: @escaping () -> Void) -> Void
        }

        func select(_ action: @escaping () -> Void) -> String {
            "zero"
        }

        func select(_ starter: @escaping Job.Starter) -> String {
            starter({})
            return "one"
        }

        select { finish in finish() }
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "one")
    }

    /// Native Swift selects the nested-alias overload on a native host
    /// receiver too. Nuke's operation scheduler has this exact extension
    /// shape (`OperationQueue.add`), and the request pipeline cannot start if
    /// host-extension ranking treats the alias as a non-function parameter.
    @Test func nestedFunctionAliasRanksHostExtensionClosureOverloads() throws {
        let source = """
        final class Job {
            typealias Starter = @Sendable (
                _ finish: @Sendable @escaping () -> Void
            ) -> Void
        }

        extension String {
            func enqueue(
                _ action: @Sendable @escaping () -> Void
            ) -> String {
                "zero"
            }

            func enqueue(_ starter: @escaping Job.Starter) -> String {
                starter({})
                return "one"
            }
        }

        "queue".enqueue { finish in finish() }
        """

        let value = try Interpreter().run(source: source)
        #expect(value.stringValue == "one")
    }
}
