#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Combine
import Foundation
import SwiftUI
import SwiftInterpreter
#if canImport(SwiftData)
import SwiftData
#endif

/// Entitlement-gated service types that fail closed (documented
/// allowlist — see the quarantine comment at the dispatch site).
let environmentalServiceTypes: Set<String> = ["WeatherService"]

/// Mutable host objects interpreted code constructs and configures —
/// backed by the real Foundation types. Shared by both registries.
final class DateFormatterBox: GeneratedReferenceBackedBox {
    let formatter = DateFormatter()
    let generatedReferenceTypeName = "DateFormatter"
    var generatedReferencePropertyValues: [String: RuntimeValue] = [:]

    var generatedReferenceObject: NSObject { formatter }
}

private let dateFormatterConstructorGateway: HostFunction = {
    do {
        return try HostFunction(declaration: "init DateFormatter()") {
            _, _ in .native(DateFormatterBox())
        }
    } catch {
        preconditionFailure("invalid DateFormatter host declaration: \(error)")
    }
}()

private let modelContextSaveGateway: HostFunction = {
    do {
        return try HostFunction(
            declaration: "func ModelContext.save() throws"
        ) { _, _ in .void }
    } catch {
        preconditionFailure("invalid ModelContext.save declaration: \(error)")
    }
}()

/// `Timer.publish(every:on:in:).autoconnect()` — backed by the real Combine
/// publisher; `.onReceive` drives interpreted closures from actual ticks.
final class TimerPublisherBox {
    let interval: Double
    lazy var publisher = Timer.publish(every: interval, on: .main, in: .common).autoconnect()

    init(interval: Double) {
        self.interval = interval
    }
}

/// `NumberFormatter` — backed by the real Foundation formatter; numberStyle
/// and fraction-digit writes configure it, string(from:) really formats.
final class NumberFormatterBox: GeneratedReferenceBackedBox {
    let formatter = NumberFormatter()
    let generatedReferenceTypeName = "NumberFormatter"
    var generatedReferencePropertyValues: [String: RuntimeValue] = [:]

    var generatedReferenceObject: NSObject { formatter }
}

/// The interpreted face of `ProcessInfo.processInfo`. `extraEnvironment`
/// lets the TEST HARNESS present the native test environment
/// (XCTestConfigurationFilePath is set under real XCTest runs, and apps
/// branch on it — clean-architecture's `isRunningTests`).
public final class ProcessInfoBox {
    public static var extraEnvironment: [String: String] = [:]
}

/// UIKit's image face on macOS: a REAL bitmap (rendered via NSImage) so
/// `pngData()`/`size` round-trip — the UIColor.image(_:) test-helper genre.
public final class UIImageBox {
    let size: CGSize
    let pngData: Data?

    init(size: CGSize, pngData: Data?) {
        self.size = size
        self.pngData = pngData
    }

    /// A solid-fill bitmap of the requested size (the renderer's honest
    /// headless output — fills happen, pixels exist, color is uniform).
    /// Rendered at EXACT pixel dimensions (scale 1, the renderer-format
    /// default in test helpers) — lockFocus would rasterize at the
    /// screen's backing scale and double the decoded size.
    static func solid(size: CGSize) -> UIImageBox {
        func rasterDimension(_ value: CGFloat) -> CGFloat {
            guard value.isFinite, value > 0,
                  Int(exactly: value.rounded(.towardZero)) != nil
            else {
                return 1
            }
            return value
        }
        let rasterSize = CGSize(
            width: rasterDimension(size.width),
            height: rasterDimension(size.height))
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let width = max(1, Int(rasterSize.width))
        let height = max(1, Int(rasterSize.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return UIImageBox(size: rasterSize, pngData: nil)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])
        return UIImageBox(size: rasterSize, pngData: png)
#else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: rasterSize, format: format)
        let data = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: rasterSize))
        }.pngData()
        return UIImageBox(size: rasterSize, pngData: data)
#endif
    }

    static func decoding(_ data: Data) -> UIImageBox? {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let image = NSImage(data: data) else { return nil }
        // Pixel size, not point size — UIImage(data:) semantics (scale 1).
        let pixelSize = NSBitmapImageRep(data: data).map {
            CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
        } ?? image.size
        return UIImageBox(size: pixelSize, pngData: data)
#else
        guard let image = UIImage(data: data) else { return nil }
        let pixelSize = image.cgImage.map {
            CGSize(width: $0.width, height: $0.height)
        } ?? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return UIImageBox(size: pixelSize, pngData: data)
#endif
    }
}

/// A decoded target bitmap is still renderable when UIKit source is
/// interpreted on an AppKit host. The generated constructor adapter asks for
/// this capability rather than branching on Image, UIImage, a member name, or
/// a call-site spelling.
extension UIImageBox: GeneratedPlatformSemanticCarrier {
    var generatedPlatformFramework: String { "UIKit" }
    var generatedPlatformTypeName: String { "UIImage" }

    var generatedPlatformNativePayload: Any? {
#if canImport(UIKit)
        pngData.flatMap(UIImage.init(data:)) ?? UIImage()
#else
        nil
#endif
    }

    var generatedPlatformViewValue: Any? {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let native = pngData.flatMap(NSImage.init(data:))
            ?? NSImage(size: size)
        return ImageBox(Image(nsImage: native))
#elseif canImport(UIKit)
        let native = pngData.flatMap(UIImage.init(data:)) ?? UIImage()
        return ImageBox(Image(uiImage: native))
#else
        return nil
#endif
    }
}

/// A decoded target bitmap owns real pixels even when its UIKit nominal is
/// unavailable on the AppKit host. Expose that raster by result TYPE; the
/// generated property table decides which unique SDK property consumes it.
extension UIImageBox: GeneratedPlatformTypedPropertyCarrier {
    var generatedPlatformTypedPropertyValues:
        [GeneratedPlatformTypedPropertyValue]
    {
        let image: CGImage?
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        image = pngData.flatMap {
            NSBitmapImageRep(data: $0)?.cgImage
        }
#else
        image = pngData.flatMap {
            UIImage(data: $0)?.cgImage
        }
#endif
        return [.optional(
            image,
            as: CGImage.self,
            framework: generatedPlatformFramework)]
    }
}

/// `UIGraphicsImageRenderer(size:format:)` — carries the size; `image { }`
/// runs the drawing closure (fills absorb) and returns the solid bitmap.
public final class GraphicsRendererBox {
    let size: CGSize

    init(size: CGSize) {
        self.size = size
    }
}

func interpretedTaskConstructor(named name: String) -> HostFunction? {
    // Task itself is a SwiftInterpreter core builtin. MainActor remains a
    // host execution-context stand-in until actor isolation is modeled.
    guard name == "MainActor" else { return nil }
    return HostFunction(name: name) { args, context in
        if let body = args.firstUnlabeledClosure ?? args.closure(labeled: "operation") {
            _ = try context.callBackgroundClosure(body, arguments: [])
        }
        return .native(UIKitStub(roles: ["MainActor"]))
    }
}

/// Constructors for host object types, consulted by both registries before
/// their own tables.
/// Real bundle identity (URL/path — path-climbing idioms terminate) with
/// ABSORBING resource lookups (nothing is bundled headlessly).
/// Project-tree resource resolution for merged programs: the COMPILED app
/// ships each target's Resources, so the live probe serves the same files
/// straight from the checkout. Roots are set per LiveCheck scenario and
/// empty everywhere else — M0 keeps the absorbed-resources doctrine.
public enum BundleResources {
    public static var roots: [String] = [] {
        didSet { index = nil }
    }
    private static var index: [String: String]?

    static func url(forResource name: String, extension ext: String?) -> URL? {
        guard !roots.isEmpty else { return nil }
        let fileName = (ext?.isEmpty == false) ? "\(name).\(ext!)" : name
        if index == nil { buildIndex() }
        return index?[fileName].map { URL(fileURLWithPath: $0) }
    }

    private static func buildIndex() {
        var built: [String: String] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            for case let path as String in enumerator {
                guard !path.contains(".git"), !path.contains(".build"),
                      !path.contains("Tests/") else { continue }
                let name = (path as NSString).lastPathComponent
                let full = root + "/" + path
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                // Resources-dir files beat stray same-named files.
                if built[name] == nil
                    || (path.contains("/Resources/") && !built[name]!.contains("/Resources/")) {
                    built[name] = full
                }
            }
        }
        index = built
    }
}

final class BundleBox {
    private struct ProjectResourceScope: Sendable {
        let root: String?
    }

    struct DataAssetResource {
        let name: String
        let data: Data
        let typeIdentifier: String
    }

    private struct DataAssetContents: Decodable {
        struct Entry: Decodable {
            let filename: String?
            let idiom: String?
            let typeIdentifier: String?

            enum CodingKeys: String, CodingKey {
                case filename, idiom
                case typeIdentifier = "universal-type-identifier"
            }
        }

        let data: [Entry]
    }

