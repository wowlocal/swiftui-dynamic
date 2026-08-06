import Testing
@testable import SwiftInterpreter

/// `resolveAnnotated` ends in a long tail that asks what an annotation's TYPE
/// gives to a member the expression could not resolve on its own — `.now`,
/// `.init(…)`, `.success(x)`. Reaching that answer splits the type name, walks
/// the lexical type scopes, canonicalizes typealiases and reads the
/// host-extension tables twice. It ran on every annotated parameter bind and
/// every declared function return, including the overwhelming majority whose
/// value was ALREADY a resolved runtime value — for which the entire tail is
/// an identity function.
///
/// The pins assert the STRUCTURE (the tail does not run) rather than a
/// duration, so machine load cannot turn them red.
@Suite("Annotation type-context cost")
struct AnnotationTypeContextCostTests {
    /// The class itself: ordinary annotated parameters, returns and stored
    /// properties carry values that are already resolved, so none of them
    /// may reach the type-context tail even once.
    @Test func resolvedValuesNeverResolveTheirAnnotationsType() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        struct Point {
            var x: Int
            var y: Int

            func scaled(by factor: Int) -> Point {
                Point(x: x * factor, y: y * factor)
            }
        }

        func total(of points: [Point]) -> Int {
            var sum = 0
            for point in points {
                sum += point.x + point.y
            }
            return sum
        }

        let points = [Point(x: 1, y: 2), Point(x: 3, y: 4)]
        total(of: points.map { $0.scaled(by: 3) })
        """)

        // Native-verified: `swiftc -O` on this same snippet prints 30.
        #expect(result.intValue == 30)
        #expect(interpreter.annotationTypeContextResolutionCount == 0)
    }

    /// The control, and the reason the guard is a value-shape test rather
    /// than a removal: a leading-dot member has no meaning until its
    /// annotation supplies the type, so it must still reach the tail and
    /// still resolve to the case it names.
    @Test func contextualMemberStillResolvesAgainstItsAnnotation() throws {
        let interpreter = Interpreter()
        let result = try interpreter.run(source: """
        enum Sort {
            case ascending
            case descending
        }

        func chosen() -> Sort {
            .descending
        }

        func describe(_ sort: Sort) -> String {
            switch sort {
            case .ascending: return "up"
            case .descending: return "down"
            }
        }

        describe(chosen())
        """)

        // Native-verified: `swiftc -O` on this same snippet prints down.
        #expect(result.stringValue == "down")
        #expect(interpreter.annotationTypeContextResolutionCount > 0)
    }
}
