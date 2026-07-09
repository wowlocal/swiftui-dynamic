import Foundation
import SwiftInterpreter

/// The network bridge. Three modes, one hard rule:
/// - `.absorbed` (default): unchanged historical behavior — network types
///   absorb, stores stay fresh-empty. ProjectCheck/TestCheck always run here.
/// - `.replay(directory)`: URLSession serves RECORDED fixture bytes matched
///   by URL path — deterministic, the only mode LiveCheck's metric may use.
///   Fixtures are real API responses captured once by a human (`curl`), never
///   edited by hand; they are the network's native baseline.
/// - `.live`: real HTTP for interactive demo runs only. Never in a metric.
public enum NetworkPolicy {
    case absorbed
    case replay(fixturesDirectory: String)
    case live
}

@MainActor
public enum NetworkBridge {
    public static var policy: NetworkPolicy = .absorbed

    /// Fixture lookup: `/api/v1/timelines/public` → `api_v1_timelines_public.json`
    /// (host-independent, so any Mastodon instance an app picks matches).
    static func fixtureData(forPath path: String, in directory: String) -> Data? {
        let sanitized = path.split(separator: "/").joined(separator: "_")
        return FileManager.default.contents(atPath: directory + "/" + sanitized + ".json")
    }

    static func respond(to url: URL) throws -> (Data, HTTPURLResponse) {
        switch policy {
        case .absorbed:
            throw RuntimeError(message: "network is absorbed in this mode (URLSession)")
        case .replay(let directory):
            guard let data = fixtureData(forPath: url.path, in: directory) else {
                throw RuntimeError(message: "no fixture recorded for \(url.host ?? "?")\(url.path)")
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        case .live:
            // Synchronous under the interpreter's inline-await model
            // (documented divergence: the calling slice blocks).
            nonisolated final class Holder: @unchecked Sendable {
                var result: Result<(Data, HTTPURLResponse), Error>?
            }
            let holder = Holder()
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: url) { data, response, error in
                if let data, let http = response as? HTTPURLResponse {
                    holder.result = .success((data, http))
                } else {
                    holder.result = .failure(error ?? URLError(.badServerResponse))
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 30)
            switch holder.result {
            case .success(let pair): return pair
            case .failure(let error): throw RuntimeError(message: "URLSession: \(error.localizedDescription)")
            case nil: throw RuntimeError(message: "URLSession: request timed out")
            }
        }
    }

    static func url(from value: RuntimeValue?) -> URL? {
        guard let value else { return nil }
        if case .host(let any) = value {
            if let url = any as? URL { return url }
            if let stub = any as? UIKitStub {
                // URLRequest(url:) built as an absorbing bag — the url rode in.
                if case .host(let inner)? = stub.config["url"], let url = inner as? URL {
                    return url
                }
                if let text = stub.config["url"]?.stringValue { return URL(string: text) }
            }
        }
        if let text = value.stringValue { return URL(string: text) }
        return nil
    }
}

/// `URLSession.shared` and friends.
public final class URLSessionBox {
    public init() {}
}

/// `session.dataTask(with:) { data, response, error in }` — completion runs
/// on `resume()`, exactly like the real API (synchronously here).
public final class DataTaskBox {
    let url: URL?
    let completion: ClosureValue?

    init(url: URL?, completion: ClosureValue?) {
        self.url = url
        self.completion = completion
    }
}

/// `HTTPURLResponse` face for interpreted code (`response.statusCode`).
public final class HTTPResponseBox {
    let response: HTTPURLResponse

    init(_ response: HTTPURLResponse) {
        self.response = response
    }
}

/// JSONDecoder with strategy writes and STRUCTURAL decode into interpreted
/// types (see JSONDecodeBridge). Custom `init(from:)` bodies don't run —
/// documented divergence until real Codable synthesis lands.
public final class JSONDecoderBox {
    var convertFromSnakeCase = false
    var dateStrategy: RuntimeValue?