    private struct ResourceRequest {
        let name: String
        let extensionName: String?
        let returnsPath: Bool

        init?(_ arguments: CallArguments) {
            guard arguments.arguments.contains(where: { $0.label == "forResource" }),
                  let name = arguments.labeled("forResource")?.stringValue else {
                return nil
            }
            self.name = name
            let extensionLabel = arguments.arguments.contains(where: { $0.label == "ofType" })
                ? "ofType" : "withExtension"
            extensionName = arguments.labeled(extensionLabel)?.stringValue
            returnsPath = extensionLabel == "ofType"
        }

        func value(for url: URL) -> RuntimeValue {
            returnsPath ? .native(url.path) : .native(url)
        }
    }

    /// The MERGE's project root: bundled resources (SPM Resources/ dirs,
    /// asset JSON) resolve against the repo's committed files — the same
    /// bytes the compiled app ships in Bundle.module.
    static var projectResourceRoot: String?

    @TaskLocal private static var projectResourceScope: ProjectResourceScope?

    /// Pin a verifier run to the project root selected by its caller. Source
    /// Tasks inherit the scope, so another parallel test can update the
    /// process-wide compatibility default without redirecting this lookup.
    static func withProjectResourceRoot<T>(
        _ root: String?,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await $projectResourceScope.withValue(
            ProjectResourceScope(root: root), operation: operation)
    }

    private static var activeProjectResourceRoot: String? {
        projectResourceScope?.root ?? projectResourceRoot
    }

    /// Find a resource file by name under the project root (bounded walk,
    /// build dirs skipped).
    static func projectResource(
        named name: String,
        extension ext: String?,
        projectResourceRoot: String? = activeProjectResourceRoot
    ) -> URL? {
        guard let root = projectResourceRoot else { return nil }
        var target = name
        if let ext, !ext.isEmpty, !target.hasSuffix(".\(ext)") { target += ".\(ext)" }
        target = target.replacingOccurrences(of: "\\", with: "/")
        let skip: Set<String> = [".git", ".build", "DerivedData", "__MACOSX", "Tests"]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let path as String in walker {
            if skip.contains(where: { path.contains($0) }) { continue }
            let file = (path as NSString).lastPathComponent
            if path == target || path.hasSuffix("/\(target)")
                || file == target
                || (ext == nil && (file as NSString).deletingPathExtension == target) {
                return URL(fileURLWithPath: root + "/" + path)
            }
        }
        return nil
    }

    static func projectResource(
        for arguments: CallArguments,
        projectResourceRoot: String? = activeProjectResourceRoot,
        fallback: (String, String?) -> URL?
    ) -> RuntimeValue? {
        guard let request = ResourceRequest(arguments) else { return nil }
        let url = projectResource(
            named: request.name,
            extension: request.extensionName,
            projectResourceRoot: projectResourceRoot)
            ?? fallback(request.name, request.extensionName)
        return url.map(request.value(for:))
    }

    /// Resolve a data entry from an uncompiled asset catalog by its catalog
    /// metadata. The runtime adapter keys on the Objective-C interface shape;
    /// this lookup keys on `.dataset` structure, never a type or asset name.
    static func projectDataAsset(
        named name: String,
        projectResourceRoot: String? = activeProjectResourceRoot
    ) -> DataAssetResource? {
        guard let root = projectResourceRoot else { return nil }
        let datasetName = "\(name.split(separator: "/").last.map(String.init) ?? name).dataset"
        let skip: Set<String> = [".git", ".build", "DerivedData", "__MACOSX", "Tests"]
        guard let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let path as String in walker {
            let components = path.split(separator: "/").map(String.init)
            guard !components.contains(where: skip.contains),
                  components.last == datasetName else { continue }
            let directory = URL(fileURLWithPath: root).appendingPathComponent(path)
            let metadataURL = directory.appendingPathComponent("Contents.json")
            guard let metadataData = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(
                    DataAssetContents.self, from: metadataData) else { continue }
            let entry = metadata.data.first(where: { $0.idiom == "universal" })
                ?? metadata.data.first
            guard let entry, let filename = entry.filename,
                  let data = try? Data(
                    contentsOf: directory.appendingPathComponent(filename)) else { continue }
            return DataAssetResource(
                name: name,
                data: data,
                typeIdentifier: entry.typeIdentifier ?? "public.data")
        }
        return nil
    }

    let bundle: Foundation.Bundle
    let fileManager: FileManagerBox

    init(bundle: Foundation.Bundle, fileManager: FileManagerBox) {
        self.bundle = bundle
        self.fileManager = fileManager
    }
}

func interfaceValidatedHostObjectConstructor(
    named name: String,
    fileManager: FileManagerBox
) -> HostFunction? {
    guard let implementation = bridgeHostObjectConstructor(
        named: name, fileManager: fileManager
    ) else { return nil }
    return GeneratedDispatch.validatingThrowingConstructor(
        named: name, implementation: implementation)
}

/// The storage a framework-supplied property wrapper hands its declaration.
/// Shared by both registries: which wrappers these are, and what they hand
/// back, is decided entirely by the generated interface sweep.
@MainActor
func generatedFrameworkSuppliedWrapperValue(
    forAttributes attributes: [String]
) -> RuntimeValue? {
    GeneratedPropertyWrappers.suppliedValue(forAttributes: attributes)
        .map { RuntimeValue.native($0) }
}

