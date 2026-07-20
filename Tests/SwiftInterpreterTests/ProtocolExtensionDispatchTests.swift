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
