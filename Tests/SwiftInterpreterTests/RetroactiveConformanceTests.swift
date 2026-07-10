import Testing
@testable import SwiftInterpreter

/// `extension Thing: Marker {}` — retroactive conformance must count for
/// checked casts (strict `as?` would otherwise false-negative exactly the
/// protocol-witness genre the SwiftUIFlux reducers rely on).
@Suite struct RetroactiveConformanceTests {
    @Test func extensionConformanceCountsForCasts() throws {
        let source = """
        protocol Marker {}
        struct Thing {
            let id = 1
        }
        extension Thing: Marker {}
        struct Plain {
            let id = 2
        }
        let thing = Thing()
        let plain = Plain()
        let a = (thing as? Marker) != nil
        let b = (plain as? Marker) != nil
        "\\(a) \\(b)"
        """
        let result = try Interpreter().run(source: source)
        #expect(result.stringValue == "true false")
    }
}
