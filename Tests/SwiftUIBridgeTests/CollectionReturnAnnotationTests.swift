import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// A computed property whose declared type is a COLLECTION of leading-dot
/// members: `var tabs: [AppTab] { [.timeline, .settings] }`
/// (IceCubes `Tabs.swift:349`). The same body written as a `func` already
/// resolved, because a function threads its declared return type; the
/// property left every element an untyped marker.
///
/// Most consumers hide it: passing the array to anything with a declared
/// parameter type resolves the elements at THAT boundary, which is why the
/// lazy design normally holds. It only bites where no such boundary exists —
/// an element handed to a generically recorded SDK container, which is
/// precisely IceCubes' shell (`Tab(value: tab)` over these very tabs, with
/// the selection holding a resolved `AppTab`), so nothing matched the
/// selection and every tab lost its content.
///
/// The assertions therefore read the elements with NO typed boundary in
/// between — `String(describing:)` over the array itself.
@Suite(.serialized)
struct CollectionReturnAnnotationTests {
    private static let source = """
    enum Screen: Hashable { case one, two }

    enum Section {
        case main

        var viaProperty: [Screen] {
            switch self {
            case .main: return [.one, .two]
            }
        }
        var viaExpressionProperty: [Screen] { [.one, .two] }
        func viaFunction() -> [Screen] {
            switch self {
            case .main: return [.one, .two]
            }
        }
    }

    struct ContentView: View {
        var body: some View {
            let prop = Section.main.viaProperty.map(String.init(describing:))
            let expr = Section.main.viaExpressionProperty
                .map(String.init(describing:))
            let fn = Section.main.viaFunction().map(String.init(describing:))
            VStack {
                Text("prop-\\(prop.joined(separator: "|"))")
                Text("expr-\\(expr.joined(separator: "|"))")
                Text("func-\\(fn.joined(separator: "|"))")
            }
        }
    }
    """

    @Test func aCollectionTypedPropertyResolvesItsElements() async throws {
        let strings = try await LiveCheckSupport.renderedStrings(
            source: Self.source)
        // The function form is the reference: same body, same declared
        // element type, and it already threaded the annotation.
        #expect(strings.contains("func-Screen.one|Screen.two"),
                Comment(rawValue: "got \(strings)"))
        #expect(strings.contains("prop-Screen.one|Screen.two"),
                Comment(rawValue:
                    "a computed property must thread its declared element "
                        + "type exactly as the function form does; an "
                        + "unresolved element prints as a bare leading dot "
                        + "and matches nothing; got \(strings)"))
        #expect(strings.contains("expr-Screen.one|Screen.two"),
                Comment(rawValue:
                    "the single-expression spelling threads it too; got "
                        + "\(strings)"))
    }
}
