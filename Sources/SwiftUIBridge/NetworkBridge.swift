#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
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

    /// Replay-mode request log (`/path?query hit|miss`) — the LiveCheck
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
#if canImport(AppKit)
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.55, green: 0.63, blue: 0.75, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
#else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format)
        return renderer.image { context in
            UIColor(red: 0.55, green: 0.63, blue: 0.75, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
#endif
    }()

    static func respond(to url: URL) throws -> (Data, HTTPURLResponse) {
        switch policy {
        case .absorbed:
            throw RuntimeError(message: "network is absorbed in this mode (URLSession)")
        case .replay(let directory):
            defer {
                if requestLog.count < 40 {
                    let hit = isImageRequest(url) || fixtureData(forPath: url.path, in: directory) != nil
                    let resource = url.query.map { "\(url.path)?\($0)" } ?? url.path
                    requestLog.append("\(resource) \(hit ? "hit" : "MISS")")
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
            let resource = url.query.map { "\(url.path)?\($0)" } ?? url.path
            func recordLiveRequest(_ outcome: String) {
                if requestLog.count < 40 {
                    requestLog.append("\(resource) \(outcome)")
                }
            }
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
            case .success(let pair):
                recordLiveRequest("HTTP \(pair.1.statusCode)")
                return pair
            case .failure(let error):
                recordLiveRequest("ERROR")
                throw RuntimeError(message: "URLSession: \(error.localizedDescription)")
            case nil:
                recordLiveRequest("TIMEOUT")
                throw RuntimeError(message: "URLSession: request timed out")
            }
        }
    }

    static func url(from value: RuntimeValue?) -> URL? {
        guard let value else { return nil }
        if case .host(let any) = value {
            if let url = any as? URL { return url }
            if let box = any as? URLRequestBox { return box.request.url }
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

/// A REAL URLRequest behind member reads/writes — the parity harness
/// showed the old absorbing bag shadowing ~12 native members. Unknowable
/// URLs still fall back to the bag at the constructor.
public final class URLRequestBox {
    var request: URLRequest
    /// Ecosystem EXTENSION properties (Alamofire's `request.headers`)
    /// memoize here — writes round-trip, replay semantics unaffected.
    var config: [String: RuntimeValue] = [:]

    init(request: URLRequest) {
        self.request = request
    }
}

extension URLRequestBox: GeneratedMemberCarrier, HostValueSemantic,
    CustomStringConvertible {
    var generatedMemberValue: Any { request }
    func writeGeneratedMemberValue(_ value: Any) -> Bool {
        guard let value = value as? URLRequest else { return false }
        request = value
        return true
    }
    func replacingGeneratedMemberValue(_ value: Any) -> Any? {
        guard let value = value as? URLRequest else { return nil }
        let copy = URLRequestBox(request: value)
        copy.config = config
        return copy
    }
    public func copiedHostValue() -> Any {
        let copy = URLRequestBox(request: request)
        copy.config = config
        return copy
    }
    public var description: String { String(describing: request) }
}

/// Combine's mutable-value subject (`CurrentValueSubject`, and via app
/// typealiases like clean-architecture's `Store`): a real value cell —
/// reads/writes/send round-trip; interpreted extension subscripts and
/// methods dispatch on it through hostExtensionSymbols.
public final class CurrentValueSubjectBox {
    public var value: RuntimeValue

    init(_ value: RuntimeValue) {
        self.value = value
    }
}

/// `URLSession.shared` and friends.
public final class URLSessionBox {
    public init() {}
}

/// Combine's fire-only subject: subscribers registered by `sink` receive
/// `send(_:)` values inline (synchronous delivery, the replay doctrine).
public final class PassthroughSubjectBox: InertCallable {
    var subscribers: [(id: UUID, receive: ClosureValue)] = []
}

/// The cancellation handle Combine APIs return: `cancel()` runs the
/// deregistration exactly once. User `extension Cancellable` members
/// (clean-architecture's `store(in: CancelBag)`) resolve on it through
/// hostProtocolCandidates.
public final class AnyCancellableBox: InertCallable {
    private var onCancel: (() -> Void)?

    init(onCancel: (() -> Void)? = nil) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// A VALUE publisher (`Result.publisher`, `Just`) with its operator chain
/// applied EAGERLY — the replay/live doctrine's synchronous delivery for
/// pipelines rooted at concrete values (bundled-resource loads):
/// decode/map/replaceError transform; subscribe/receive/erase pass
/// through; sink delivers immediately.
/// A success-or-failure of interpreted values (Result's shape without
/// the Error constraint).
public enum ValueOutcome {
    case success(RuntimeValue)
    case failure(RuntimeValue)
}

/// `Result(catching:)` / `.success(x)` / `.failure(e)` — success/failure
/// carried for `.publisher`, `.get()`, and pattern access.
public final class ResultBox: CaseShaped {
    let outcome: ValueOutcome

    init(_ outcome: ValueOutcome) {
        self.outcome = outcome
    }

    public var caseName: String {
        if case .success = outcome { return "success" }
        return "failure"
    }

    public var casePayloads: [RuntimeValue] {
        switch outcome {
        case .success(let value): return [value]
        case .failure(let error): return [error]
        }
    }
}

public final class ValuePublisherBox {
    var outcome: ValueOutcome

    init(_ outcome: ValueOutcome) {
        self.outcome = outcome
    }
}

/// `.decode(type: T.self, …)` inside a generic factory whose T only pins
/// DOWNSTREAM (`fetchFile(...).replaceError(with: NewItemResponse(...))`):
/// the data rides along undecoded until a typed fallback names the type —
/// the same inference direction the compiler runs.
final class PendingDecode {
    let data: Data
    let decoder: JSONDecoderBox

    init(data: Data, decoder: JSONDecoderBox) {
        self.data = data
        self.decoder = decoder
    }
}

@MainActor
func valuePublisherMember(_ name: String, on box: ValuePublisherBox) -> RuntimeValue? {
    switch name {
    case "decode":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            guard let interpreter = ctx as? Interpreter else { return .native(box) }
            switch box.outcome {
            case .failure:
                return .native(box)
            case .success(let value):
                guard case .host(let any) = value, let data = any as? Data else {
                    return .native(box)
                }
                guard let typeValue = args.labeled("type") ?? args.positional(0) else {
                    return .native(box)
                }
                let decoder = JSONDecoderBox()
                if case .host(let decoderAny)? = args.labeled("decoder"),
                   let real = decoderAny as? JSONDecoderBox {
                    decoder.convertFromSnakeCase = real.convertFromSnakeCase
                    decoder.dateStrategy = real.dateStrategy
                }
                if !JSONDecodeBridge.isTypeDescriptor(typeValue) {
                    return .native(ValuePublisherBox(.success(
                        .native(PendingDecode(data: data, decoder: decoder)))))
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                    let decoded = try JSONDecodeBridge.decode(
                        typeValue, json: json, interpreter: interpreter, decoder: decoder)
                    return .native(ValuePublisherBox(.success(decoded)))
                } catch {
                    if LiveCheckSupport.traceLifecycle {
                        print("   ⚠ publisher decode failed: \(String(describing: error).prefix(200))")
                    }
                    return .native(ValuePublisherBox(.failure(.native("\(error)"))))
                }
            }
        })
    case "map":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            guard case .success(let value) = box.outcome else { return .native(box) }
            if case .host(let any) = value, any is PendingDecode { return .native(box) }
            if let transform = args.firstUnlabeledClosure {
                return .native(ValuePublisherBox(.success(try ctx.callClosure(transform, arguments: [value]))))
            }
            // `.map(\.data)` — dataTaskPublisher's (data, response) tuple
            // reads through the keypath.
            if case .host(let any)? = args.positional(0), let keyPath = any as? KeyPathStub,
               let component = keyPath.components.first,
               let tuple = value.tupleValue, let read = tuple.value(for: component) {
                return .native(ValuePublisherBox(.success(read)))
            }
            return .native(box)
        })
    case "mapError":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            guard case .failure(let error) = box.outcome,
                  let transform = args.firstUnlabeledClosure else { return .native(box) }
            return .native(ValuePublisherBox(.failure(try ctx.callClosure(transform, arguments: [error]))))
        })
    case "replaceError":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            if case .failure(let error) = box.outcome, let fallback = args.labeled("with") {
                if LiveCheckSupport.traceLifecycle {
                    print("   ⚠ replaceError absorbed: \(error.stringified.prefix(160))")
                }
                return .native(ValuePublisherBox(.success(fallback)))
            }
            // A typed fallback names the deferred decode's T: decode now,
            // and on failure the fallback stands in — exactly the chain's
            // native semantics.
            if case .success(let value) = box.outcome,
               case .host(let any) = value, let pending = any as? PendingDecode,
               let fallback = args.labeled("with"),
               let interpreter = ctx as? Interpreter {
                var typeValue: RuntimeValue?
                if case .instance(let instance) = fallback {
                    typeValue = .type(instance.symbol)
                } else if case .enumCase(let enumCase) = fallback {
                    typeValue = .enumType(enumCase.symbol)
                }
                guard let resolved = typeValue else {
                    if LiveCheckSupport.traceLifecycle {
                        print("   ⚠ deferred decode dropped (untyped fallback \(fallback.stringified.prefix(60)))")
                    }
                    return .native(ValuePublisherBox(.success(fallback)))
                }
                do {
                    let json = try JSONSerialization.jsonObject(
                        with: pending.data, options: [.fragmentsAllowed])
                    let decoded = try JSONDecodeBridge.decode(
                        resolved, json: json, interpreter: interpreter, decoder: pending.decoder)
                    return .native(ValuePublisherBox(.success(decoded)))
                } catch {
                    if LiveCheckSupport.traceLifecycle {
                        print("   ⚠ deferred decode failed: \(String(describing: error).prefix(200))")
                    }
                    return .native(ValuePublisherBox(.success(fallback)))
                }
            }
            return .native(box)
        })
    case "subscribe", "receive", "eraseToAnyPublisher", "removeDuplicates", "print":
        return .hostFunction(HostFunction(name: name) { _, _ in .native(box) })
    case "sink":
        return .hostFunction(HostFunction(name: name) { args, ctx in
            let closures = args.arguments.compactMap { $0.value.closureValue }
            switch box.outcome {
            case .success(let value):
                if case .host(let any) = value, any is PendingDecode {
                    if LiveCheckSupport.traceLifecycle {
                        print("   ⚠ sink dropped an unresolved deferred decode")
                    }
                    return .native(PublishedProjection())
                }
                if let receiveValue = args.closure(labeled: "receiveValue") ?? closures.last {
                    _ = try ctx.callClosure(receiveValue, arguments: [value])
                }
                if let completion = args.closure(labeled: "receiveCompletion") {
                    _ = try? ctx.callClosure(completion, arguments: [.implicitMember("finished")])
                }
            case .failure(let error):
                if let completion = args.closure(labeled: "receiveCompletion") {
                    _ = try? ctx.callClosure(completion, arguments: [.native(ImplicitMemberCall(
                        name: "failure",
                        arguments: CallArguments(arguments: [.init(label: nil, value: error)])))])
                }
            }
            return .native(PublishedProjection())
        })
    default:
        return nil
    }
}

