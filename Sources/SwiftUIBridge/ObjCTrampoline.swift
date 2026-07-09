import Foundation
import ObjCExceptionShim
import ObjectiveC
import SwiftInterpreter

/// The automatic tier: NSObject-world APIs dispatch DYNAMICALLY through the
/// Objective-C runtime — no hand-written gateways. Construction resolves
/// classes by name, property reads/writes ride Key-Value Coding, and method
/// calls go through perform(_:with:with:) — but only after
/// method_getTypeEncoding proves every argument and the return are
/// object-typed ('@'), so a wrong shape falls back instead of crashing.
///
/// Guardrails:
/// - ALLOWLIST only — interpreted code doesn't get arbitrary system access.
///   Network classes are deliberately absent: URLSession stays behind
///   NetworkPolicy (determinism beats automation there).
/// - Swift-renamed selectors (`set(_:forKey:)` → setObject:forKey:) resolve
///   by scanning the class's method list: each selector part must START
///   WITH the Swift-name part (the rename convention fuses argument TYPES
///   onto the tails). The full renamed surface belongs to the BridgeGen tier.
@MainActor
enum ObjCTrampoline {
    static let allowedClasses: Set<String> = [
        "UserDefaults", "NSUserDefaults",
        "NotificationCenter", "NSNotificationCenter",
        "RelativeDateTimeFormatter",
        "DateComponentsFormatter",
        "ByteCountFormatter",
        "ISO8601DateFormatter",
        "NSCache",
        "PersonNameComponentsFormatter",
        "MeasurementFormatter",
    ]

    /// ObjC classes reachable under their Swift OR Foundation name.
    private static func resolveClass(_ name: String) -> NSObject.Type? {
        guard allowedClasses.contains(name) else { return nil }
        for candidate in [name, "NS" + name] {
            if let cls = NSClassFromString(candidate) as? NSObject.Type {
                return cls
            }
        }
        return nil
    }

    /// `RelativeDateTimeFormatter()` — no-argument construction.
    static func constructor(named name: String) -> HostFunction? {
        guard let cls = resolveClass(name) else { return nil }
        return HostFunction(name: name) { args, _ in
            guard args.arguments.isEmpty else {
                throw RuntimeError(message: "\(name)(…): only () init is bridged automatically")
            }
            return .native(ObjCBox(cls.init()))
        }
    }

    /// `UserDefaults.standard` — class singletons/statics via candidates.
    static func staticMember(_ name: String, onClassNamed className: String) -> RuntimeValue? {
        guard let cls = resolveClass(className) else { return nil }
        var candidates = [name, name + className.dropFirst(0)]
        if name == "standard" { candidates.append("standardUserDefaults") }
        if name == "default" { candidates += ["defaultCenter", "defaultManager"] }
        for candidate in candidates {
            let selector = Selector(candidate)
            guard let method = class_getClassMethod(cls, selector),
                  methodEncodingObjectOnly(method, expectedArgs: 0) else { continue }
            guard let unmanaged = try? performCatching({ cls.perform(selector) }) else { continue }
            return marshalToRuntime(unmanaged.takeUnretainedValue())
        }
        return nil
    }

