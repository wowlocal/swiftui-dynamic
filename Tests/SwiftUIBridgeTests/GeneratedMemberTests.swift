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

    @Test func optionalReturnsFlattenToNil() throws {
        let source = """
        let url = URL(string: "file:///tmp/x")!
        url.host ?? "NO HOST"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
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