    public init() {}
}

// MARK: - Member dispatch (called from bridgeHostMember)

@MainActor
func networkBridgeMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let marker = value as? HostTypeMarker, marker.name == "URLSession", name == "shared" {
        return .native(URLSessionBox())
    }
    if value is URLSessionBox {
        switch name {
        case "data":
            // async forms: `let (data, response) = try await session.data(from:/for:)`
            return .hostFunction(HostFunction(name: "data") { args, _ in
                guard let url = NetworkBridge.url(from: args.labeled("from") ?? args.labeled("for") ?? args.positional(0)) else {
                    throw RuntimeError(message: "URLSession.data needs a URL")
                }
                let (data, response) = try NetworkBridge.respond(to: url)
                return .native(TupleValue(labels: [nil, nil], values: [
                    .native(data), .native(HTTPResponseBox(response)),
                ]))
            })
        case "dataTask":
            return .hostFunction(HostFunction(name: "dataTask") { args, _ in
                let url = NetworkBridge.url(from: args.labeled("with") ?? args.positional(0))
                let completion: ClosureValue? = args.arguments
                    .compactMap { if case .closure(let c) = $0.value { c } else { nil } }
                    .first
                return .native(DataTaskBox(url: url, completion: completion))
            })
        default:
            return nil
        }
    }
    if let task = value as? DataTaskBox {
        switch name {
        case "resume":
            return .hostFunction(HostFunction(name: "resume") { _, ctx in
                guard let completion = task.completion else { return .void }
                guard let url = task.url else {
                    _ = try ctx.callClosure(completion, arguments: [
                        .nilValue, .nilValue,
                        .native(RuntimeError(message: "dataTask has no URL")),
                    ])
                    return .void
                }
                do {
                    let (data, response) = try NetworkBridge.respond(to: url)
                    _ = try ctx.callClosure(completion, arguments: [
                        .native(data), .native(HTTPResponseBox(response)), .nilValue,
                    ])
                } catch let error as RuntimeError {
                    _ = try ctx.callClosure(completion, arguments: [
                        .nilValue, .nilValue, .native(error),
                    ])
                }
                return .void
            })
        case "cancel":
            return .hostFunction(HostFunction(name: "cancel") { _, _ in .void })
        default:
            return nil
        }
    }
    if let box = value as? HTTPResponseBox {
        switch name {
        case "statusCode": return .native(box.response.statusCode)
        case "url": return box.response.url.map { .native($0) } ?? .nilValue
        default: return nil
        }
    }
    if let decoder = value as? JSONDecoderBox {
        switch name {
        case "decode":
            return .hostFunction(HostFunction(name: "decode") { args, ctx in
                guard let interpreter = ctx as? Interpreter else {
                    throw RuntimeError(message: "decode needs the interpreter context")
                }
                guard case .host(let dataAny)? = args.labeled("from"),
                      let data = dataAny as? Data else {
                    throw RuntimeError(message: "decode(_:from:) needs Data")
                }
                guard let typeValue = args.positional(0) else {
                    throw RuntimeError(message: "decode(_:from:) needs a type")
                }
                let json: Any
                do {
                    json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                } catch {
                    throw RuntimeError(message: "decode: invalid JSON — \(error.localizedDescription)")
                }
                return try JSONDecodeBridge.decode(
                    typeValue, json: json, interpreter: interpreter, decoder: decoder)
            })
        default:
            // keyDecodingStrategy/dateDecodingStrategy land via hostSetMember.
            return nil
        }
    }
    return nil
}

@MainActor
func networkHostSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
    guard let decoder = value as? JSONDecoderBox else { return false }
    switch name {
    case "keyDecodingStrategy":
        decoder.convertFromSnakeCase = newValue.stringified.contains("convertFromSnakeCase")
        return true
    case "dateDecodingStrategy":
        decoder.dateStrategy = newValue
        return true
    default:
        return false
    }
}

@MainActor
func networkHostObjectConstructor(named name: String) -> HostFunction? {
    switch name {
    case "URL":
        return HostFunction(name: name) { args, _ in
            // Real, failable semantics: URL(string:) is nil on garbage.
            if let text = args.labeled("string")?.stringValue {
                return URL(string: text).map { .native($0) } ?? .nilValue
            }
            if let value = args.labeled("fileURLWithPath"), let path = value.stringValue {
                return .native(URL(fileURLWithPath: path))
            }
            return .nilValue
        }
    case "JSONDecoder":
        return HostFunction(name: name) { _, _ in .native(JSONDecoderBox()) }
    case "__fixtureData":
        // Harness-only: LiveCheck's decode scenarios read recorded bytes.
        return HostFunction(name: name) { args, _ in
            guard case .replay(let directory) = NetworkBridge.policy,
                  let stem = args.positional(0)?.stringValue,
                  let data = FileManager.default.contents(atPath: directory + "/" + stem + ".json") else {
                throw RuntimeError(message: "__fixtureData: no fixture in replay directory")
            }
            return .native(data)
        }
    default:
        return nil
    }
}

// MARK: - Structural JSON decode

/// Decodes JSON into INTERPRETED types structurally: stored-property names
/// (CodingKeys raw values win, then exact, then snake_case) map JSON keys;
/// annotations drive element types. Custom init(from:) bodies do NOT run —
/// a documented divergence until real Codable synthesis; the histogram
/// surfaces types this breaks.
@MainActor
enum JSONDecodeBridge {
    static func decode(
        _ typeValue: RuntimeValue, json: Any, interpreter: Interpreter, decoder: JSONDecoderBox
    ) throws -> RuntimeValue {
        // `[Status].self` — an array literal holding the element type.
        if let array = typeValue.arrayValue, array.count == 1 {
            guard let items = json as? [Any] else {
                throw RuntimeError(message: "decode: expected a JSON array")
            }
            return .native(try items.map {
                try decode(array[0], json: $0, interpreter: interpreter, decoder: decoder)
            })
        }
        switch typeValue {
        case .type(let symbol):
            return try decodeInstance(of: symbol, json: json, interpreter: interpreter, decoder: decoder)
        case .enumType(let symbol):
            return try decodeEnum(symbol: symbol, json: json)
        default:
            throw RuntimeError(message: "decode: unsupported type value \(typeValue.stringified)")
        }
    }