    /// Every dynamic call runs under an @try/@catch shim: an ObjC exception
    /// becomes a located interpreter error instead of a process abort.
    private static func performCatching(
        _ body: () -> Unmanaged<AnyObject>?
    ) throws -> Unmanaged<AnyObject>? {
        var result: Unmanaged<AnyObject>?
        if let exception = DSUICatchObjCException({ result = body() }) {
            throw RuntimeError(
                message: "ObjC exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
        }
        return result
    }

    /// Members on a live ObjC object: zero-argument object-returning getters
    /// read immediately; everything else becomes a callable that resolves
    /// its selector at invocation time.
    static func member(_ name: String, on box: ObjCBox) -> RuntimeValue? {
        if let read = propertyRead(name, on: box) {
            return read
        }
        let object = box.object
        return .hostFunction(HostFunction(name: name) { args, _ in
            // No matching selector / unmarshalable argument = a Swift-only
            // or unbridgeable member: absorb inert (the doctrine), so
            // Combine surfaces like NotificationCenter.publisher keep
            // flowing as markers instead of erroring.
            guard let result = try invokeIfBridgeable(name, on: object, box: box, args: args) else {
                return .native(ChainedImplicitCall(base: .native(box), member: name, arguments: args))
            }
            return result
        })
    }

    static func propertyRead(_ name: String, on box: ObjCBox) -> RuntimeValue? {
        let object = box.object
        let selector = Selector(name)
        guard object.responds(to: selector) else { return nil }
        guard encodingIsObjectOnly(object, selector: selector, expectedArgs: 0) else { return nil }
        guard let unmanaged = try? performCatching({ object.perform(selector) }) else { return .nilValue }
        return marshalToRuntime(unmanaged.takeUnretainedValue())
    }

    static func propertyWrite(_ name: String, on box: ObjCBox, value: RuntimeValue) -> Bool {
        guard let marshaled = marshalToObjC(value) else { return false }
        let object = box.object
        let setter = Selector("set\(name.prefix(1).uppercased())\(name.dropFirst()):")
        guard object.responds(to: setter) else { return false }
        guard (try? performCatching({ object.perform(setter, with: marshaled) })) != nil else { return false }
        return true
    }

    private static func invokeIfBridgeable(
        _ name: String, on object: NSObject, box: ObjCBox, args: CallArguments
    ) throws -> RuntimeValue? {
        let positionals = args.arguments.filter { !$0.isTrailing }
        guard positionals.count == args.arguments.count else { return nil } // closures aren't marshalable
        let head = name
        // Swift-name parts: `localizedString(for:relativeTo:)` becomes
        // ["localizedStringFor", "relativeTo"] — the ObjC selector's parts
        // (localizedStringForDate:relativeToDate:) each START WITH them
        // (the rename convention fuses the argument's TYPE onto the tail).
        let expectedParts: [String] = positionals.enumerated().map { index, argument in
            let label = argument.label ?? ""
            if index == 0 {
                return head + (label.isEmpty ? "" : label.prefix(1).uppercased() + label.dropFirst())
            }
            return label
        }
        var marshaled: [AnyObject] = []
        for argument in positionals {
            guard let value = marshalToObjC(argument.value) else { return nil }
            marshaled.append(value)
        }
        guard marshaled.count <= 2 else { return nil }
        guard let selector = matchSelector(
            on: object, arity: positionals.count,
            exact: expectedParts.isEmpty ? head : expectedParts.map { $0 + ":" }.joined(),
            prefixParts: expectedParts, arguments: marshaled) else { return nil }
        let result: Unmanaged<AnyObject>? = try performCatching {
            switch marshaled.count {
            case 0: return object.perform(selector)
            case 1: return object.perform(selector, with: marshaled[0])
            default: return object.perform(selector, with: marshaled[0], with: marshaled[1])
            }
        }
        // perform() on a VOID method returns garbage — only read the result
        // when the encoding says an object comes back. An object-returning
        // method that hands back nil IS nil (fresh UserDefaults
        // .object(forKey:) — nothing persisted), never ().
        guard returnsObject(object, selector: selector) else { return .void }
        guard let returned = result?.takeUnretainedValue() else { return .nilValue }
        return marshalToRuntime(returned)
    }

    private static func returnsObject(_ object: NSObject, selector: Selector) -> Bool {
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return false }
        return String(cString: method_copyReturnType(method)).hasPrefix("@")
    }

    /// Exact selector first; otherwise scan the class's method list for an
    /// object-only method whose selector parts each start with the Swift
    /// parts AND whose fused TYPE SUFFIXES agree with the actual argument
    /// classes (`set` + NSString matches setObject:/setValue:, never
    /// setURL:). Shortest valid match wins (deterministic).
    private static func matchSelector(
        on object: NSObject, arity: Int, exact: String, prefixParts: [String], arguments: [AnyObject]
    ) -> Selector? {
        let exactSelector = Selector(exact)
        if object.responds(to: exactSelector),
           encodingIsObjectOnly(object, selector: exactSelector, expectedArgs: arity) {
            return exactSelector
        }
        guard let cls = object_getClass(object), !prefixParts.isEmpty else { return nil }
        var best: (selector: Selector, length: Int)?
        var currentClass: AnyClass? = cls
        while let scanned = currentClass {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(scanned, &count) {
                defer { free(methods) }
                for index in 0..<Int(count) {
                    let selector = method_getName(methods[index])
                    let selectorName = NSStringFromSelector(selector)
                    let parts = selectorName.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
                    guard parts.count == prefixParts.count,
                          selectorName.filter({ $0 == ":" }).count == arity else { continue }
                    guard zip(parts, prefixParts).allSatisfy({ $0.lowercased().hasPrefix($1.lowercased()) }) else {
                        continue
                    }
                    guard suffixesAgreeWithArguments(parts, prefixParts, arguments) else { continue }
                    guard methodEncodingObjectOnly(methods[index], expectedArgs: arity) else { continue }
                    if best == nil || selectorName.count < best!.length {
                        best = (selector, selectorName.count)
                    }
                }
            }
            currentClass = class_getSuperclass(scanned)
        }
        return best?.selector
    }

