import AppKit
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

    /// Replay-mode request log (`/path hit|miss`) — the LiveCheck
    /// histogram's view into WHICH requests the app actually made.
    public static var requestLog: [String] = []

    /// Fixture lookup: `/api/v1/timelines/public` → `api_v1_timelines_public.json`
    /// (host-independent, so any Mastodon instance an app picks matches).
    /// Parameterized paths fall back to `_` wildcard segments:
    /// `/3/movie/1311031` matches `3_movie__.json` — one recorded detail
    /// serves every id.
    static func fixtureData(forPath path: String, in directory: String) -> Data? {
        let segments = path.split(separator: "/").map(String.init)
        let exact = segments.joined(separator: "_")
        if let data = FileManager.default.contents(atPath: directory + "/" + exact + ".json") {
            return data
        }
        var wildcarded = segments
        for index in segments.indices.reversed() where looksLikeID(segments[index]) {
            wildcarded[index] = "_"
            let name = wildcarded.joined(separator: "_")
            if let data = FileManager.default.contents(atPath: directory + "/" + name + ".json") {
                return data
            }
        }
        return nil
    }

    private static func looksLikeID(_ segment: String) -> Bool {
        if !segment.isEmpty, segment.allSatisfy(\.isNumber) { return true }
        return segment.count >= 12 && segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// Image requests replay as a DETERMINISTIC placeholder (a solid PNG) —
    /// posters and avatars render without recording binary fixtures.
    static func isImageRequest(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic"]
            .contains(url.pathExtension.lowercased())
    }

    static let placeholderPNG: Data = {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.55, green: 0.63, blue: 0.75, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    static func respond(to url: URL) throws -> (Data, HTTPURLResponse) {
        switch policy {
        case .absorbed:
            throw RuntimeError(message: "network is absorbed in this mode (URLSession)")
        case .replay(let directory):
            defer {
                if requestLog.count < 40 {
                    let hit = isImageRequest(url) || fixtureData(forPath: url.path, in: directory) != nil
                    requestLog.append("\(url.path) \(hit ? "hit" : "MISS")")
                }
            }
            if isImageRequest(url) {
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"])!
                return (Self.placeholderPNG, response)
            }
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
            if let node = any as? TraceNode {
                // Under the TRACE registry the same catch-all bag is a
                // TraceNode — the url rides in its config identically.
                if case .host(let inner)? = node.config["url"], let url = inner as? URL {
                    return url
                }
                if let text = node.config["url"]?.stringValue { return URL(string: text) }
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

/// Real `URLComponents` semantics — the client-genre `makeURL` builds its
/// request URL through scheme/host/path/queryItems writes and reads `.url`
/// back; an absorbed bag here would kill every fetch downstream.
public final class URLComponentsBox {
    var components: URLComponents

    init(_ components: URLComponents = URLComponents()) {
        self.components = components
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

/// The `Decoder` handed to a custom `init(from: Decoder)` when the JSON
/// value is a SCALAR (IceCubes' HTMLString decodes from a plain string via
/// singleValueContainer) — the smallest honest slice of Codable synthesis.
public final class DecoderStub {
    let json: Any
    let decoder: JSONDecoderBox

    init(json: Any, decoder: JSONDecoderBox) {
        self.json = json
        self.decoder = decoder
    }
}

public final class SingleValueContainerStub {
    let json: Any
    let decoder: JSONDecoderBox

    init(json: Any, decoder: JSONDecoderBox) {
        self.json = json
        self.decoder = decoder
    }
}

public final class KeyedContainerStub {
    let object: [String: Any]
    let decoder: JSONDecoderBox

    init(object: [String: Any], decoder: JSONDecoderBox) {
        self.object = object
        self.decoder = decoder
    }
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
                    if LiveCheckSupport.traceLifecycle {
                        let raw = args.labeled("from") ?? args.labeled("for") ?? args.positional(0)
                        print("   ⚠ data(): no URL in \(raw?.stringified ?? "nil")")
                    }
                    throw RuntimeError(message: "URLSession.data needs a URL")
                }
                if LiveCheckSupport.traceLifecycle { print("   ⇢ data(): \(url)") }
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
    if let box = value as? URLComponentsBox {
        switch name {
        case "url":
            return box.components.url.map { .native($0) } ?? .nilValue
        case "string":
            return box.components.string.map { .native($0) } ?? .nilValue
        case "scheme": return box.components.scheme.map { .native($0) } ?? .nilValue
        case "host": return box.components.host.map { .native($0) } ?? .nilValue
        case "path": return .native(box.components.path)
        case "port": return box.components.port.map { .int($0) } ?? .nilValue
        case "query": return box.components.query.map { .native($0) } ?? .nilValue
        case "fragment": return box.components.fragment.map { .native($0) } ?? .nilValue
        case "queryItems":
            guard let items = box.components.queryItems else { return .nilValue }
            return .native(items.map { RuntimeValue.native($0) })
        default:
            return nil
        }
    }
    if let query = value as? URLQueryItem {
        switch name {
        case "name": return .native(query.name)
        case "value": return query.value.map { .native($0) } ?? .nilValue
        default: return nil
        }
    }
    if let box = value as? HTTPResponseBox {
        switch name {
        case "statusCode": return .native(box.response.statusCode)
        case "url": return box.response.url.map { .native($0) } ?? .nilValue
        default: return nil
        }
    }
    if let stub = value as? DecoderStub {
        switch name {
        case "singleValueContainer":
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(SingleValueContainerStub(json: stub.json, decoder: stub.decoder))
            })
        case "container":
            return .hostFunction(HostFunction(name: name) { _, _ in
                guard let object = stub.json as? [String: Any] else {
                    throw RuntimeError(message: "decode: value is not a keyed container")
                }
                return .native(KeyedContainerStub(object: object, decoder: stub.decoder))
            })
        case "unkeyedContainer":
            return .hostFunction(HostFunction(name: name) { _, _ in
                throw RuntimeError(message: "decode: unkeyed containers not supported")
            })
        case "codingPath":
            return .native([RuntimeValue]())
        default:
            return nil
        }
    }
    if let container = value as? SingleValueContainerStub {
        switch name {
        case "decode":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                guard let interpreter = ctx as? Interpreter,
                      let typeArgument = args.positional(0) else {
                    throw RuntimeError(message: "decode needs a type argument")
                }
                return try JSONDecodeBridge.decodeContainerValue(
                    container.json, typeArgument: typeArgument, interpreter: interpreter,
                    decoder: container.decoder, context: "singleValueContainer")
            })
        case "decodeNil":
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(container.json is NSNull)
            })
        case "codingPath":
            return .native([RuntimeValue]())
        default:
            return nil
        }
    }
    if let container = value as? KeyedContainerStub {
        func keyString(_ value: RuntimeValue?) -> String? {
            guard let value else { return nil }
            if case .enumCase(let enumCase) = value {
                return enumCase.rawValue.stringValue ?? enumCase.name
            }
            if case .implicitMember(let name) = value { return name }
            return value.stringValue
        }
        switch name {
        case "decode", "decodeIfPresent":
            let optional = name == "decodeIfPresent"
            return .hostFunction(HostFunction(name: name) { args, ctx in
                guard let interpreter = ctx as? Interpreter,
                      let typeArgument = args.positional(0),
                      let key = keyString(args.labeled("forKey")) else {
                    throw RuntimeError(message: "decode needs a type and a key")
                }
                let raw = container.object[key] ?? container.object[JSONDecodeBridge.snakeCasedKey(key)]
                guard let jsonValue = raw, !(jsonValue is NSNull) else {
                    if optional { return .nilValue }
                    throw RuntimeError(message: "decode: missing key '\(key)'")
                }
                return try JSONDecodeBridge.decodeContainerValue(
                    jsonValue, typeArgument: typeArgument, interpreter: interpreter,
                    decoder: container.decoder, context: key)
            })
        case "contains":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let key = keyString(args.positional(0)) else { return .native(false) }
                let present = container.object[key] ?? container.object[JSONDecodeBridge.snakeCasedKey(key)]
                return .native(present != nil)
            })
        case "decodeNil":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let key = keyString(args.labeled("forKey")) else { return .native(false) }
                let present = container.object[key] ?? container.object[JSONDecodeBridge.snakeCasedKey(key)]
                return .native(present is NSNull)
            })
        case "codingPath":
            return .native([RuntimeValue]())
        default:
            return nil
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
                do {
                    return try JSONDecodeBridge.decode(
                        typeValue, json: json, interpreter: interpreter, decoder: decoder)
                } catch {
                    if LiveCheckSupport.traceLifecycle { print("   ⚠ decode failed: \(error)") }
                    throw error
                }
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
    if let box = value as? URLComponentsBox {
        switch name {
        case "scheme":
            box.components.scheme = newValue.stringValue
            return true
        case "host":
            box.components.host = newValue.stringValue
            return true
        case "path":
            box.components.path = newValue.stringValue ?? ""
            return true
        case "port":
            box.components.port = newValue.intValue
            return true
        case "query":
            box.components.query = newValue.stringValue
            return true
        case "fragment":
            box.components.fragment = newValue.stringValue
            return true
        case "queryItems":
            if let items = newValue.arrayValue {
                box.components.queryItems = items.compactMap { item in
                    if case .host(let any) = item, let query = any as? URLQueryItem {
                        return query
                    }
                    return nil
                }
            } else if newValue.isNil {
                box.components.queryItems = nil
            }
            return true
        default:
            return false
        }
    }
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
    case "URLComponents":
        return HostFunction(name: name) { args, _ in
            // Failable like the real thing: URLComponents(string:) is nil
            // on garbage; the bare init starts empty.
            if let text = args.labeled("string")?.stringValue {
                return URLComponents(string: text).map { .native(URLComponentsBox($0)) } ?? .nilValue
            }
            if let url = NetworkBridge.url(from: args.labeled("url")) {
                let resolve = args.labeled("resolvingAgainstBaseURL")?.boolValue ?? false
                return URLComponents(url: url, resolvingAgainstBaseURL: resolve)
                    .map { .native(URLComponentsBox($0)) } ?? .nilValue
            }
            return .native(URLComponentsBox())
        }
    case "URLQueryItem":
        return HostFunction(name: name) { args, _ in
            let itemName = args.labeled("name")?.stringValue ?? args.positional(0)?.stringValue ?? ""
            let itemValue = args.labeled("value") ?? args.positional(1)
            return .native(URLQueryItem(name: itemName, value: itemValue?.stringValue))
        }
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
        // A declared `init(from: Decoder)` runs against a Decoder stub —
        // real Codable semantics (HTMLString decodes from a plain string
        // via singleValueContainer; Account fills cachedDisplayName itself
        // through a keyed container). Object-shaped types FALL BACK to the
        // structural decode when the custom init trips an unsupported
        // container feature, keeping the old divergence as the safety net.
        if hasDecoderInit(symbol) {
            let stub = CallArguments(arguments: [
                .init(label: "from", value: .native(DecoderStub(json: json, decoder: decoder)))
            ])
            do {
                return try interpreter.instantiateForBridge(symbol, arguments: stub)
            } catch let custom {
                guard json is [String: Any] else { throw custom }
                do {
                    return try structuralDecode(
                        of: symbol, json: json, interpreter: interpreter, decoder: decoder)
                } catch {
                    throw custom // the custom init's error is the honest one
                }
            }
        }
        return try structuralDecode(of: symbol, json: json, interpreter: interpreter, decoder: decoder)
    }

    private static func structuralDecode(
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
                context: "\(symbol.name).\(property.name)", owner: symbol)
            arguments.append(.init(label: property.name, value: decoded))
        }
        return try interpreter.instantiateForBridge(symbol, arguments: CallArguments(arguments: arguments))
    }

    private static func decodeField(
        _ json: Any, annotation: String?, interpreter: Interpreter, decoder: JSONDecoderBox,
        context: String, owner: StructSymbol? = nil
    ) throws -> RuntimeValue {
        var typeName = annotation ?? ""
        if typeName.hasSuffix("?") { typeName = String(typeName.dropLast()) }

        if typeName.hasPrefix("[") && typeName.hasSuffix("]") && !typeName.contains(":") {
            guard let items = json as? [Any] else {
                throw RuntimeError(message: "decode(\(context)): expected array")
            }
            let element = String(typeName.dropFirst().dropLast())
            return .native(try items.map {
                try decodeField(
                    $0, annotation: element, interpreter: interpreter, decoder: decoder,
                    context: context, owner: owner)
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
            guard let typeValue = interpreter.typeValue(named: typeName, within: owner) else {
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

    /// `init(from decoder: Decoder)` — exactly one parameter labeled `from`
    /// whose type ends in Decoder.
    static func hasDecoderInit(_ symbol: StructSymbol) -> Bool {
        symbol.initializers.contains { decl in
            let params = decl.signature.parameterClause.parameters
            guard params.count == 1, let only = params.first else { return false }
            return only.firstName.text == "from"
                && only.type.trimmedDescription.hasSuffix("Decoder")
        }
    }

    /// The annotation string a container's TYPE argument denotes:
    /// `String.self` arrives as the String builtin (hostFunction),
    /// `[URL].self` as an array literal, interpreted types as .type/.enumType.
    static func annotationName(from typeValue: RuntimeValue) -> String? {
        if let array = typeValue.arrayValue, array.count == 1,
           let inner = annotationName(from: array[0]) {
            return "[" + inner + "]"
        }
        switch typeValue {
        case .type(let symbol): return symbol.name
        case .enumType(let symbol): return symbol.name
        case .hostFunction(let fn): return fn.name
        case .host(let any):
            if let marker = any as? HostTypeMarker { return marker.name }
            return nil
        default:
            return nil
        }
    }

    /// Container decode shared by single-value and keyed stubs.
    static func decodeContainerValue(
        _ json: Any, typeArgument: RuntimeValue, interpreter: Interpreter,
        decoder: JSONDecoderBox, context: String
    ) throws -> RuntimeValue {
        guard let annotation = annotationName(from: typeArgument) else {
            throw RuntimeError(message: "decode(\(context)): unsupported type argument")
        }
        return try decodeField(
            json, annotation: annotation, interpreter: interpreter, decoder: decoder,
            context: context)
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

    static func snakeCasedKey(_ name: String) -> String { snakeCased(name) }

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