func bridgeHostObjectConstructor(
    named name: String,
    fileManager: FileManagerBox
) -> HostFunction? {
    if let network = networkHostObjectConstructor(named: name) { return network }
    switch name {
    case "DispatchQueue":
        // Dispatch is a Clang overlay rather than part of Foundation's
        // swiftinterface sweep. Keep the reusable callback semantics in the
        // shared queue carrier used by both `.main` and labeled queues.
        return HostFunction(name: name) { args, _ in
            guard args.labeled("label")?.stringValue != nil else {
                throw RuntimeError(message:
                    "DispatchQueue(label:) needs a String label")
            }
            return .native(DispatchQueueStub())
        }
    case "UIGraphicsImageRenderer":
        return HostFunction(name: name) { args, _ in
            var size = CGSize(width: 1, height: 1)
            if case .host(let any)? = args.labeled("size"), let real = any as? CGSize {
                size = real
            }
            return .native(GraphicsRendererBox(size: size))
        }
    case "UIImage", "NSImage":
        return HostFunction(name: name) { args, _ in
            // `UIImage(data:)` decodes for REAL (failable, like native).
            if case .host(let any)? = args.labeled("data"), let data = any as? Data {
                return .optional(
                    UIImageBox.decoding(data).map { .native($0) },
                    wrappedTypeName: name)
            }
            // named:/systemName:/other forms keep the absorbing-bag doctrine.
            let stub = UIKitStub(roles: [name])
            for argument in args.arguments {
                if let label = argument.label { stub.config[label] = argument.value }
            }
            return .native(stub)
        }
    case "URLRequest":
        // REAL when the url resolves (member reads ride the generated
        // table via the carrier; writes go through networkHostSetMember);
        // unknowable urls keep the old absorbing bag so broken chains
        // stay absorbed instead of crashing.
        return HostFunction(name: name) { args, _ in
            let urlValue = args.labeled("url") ?? args.positional(0)
            if let url = NetworkBridge.url(from: urlValue) {
                return .native(URLRequestBox(request: URLRequest(url: url)))
            }
            let bag = UIKitStub()
            if let urlValue { bag.config["url"] = urlValue }
            return .native(bag)
        }
    case "DateInterval":
        return HostFunction(name: name) { args, _ in
            var start = Date(timeIntervalSince1970: 0)
            if case .host(let any)? = args.labeled("start"), let date = any as? Date {
                start = date
            }
            if case .host(let any)? = args.labeled("end"), let end = any as? Date {
                return .native(DateInterval(start: start, end: end))
            }
            if let duration = args.labeled("duration")?.doubleValue {
                return .native(DateInterval(start: start, duration: duration))
            }
            return .native(DateInterval())
        }
    case "ModelContainer":
        return HostFunction(name: name) { _, _ in .native(ModelContainerBox()) }
    case "#Predicate":
        // `#Predicate<DBModel.Country> { $0.alpha3Code == code }` — the
        // generic names the model type; the closure filters for real.
        return HostFunction(name: name) { args, _ in
            .native(PredicateBox(
                typeName: args.labeled("__genericArguments")?.stringValue,
                closure: args.arguments.first(where: { $0.value.closureValue != nil })?.value.closureValue))
        }
    case "FetchDescriptor", "SectionedFetchDescriptor":
        return HostFunction(name: name) { args, _ in
            var typeName = args.labeled("__genericArguments")?.stringValue
            var predicate: PredicateBox?
            if case .host(let any)? = args.labeled("predicate"), let box = any as? PredicateBox {
                predicate = box
                if typeName == nil { typeName = box.typeName }
            }
            if let comma = typeName?.firstIndex(of: ",") {
                typeName = typeName.map { String($0[..<comma]) }
            }
            return .native(FetchDescriptorBox(typeName: typeName, predicate: predicate))
        }
    case "NSLock", "NSRecursiveLock", "NSCondition":
        // Single-threaded probes hold every lock trivially: withLock RUNS
        // its body and returns the result (clean-architecture's mock store
        // wraps all access in lock.withLock { … }).
        return HostFunction(name: name) { _, _ in .native(LockBox()) }
    case "NSRegularExpression":
        return HostFunction(name: name) { args, _ in
            // REAL regex — the host-hardware doctrine: patterns compile and
            // match genuinely (version parsers, validators).
            guard let pattern = (args.labeled("pattern") ?? args.positional(0))?.stringValue else {
                throw RuntimeError(message: "NSRegularExpression(pattern:) needs a String")
            }
            let regex = try NSRegularExpression(pattern: pattern)
            return .native(RegexBox(regex: regex))
        }
    case "NSRange":
        return HostFunction(name: name) { args, _ in
            if let location = args.labeled("location")?.intValue,
               let length = args.labeled("length")?.intValue {
                return .native(NSRange(location: location, length: length))
            }
            // NSRange(text.startIndex..., in: text) — the whole string.
            if let text = args.labeled("in")?.stringValue {
                return .native(NSRange(text.startIndex..., in: text))
            }
            return .native(NSRange(location: 0, length: 0))
        }
    case "NSDictionary":
        return HostFunction(name: name) { args, _ in
            // Real plist loads from real URLs (the seeded sandbox
            // Info.plist); unknowable URLs honestly fail (nil).
            if case .host(let any)? = args.labeled("contentsOf"), let url = any as? URL,
               let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                var out = DictValue()
                for (key, value) in dict {
                    if let text = value as? String { try? out.update(.native(key), to: .native(text)) }
                    else if let number = value as? Int { try? out.update(.native(key), to: .native(number)) }
                    else if let number = value as? Double { try? out.update(.native(key), to: .native(number)) }
                    else if let flag = value as? Bool { try? out.update(.native(key), to: .native(flag)) }
                }
                return .some(.native(out), wrappedTypeName: "NSDictionary")
            }
            return .none(wrappedTypeName: "NSDictionary")
        }
    case "NSArray":
        return HostFunction(name: name) { args, _ in
            if case .host(let any)? = args.labeled("contentsOf"), let url = any as? URL,
               let array = NSArray(contentsOf: url) as? [Any] {
                return .some(.native(array.compactMap { item -> RuntimeValue? in
                    if let text = item as? String { return .native(text) }
                    if let number = item as? Int { return .native(number) }
                    return nil
                }), wrappedTypeName: "NSArray")
            }
            return .none(wrappedTypeName: "NSArray")
        }
    case "Bundle":
        return HostFunction(name: name) { args, _ in
            // The host process is real: Bundle(url:)/(path:)/(identifier:)
            // resolve against the actual filesystem; no argument = main.
            if case .host(let any)? = args.labeled("url"), let url = any as? URL {
                return .optional(
                    Foundation.Bundle(url: url).map {
                        .native(BundleBox(bundle: $0, fileManager: fileManager))
                    },
                    wrappedTypeName: "Bundle")
            }
            if let path = args.labeled("path")?.stringValue {
                return .optional(
                    Foundation.Bundle(path: path).map {
                        .native(BundleBox(bundle: $0, fileManager: fileManager))
                    },
                    wrappedTypeName: "Bundle")
            }
            if let identifier = args.labeled("identifier")?.stringValue {
                return .optional(
                    Foundation.Bundle(identifier: identifier).map {
                        .native(BundleBox(bundle: $0, fileManager: fileManager))
                    },
                    wrappedTypeName: "Bundle")
            }
            return .native(BundleBox(bundle: .main, fileManager: fileManager))
        }
    case "DateFormatter":
        return dateFormatterConstructorGateway
    case "NumberFormatter":
        return HostFunction(name: name) { _, _ in .native(NumberFormatterBox()) }
    case "Data":
        return HostFunction(name: name) { args, _ in
            // Real semantics: reading a file that isn't there throws (a
            // fresh sandbox is empty), so `try?` honestly yields nil.
            if let value = args.labeled("contentsOf") {
                if let stored = fileManager.blobStore[value.stringified] {
                    return stored
                }
                if case .host(let any) = value, let url = any as? URL {
                    if let stored = fileManager.blobStore[url.path] {
                        return stored
                    }
                    do { return .native(try Data(contentsOf: url)) } catch {
                        throw RuntimeError(message: "Data(contentsOf:): \(error.localizedDescription)")
                    }
                }
                // Unknowable source (an unbridged Bundle resource URL): the
                // bytes exist on device — the marker flows through.
                if !value.isNil { return value }
                throw RuntimeError(message: "Data(contentsOf:) needs a URL")
            }
            // `Data(otherData)` — copy construction passes through.
            if case .host(let existing)? = args.positional(0), let d = existing as? Data {
                return .native(d)
            }
            // `Data(bytes)` — a real byte buffer from an Int array.
            if let bytes = args.positional(0)?.arrayValue {
                return .native(Data(bytes.compactMap { $0.intValue.map { UInt8(truncatingIfNeeded: $0) } }))
            }
            if let repeating = args.labeled("repeating")?.intValue,
               let count = args.labeled("count")?.intValue {
                return .native(Data(repeating: UInt8(truncatingIfNeeded: repeating), count: Swift.max(0, count)))
            }
            // `Data(bytes: &sysinfo.machine, count: n)` — bag members carry
            // real strings; byte arrays carry ints.
            if let bytesValue = args.labeled("bytes") {
                if case .host(let host) = bytesValue,
                   let memory = host as? HostRawMemory,
                   let count = args.labeled("count")?.intValue {
                    return .native(try memory.readBytes(count: max(0, count)))
                }
                if let text = bytesValue.stringValue {
                    var data = Data(text.utf8)
                    if let count = args.labeled("count")?.intValue, count > data.count {
                        data.append(Data(repeating: 0, count: count - data.count))
                    }
                    return .native(data)
                }
                if let array = bytesValue.arrayValue {
                    return .native(Data(array.compactMap { $0.intValue.map { UInt8(truncatingIfNeeded: $0) } }))
                }
            }
            return .native(Data())
        }
    case "CharacterSet":
        return HostFunction(name: name) { args, _ in
            if let text = args.labeled("charactersIn")?.stringValue {
                return .native(CharacterSet(charactersIn: text))
            }
            return .native(CharacterSet())
        }
    case "IndexSet":
        return HostFunction(name: name) { args, _ in
            if let values = args.positional(0)?.arrayValue {
                return .native(IndexSet(values.compactMap { $0.intValue }))
            }
            if let single = args.labeled("integer")?.intValue {
                return .native(IndexSet(integer: single))
            }
            return .native(IndexSet())
        }
    case "Decimal":
        return HostFunction(name: name) { args, _ in
            // Real Decimal semantics: the string parse is honestly nil on junk.
            if let s = args.labeled("string")?.stringValue {
                return .native(Decimal(string: s))
            }
            if let arg = args.positional(0) {
                if case .int(let i) = arg { return .native(Decimal(i)) }
                if let d = arg.doubleValue { return .native(Decimal(d)) }
            }
            return .native(Decimal.zero)
        }
    case "IndexPath":
        return HostFunction(name: name) { args, _ in
            if let values = args.labeled("indexes")?.arrayValue {
                return .native(IndexPath(indexes: values.compactMap { $0.intValue }))
            }
            // UIKit/AppKit conveniences the corpus uses: (item|row:section:).
            if let section = args.labeled("section")?.intValue {
                let leaf = args.labeled("item")?.intValue ?? args.labeled("row")?.intValue ?? 0
                return .native(IndexPath(indexes: [section, leaf]))
            }
            if let single = args.labeled("index")?.intValue {
                return .native(IndexPath(index: single))
            }
            return .native(IndexPath())
        }
    case "PersonNameComponents":
        return HostFunction(name: name) { args, _ in
            var components = PersonNameComponents()
            if let v = args.labeled("namePrefix")?.stringValue { components.namePrefix = v }
            if let v = args.labeled("givenName")?.stringValue { components.givenName = v }
            if let v = args.labeled("middleName")?.stringValue { components.middleName = v }
            if let v = args.labeled("familyName")?.stringValue { components.familyName = v }
            if let v = args.labeled("nameSuffix")?.stringValue { components.nameSuffix = v }
            if let v = args.labeled("nickname")?.stringValue { components.nickname = v }
            return .native(components)
        }
    case "Locale":
        return HostFunction(name: name) { args, _ in
            guard let identifier = args.labeled("identifier")?.stringValue else {
                return .native(Locale.current)
            }
            return .native(Locale(identifier: identifier))
        }
    case "NSNumber":
        // Our numbers are already boxed RuntimeValues — pass through.
        return HostFunction(name: name) { args, _ in
            args.labeled("value") ?? args.positional(0) ?? .native(0)
        }
    case "State", "StateObject", "ObservedObject", "Published", "Bindable":
        // `self._count = State(initialValue: 5)` /
        // `self._viewModel = StateObject(wrappedValue: ViewModel(…))` —
        // the storage IS the value.
        return HostFunction(name: name) { args, _ in
            args.labeled("initialValue") ?? args.labeled("wrappedValue") ?? args.positional(0) ?? .void
        }
    case "Query", "FetchRequest", "SectionedFetchRequest", "ObservedResults":
        // `_list = Query(descriptor, animation: .snappy)` in custom inits —
        // the storage is fresh-store results: empty (same doctrine as the
        // wrapper flatten).
        return HostFunction(name: name) { _, _ in .native([RuntimeValue]()) }
    case "LocalizedStringKey":
        // The merged model has no string catalogs: a key IS its literal
        // text (the String(localized:) doctrine) — `Text(.init(donut.name))`
        // renders the name instead of absorbing.
        return HostFunction(name: name) { args, _ in
            .native(args.positional(0)?.stringValue ?? "")
        }
    case "ProposedViewSize":
        return HostFunction(name: name) { args, _ in
            if case .host(let any)? = args.positional(0), let size = any as? CGSize {
                return .native(ProposedViewSize(size))
            }
            let width = args.labeled("width")?.doubleValue
            let height = args.labeled("height")?.doubleValue
            return .native(ProposedViewSize(
                width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) }))
        }
    case "CGSize":
        return HostFunction(name: name) { args, _ in
            .native(CGSize(
                width: try Coerce.cgFloat(args.labeled("width") ?? .native(0)),
                height: try Coerce.cgFloat(args.labeled("height") ?? .native(0))
            ))
        }
    case "CGPoint":
        return HostFunction(name: name) { args, _ in
            .native(CGPoint(
                x: try Coerce.cgFloat(args.labeled("x") ?? .native(0)),
                y: try Coerce.cgFloat(args.labeled("y") ?? .native(0))
            ))
        }
    case "CGRect":
        return HostFunction(name: name) { args, _ in
            if case .host(let any)? = args.labeled("origin"), let origin = any as? CGPoint {
                var size = CGSize.zero
                if case .host(let sized)? = args.labeled("size"), let s = sized as? CGSize {
                    size = s
                }
                return .native(CGRect(origin: origin, size: size))
            }
            return .native(CGRect(
                x: try Coerce.cgFloat(args.labeled("x") ?? .native(0)),
                y: try Coerce.cgFloat(args.labeled("y") ?? .native(0)),
                width: try Coerce.cgFloat(args.labeled("width") ?? .native(0)),
                height: try Coerce.cgFloat(args.labeled("height") ?? .native(0))
            ))
        }
    case "ViewSpacing":
        return HostFunction(name: name) { _, _ in .native(ViewSpacing()) }
    case "UnitPoint":
        return HostFunction(name: name) { args, _ in
            .native(UnitPoint(
                x: try Coerce.cgFloat(args.labeled("x") ?? .native(0)),
                y: try Coerce.cgFloat(args.labeled("y") ?? .native(0))
            ))
        }
    case "DateComponents":
        return HostFunction(name: name) { args, _ in
            var components = DateComponents()
            components.year = args.labeled("year")?.intValue
            components.month = args.labeled("month")?.intValue
            components.day = args.labeled("day")?.intValue
            components.hour = args.labeled("hour")?.intValue
            components.minute = args.labeled("minute")?.intValue
            components.second = args.labeled("second")?.intValue
            return .native(DateComponentsBox(components: components))
        }
    case "StrokeStyle":
        return HostFunction(name: name) { args, _ in
            var lineCap = CGLineCap.butt
            if case .implicitMember(let cap)? = args.labeled("lineCap") {
                switch cap {
                case "round": lineCap = .round
                case "square": lineCap = .square
                default: break
                }
            }
            var lineJoin = CGLineJoin.miter
            if case .implicitMember(let join)? = args.labeled("lineJoin") {
                switch join {
                case "round": lineJoin = .round
                case "bevel": lineJoin = .bevel
                default: break
                }
            }
            return .native(StrokeStyle(
                lineWidth: (try? Coerce.cgFloat(args.labeled("lineWidth") ?? .native(1.0))) ?? 1,
                lineCap: lineCap,
                lineJoin: lineJoin
            ))
        }
    case "NSError":
        return HostFunction(name: name) { args, _ in
            // Real NSError — localizedDescription and userInfo round-trip
            // (the NSLocalizedDescriptionKey genre in test helpers).
            let domain = args.labeled("domain")?.stringValue ?? "interpreted"
            let code = args.labeled("code")?.intValue ?? 0
            var userInfo: [String: Any] = [:]
            if let dict = args.labeled("userInfo")?.dictValue {
                for (key, value) in zip(dict.keys, dict.values) {
                    guard let keyText = key.stringValue else { continue }
                    userInfo[keyText] = value.stringValue ?? value.stringified
                }
            }
            return .native(ObjCBox(NSError(domain: domain, code: code, userInfo: userInfo)))
        }
    case "AttributedString":
        return HostFunction(name: name) { args, _ in
            // `AttributedString(markdown: text)` converts for real (author
            // names and status bodies flow through this in the EmojiText
            // genre); `stringLiteral:`/positional wrap plainly.
            if let markdown = args.labeled("markdown")?.stringValue {
                let options = AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace)
                let attributed = (try? AttributedString(markdown: markdown, options: options))
                    ?? AttributedString(markdown)
                return .native(AttributedStringBox(attributed))
            }
            let text = args.positional(0)?.stringValue
                ?? args.labeled("stringLiteral")?.stringValue ?? ""
            return .native(AttributedStringBox(AttributedString(text)))
        }
    case "Binding":
        // `Binding(get:set:)` — a computed binding. The box snapshots get()
        // now (bindings are reconstructed every render pass, so the snapshot
        // refreshes per pass); writes call set(newValue).
        return HostFunction(name: name) { args, ctx in
            .native(try BindingSemanticBridge.makeStub(
                arguments: args, context: ctx))
        }
    default:
        return nil
    }
}

