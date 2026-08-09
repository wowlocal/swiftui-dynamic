import Testing
@testable import SwiftInterpreter

/// User-declared GLOBAL operator functions dispatch when builtins can't
/// combine the operands — the MovieSwiftUI reducer genre.
@Suite struct UserOperatorTests {
    @Test func compoundOperatorFunctionMergesDictAndArray() throws {
        let source = """
        struct Movie {
            let id: Int
            let title: String
        }
        func +=(lhs: inout [Int: Movie], rhs: [Movie]) {
            for movie in rhs {
                lhs[movie.id] = movie
            }
        }
        struct State {
            var movies: [Int: Movie] = [:]
        }
        var state = State()
        state.movies += [Movie(id: 7, title: "Heat"), Movie(id: 9, title: "Ronin")]
        state.movies += [Movie(id: 7, title: "Heat II")]
        "\\(state.movies[7]!.title) \\(state.movies[9]!.title) \\(state.movies.count)"
        """
        let result = try Interpreter().run(source: source)
        #expect(result.stringValue == "Heat II Ronin 2")
    }

    @Test func builtinCompoundStillWins() throws {
        let source = """
        func +=(lhs: inout [Int: String], rhs: [String]) {
            lhs[0] = rhs.first ?? ""
        }
        var n = 5
        n += 2
        var items = ["a"]
        items += ["b"]
        "\\(n) \\(items.joined(separator: ""))"
        """
        let result = try Interpreter().run(source: source)
        #expect(result.stringValue == "7 ab")
    }

    /// Distilled from SwiftSoup's pointer arithmetic colliding with its
    /// unrelated `StringBuilder + StringBuilder` declaration. Native Swift
    /// selects the only overload whose parameter types accept both operands.
    @Test func globalOperatorOverloadUsesRuntimeArgumentTypes() throws {
        let source = """
        struct Cursor {
            let offset: Int
        }

        struct Builder {}

        func +(lhs: Cursor, rhs: Int) -> Int {
            lhs.offset + rhs
        }

        func +(lhs: Builder, rhs: Builder) -> Int {
            -100
        }

        Cursor(offset: 40) + 2
        """

        let result = try Interpreter().run(source: source)
        #expect(result.intValue == 42)
    }

    /// A generic parameter inside a concrete outer type does not erase that
    /// outer type during overload selection. SwiftSoup declares generic
    /// collection operators that must not capture unrelated pointer operands.
    @Test func genericOperatorOverloadRequiresItsConcreteOuterType() throws {
        let source = """
        struct Cursor {
            let offset: Int
        }

        struct Box<Element> {}

        func +<Element, Other>(lhs: Box<Element>, rhs: Other) -> Int {
            -100
        }

        func +(lhs: Cursor, rhs: Int) -> Int {
            lhs.offset + rhs
        }

        Cursor(offset: 40) + 2
        """

        let result = try Interpreter().run(source: source)
        #expect(result.intValue == 42)
    }

    /// A leading-dot static value is inferred from either nominal operand,
    /// including a source struct whose Equatable witness is synthesized.
    /// Collection predicates exercise the same operator path as a direct
    /// comparison and must receive that contextual type too.
    @Test func sourceStructPeerContextsLeadingDotStaticEquality() throws {
        let source = """
        struct Kind: RawRepresentable, Hashable {
            var rawValue: String
            init(rawValue: String) { self.rawValue = rawValue }
            static let common = Self(rawValue: "common")
            static let rare = Self(rawValue: "rare")
        }

        struct Item {
            let id: Int
            let kind: Kind
        }

        let items = [
            Item(id: 1, kind: .common),
            Item(id: 2, kind: .rare),
        ]

        func classify(_ kind: Kind) -> Int {
            switch kind {
            case .common: 10
            case .rare: 20
            default: -1
            }
        }

        (items.first(where: { $0.kind == .rare })!.id,
         classify(items[1].kind))
        """

        let result = try Interpreter().run(source: source)
        let tuple = try #require(result.tupleValue)
        #expect(tuple.values[0].intValue == 2)
        #expect(tuple.values[1].intValue == 20)
    }

    /// An enum computed property may select a source static value and feed it
    /// through a source static factory. Neither hop is an imported SDK chain.
    @Test func enumComputedStaticValueSurvivesSourceFactoryChain() throws {
        let source = """
        struct Payload {
            let number: Int
            func adding(_ other: Payload) -> Payload {
                Payload(number: number + other.number)
            }
        }
        enum Phase {
            case first, second
            static let firstPayload = Payload(number: 20)
            static let secondPayload = Payload(number: 22)
            var payload: Payload {
                switch self {
                case .first: Self.firstPayload
                case .second: Self.secondPayload
                }
            }
        }
        struct Palette {
            static func make() -> Payload {
                let current = Phase.first
                let next = Phase.second
                return current.payload.adding(next.payload)
            }
        }
        Palette.make().number
        """

        let result = try Interpreter().run(source: source)
        #expect(result.intValue == 42)
    }
}
