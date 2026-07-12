import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// The generated Foundation tier (BridgeGen --emit over the SDK's
/// swiftinterface): members no hand box claims dispatch through
/// GeneratedMembers — real SDK calls, compiled statically.
@Suite struct GeneratedMemberTests {
    @Test func generatedPropertiesExposeParsedReadOnlyContracts() {
        #expect(GeneratedMembers.properties.count >= 240)
        for (key, property) in GeneratedMembers.properties {
            #expect(property.signature.kind == .property)
            #expect(!property.signature.isSettable)
            #expect(property.signature.returnType != nil)
            #expect(key == "\(property.signature.receiverType!).\(property.name)")
        }

        let components = GeneratedMembers.properties["URLComponents.queryItems"]
        #expect(components?.signature.declaration ==
            "var URLComponents.queryItems: [URLQueryItem]? { get }")
    }

    @Test func everyGeneratedPropertyValidatesAgainstSDKReceiver() throws {
        let seedDate = Date(timeIntervalSince1970: 1_234_567_890)
        let seedURL = URL(string: "https://user:pass@example.com/a?x=1#f")!
        var components = URLComponents(url: seedURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "x", value: "1")]
        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar(identifier: .gregorian)
        dateComponents.timeZone = TimeZone(secondsFromGMT: 0)
        dateComponents.year = 2024
        dateComponents.month = 7
        dateComponents.day = 12
        var person = PersonNameComponents()
        person.givenName = "Ada"
        person.familyName = "Lovelace"

        let receivers: [String: Any] = [
            "Calendar": Calendar(identifier: .gregorian),
            "CharacterSet": CharacterSet.alphanumerics,
            "Data": Data([1, 2, 3, 4]),
            "Date": seedDate,
            "DateComponents": dateComponents,
            "DateInterval": DateInterval(start: seedDate, duration: 3_600),
            "Decimal": Decimal(string: "12.5")!,
            "IndexPath": IndexPath(indexes: [1, 3, 5]),
            "IndexSet": IndexSet(integersIn: 1..<6),
            "Locale": Locale(identifier: "en_US"),
            "PersonNameComponents": person,
            "TimeZone": TimeZone(secondsFromGMT: 0)!,
            "URL": seedURL,
            "URLComponents": components,
            "URLQueryItem": URLQueryItem(name: "x", value: "1"),
            "URLRequest": URLRequest(url: seedURL),
            "UUID": UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
        ]
        let interpreter = Interpreter(registry: ViewRegistry())

        for (key, property) in GeneratedMembers.properties.sorted(
            by: { $0.key < $1.key }) {
            guard let receiverType = property.signature.receiverType,
                  let receiver = receivers[receiverType] else {
                Issue.record("\(key): deterministic receiver seed is missing")
                continue
            }
            do {
                _ = try property.read(
                    from: .native(receiver), in: interpreter)
            } catch {
                Issue.record("\(key): \(error)")
            }
        }
    }

    @Test func generatedPropertiesValidateReceiverAndReadOnlyAccess() throws {
        guard let property = GeneratedMembers.properties["Calendar.monthSymbols"] else {
            Issue.record("generated Calendar.monthSymbols contract is missing")
            return
        }
        let interpreter = Interpreter(registry: ViewRegistry())

        do {
            _ = try property.read(
                from: .native(URL(string: "https://example.com")!),
                in: interpreter)
            Issue.record("a generated getter must reject the wrong receiver")
        } catch let error as RuntimeError {
            #expect(error.message.contains("expected receiver 'Calendar'"))
        }

        do {
            try property.write(
                .native([RuntimeValue.native("January")]),
                to: .native(Calendar(identifier: .gregorian)),
                in: interpreter)
            Issue.record("generated property contracts must be read-only")
        } catch let error as RuntimeError {
            #expect(error.message.contains("read-only host property"))
        }
    }

    @Test func generatedPropertiesValidateCollectionsAliasesAndCarriers() throws {
        let registry = ViewRegistry()
        let interpreter = Interpreter(registry: registry)

        let calendar = Calendar(identifier: .gregorian)
        guard let symbols = registry.hostProperty(
            named: "monthSymbols", on: calendar) else {
            Issue.record("generated Calendar.monthSymbols property is missing")
            return
        }
        let months = try symbols.read(from: .native(calendar), in: interpreter)
        #expect((months.hostPayload as? [String])?.count == 12)

        let request = URLRequest(url: URL(string: "https://example.com")!)
        let carrier = URLRequestBox(request: request)
        guard let policy = registry.hostProperty(
            named: "cachePolicy", on: carrier),
              let stream = registry.hostProperty(
                named: "httpBodyStream", on: carrier) else {
            Issue.record("generated URLRequest carrier properties are missing")
            return
        }
        let policyValue = try policy.read(from: .native(carrier), in: interpreter)
        #expect(policyValue.hostPayload as? URLRequest.CachePolicy == request.cachePolicy)

        let streamValue = try stream.read(from: .native(carrier), in: interpreter)
        guard case .optional(let optional) = streamValue else {
            Issue.record("InputStream? should retain Optional storage")
            return
        }
        #expect(optional.wrapped == nil)
    }

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

    @Test func generatedMethodsExposeParsedContractsAndRankByType() throws {
        let registry = ViewRegistry()
        let base = IndexPath(index: 4)
        guard case .hostFunction(let function)? = registry.hostMethod(
            "appending", on: base) else {
            Issue.record("generated IndexPath.appending should be callable")
            return
        }

        #expect(Set(function.signatures.map(\.declaration)) == [
            "func IndexPath.appending(_ p0: Int) -> IndexPath",
            "func IndexPath.appending(_ p0: IndexPath) -> IndexPath",
            "func IndexPath.appending(_ p0: [Int]) -> IndexPath",
        ])

        let result = try function.invoke(CallArguments(arguments: [
            .init(label: nil, value: .native([.native(6), .native(8)])),
        ]), Interpreter(registry: registry))
        #expect(result.hostPayload as? IndexPath == IndexPath(indexes: [4, 6, 8]))
    }

    @Test func generatedContractsRejectWrongTypesBeforeStaticInvocation() throws {
        let registry = ViewRegistry()
        guard case .hostFunction(let function)? = registry.hostMethod(
            "appending", on: IndexPath(index: 1)) else {
            Issue.record("generated IndexPath.appending should be callable")
            return
        }

        do {
            _ = try function.invoke(CallArguments(arguments: [
                .init(label: nil, value: .native("not an index")),
            ]), Interpreter(registry: registry))
            Issue.record("an unsupported argument must not reach generated host code")
        } catch let error as RuntimeError {
            #expect(error.message.contains("no matching host overload"))
            #expect(!error.message.contains("host contract violation"))
        }
    }

    @Test func generatedContractsContextualizeEnumSetLiterals() throws {
        let registry = ViewRegistry()
        let calendar = Calendar(identifier: .gregorian)
        guard case .hostFunction(let function)? = registry.hostMethod(
            "dateComponents", on: calendar) else {
            Issue.record("generated Calendar.dateComponents should be callable")
            return
        }
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        let result = try function.invoke(CallArguments(arguments: [
            .init(label: nil, value: .native([
                .implicitMember("year"), .implicitMember("month"),
            ])),
            .init(label: "from", value: .native(date)),
        ]), Interpreter(registry: registry))

        let components = result.hostPayload as? DateComponents
        #expect(components?.year != nil)
        #expect(components?.month != nil)
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

    @Test func generatedReadContractsDoNotMaskHandWrittenSetters() throws {
        let source = """
        var components = URLComponents(string: "https://example.com/a")!
        components.scheme = "http"
        components.host = "swift.org"
        "\\(components.scheme!)://\\(components.host!)\\(components.path)"
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        #expect(result.stringValue == "http://swift.org/a")
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