/// `UITabBar.appearance().isHidden = true` — iOS styling side-channels have
/// no macOS analog; the proxy accepts configuration inertly (writes ignored,
/// config calls chain).

/// `FileManager.default` — real file operations confined to a per-run
/// sandbox, the analog of an app's fresh container: documents start empty,
/// writes/copies/removals genuinely happen (inside the sandbox only).
public final class FileManagerBox {
    /// In-run persistence for interpreted encode→write→read→decode cycles.
    var blobStore: [String: RuntimeValue] = [:]

    /// Immutable bundled-resource scope for the registry that owns this
    /// filesystem capability. Project bytes and the sandbox travel together;
    /// another render cannot redirect either one through process-global state.
    let projectResourceRoot: String?

    /// One registry owns one app-container capability. A process-global root
    /// lets an unrelated interpreter delete or redirect an in-flight task's
    /// files while that task is suspended — the parallel-worker sandbox race.
    /// Fresh-container determinism now comes from each verification building
    /// a fresh registry, not from resetting shared state.
    let sandboxRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "DynamicSwiftUI-Sandbox-\(UUID().uuidString)",
            isDirectory: true)

    let manager = FileManager.default

    init(projectResourceRoot: String? = nil) {
        self.projectResourceRoot = projectResourceRoot
    }

    deinit {
        try? FileManager.default.removeItem(at: sandboxRoot)
    }

    func documentsDirectory() -> URL {
        let documents = sandboxRoot.appendingPathComponent(
            "Documents", isDirectory: true)
        try? manager.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Canonical container path: standardized, with every EXISTING
    /// directory component resolved. Both sides of the admission check use
    /// it, so /var vs /private/var spellings agree.
    private func containerPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func requireSandboxed(_ url: URL) throws {
        // Resolve the DIRECTORY chain but keep the leaf unresolved: a
        // symlink inside the container pointing outside must not smuggle a
        // mutation out through its parent chain, while removing or
        // replacing the link itself remains an ordinary in-container
        // mutation (native removeItem on a link removes the link).
        let rootPath = containerPath(sandboxRoot)
        let candidate = url.standardizedFileURL
        let candidatePath = containerPath(candidate.deletingLastPathComponent())
            + "/" + candidate.lastPathComponent
        guard candidatePath == rootPath
                || candidatePath.hasPrefix(rootPath + "/") else {
            throw RuntimeError(message: "file operation outside the app sandbox: \(url.path)")
        }
    }
}

/// `calendar.dateComponents([.hour, .minute], from:to:)` results and
/// `DateComponents()` builders — member reads AND writes hit real values.
final class DateComponentsBox {
    var components: DateComponents

    init(components: DateComponents) {
        self.components = components
    }
}