    private static func decodeInstance(
        of symbol: StructSymbol, json: Any, interpreter: Interpreter, decoder: JSONDecoderBox
    ) throws -> RuntimeValue {
        guard let object = json as? [String: Any] else {
            throw RuntimeError(message: "decode(\(symbol.name)): expected a JSON object")
        }
        let codingKeys = codingKeyMap(of: symbol)
        var arguments: [CallArguments.Argument] = []
        for property in symbol.storedProperties {
            let jsonValue = lookup(property.name, in: object, codingKeys: codingKeys)
            let annotation = property.typeAnnotation?.trimmedDescription
            if jsonValue == nil || jsonValue is NSNull {
                if annotation?.hasSuffix("?") == true {
                    arguments.append(.init(label: property.name, value: .nilValue))
                    continue
                }
                if property.initializer != nil {
                    continue // memberwise default fills it
                }
                throw RuntimeError(message: "decode(\(symbol.name)): missing key for '\(property.name)'")
            }
            let decoded = try decodeField(
                jsonValue!, annotation: annotation, interpreter: interpreter, decoder: decoder,
                context: "\(symbol.name).\(property.name)")
            arguments.append(.init(label: property.name, value: decoded))
        }
        return try interpreter.instantiateForBridge(symbol, arguments: CallArguments(arguments: arguments))
    }

    private static func decodeField(
        _ json: Any, annotation: String?, interpreter: Interpreter, decoder: JSONDecoderBox,
        context: String
    ) throws -> RuntimeValue {
        var typeName = annotation ?? ""
        if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }

        if typeName.hasPrefix("[") && typeName.hasSuffix("]") && !typeName.contains(":") {
            guard let items = json as? [Any] else {
                throw RuntimeError(message: "decode(\(context)): expected array")
            }
            let element = String(typeName.dropFirst().dropLast())
            return .native(try items.map {
                try decodeField($0, annotation: element, interpreter: interpreter, decoder: decoder, context: context)
            })
        }
        switch typeName {
        case "String":
            guard let text = json as? String else {
                throw RuntimeError(message: "decode(\(context)): expected String")
            }
            return .native(text)
        case "Int", "Int64", "Int32", "UInt":
            if let number = json as? NSNumber { return .native(number.intValue) }
            throw RuntimeError(message: "decode(\(context)): expected Int")
        case "Double", "Float", "CGFloat", "TimeInterval":
            if let number = json as? NSNumber { return .native(number.doubleValue) }
            throw RuntimeError(message: "decode(\(context)): expected Double")
        case "Bool":
            if let number = json as? NSNumber { return .native(number.boolValue) }
            throw RuntimeError(message: "decode(\(context)): expected Bool")
        case "URL":
            guard let text = json as? String, let url = URL(string: text) else {
                throw RuntimeError(message: "decode(\(context)): expected URL string")
            }
            return .native(url)
        case "Date":
            guard let text = json as? String, let date = parseISO8601(text) else {
                throw RuntimeError(message: "decode(\(context)): expected ISO8601 date string")
            }
            return .native(date)
        default:
            guard let typeValue = interpreter.typeValue(named: typeName) else {
                throw RuntimeError(message: "decode(\(context)): unknown type '\(typeName)'")
            }
            return try decode(typeValue, json: json, interpreter: interpreter, decoder: decoder)
        }
    }

    private static func decodeEnum(symbol: EnumSymbol, json: Any) throws -> RuntimeValue {
        for enumCase in symbol.cases {
            let raw = enumCase.rawValue
            if let text = json as? String, raw.stringValue == text {
                return .enumCase(EnumCaseValue(symbol: symbol, name: enumCase.name))
            }
            if let number = json as? NSNumber, raw.intValue == number.intValue {
                return .enumCase(EnumCaseValue(symbol: symbol, name: enumCase.name))
            }
        }
        throw RuntimeError(message: "decode(\(symbol.name)): no case matches \(json)")
    }

    private static func codingKeyMap(of symbol: StructSymbol) -> [String: String] {
        guard case .enumType(let keys)? = symbol.nestedTypes["CodingKeys"] else { return [:] }
        var map: [String: String] = [:]
        for enumCase in keys.cases {
            map[enumCase.name] = enumCase.rawValue.stringValue ?? enumCase.name
        }
        return map
    }

    private static func lookup(_ property: String, in object: [String: Any], codingKeys: [String: String]) -> Any? {
        if let key = codingKeys[property], let value = object[key] { return value }
        if let value = object[property] { return value }
        return object[snakeCased(property)]
    }

    private static func snakeCased(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase {
                out.append("_")
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }
}
