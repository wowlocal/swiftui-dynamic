import Testing
@testable import SwiftInterpreter

@Suite struct ProtocolExtensionDispatchTests {
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
}