/// `@Environment(\.modelContext)` — SwiftData persistence has no interpreter
/// analog; the stub behaves like a fresh in-memory store: writes accepted
/// and ignored, fetches return empty.
struct ModelContextStub {}

/// A REAL in-memory SwiftData store: `ModelContainer(for:…)` shares one
/// context; insert/fetch round-trip interpreted @Model instances, with
/// FetchDescriptor predicates genuinely filtering.
public final class ModelContainerBox {
    let context = ModelContextBox()
#if canImport(SwiftData)
    /// Execute SwiftData for the native value SwiftUI's generated modifier
    /// requires. Interpreted models remain in LiveModelStore because runtime
    /// source types cannot conform to the compiled PersistentModel protocol;
    /// the native empty container supplies framework environment semantics.
    let nativeContainer: SwiftData.ModelContainer

    init() {
        let schema = SwiftData.Schema([])
        let configuration = SwiftData.ModelConfiguration(
            isStoredInMemoryOnly: true)
        do {
            nativeContainer = try SwiftData.ModelContainer(
                for: schema, configurations: [configuration])
        } catch {
            preconditionFailure(
                "failed to create the in-memory SwiftData carrier: \(error)")
        }
    }
#endif
}

#if canImport(SwiftData)
extension ModelContainerBox: GeneratedMemberCarrier {
    var generatedMemberValue: Any { nativeContainer }
}
#endif

public final class ModelContextBox {
    var stored: [RuntimeValue] = []
}

/// `FetchDescriptor<DBModel.Country>()` / `FetchDescriptor(predicate:)` —
/// the model TYPE rides in (from the generic specialization or the
/// predicate's own generic), plus the predicate closure for real filtering.
public final class FetchDescriptorBox {
    var typeName: String?
    var predicate: PredicateBox?
    /// fetchLimit/sortBy/includePendingChanges — accepted and memoized
    /// (fetches honor fetchLimit; the rest are invisible to the
    /// in-memory store).
    var config: [String: RuntimeValue] = [:]

    init(typeName: String?, predicate: PredicateBox?) {
        self.typeName = typeName
        self.predicate = predicate
    }
}

/// `#Predicate<T> { … }` — the closure evaluates per candidate.
public final class PredicateBox {
    let typeName: String?
    let closure: ClosureValue?

    init(typeName: String?, closure: ClosureValue?) {
        self.typeName = typeName
        self.closure = closure
    }
}

/// `FetchDescriptor<Item>()` arrives as an absorbed marker/stub — its
/// stringified form carries the generic argument naming the model type.
func modelFetchTypeName(from descriptor: RuntimeValue) -> String? {
    if case .host(let any) = descriptor,
       let descriptor = any as? FetchDescriptorBox {
        return descriptor.typeName
    }
    let text = descriptor.stringified
    guard let open = text.firstIndex(of: "<"),
          let close = text[open...].firstIndex(of: ">") else { return nil }
    let inner = text[text.index(after: open)..<close]
    let name = inner.split(separator: ",").first.map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    return (name?.isEmpty == false) ? name : nil
}

/// `calendar.dateInterval(of:for:)` results — start/end/duration reads.
struct DateIntervalBox {
    let interval: DateInterval
}

/// `UIFont.systemFont(ofSize: 16, weight: .semibold)` and friends arrive as
/// implicit-member-call markers; map them onto real platform fonts so text
/// measurement uses actual metrics. Unresolvable markers fall back to the
/// system font.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private typealias PlatformFont = NSFont
#else
private typealias PlatformFont = UIFont
#endif

private func platformFont(from value: RuntimeValue) -> PlatformFont? {
    if case .host(let any) = value, let font = any as? PlatformFont { return font }
    guard case .host(let any) = value, let call = any as? ImplicitMemberCall else { return nil }
    let size = call.arguments.labeled("ofSize")?.doubleValue.map { CGFloat($0) }
        ?? PlatformFont.systemFontSize
    switch call.name {
    case "systemFont":
        var weight = PlatformFont.Weight.regular
        if case .implicitMember(let name)? = call.arguments.labeled("weight") {
            switch name {
            case "ultraLight": weight = .ultraLight
            case "thin": weight = .thin
            case "light": weight = .light
            case "medium": weight = .medium
            case "semibold": weight = .semibold
            case "bold": weight = .bold
            case "heavy": weight = .heavy
            case "black": weight = .black
            default: break
            }
        }
        return PlatformFont.systemFont(ofSize: size, weight: weight)
    case "boldSystemFont":
        return PlatformFont.boldSystemFont(ofSize: size)
    case "italicSystemFont":
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return PlatformFont.systemFont(ofSize: size)
#else
        return PlatformFont.italicSystemFont(ofSize: size)
#endif
    case "monospacedSystemFont":
        return PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    case "preferredFont":
        guard case .implicitMember(let styleName)? = call.arguments.labeled("forTextStyle") else {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return PlatformFont.preferredFont(forTextStyle: .body, options: [:])
#else
            return PlatformFont.preferredFont(forTextStyle: .body)
#endif
        }
        let style: PlatformFont.TextStyle
        switch styleName {
        case "largeTitle": style = .largeTitle
        case "title", "title1": style = .title1
        case "title2": style = .title2
        case "title3": style = .title3
        case "headline": style = .headline
        case "subheadline": style = .subheadline
        case "callout": style = .callout
        case "footnote": style = .footnote
        case "caption", "caption1": style = .caption1
        case "caption2": style = .caption2
        default: style = .body
        }
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return PlatformFont.preferredFont(forTextStyle: style, options: [:])
#else
        return PlatformFont.preferredFont(forTextStyle: style)
#endif
    default:
        return nil
    }
}

/// Readable members on host objects (extends bridgeHostMember's coverage).
/// A REAL NSRegularExpression (host-executable regex).
/// NSLock/NSRecursiveLock stand-in: single-threaded probes hold every
/// lock trivially; withLock runs its body.
public final class LockBox {}

final class RegexBox {
    let regex: NSRegularExpression
    init(regex: NSRegularExpression) { self.regex = regex }
}

