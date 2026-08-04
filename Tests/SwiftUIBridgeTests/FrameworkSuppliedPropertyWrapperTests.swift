import SwiftUI
import Testing

@testable import SwiftUIBridge

/// `@Namespace var ns` writes no initializer and passes the wrapper no input,
/// so there is no source expression for the interpreter to evaluate — and it
/// left the storage empty. Every consumer of that storage then received a void
/// where the framework's own identity belonged: IceCubes' media preview stores
/// it into `QuickLook.namespace` (AppRegistry.swift:46) and every
/// `.matchedTransitionSource(id:in:)` on the screen reads it back
/// (StatusRowMediaPreviewView.swift:162).
///
/// The class is not `@Namespace`. It is a property wrapper whose value the
/// FRAMEWORK supplies: the interface gives it a no-argument `init()`, a
/// get-only `wrappedValue`, and `DynamicProperty` conformance saying the
/// framework owns the storage. Nothing in the generator or the interpreter
/// names a wrapper; that shape selects them.
@Suite(.serialized)
struct FrameworkSuppliedPropertyWrapperTests {
    /// Native-verified: the same view compiled with real swiftc prints
    /// `ns-ID(id: 16)` — the id counts framework allocations, so the pin is the
    /// spelling of a real `Namespace.ID`, not one particular allocation.
    @Test func aFrameworkSuppliedWrapperReceivesTheFrameworksValue()
        async throws
    {
        let source = """
        struct ContentView: View {
            @Namespace private var namespace

            var body: some View {
                Text("ns-" + String(describing: namespace))
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains { $0.hasPrefix("ns-ID(id: ") },
                Comment(rawValue:
                    "@Namespace must hold a real framework namespace "
                        + "identity: \(strings.filter { !$0.isEmpty })"))
    }

    /// Two declarations are two namespaces. This is what says the value is
    /// allocated per declaration rather than shared from one cached identity —
    /// the property that makes a namespace worth having.
    @Test func separateDeclarationsReceiveSeparateIdentities() async throws {
        let source = """
        struct ContentView: View {
            @Namespace private var first
            @Namespace private var second

            var body: some View {
                Text("same-" + String(describing: first == second))
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("same-false"),
                Comment(rawValue:
                    "two @Namespace declarations must not be the same "
                        + "namespace: \(strings.filter { !$0.isEmpty })"))
    }

    /// The control that keeps this from becoming "every wrapper gets a value".
    /// `@State var count = 0` states its own value, and a wrapper the
    /// interpreter models itself must keep winning.
    @Test func aWrapperWithASourceValueKeepsIt() async throws {
        let source = """
        struct ContentView: View {
            @State private var count = 7

            var body: some View {
                Text("count-" + String(count))
            }
        }
        """
        let strings = try await LiveCheckSupport.renderedStrings(source: source)
        #expect(strings.contains("count-7"),
                Comment(rawValue: "\(strings.filter { !$0.isEmpty })"))
    }

    /// The sweep is a SHAPE, so assert the shape rather than the roster: the
    /// wrapper it admits hands back a value of the type the interface declared,
    /// and the wrappers that take input from the declaration stay out. `State`
    /// and `Environment` are generic in exactly what the declaration supplies,
    /// which is why no rule had to mention them.
    @MainActor
    @Test func onlyWrappersThatNeedNoInputAreSupplied() {
        let supplied = GeneratedPropertyWrappers.table["Namespace"]
        #expect(supplied != nil,
                "the interface declares Namespace() and a get-only wrappedValue")
        #expect(supplied?() is Namespace.ID)
        for wrapper in ["State", "Binding", "Environment", "AppStorage",
                        "StateObject", "ObservedObject", "FocusState"] {
            #expect(GeneratedPropertyWrappers.table[wrapper] == nil,
                    Comment(rawValue:
                        "\(wrapper) takes its value from the declaration"))
        }
    }
}
