import Testing
import SwiftInterpreter
import SwiftUIBridge

/// The generated Foundation tier (BridgeGen --emit over the SDK's
/// swiftinterface): members no hand box claims dispatch through
/// GeneratedMembers — real SDK calls, compiled statically.
@Suite struct GeneratedMemberTests {
    @Test func urlPathMembersDispatchThroughGeneratedTable() throws {
        let source = """
        let url = URL(string: "https://example.com/folder/file.txt")!
        let renamed = url.deletingLastPathComponent().appendingPathComponent("other.md")
        renamed.path + " | " + renamed.lastPathComponent + " | " + renamed.pathExtension
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "/folder/other.md | other.md | md")
    }

    @Test func generatedMethodOverloadPicksByLabels() throws {
        let source = """
        let base = URL(string: "https://example.com/a")!
        base.appendingPathComponent("dir", isDirectory: true).absoluteString
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "https://example.com/a/dir/")
    }

    @Test func optionalReturnsUseDedicatedStorageAndCoalesce() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let optional = try interpreter.run(source: """
        let url = URL(string: "file:///tmp/x")!
        url.host
        """)
        guard case .optional(let host) = optional else {
            Issue.record("generated Optional member should retain its wrapper")
            return
        }
        #expect(host.wrapped == nil)

        let source = """
        let url = URL(string: "file:///tmp/x")!
        url.host ?? "NO HOST"
        """
        let result = try interpreter.run(source: source)
        #expect(result.stringValue == "NO HOST")
    }

    @Test func handWrittenBoxesStillWinOverGenerated() throws {
        // URLComponents lives in a hand box (URLComponentsBox) whose dynamic
        // type never reaches the generated table — the box's write-back
        // semantics must keep working with the tier installed.
        let source = """
        var components = URLComponents(string: "https://example.com/a?x=1")!
        components.host ?? "?"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "example.com")
    }

    @Test func handWrittenOptionalBoundariesRetainWrappers() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let constructed = try interpreter.run(source: "URL(string: \"https://example.com\")")
        guard case .optional(let url) = constructed else {
            Issue.record("failable handwritten constructor should return Optional storage")
            return
        }
        #expect(url.wrapped != nil)
        #expect(url.wrappedTypeName == "URL")

        let scheme = try interpreter.run(source: """
        let components = URLComponents(string: "https://example.com")!
        components.scheme
        """)
        guard case .optional(let schemeOptional) = scheme else {
            Issue.record("handwritten Optional property should retain its wrapper")
            return
        }
        #expect(schemeOptional.wrapped?.stringValue == "https")
        #expect(schemeOptional.wrappedTypeName == "String")

        let fragment = try interpreter.run(source: """
        let components = URLComponents(string: "https://example.com")!
        components.fragment
        """)
        guard case .optional(let fragmentOptional) = fragment else {
            Issue.record("nil handwritten Optional property should retain its wrapper")
            return
        }
        #expect(fragmentOptional.wrapped == nil)
        #expect(fragmentOptional.wrappedTypeName == "String")
    }

    @Test func absorbTelemetryRecordsUnknownHostMembers() throws {
        let interpreter = Interpreter(registry: ViewRegistry())
        let source = """
        import Foundation
        let url = URL(string: "https://example.com")!
        url.definitelyNotARealMemberXYZ
        """
        _ = try interpreter.run(source: source, lazyTopLevelGlobals: true)
        #expect(interpreter.absorbedHostMembers["URL.definitelyNotARealMemberXYZ"] == 1)
    }
}