func hostObjectMember(_ name: String, on value: Any) -> RuntimeValue? {
    // Alignment's axis accessors — the FlowLayout placement math reads
    // `alignment.horizontal.percent` through an app extension.
    if let alignment = value as? Alignment {
        if name == "horizontal" { return .native(alignment.horizontal) }
        if name == "vertical" { return .native(alignment.vertical) }
    }
    if let layout = layoutHostMember(name, on: value) { return layout }
    if let configuration =
        GeneratedSDKProtocolValueCoercions.frameworkConfigurationMember(
            name, on: value
        ) {
        return configuration
    }
    if let column = tableColumnSpecMember(name, on: value) { return column }
    if let generated = GeneratedOpaqueProtocolMembers.member(
        name, on: value
    ) {
        return generated
    }
    if let axis = axisValueMember(name, on: value) { return axis }
    if let container = value as? ModelContainerBox {
        if name == "mainContext" { return .native(container.context) }
        return nil
    }
    if let context = value as? ModelContextBox {
        switch name {
        case "insert":
            return .hostFunction(HostFunction(name: name) { args, _ in
                if let model = args.positional(0) { context.stored.append(model) }
                return .void
            })
        case "delete":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard case .instance(let doomed)? = args.positional(0) else { return .void }
                context.stored.removeAll {
                    if case .instance(let candidate) = $0 { return candidate === doomed }
                    return false
                }
                return .void
            })
        case "save":
            return .hostFunction(modelContextSaveGateway)
        case "transaction":
            // Runs the block immediately — the in-memory store has no
            // isolation to defer.
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let body = args.firstUnlabeledClosure {
                    _ = try ctx.callClosure(body, arguments: [])
                }
                return .void
            })
        case "fetch", "fetchCount":
            let wantsCount = name == "fetchCount"
            return .hostFunction(HostFunction(name: name) { args, ctx in
                var typeName: String?
                var predicate: PredicateBox?
                var fetchLimit: Int?
                if case .host(let any)? = args.positional(0), let descriptor = any as? FetchDescriptorBox {
                    typeName = descriptor.typeName
                    predicate = descriptor.predicate
                    fetchLimit = descriptor.config["fetchLimit"]?.intValue
                } else if let text = args.positional(0).map({ modelFetchTypeName(from: $0) }) {
                    typeName = text
                }
                let wantedLast = typeName?.split(separator: ".").last.map(String.init)
                var matches: [RuntimeValue] = []
                for candidate in context.stored {
                    guard case .instance(let instance) = candidate else { continue }
                    if let wantedLast, instance.symbol.name != wantedLast,
                       !instance.symbol.name.hasSuffix(".\(wantedLast)") {
                        continue
                    }
                    if let predicate, let closure = predicate.closure {
                        let verdict = try? ctx.callClosure(closure, arguments: [candidate])
                        if verdict?.boolValue != true { continue }
                    }
                    matches.append(candidate)
                    if let fetchLimit, matches.count >= fetchLimit { break }
                }
                return wantsCount ? .native(matches.count) : .native(matches)
            })
        default:
            return nil
        }
    }
    if value is LockBox {
        switch name {
        case "withLock", "sync":
            // Runs the body and returns its result — the lock is always
            // free in a single-threaded probe.
            return .hostFunction(HostFunction(name: name) { args, ctx in
                guard let body = args.firstUnlabeledClosure else { return .void }
                return try ctx.callClosure(body, arguments: [])
            })
        case "lock", "unlock", "signal", "broadcast", "wait":
            return .hostFunction(HostFunction(name: name) { _, _ in .void })
        default:
            return nil
        }
    }
    if let box = value as? RegexBox {
        switch name {
        case "numberOfCaptureGroups": return .native(box.regex.numberOfCaptureGroups)
        case "firstMatch", "matches":
            let isFirst = name == "firstMatch"
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let text = args.labeled("in")?.stringValue else {
                    return isFirst
                        ? .none(wrappedTypeName: "NSTextCheckingResult")
                        : .native([RuntimeValue]())
                }
                let range: NSRange
                if case .host(let any)? = args.labeled("range"), let r = any as? NSRange {
                    range = r
                } else {
                    range = NSRange(text.startIndex..., in: text)
                }
                if isFirst {
                    return .native(box.regex.firstMatch(in: text, range: range))
                }
                return .native(box.regex.matches(in: text, range: range).map { RuntimeValue.native($0) })
            })
        case "stringByReplacingMatches":
            return .hostFunction(HostFunction(name: name) { args, _ in
                guard let text = args.labeled("in")?.stringValue else { return .native("") }
                let range = NSRange(text.startIndex..., in: text)
                let template = args.labeled("withTemplate")?.stringValue ?? ""
                return .native(box.regex.stringByReplacingMatches(
                    in: text, range: range, withTemplate: template))
            })
        default: return nil
        }
    }
    if let match = value as? NSTextCheckingResult {
        switch name {
        case "numberOfRanges": return .native(match.numberOfRanges)
        case "range":
            return .hostFunction(HostFunction(name: name) { args, _ in
                if let index = (args.labeled("at") ?? args.positional(0))?.intValue,
                   index < match.numberOfRanges {
                    return .native(match.range(at: index))
                }
                return .native(match.range)
            })
        default: return nil
        }
    }
    if let box = value as? BundleBox {
        switch name {
        case "bundleURL": return .native(box.bundle.bundleURL)
        case "bundlePath": return .native(box.bundle.bundlePath)
        case "resourceURL": return .native(box.bundle.resourceURL)
        case "bundleIdentifier":
            // Real when the host process is bundled; a device app ALWAYS
            // has one, so the unbundled harness answers a stable stand-in
            // (the ScreenStub representative-default doctrine).
            return .native(box.bundle.bundleIdentifier ?? "interpreted.host.app")
        default:
            // Identity is real; RESOURCES aren't (nothing is bundled
            // headlessly). VERSION metadata gets representative stand-ins —
            // a device app always has them, and version-gate code
            // fatalErrors on their absence (the bundleIdentifier doctrine).
            if name == "url" {
                // `url(forResource: "Info.plist", …)` — SwiftGen's plist
                // readers hard-require it. The sandbox gets a REAL minimal
                // Info.plist seeded with the version stand-ins; other
                // resources stay absorbed (nothing else is bundled).
                return .hostFunction(HostFunction(name: name) { args, _ in
                    let resource = (args.labeled("forResource") ?? args.positional(0))?.stringValue ?? ""
                    let ext = args.labeled("withExtension")?.stringValue ?? ""
                    if let real = BundleBox.projectResource(
                        for: args,
                        projectResourceRoot:
                            box.fileManager.projectResourceRoot,
                        fallback: BundleResources.url(forResource:extension:)) {
                        return real
                    }
                    if resource.contains("Info"), resource.hasSuffix(".plist") || ext == "plist" {
                        let url = box.fileManager.sandboxRoot
                            .appendingPathComponent("Seeded-Info.plist")
                        try? FileManager.default.createDirectory(
                            at: box.fileManager.sandboxRoot,
                            withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: url.path) {
                            let seeded: [String: Any] = [
                                "CFBundleShortVersionString": box.bundle
                                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
                                "CFBundleVersion": box.bundle
                                    .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                                "CFBundleName": "InterpretedApp",
                            ]
                            (seeded as NSDictionary).write(to: url, atomically: true)
                        }
                        return .native(url)
                    }
                    return .native(ChainedImplicitCall(
                        base: .implicitMember("Bundle"), member: name, arguments: args))
                })
            }
            if name == "object" || name == "infoDictionary" {
                let versionKeys: [String: String] = [
                    "CFBundleShortVersionString": box.bundle
                        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
                    "CFBundleVersion": box.bundle
                        .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                    "CFBundleName": box.bundle
                        .object(forInfoDictionaryKey: "CFBundleName") as? String ?? "InterpretedApp",
                ]
                if name == "infoDictionary" {
                    var dict = DictValue()
                    for (key, value) in versionKeys {
                        try? dict.update(.native(key), to: .native(value))
                    }
                    return .native(dict)
                }
                return .hostFunction(HostFunction(name: name) { args, _ in
                    if let key = args.labeled("forInfoDictionaryKey")?.stringValue,
                       let known = versionKeys[key] {
                        return .native(known)
                    }
                    return .native(ChainedImplicitCall(
                        base: .implicitMember("Bundle"), member: name, arguments: args))
                })
            }
            return .hostFunction(HostFunction(name: name) { args, _ in
                if let resource = BundleBox.projectResource(
                    for: args,
                    projectResourceRoot:
                        box.fileManager.projectResourceRoot,
                    fallback: BundleResources.url(forResource:extension:)) {
                    return resource
                }
                return .native(ChainedImplicitCall(
                    base: .implicitMember("Bundle"), member: name, arguments: args))
            })
        }
    }
    // Text measurement, dispatched by the evaluator's label-aware member-call
    // hook (never by plain member access — user `size` extensions win there).
    if let string = value as? String, name == "sizeWithAttributes" {
        return .hostFunction(HostFunction(name: "size") { args, _ in
            let attributes = (args.labeled("withAttributes") ?? args.positional(0))?.dictValue
            let font = attributes?.values.lazy.compactMap(platformFont(from:)).first
                ?? PlatformFont.systemFont(ofSize: PlatformFont.systemFontSize)
            let measured = (string as NSString).size(withAttributes: [.font: font])
            return .native(CGSize(width: measured.width, height: measured.height))
        })
    }
    if let marker = value as? HostTypeMarker, marker.name == "Thread" {
        switch name {
        case "isMainThread": return .native(Thread.isMainThread)
        case "current", "main": return .native(UIKitStub())
        default: break
        }
    }
    if let marker = value as? HostTypeMarker, marker.name == "Date", name == "now" {
        return .native(Date())
    }
    // LOOP.md scope quarantine + AGENTS.md documented allowlist:
    // entitlement-gated services FAIL CLOSED. A swiftinterface cannot
    // express that these calls throw without an entitlement, and absorbing
    // lets junk overwrite app state — FoodTruck's forecast .task replaced
    // the placeholder with EMPTY entries, blanking the chart; headless
    // native throws and the app's own catch keeps the sample data.
    if let marker = value as? HostTypeMarker, environmentalServiceTypes.contains(marker.name) {
        if name == "shared" {
            return .native(HostTypeMarker(name: marker.name))
        }
        let serviceName = marker.name
        return .hostFunction(HostFunction(name: name) { _, _ in
            throw InterpretedThrow(value: .native(NSError(
                domain: serviceName, code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(serviceName).\(name) requires an entitlement (environmental — headless native throws)"])))
        })
    }
    if let marker = value as? HostTypeMarker, marker.name == "Task",
       name == "sleep" || name == "yield" {
        // `try await Task.sleep(…)` — inline await means no real clock;
        // yielding to the main loop IS the observable behavior, so pending
        // main-queue deliveries (asyncAfter hops) run now, like a native
        // sleep letting the runloop turn.
        return .hostFunction(HostFunction(name: name) { _, _ in
            MainQueueDrain.drain()
            return .void
        })
    }
    if let renderer = value as? GraphicsRendererBox, name == "image" {
        return .hostFunction(HostFunction(name: name) { args, ctx in
            if let closure = args.firstUnlabeledClosure {
                // The drawing closure runs (its fills absorb) — side effects
                // in user code still happen.
                _ = try? ctx.callClosure(closure, arguments: [.native(UIKitStub())])
            }
            return .native(UIImageBox.solid(size: renderer.size))
        })
    }
    if let image = value as? UIImageBox {
        switch name {
        case "size":
            return .native(image.size)
        case "pngData", "jpegData":
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(image.pngData)
            })
        default:
            break
        }
    }
    if let box = value as? ProcessInfoBox {
        switch name {
        case "environment":
            var keys: [RuntimeValue] = []
            var values: [RuntimeValue] = []
            for (key, entry) in ProcessInfo.processInfo.environment {
                keys.append(.native(key))
                values.append(.native(entry))
            }
            for (key, entry) in ProcessInfoBox.extraEnvironment {
                keys.append(.native(key))
                values.append(.native(entry))
            }
            return .native(DictValue(keys: keys, values: values))
        case "arguments":
            return .native(ProcessInfo.processInfo.arguments.map { RuntimeValue.native($0) })
        case "processIdentifier":
            return .native(Int(ProcessInfo.processInfo.processIdentifier))
        case "processName":
            return .native(ProcessInfo.processInfo.processName)
        default:
            break
        }
    }
    if let box = value as? FileManagerBox {
        switch name {
        case "urls":
            // Any search path reads the sandbox documents dir — the
            // fresh-container reading of (for: .documentDirectory, in:).
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native([RuntimeValue.native(box.documentsDirectory())])
            })
        case "url":
            return .hostFunction(HostFunction(name: name) { args, _ in
                // `url(forUbiquityContainerIdentifier:)` — a fresh device
                // has no iCloud container.
                if args.labeled("forUbiquityContainerIdentifier") != nil {
                    return .none(wrappedTypeName: "URL")
                }
                // `url(for: .documentDirectory, in: …, appropriateFor:
                // create:)` — the sandbox documents dir, like urls(for:in:).
                return .native(box.documentsDirectory())
            })
        case "homeDirectoryForCurrentUser":
            // The app's "home" is its container — the sandbox root.
            return .native(box.sandboxRoot)
        case "temporaryDirectory":
            let tmp = box.sandboxRoot.appendingPathComponent(
                "tmp", isDirectory: true)
            try? box.manager.createDirectory(at: tmp, withIntermediateDirectories: true)
            return .native(tmp)
        case "startDownloadingUbiquitousItem", "setUbiquitous":
            return .hostFunction(HostFunction(name: name) { _, _ in .void })
        default:
            // Forwarded file operations live in the declarative
            // FileServiceOperations table: one row per member states the
            // sandbox-analog semantics, one engine builds the confined and
            // the checked physical-worker face from the same row.
            return FileServiceOperations.hostFunction(named: name, on: box)
                .map { .hostFunction($0) }
        }
    }
    if let language = value as? Locale.Language {
        switch name {
        case "languageCode":
            return .native(language.languageCode)
        case "minimalIdentifier": return .native(language.minimalIdentifier)
        case "maximalIdentifier": return .native(language.maximalIdentifier)
        case "characterDirection":
            // .leftToRight / .rightToLeft as implicit members so case
            // comparisons (`== .rightToLeft`) match by name.
            switch language.characterDirection {
            case .rightToLeft: return .implicitMember("rightToLeft")
            case .topToBottom: return .implicitMember("topToBottom")
            case .bottomToTop: return .implicitMember("bottomToTop")
            default: return .implicitMember("leftToRight")
            }
        default: return nil
        }
    }
    if let code = value as? Locale.LanguageCode {
        if name == "identifier" { return .native(code.identifier) }
        return nil
    }
    if let locale = value as? Locale {
        switch name {
        case "language": return .native(locale.language)
        case "identifier": return .native(locale.identifier)
        case "regionCode":
            return .optional(
                locale.region.map { RuntimeValue.native($0.identifier) },
                wrappedTypeName: "String")
        case "languageCode":
            return .optional(
                locale.language.languageCode.map { RuntimeValue.native($0.identifier) },
                wrappedTypeName: "String")
        case "currencyCode":
            return .optional(
                locale.currency.map { RuntimeValue.native($0.identifier) },
                wrappedTypeName: "String")
        case "currencySymbol":
            return .native(locale.currencySymbol)
        case "localizedString":
            return .hostFunction(HostFunction(name: name) { args, _ in
                if let code = args.labeled("forRegionCode")?.stringValue {
                    return .native(locale.localizedString(forRegionCode: code))
                }
                if let code = args.labeled("forIdentifier")?.stringValue {
                    return .native(locale.localizedString(forIdentifier: code))
                }
                if let code = args.labeled("forLanguageCode")?.stringValue {
                    return .native(locale.localizedString(forLanguageCode: code))
                }
                return .none(wrappedTypeName: "String")
            })
        default: return nil
        }
    }
    if let box = value as? DateIntervalBox {
        switch name {
        case "start": return .native(box.interval.start)
        case "end": return .native(box.interval.end)
        case "duration": return .native(box.interval.duration)
        default: return nil
        }
    }
    if let box = value as? DateComponentsBox {
        switch name {
        case "hour": return .native(box.components.hour)
        case "minute": return .native(box.components.minute)
        case "second": return .native(box.components.second)
        case "day": return .native(box.components.day)
        case "month": return .native(box.components.month)
        case "year": return .native(box.components.year)
        case "weekday": return .native(box.components.weekday)
        default: return nil
        }
    }
    if let stub = value as? EnvironmentValuesStub {
        return stub.values[name]
    }
    if let box = value as? AttributedStringBox {
        switch name {
        case "range":
            return .hostFunction(HostFunction(name: "range") { args, _ in
                guard let text = (args.labeled("of") ?? args.positional(0))?.stringValue,
                      let range = box.attributed.range(of: text) else {
                    return .none(wrappedTypeName: "Range<AttributedString.Index>")
                }
                return .some(
                    .native(AttributedRangeBox(range)),
                    wrappedTypeName: "Range<AttributedString.Index>")
            })
        case "subscript":
            return .hostFunction(HostFunction(name: "subscript") { args, _ in
                guard case .host(let any)? = args.positional(0),
                      let range = (any as? GeneratedAttributedTextRangeCarrier)?
                        .generatedAttributedTextRange else {
                    throw RuntimeError(message: "AttributedString subscripting needs an attributed index range")
                }
                return .native(AttributedRangeProxy(box: box, range: range))
            })
        case "replacingAttributes", "settingAttributes", "mergingAttributes",
             "transformingAttributes":
            // Attribute transforms are cosmetic headlessly — the text
            // carries through (styling-proxy precedent).
            return .hostFunction(HostFunction(name: name) { _, _ in
                .native(AttributedStringBox(box.attributed))
            })
        case "description": return .native(String(box.attributed.characters))
        default:
            return nil
        }
    }
    if let box = value as? NumberFormatterBox {
        switch name {
        case "string":
            return .hostFunction(HostFunction(name: "string") { args, _ in
                var value = args.labeled("from") ?? args.positional(0)
                // `.init(value: x)` — the NSNumber marker unwraps to x.
                if case .host(let any)? = value, let call = any as? ImplicitMemberCall,
                   call.name == "init" {
                    value = call.arguments.labeled("value") ?? call.arguments.positional(0)
                }
                if case .implicitMember("zero")? = value {
                    value = .native(0.0)
                }
                guard let number = value?.doubleValue else {
                    throw RuntimeError(message: "string(from:) needs a number, got \(value?.stringified ?? "nothing")")
                }
                return .native(box.formatter.string(from: NSNumber(value: number)) ?? "\(number)")
            })
        case "number":
            return .hostFunction(HostFunction(name: "number") { args, _ in
                guard let text = (args.labeled("from") ?? args.positional(0))?.stringValue,
                      let parsed = box.formatter.number(from: text) else {
                    return .none(wrappedTypeName: "NSNumber")
                }
                return .some(.native(parsed.doubleValue), wrappedTypeName: "NSNumber")
            })
        default:
            return nil
        }
    }
    if value is ModelContextStub {
        // Fresh-store doctrine v2 (M3): the context backs a LIVE per-run
        // store — inserts are fetchable, deletes remove, save is a no-op,
        // and every run still starts empty (determinism holds).
        switch name {
        case "insert":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let inserted = args.positional(0) {
                    LiveModelStore.for(ctx).insert(inserted)
                }
                return .void
            })
        case "delete":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                if let deleted = args.positional(0) {
                    LiveModelStore.for(ctx).delete(deleted)
                }
                return .void
            })
        case "save":
            return .hostFunction(HostFunction(name: name) { _, _ in .void })
        case "fetch":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let typeName = args.positional(0).flatMap(modelFetchTypeName(from:))
                return .native(LiveModelStore.for(ctx).fetch(typeName: typeName))
            })
        case "fetchCount":
            return .hostFunction(HostFunction(name: name) { args, ctx in
                let typeName = args.positional(0).flatMap(modelFetchTypeName(from:))
                return .native(LiveModelStore.for(ctx).fetch(typeName: typeName).count)
            })
        case "autosaveEnabled":
            return .native(true)
        default:
            return nil
        }
    }
    if value is HostTypeMarker, name == "appearance" {
        // The appearance proxy is a UIKitStub: reads memoize, writes stick
        // (`refreshControl.bounds = …` then reading it back), calls chain.
        return .hostFunction(HostFunction(name: "appearance") { _, _ in .native(UIKitStub()) })
    }
    if let marker = value as? HostTypeMarker, marker.name == "Timer", name == "publish" {
        return .hostFunction(HostFunction(name: "publish") { args, _ in
            let interval = (args.labeled("every") ?? args.positional(0))?.doubleValue ?? 1.0
            return .native(TimerPublisherBox(interval: interval)) // on:/in: accepted, main/common assumed
        })
    }
    if let box = value as? TimerPublisherBox {
        if name == "autoconnect" {
            return .hostFunction(HostFunction(name: "autoconnect") { _, _ in .native(box) })
        }
        return nil
    }
    guard let box = value as? DateFormatterBox else { return nil }
    switch name {
    case "dateFormat":
        return .native(box.formatter.dateFormat ?? "")
    case "string":
        return .hostFunction(HostFunction(name: "string") { args, ctx in
            let operand = args.labeled("from") ?? args.positional(0)
            let date = operand.flatMap {
                ctx.resolveForBridge($0, typeName: "Date").hostPayload as? Date
            }
            guard let date else {
                // An UNKNOWABLE operand (a date the merge couldn't produce)
                // formats as the fresh string — "" — like every string
                // context; genuinely wrong values still throw.
                if let operand, Coerce.isUnknowable(operand) || operand.isNil {
                    return .native("")
                }
                if case .double(let interval)? = operand {
                    return .native(box.formatter.string(from: Date(timeIntervalSince1970: interval)))
                }
                throw RuntimeError(message: "string(from:) needs a Date, got \(operand?.stringified ?? "nothing")")
            }
            return .native(box.formatter.string(from: date))
        })
    case "date":
        return .hostFunction(HostFunction(name: "date") { args, _ in
            guard let text = (args.labeled("from") ?? args.positional(0))?.stringValue else {
                throw RuntimeError(message: "date(from:) needs a String")
            }
            return .native(box.formatter.date(from: text))
        })
    default:
        return nil
    }
}

