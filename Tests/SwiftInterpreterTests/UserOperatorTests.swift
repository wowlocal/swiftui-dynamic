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
}