/// The URLProtocol CLIENT handed to interpreted mock protocols: records
/// didReceive/didLoad/didFinish/didFail so data() can answer with the
/// mock's bytes — real URLProtocol semantics distilled.
final class URLProtocolClientRecorder {
    var response: RuntimeValue?
    var data = Data()
    var error: RuntimeValue?
    var finished = false
}

@MainActor
func urlProtocolClientMember(_ name: String, on recorder: URLProtocolClientRecorder) -> RuntimeValue? {
    switch name {
    case "urlProtocol":
        return .hostFunction(HostFunction(name: name) { args, _ in
            if let received = args.labeled("didReceive") {
                recorder.response = received
            }
            if case .host(let any)? = args.labeled("didLoad"), let chunk = any as? Data {
                recorder.data.append(chunk)
            }
            if let failure = args.labeled("didFailWithError") {
                recorder.error = failure
            }
            return .void
        })
    case "urlProtocolDidFinishLoading":
        return .hostFunction(HostFunction(name: name) { _, _ in
            recorder.finished = true
            return .void
        })
    default:
        return nil
    }
}

/// Interpreted URLProtocol mocking (the RequestMocking genre): when a
/// declared URLProtocol subclass's canInit(with:) accepts the request,
/// its startLoading runs against a recording client and the recorded
/// bytes/response/error ARE the session's answer.
@MainActor
func interpretedProtocolResponse(
    for requestValue: RuntimeValue, interpreter: Interpreter
) throws -> (data: Data, response: RuntimeValue)? {
    for symbol in interpreter.urlProtocolSymbols {
        let rawVerdict = try? interpreter.callStatic(
            "canInit", on: symbol, arguments: [requestValue])
        if LiveCheckSupport.traceLifecycle {
            print("   ⚡ \(symbol.name).canInit → \(rawVerdict?.stringified ?? "THREW") request.url=\(NetworkBridge.url(from: requestValue)?.absoluteString ?? "nil")")
        }
        guard let verdict = rawVerdict, verdict.boolValue == true else { continue }
        let instance = Instance(symbol: symbol, lifecycleOwner: interpreter)
        let recorder = URLProtocolClientRecorder()
        instance.properties["request"] = Box(requestValue)
        instance.properties["client"] = Box(.native(recorder))
        _ = try interpreter.callMethod(named: "startLoading", on: instance, arguments: [])
        // Deliveries may ride main-queue hops (asyncAfter loading delays).
        MainQueueDrain.drain()
        if LiveCheckSupport.traceLifecycle {
            print("   ⚡ \(symbol.name) recorder: data=\(recorder.data.count)b response=\(recorder.response != nil) error=\(recorder.error != nil)")
        }
        if let failure = recorder.error {
            throw InterpretedThrow(value: failure)
        }
        let response = recorder.response
            ?? .native(HTTPResponseBox(HTTPURLResponse(
                url: NetworkBridge.url(from: requestValue) ?? URL(string: "https://interpreted.mock")!,
                statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!))
        return (recorder.data, response)
    }
    return nil
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

/// JSONEncoder with STRUCTURAL encode of interpreted values — the decode
/// bridge's inverse (stored properties → JSON keys through CodingKeys/
/// snake_case; dates ISO8601; URLs absolute strings; enums raw values).
public final class JSONEncoderBox {
    var convertToSnakeCase = false

    public init() {}
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
    /// The `keyedBy:` CodingKeys enum — case RAW VALUES name the JSON keys
    /// (`case flag = "alpha2Code"`), so key lookups resolve through it.
    let keySymbol: EnumSymbol?

    init(object: [String: Any], decoder: JSONDecoderBox, keySymbol: EnumSymbol? = nil) {
        self.object = object
        self.decoder = decoder
        self.keySymbol = keySymbol
    }
}

// MARK: - Member dispatch (called from bridgeHostMember)

@MainActor
func networkBridgeMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let marker = value as? HostTypeMarker,
       marker.name == "JSONSerialization", name == "jsonObject" {
        return .hostFunction(HostFunction(name: name) { args, _ in
            guard case .host(let payload)? = args.labeled("with")
                    ?? args.positional(0),
                  let data = payload as? Data else {
                throw RuntimeError(
                    message: "JSONSerialization.jsonObject needs Data")
            }
            do {
                let json = try JSONSerialization.jsonObject(
                    with: data, options: [.fragmentsAllowed])
                return JSONDecodeBridge.runtimeValue(fromJSON: json)
            } catch {
                throw RuntimeError(
                    message: "JSONSerialization.jsonObject: invalid JSON — "
                        + error.localizedDescription)
            }
        })
    }
    if let marker = value as? HostTypeMarker,
       marker.name == "JSONSerialization", name == "data" {
        return .hostFunction(HostFunction(name: name) { args, _ in
            guard let object = args.labeled("withJSONObject")
                    ?? args.positional(0) else {
                throw RuntimeError(
                    message: "JSONSerialization.data needs withJSONObject:")
            }
            let json = try JSONDecodeBridge.encodeToJSON(
                object, snakeCase: false)
            let optionNames = (args.labeled("options")
                ?? args.positional(1))?.stringified ?? ""
            var options: JSONSerialization.WritingOptions = []
            if optionNames.contains("prettyPrinted") {
                options.insert(.prettyPrinted)
            }
            if optionNames.contains("sortedKeys") {
                options.insert(.sortedKeys)
            }
            if optionNames.contains("fragmentsAllowed") {
                options.insert(.fragmentsAllowed)
            }
            let data = try JSONSerialization.data(
                withJSONObject: json, options: options)
            return .native(data)
        })
    }
    if let box = value as? URLRequestBox {
        switch name {
        case "setValue", "addValue":
            return .hostFunction(HostFunction(name: name) { args, _ in
                let headerValue = args.positional(0)?.stringValue
                if let field = args.labeled("forHTTPHeaderField")?.stringValue {
                    if name == "addValue", let headerValue {
                        box.request.addValue(headerValue, forHTTPHeaderField: field)
                    } else {
                        box.request.setValue(headerValue, forHTTPHeaderField: field)
                    }
                }
                return .void
            })
        case "value":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let field = args.labeled("forHTTPHeaderField")?.stringValue else {
                    return .none(wrappedTypeName: "String")
                }
                return .native(box.request.value(forHTTPHeaderField: field))
            })
        default:
            if let stored = box.config[name] { return stored }
            break
        }
    }
    if let marker = value as? HostTypeMarker, marker.name == "URLSession", name == "shared" {
        return .native(URLSessionBox())
    }
    if let subject = value as? CurrentValueSubjectBox {
        switch name {
        case "value":
            // Copy-out: a read is a VALUE, never a live view of the store.
            return Builtins.valueSemanticsCopy(subject.value)
        case "send":
            return .hostFunction(HostFunction(name: name) { args, _ in
                if let newValue = args.positional(0) {
                    subject.value = Builtins.valueSemanticsCopy(newValue)
                }
                return .void
            })
        default:
            return nil
        }
    }
    if let subject = value as? PassthroughSubjectBox {
        switch name {
        case "send":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let payload = args.positional(0) ?? .void
                for entry in subject.subscribers {
                    _ = try ctx.callClosure(entry.receive, arguments: [payload])
                }
                return .void
            })
        case "sink":
            return .hostFunction(HostFunction(name: name) { args, _ in
                let closures = args.arguments.compactMap { $0.value.closureValue }
                guard let receive = args.closure(labeled: "receiveValue") ?? closures.last else {
                    return .native(AnyCancellableBox())
                }
                let id = UUID()
                subject.subscribers.append((id: id, receive: receive))
                return .native(AnyCancellableBox(onCancel: { [weak subject] in
                    subject?.subscribers.removeAll { $0.id == id }
                }))
            })
        case "eraseToAnyPublisher", "receive", "subscribe":
            return .hostFunction(HostFunction(name: name) { _, _ in .native(subject) })
        default:
            return nil
        }
    }
    if let cancellable = value as? AnyCancellableBox, name == "cancel" {
        return .hostFunction(HostFunction(name: name) { _, _ in
            cancellable.cancel()
            return .void
        })
    }
    if value is URLSessionBox {
        switch name {
        case "data":
            // async forms: `let (data, response) = try await session.data(from:/for:)`
            return .hostFunction(HostFunction(name: "data") { args, ctx in
                var requestValue = args.labeled("from") ?? args.labeled("for") ?? args.positional(0)
                // `data(from: url)` wraps bare URLs exactly like download.
                if case .host(let any)? = requestValue, let url = any as? URL {
                    requestValue = .native(URLRequestBox(request: URLRequest(url: url)))
                }
                if let interpreter = ctx as? Interpreter, let requestValue,
                   let mocked = try interpretedProtocolResponse(for: requestValue, interpreter: interpreter) {
                    return .native(TupleValue(labels: [nil, nil], values: [
                        .native(mocked.data), mocked.response,
                    ]))
                }
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
        case "download":
            // `let (localURL, response) = try await session.download(from:)`
            // — real download semantics: the bytes land in a TEMP FILE the
            // caller reads back (`Data(contentsOf: localURL)`). Mocked
            // protocols serve the bytes (and failures) exactly like data().
            return .hostFunction(HostFunction(name: "download") { args, ctx in
                var requestValue = args.labeled("from") ?? args.labeled("for") ?? args.positional(0)
                // `download(from: url)` — the session wraps bare URLs in a
                // URLRequest before URLProtocol.canInit sees them.
                if case .host(let any)? = requestValue, let url = any as? URL {
                    requestValue = .native(URLRequestBox(request: URLRequest(url: url)))
                }
                func tempFile(_ data: Data) -> URL {
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("interpreted-download-\(UUID().uuidString)")
                    try? data.write(to: fileURL)
                    return fileURL
                }
                if let interpreter = ctx as? Interpreter, let requestValue,
                   let mocked = try interpretedProtocolResponse(for: requestValue, interpreter: interpreter) {
                    return .native(TupleValue(labels: [nil, nil], values: [
                        .native(tempFile(mocked.data)), mocked.response,
                    ]))
                }
                guard let url = NetworkBridge.url(from: requestValue) else {
                    throw RuntimeError(message: "URLSession.download needs a URL")
                }
                let (data, response) = try NetworkBridge.respond(to: url)
                return .native(TupleValue(labels: [nil, nil], values: [
                    .native(tempFile(data)), .native(HTTPResponseBox(response)),
                ]))
            })
        case "dataTaskPublisher":
            // Combine networking source — same inline model as the value
            // publishers: the outcome is computed at the call.
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let url = NetworkBridge.url(from: args.labeled("for") ?? args.positional(0)) else {
                    return .native(ValuePublisherBox(.failure(.native("dataTaskPublisher: no URL"))))
                }
                do {
                    let (data, response) = try NetworkBridge.respond(to: url)
                    return .native(ValuePublisherBox(.success(.native(TupleValue(
                        labels: ["data", "response"],
                        values: [.native(data), .native(HTTPResponseBox(response))])))))
                } catch {
                    return .native(ValuePublisherBox(.failure(.native("\(error)"))))
                }
            })
        case "dataTask":
            return .hostFunction(HostFunction(name: "dataTask") { args, _ in
                let url = NetworkBridge.url(from: args.labeled("with") ?? args.positional(0))
                if LiveCheckSupport.traceLifecycle {
                    let raw = args.labeled("with") ?? args.positional(0)
                    print("   ⇢ dataTask(): url=\(url?.absoluteString ?? "nil") from \(raw?.stringified.prefix(120) ?? "nil")")
                }
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
                        .none(wrappedTypeName: "Data"),
                        .none(wrappedTypeName: "URLResponse"),
                        .some(
                            .native(RuntimeError(message: "dataTask has no URL")),
                            wrappedTypeName: "Error"),
                    ])
                    return .void
                }
                do {
                    let (data, response) = try NetworkBridge.respond(to: url)
                    _ = try ctx.callClosure(completion, arguments: [
                        .some(.native(data), wrappedTypeName: "Data"),
                        .some(
                            .native(HTTPResponseBox(response)),
                            wrappedTypeName: "URLResponse"),
                        .none(wrappedTypeName: "Error"),
                    ])
                } catch let error as RuntimeError {
                    _ = try ctx.callClosure(completion, arguments: [
                        .none(wrappedTypeName: "Data"),
                        .none(wrappedTypeName: "URLResponse"),
                        .some(.native(error), wrappedTypeName: "Error"),
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
    if let box = value as? ValuePublisherBox {
        return valuePublisherMember(name, on: box)
    }
    if let result = value as? ResultBox {
        switch name {
        case "publisher":
            return .native(ValuePublisherBox(result.outcome))
        case "get":
            // `try result.get()` — the failure throws the app's OWN error
            // value (clean-architecture's mocks: `responses.removeFirst()
            // .get()`).
            return .hostFunction(HostFunction(name: name) { _, _ in
                switch result.outcome {
                case .success(let value): return value
                case .failure(let error): throw InterpretedThrow(value: error)
                }
            })
        default:
            return nil
        }
    }
    if let recorder = value as? URLProtocolClientRecorder {
        return urlProtocolClientMember(name, on: recorder)
    }
    if let box = value as? URLComponentsBox {
        switch name {
        case "url":
            return .native(box.components.url)
        case "string":
            return .native(box.components.string)
        case "scheme": return .native(box.components.scheme)
        case "host": return .native(box.components.host)
        case "path": return .native(box.components.path)
        case "port": return .native(box.components.port)
        case "query": return .native(box.components.query)
        case "fragment": return .native(box.components.fragment)
        case "queryItems":
            return .optional(box.components.queryItems.map {
                .native($0.map(RuntimeValue.native))
            }, wrappedTypeName: "[URLQueryItem]")
        default:
            return nil
        }
    }
    if let query = value as? URLQueryItem {
        switch name {
        case "name": return .native(query.name)
        case "value": return .native(query.value)
        default: return nil
        }
    }
    if let box = value as? HTTPResponseBox {
        switch name {
        case "statusCode": return .native(box.response.statusCode)
        case "url": return .native(box.response.url)
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
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let object = stub.json as? [String: Any] else {
                    throw RuntimeError(message: "decode: value is not a keyed container")
                }
                var keySymbol: EnumSymbol?
                if case .enumType(let symbol)? = args.labeled("keyedBy") ?? args.positional(0) {
                    keySymbol = symbol
                }
                return .native(KeyedContainerStub(
                    object: object, decoder: stub.decoder, keySymbol: keySymbol))
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
            if case .implicitMember(let name) = value {
                // `.flag` rides unresolved — the keyedBy enum's case raw
                // value IS the JSON key (`case flag = "alpha2Code"`).
                if let declared = container.keySymbol?.cases.first(where: { $0.name == name }) {
                    return declared.rawValue.stringValue ?? name
                }
                return name
            }
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
                    if optional { return .none() }
                    throw RuntimeError(message: "decode: missing key '\(key)'")
                }
                let decoded = try JSONDecodeBridge.decodeContainerValue(
                    jsonValue, typeArgument: typeArgument, interpreter: interpreter,
                    decoder: container.decoder, context: key)
                return optional ? decoded.liftedToOptional() : decoded
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
    if let encoder = value as? JSONEncoderBox {
        switch name {
        case "encode":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let value = args.positional(0) else {
                    throw RuntimeError(message: "encode needs a value")
                }
                let json = try JSONDecodeBridge.encodeToJSON(value, snakeCase: encoder.convertToSnakeCase)
                let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
                return .native(data)
            })
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
    if let encoder = value as? JSONEncoderBox {
        switch name {
        case "keyEncodingStrategy":
            encoder.convertToSnakeCase = "\(newValue.stringified)".contains("convertToSnakeCase")
            return true
        case "outputFormatting", "dateEncodingStrategy":
            return true // accepted; formatting is invisible to decode round-trips
        default:
            return false
        }
    }
    if let subject = value as? CurrentValueSubjectBox, name == "value" {
        // Copy-in, like the ctor and send: native value semantics at the
        // subject boundary.
        subject.value = Builtins.valueSemanticsCopy(newValue)
        return true
    }
    if let box = value as? URLRequestBox {
        switch name {
        case "httpMethod":
            box.request.httpMethod = newValue.stringValue
            return true
        case "url":
            box.request.url = NetworkBridge.url(from: newValue)
            return true
        case "httpBody":
            if case .host(let any) = newValue, let data = any as? Data {
                box.request.httpBody = data
            }
            return true
        case "timeoutInterval":
            if let interval = newValue.doubleValue { box.request.timeoutInterval = interval }
            return true
        case "cachePolicy", "allHTTPHeaderFields", "httpShouldHandleCookies",
             "allowsCellularAccess":
            return true // accepted; invisible to replay semantics
        default:
            // Ecosystem extension properties (Alamofire's `headers`):
            // accept and memoize — a native `var headers: HTTPHeaders`
            // extension write can't be rejected by the compiler.
            box.config[name] = newValue
            return true
        }
    }
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
                return .native(URL(string: text))
            }
            if let value = args.labeled("fileURLWithPath"), let path = value.stringValue {
                return .native(URL(fileURLWithPath: path))
            }
            throw RuntimeError(message: "URL initializer needs string: or fileURLWithPath:")
        }
    case "JSONDecoder":
        return HostFunction(name: name) { _, _ in .native(JSONDecoderBox()) }
    case "Result":
        return HostFunction(name: name) { args, ctx in
            // `Result(catching:)` — run the body; thrown values become the
            // failure. `.publisher` then rides the value pipeline.
            guard let body = args.closure(labeled: "catching") ?? args.firstUnlabeledClosure else {
                throw RuntimeError(message: "Result(catching:) needs a closure")
            }
            do {
                let value = try ctx.callClosure(body, arguments: [])
                return .native(ResultBox(.success(value)))
            } catch let thrown as InterpretedThrow {
                return .native(ResultBox(.failure(thrown.value)))
            } catch let error as RuntimeError where !error.fatal {
                return .native(ResultBox(.failure(.native(error.message))))
            }
        }
    case "JSONEncoder":
        return HostFunction(name: name) { _, _ in .native(JSONEncoderBox()) }
    case "CurrentValueSubject":
        return HostFunction(name: name) { args, _ in
            // Native value semantics at the subject boundary: the seed is
            // COPIED, so the store never aliases the caller's value.
            .native(CurrentValueSubjectBox(Builtins.valueSemanticsCopy(args.positional(0) ?? .void)))
        }
    case "PassthroughSubject":
        return HostFunction(name: name) { _, _ in
            .native(PassthroughSubjectBox())
        }
    case "HTTPURLResponse":
        return HostFunction(name: name) { args, _ in
            guard let url = NetworkBridge.url(from: args.labeled("url")),
                  let code = args.labeled("statusCode")?.intValue else {
                return .none(wrappedTypeName: "HTTPURLResponse")
            }
            var headers: [String: String]?
            if let dict = args.labeled("headerFields")?.dictValue {
                headers = [:]
                for (key, value) in zip(dict.keys, dict.values) {
                    if let k = key.stringValue { headers?[k] = value.stringValue ?? value.stringified }
                }
            }
            guard let response = HTTPURLResponse(
                url: url, statusCode: code,
                httpVersion: args.labeled("httpVersion")?.stringValue, headerFields: headers) else {
                return .none(wrappedTypeName: "HTTPURLResponse")
            }
            return .some(
                .native(HTTPResponseBox(response)),
                wrappedTypeName: "HTTPURLResponse")
        }
    case "URLSession":
        return HostFunction(name: name) { _, _ in
            // URLSession(configuration:) — the box; interpreted URLProtocol
            // subclasses are consulted globally by data(), so the
            // configuration's protocolClasses need no threading.
            .native(URLSessionBox())
        }
    case "URLComponents":
        return HostFunction(name: name) { args, _ in
            // Failable like the real thing: URLComponents(string:) is nil
            // on garbage; the bare init starts empty.
            if let text = args.labeled("string")?.stringValue {
                return .optional(
                    URLComponents(string: text).map { .native(URLComponentsBox($0)) },
                    wrappedTypeName: "URLComponents")
            }
            if let url = NetworkBridge.url(from: args.labeled("url")) {
                let resolve = args.labeled("resolvingAgainstBaseURL")?.boolValue ?? false
                return .optional(
                    URLComponents(url: url, resolvingAgainstBaseURL: resolve)
                        .map { .native(URLComponentsBox($0)) },
                    wrappedTypeName: "URLComponents")
            }
            if LiveCheckSupport.traceLifecycle, let raw = args.labeled("url") {
                print("   ⚠ URLComponents(url:): no URL in \(raw.stringified.prefix(160))")
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
    /// Preserve Foundation's untyped JSON container shape at the interpreter
    /// boundary. Objects use DictValue so both Dictionary and NSDictionary
    /// APIs can dispatch through the same runtime representation.
    static func runtimeValue(fromJSON json: Any) -> RuntimeValue {
        if json is NSNull { return .nilValue }
        if let text = json as? String { return .native(text) }
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .native(number.boolValue)
            }
            let encoding = String(cString: number.objCType)
            if encoding == "f" || encoding == "d" {
                return .native(number.doubleValue)
            }
            return .native(number.intValue)
        }
        if let items = json as? [Any] {
            return .native(items.map(runtimeValue(fromJSON:)))
        }
        if let object = json as? [String: Any] {
            let entries = object.map { key, value in
                (RuntimeValue.native(key), runtimeValue(fromJSON: value))
            }
            return .native(DictValue(
                keys: entries.map(\.0), values: entries.map(\.1)))
        }
        return .native(json)
    }

    /// The shapes `decode(_:json:…)` can act on. Anything else is an
    /// UNRESOLVED type reference (a generic parameter that only pins
    /// downstream) — callers defer instead of failing.
    static func isTypeDescriptor(_ typeValue: RuntimeValue) -> Bool {
        if let array = typeValue.arrayValue, array.count == 1 {
            return isTypeDescriptor(array[0])
        }
        if case .host(let any) = typeValue, any is GenericApplication { return true }
        switch typeValue {
        case .type, .enumType: return true
        default: return false
        }
    }

    static func decode(
        _ typeValue: RuntimeValue, json: Any, interpreter: Interpreter, decoder: JSONDecoderBox
    ) throws -> RuntimeValue {
        // `[Status].self` — an array literal holding the element type.
        if let array = typeValue.arrayValue, array.count == 1 {
            guard let items = json as? [Any] else {
                throw RuntimeError(message: "decode: expected a JSON array")
            }
            return .native(try mapKnownFiniteElements(items, interpreter: interpreter) {
                try decode(array[0], json: $0, interpreter: interpreter,
                           decoder: decoder)
            })
        }
        // A generic APPLICATION (`PaginatedResponse<Movie>`): the head
        // symbol decodes with its generic parameters substituted by the
        // application's arguments (results: [T] → [Movie]).
        if case .host(let any) = typeValue, let application = any as? GenericApplication {
            let text = application.text
            guard let angle = text.firstIndex(of: "<"), text.hasSuffix(">"),
                  case .type(let symbol)? = interpreter.typeValue(named: String(text[..<angle])) else {
                throw RuntimeError(message: "decode: unresolvable generic application '\(text)'")
            }
            let arguments = Interpreter.splitTopLevel(
                String(text[text.index(after: angle)..<text.index(before: text.endIndex)]))
            let substitutions = Dictionary(
                uniqueKeysWithValues: zip(symbol.orderedGenericParameters, arguments))
            return try decodeInstance(
                of: symbol, json: json, interpreter: interpreter, decoder: decoder,
                substitutions: substitutions)
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
        of symbol: StructSymbol, json: Any, interpreter: Interpreter, decoder: JSONDecoderBox,
        substitutions: [String: String] = [:]
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
        return try structuralDecode(
            of: symbol, json: json, interpreter: interpreter, decoder: decoder,
            substitutions: substitutions)
    }

    private static func structuralDecode(
        of symbol: StructSymbol, json: Any, interpreter: Interpreter, decoder: JSONDecoderBox,
        substitutions: [String: String] = [:]
    ) throws -> RuntimeValue {
        guard let object = json as? [String: Any] else {
            throw RuntimeError(message: "decode(\(symbol.name)): expected a JSON object")
        }
        let codingKeys = codingKeyMap(of: symbol)
        var arguments: [CallArguments.Argument] = []
        for property in symbol.storedProperties {
            let jsonValue = lookup(property.name, in: object, codingKeys: codingKeys)
            var annotation = property.typeName
            if let text = annotation, !substitutions.isEmpty {
                annotation = substituteGenerics(text, substitutions)
            }
            if jsonValue == nil || jsonValue is NSNull {
                if annotation?.hasSuffix("?") == true {
                    arguments.append(.init(
                        label: property.name,
                        value: .none(forTypeAnnotation: annotation!)))
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
            return .native(try mapKnownFiniteElements(items, interpreter: interpreter) {
                try decodeField(
                    $0, annotation: element, interpreter: interpreter, decoder: decoder,
                    context: context, owner: owner)
            })
        }
        // `[String: V]` dictionaries (JSON objects; keys are strings by the
        // format). `null` entries decode to nil — the `[String: String?]`
        // shape (clean-architecture's Country.translations).
        if typeName.hasPrefix("["), typeName.hasSuffix("]"),
           let colon = typeName.firstIndex(of: ":") {
            guard let object = json as? [String: Any] else {
                throw RuntimeError(message: "decode(\(context)): expected object")
            }
            let valueAnnotation = String(
                typeName[typeName.index(after: colon)..<typeName.index(before: typeName.endIndex)]
            ).trimmingCharacters(in: .whitespaces)
            var keys: [RuntimeValue] = []
            var values: [RuntimeValue] = []
            for (key, entry) in object {
                keys.append(.native(key))
                if entry is NSNull {
                    values.append(.none(forTypeAnnotation: valueAnnotation))
                } else {
                    values.append(try decodeField(
                        entry, annotation: valueAnnotation, interpreter: interpreter,
                        decoder: decoder, context: context, owner: owner))
                }
            }
            return .native(DictValue(keys: keys, values: values))
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
        case "UUID":
            guard let text = json as? String, let uuid = UUID(uuidString: text) else {
                throw RuntimeError(message: "decode(\(context)): expected UUID string")
            }
            return .native(uuid)
        case "Date":
            if let number = json as? NSNumber, decoder.dateStrategy == nil {
                return .native(Date(
                    timeIntervalSinceReferenceDate: number.doubleValue))
            }
            guard let text = json as? String, let date = parseISO8601(text) else {
                throw RuntimeError(message:
                    "decode(\(context)): expected Date representation")
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

    /// Foundation has already materialized each JSON array, proving finite
    /// cardinality before interpreted custom decoders run. Give every element
    /// the same independently bounded slice as a source `for` iteration; a
    /// non-terminating `init(from:)` still exhausts that element's budget.
    private static func mapKnownFiniteElements<Element>(
        _ elements: [Element],
        interpreter: Interpreter,
        transform: (Element) throws -> RuntimeValue
    ) throws -> [RuntimeValue] {
        try elements.map { element in
            try interpreter.withKnownFiniteHostIteration {
                try transform(element)
            }
        }
    }

    /// STRUCTURAL encode — the decode direction reversed. CodingKeys raw
    /// values name the JSON keys, then snake_case per strategy; nil
    /// optionals are omitted (encodeIfPresent semantics).
    static func encodeToJSON(_ value: RuntimeValue, snakeCase: Bool) throws -> Any {
        switch value {
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .string(let string): return string
        case .array(let array):
            return try array.map { try encodeToJSON($0, snakeCase: snakeCase) }
        case .set(let set):
            return try set.elements.map {
                try encodeToJSON($0, snakeCase: snakeCase)
            }
        case .optional(let optional):
            guard let wrapped = optional.wrapped else { return NSNull() }
            return try encodeToJSON(wrapped, snakeCase: snakeCase)
        case .dictionary(let dictionary):
            var out: [String: Any] = [:]
            for (key, entry) in zip(dictionary.keys, dictionary.values) {
                guard let keyText = key.stringValue else { continue }
                out[keyText] = try encodeToJSON(entry, snakeCase: snakeCase)
            }
            return out
        case .tuple(let tuple):
            return try tuple.values.map { try encodeToJSON($0, snakeCase: snakeCase) }
        case .nilValue: return NSNull()
        case .enumCase(let enumCase):
            return enumCase.rawValue.stringValue ?? enumCase.rawValue.intValue ?? enumCase.name
        case .instance(let instance):
            var out: [String: Any] = [:]
            let codingKeys = codingKeyMap(of: instance.symbol)
            let hasExplicitCodingKeys = declaresCodingKeys(instance.symbol)
            // A subclass's CodingKeys may deliberately include storage
            // inherited from its interpreted superclass. The instance owns
            // those boxes even though they are not in the child symbol's
            // direct stored-property list.
            let propertyNames = hasExplicitCodingKeys
                ? Array(codingKeys.keys)
                : instance.symbol.storedProperties.map(\.name)
            for propertyName in propertyNames {
                guard let box = instance.box(for: propertyName) else { continue }
                if box.value.isNil { continue }
                var key = codingKeys[propertyName] ?? propertyName
                if codingKeys[propertyName] == nil, snakeCase { key = snakeCased(key) }
                do {
                    out[key] = try encodeToJSON(box.value, snakeCase: snakeCase)
                } catch let error as RuntimeError {
                    throw RuntimeError(
                        message: "encode(\(instance.symbol.name).\(propertyName)): "
                            + error.message)
                }
            }
            return out
        case .host(let any):
            if let s = any as? String { return s }
            if let data = any as? Data { return String(decoding: data, as: UTF8.self) }
            if let date = any as? Date {
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date)
            }
            if let url = any as? URL { return url.absoluteString }
            if let uuid = any as? UUID { return uuid.uuidString }
            if let array = any as? [RuntimeValue] {
                return try array.map { try encodeToJSON($0, snakeCase: snakeCase) }
            }
            if let dict = any as? DictValue {
                var out: [String: Any] = [:]
                for (key, entry) in zip(dict.keys, dict.values) {
                    guard let keyText = key.stringValue else { continue }
                    out[keyText] = try encodeToJSON(entry, snakeCase: snakeCase)
                }
                return out
            }
            if let tuple = any as? TupleValue {
                return try tuple.values.map { try encodeToJSON($0, snakeCase: snakeCase) }
            }
            throw RuntimeError(message: "encode: unsupported value \(type(of: any))")
        default:
            throw RuntimeError(message: "encode: unsupported value \(value.stringified)")
        }
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
        // `[String: String?].self` — a dictionary TYPE literal: one entry
        // whose key/value are themselves type values.
        if let dict = typeValue.dictValue,
           dict.keys.count == 1,
           let key = annotationName(from: dict.keys[0]),
           let value = annotationName(from: dict.values[0]) {
            return "[" + key + ": " + value + "]"
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

    /// Whole-identifier substitution: `[T]` with T→Movie is `[Movie]`;
    /// `PaginatedT` stays untouched.
    static func substituteGenerics(_ text: String, _ substitutions: [String: String]) -> String {
        var out = ""
        var identifier = ""
        func flush() {
            out += substitutions[identifier] ?? identifier
            identifier = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" {
                identifier.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }

    private static func codingKeyMap(of symbol: StructSymbol) -> [String: String] {
        guard case .enumType(let keys)? = symbol.nestedTypes["CodingKeys"] else { return [:] }
        var map: [String: String] = [:]
        for enumCase in keys.cases {
            map[enumCase.name] = enumCase.rawValue.stringValue ?? enumCase.name
        }
        return map
    }

    private static func declaresCodingKeys(_ symbol: StructSymbol) -> Bool {
        guard case .enumType? = symbol.nestedTypes["CodingKeys"] else {
            return false
        }
        return true
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


extension URLComponentsBox: GeneratedMemberCarrier, HostValueSemantic,
    CustomStringConvertible {
    var generatedMemberValue: Any { components }
    func writeGeneratedMemberValue(_ value: Any) -> Bool {
        guard let value = value as? URLComponents else { return false }
        components = value
        return true
    }
    func replacingGeneratedMemberValue(_ value: Any) -> Any? {
        (value as? URLComponents).map(URLComponentsBox.init)
    }
    public func copiedHostValue() -> Any {
        URLComponentsBox(components)
    }
    public var description: String { String(describing: components) }
}