/// Writable members on host objects.
func hostObjectSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
    if let record = value as? GeneratedCRecordValue {
        record.members[name] = newValue
        return true
    }
    if value is ImplicitMemberCall || value is ChainedImplicitCall {
        // Unresolvable host objects (`manager.delegate = self` on a marker
        // CLLocationManager) — config writes are dead machinery headlessly.
        return true
    }
    if let stub = value as? UIKitStub {
        stub.config[name] = newValue
        return true
    }
    if let descriptor = value as? FetchDescriptorBox {
        if name == "predicate", case .host(let obj) = newValue,
           let box = obj as? PredicateBox {
            descriptor.predicate = box
        }
        descriptor.config[name] = newValue
        return true
    }
    if let box = value as? NumberFormatterBox {
        switch name {
        case "numberStyle":
            if case .implicitMember(let style) = newValue {
                switch style {
                case "decimal": box.formatter.numberStyle = .decimal
                case "currency": box.formatter.numberStyle = .currency
                case "percent": box.formatter.numberStyle = .percent
                case "ordinal": box.formatter.numberStyle = .ordinal
                default: break
                }
            }
            return true
        case "maximumFractionDigits":
            if let digits = newValue.intValue { box.formatter.maximumFractionDigits = digits }
            return true
        case "minimumFractionDigits":
            if let digits = newValue.intValue { box.formatter.minimumFractionDigits = digits }
            return true
        case "decimalSeparator":
            if let separator = newValue.stringValue { box.formatter.decimalSeparator = separator }
            return true
        case "minimumIntegerDigits":
            if let digits = newValue.intValue { box.formatter.minimumIntegerDigits = digits }
            return true
        case "locale", "currencySymbol", "groupingSeparator", "allowsFloats",
             "usesGroupingSeparator", "roundingMode", "positiveFormat", "negativeFormat":
            return true // accepted; defaults suffice headlessly
        default:
            return false
        }
    }
    if let shell = value as? GeneratedPlatformValue,
       shell.semanticRoles.contains(.applicationShell) {
        // Framework-created application/window/scene objects are configurable
        // bags only after generated properties decline the write.
        shell.config[name] = newValue
        return true
    }
    if value is ScreenStub {
        return true // screen-shell config is accepted headlessly
    }
    if value is GraphicsContextStub || value is PathDrawStub {
        return true // `context.opacity = 0.5` — draw state accepted, no surface
    }
    if let box = value as? NumberFormatterBox {
        switch name {
        case "numberStyle":
            if case .implicitMember(let style) = newValue {
                switch style {
                case "decimal": box.formatter.numberStyle = .decimal
                case "currency": box.formatter.numberStyle = .currency
                case "percent": box.formatter.numberStyle = .percent
                case "ordinal": box.formatter.numberStyle = .ordinal
                default: break
                }
            }
            return true
        case "maximumFractionDigits":
            if let digits = newValue.intValue { box.formatter.maximumFractionDigits = digits }
            return true
        case "minimumFractionDigits":
            if let digits = newValue.intValue { box.formatter.minimumFractionDigits = digits }
            return true
        case "decimalSeparator":
            if let separator = newValue.stringValue { box.formatter.decimalSeparator = separator }
            return true
        case "minimumIntegerDigits":
            if let digits = newValue.intValue { box.formatter.minimumIntegerDigits = digits }
            return true
        case "locale", "currencySymbol", "groupingSeparator", "allowsFloats",
             "usesGroupingSeparator", "roundingMode", "positiveFormat", "negativeFormat":
            return true // accepted; defaults suffice headlessly
        default:
            return false
        }
    }
    if let box = value as? DateComponentsBox {
        guard let amount = newValue.intValue ?? newValue.doubleValue.map({ Int($0) }) else { return false }
        switch name {
        case "year": box.components.year = amount
        case "month": box.components.month = amount
        case "day": box.components.day = amount
        case "hour": box.components.hour = amount
        case "minute": box.components.minute = amount
        case "second": box.components.second = amount
        case "weekday": box.components.weekday = amount
        default: return false
        }
        return true
    }
    if let box = value as? AttributedStringBox {
        switch name {
        case "foregroundColor":
            if let color = Coerce.colorLike(newValue) { box.attributed.foregroundColor = color }
            return true
        case "font":
            if let font = try? Coerce.font(newValue) { box.attributed.font = font }
            return true
        case "underlineStyle", "underlineColor", "backgroundColor", "link":
            return true
        default:
            return false
        }
    }
    if let proxy = value as? AttributedRangeProxy {
        switch name {
        case "foregroundColor":
            if let color = Coerce.colorLike(newValue) {
                proxy.box.attributed[proxy.range].foregroundColor = color
            }
            return true
        case "font":
            if let font = try? Coerce.font(newValue) {
                proxy.box.attributed[proxy.range].font = font
            }
            return true
        case "underlineStyle", "underlineColor", "backgroundColor", "link":
            return true // accepted; not yet rendered
        default:
            return false
        }
    }
    guard let box = value as? DateFormatterBox else { return false }
    switch name {
    case "dateFormat":
        guard let format = newValue.stringValue else { return false }
        box.formatter.dateFormat = format
        return true
    case "locale":
        if case .host(let any) = newValue, let locale = any as? Locale {
            box.formatter.locale = locale
        } else if case .implicitMember("current") = newValue {
            box.formatter.locale = .current
        }
        return true // unknown locale markers keep the default — accepted
    case "calendar":
        if case .host(let any) = newValue, let calendar = any as? Calendar {
            box.formatter.calendar = calendar
        }
        return true
    case "timeZone":
        return true // host formatting stays in the run's zone — accepted
    case "dateStyle", "timeStyle":
        if case .implicitMember(let style) = newValue {
            let mapped: DateFormatter.Style
            switch style {
            case "short": mapped = .short
            case "medium": mapped = .medium
            case "long": mapped = .long
            case "full": mapped = .full
            default: mapped = .none
            }
            if name == "dateStyle" { box.formatter.dateStyle = mapped }
            else { box.formatter.timeStyle = mapped }
        }
        return true
    case "amSymbol", "pmSymbol":
        if let symbol = newValue.stringValue {
            if name == "amSymbol" { box.formatter.amSymbol = symbol }
            else { box.formatter.pmSymbol = symbol }
        }
        return true
    default:
        return false
    }
}


extension DateComponentsBox: GeneratedMemberCarrier, HostValueSemantic,
    CustomStringConvertible {
    var generatedMemberValue: Any { components }
    func writeGeneratedMemberValue(_ value: Any) -> Bool {
        guard let value = value as? DateComponents else { return false }
        components = value
        return true
    }
    func replacingGeneratedMemberValue(_ value: Any) -> Any? {
        (value as? DateComponents).map(DateComponentsBox.init(components:))
    }
    func copiedHostValue() -> Any {
        DateComponentsBox(components: components)
    }
    public var description: String { String(describing: components) }
}