    /// The fused tail of each selector part names the parameter's TYPE —
    /// it must agree with what we actually pass.
    private static func suffixesAgreeWithArguments(
        _ parts: [String], _ prefixes: [String], _ arguments: [AnyObject]
    ) -> Bool {
        for (index, (part, prefix)) in zip(parts, prefixes).enumerated() {
            guard index < arguments.count else { break }
            let suffix = String(part.dropFirst(prefix.count))
            guard !suffix.isEmpty else { continue }
            let allowed: Set<String>
            switch arguments[index] {
            case is NSString: allowed = ["Object", "Value", "String", "Key", "Name"]
            case is NSNumber: allowed = ["Object", "Value", "Number", "Integer", "Int", "Double", "Float", "Bool", "Count"]
            case is NSDate: allowed = ["Object", "Value", "Date"]
            case is NSURL: allowed = ["Object", "Value", "URL"]
            case is NSData: allowed = ["Object", "Value", "Data"]
            case is NSArray: allowed = ["Object", "Value", "Array", "Objects"]
            default: continue
            }
            guard allowed.contains(suffix) else { return false }
        }
        return true
    }

    /// Type-encoding audit: every argument and the return must be id ('@'),
    /// void return allowed — the shapes perform() can carry safely.
    private static func encodingIsObjectOnly(_ object: NSObject, selector: Selector, expectedArgs: Int) -> Bool {
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return false }
        return methodEncodingObjectOnly(method, expectedArgs: expectedArgs)
    }

    private static func methodEncodingObjectOnly(_ method: Method, expectedArgs: Int) -> Bool {
        guard method_getNumberOfArguments(method) == UInt32(expectedArgs + 2) else { return false }
        let returnEncoding = String(cString: method_copyReturnType(method))
        guard returnEncoding.hasPrefix("@") || returnEncoding.hasPrefix("v") else { return false }
        for index in 0..<expectedArgs {
            guard let raw = method_copyArgumentType(method, UInt32(index + 2)) else { return false }
            let encoding = String(cString: raw)
            free(raw)
            guard encoding.hasPrefix("@") else { return false }
        }
        return true
    }

    // MARK: - Marshaling

    static func marshalToObjC(_ value: RuntimeValue) -> AnyObject? {
        if let text = value.stringValue { return text as NSString }
        if let number = value.intValue { return NSNumber(value: number) }
        if let number = value.doubleValue { return NSNumber(value: number) }
        if let flag = value.boolValue { return NSNumber(value: flag) }
        if case .host(let any) = value {
            if let object = any as? NSObject { return object }
            if let date = any as? Date { return date as NSDate }
            if let url = any as? URL { return url as NSURL }
            if let data = any as? Data { return data as NSData }
            if let box = any as? ObjCBox { return box.object }
        }
        if let array = value.arrayValue {
            return array.compactMap { marshalToObjC($0) } as NSArray
        }
        return nil
    }

    static func marshalToRuntime(_ object: AnyObject) -> RuntimeValue {
        if let text = object as? String { return .native(text) }
        if let number = object as? NSNumber {
            // Preserve integer-ness for interpreted arithmetic.
            let encoding = String(cString: number.objCType)
            if encoding == "q" || encoding == "i" || encoding == "l" || encoding == "s" {
                return .native(number.intValue)
            }
            if encoding == "c" || encoding == "B" { return .native(number.boolValue) }
            return .native(number.doubleValue)
        }
        if let date = object as? Date { return .native(date) }
        if let url = object as? URL { return .native(url) }
        if let data = object as? Data { return .native(data) }
        if let array = object as? [AnyObject] {
            return .native(array.map { marshalToRuntime($0) })
        }
        if let nsObject = object as? NSObject {
            return .native(ObjCBox(nsObject))
        }
        return .void
    }
}

/// A live NSObject riding through the interpreter.
public final class ObjCBox {
    let object: NSObject

    init(_ object: NSObject) {
        self.object = object
    }
}

/// Dispatch hooks for the shared bridge funnels.
@MainActor
func objcTrampolineMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let box = value as? ObjCBox {
        return ObjCTrampoline.member(name, on: box)
    }
    if let marker = value as? HostTypeMarker, ObjCTrampoline.allowedClasses.contains(marker.name) {
        return ObjCTrampoline.staticMember(name, onClassNamed: marker.name)
    }
    return nil
}

@MainActor
func objcTrampolineSetMember(_ name: String, on value: Any, to newValue: RuntimeValue) -> Bool {
    guard let box = value as? ObjCBox else { return false }
    return ObjCTrampoline.propertyWrite(name, on: box, value: newValue)
}

private extension String {
    var colonSuffixed: String {
        isEmpty ? ":" : self + ":"
    }
}
