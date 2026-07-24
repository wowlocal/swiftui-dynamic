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
        for candidate in [name, "NS" + name] {
            if let cls = NSClassFromString(candidate) as? NSObject.Type,
               allowedClasses.contains(name) || supportsProjectDataAsset(cls) {
                return cls
            }
        }
        return nil
    }

    /// Clang-imported SDK declarations do not appear in a swiftinterface.
    /// Recognize the immutable data-asset contract from Objective-C runtime
    /// metadata instead of growing a constructor branch per SDK type.
    private static func supportsProjectDataAsset(_ cls: NSObject.Type) -> Bool {
        let getters = ["name", "data", "typeIdentifier"].allSatisfy { name in
            class_getInstanceMethod(cls, Selector(name)).map {
                methodEncodingObjectOnly($0, expectedArgs: 0)
            } ?? false
        }
        let initializerShapes = [
            ("initWithName:", 1),
            ("initWithName:bundle:", 2),
        ]
        return getters && initializerShapes.contains { selectorName, arity in
            class_getInstanceMethod(cls, Selector(selectorName)).map {
                methodEncodingObjectOnly($0, expectedArgs: arity)
            } ?? false
        }
    }

    /// Constructor lookup restricted to classes that prove the immutable
    /// data-asset property/initializer contract through Objective-C metadata.
    /// Trace-mode callers use this narrower capability instead of admitting
    /// every unrelated class on the general Objective-C allowlist.
    static func projectDataAssetConstructor(
        named name: String,
        projectResourceRoot: String? = nil
    ) -> HostFunction? {
        guard let cls = resolveClass(name), supportsProjectDataAsset(cls) else {
            return nil
        }
        return constructor(
            named: name,
            projectResourceRoot: projectResourceRoot)
    }

    /// `RelativeDateTimeFormatter()` — no-argument construction.
    static func constructor(
        named name: String,
        projectResourceRoot: String? = nil
    ) -> HostFunction? {
        guard let cls = resolveClass(name) else { return nil }
        return HostFunction(name: name) { args, _ in
            if supportsProjectDataAsset(cls) {
                guard (1...2).contains(args.arguments.count),
                      args.arguments.allSatisfy({ $0.label == "name" || $0.label == "bundle" }),
                      let assetName = args.labeled("name")?.stringValue else {
                    throw RuntimeError(
                        message: "\(name)(…): expected name: and optional bundle:")
                }
                guard let asset = BundleBox.projectDataAsset(
                    named: assetName,
                    projectResourceRoot: projectResourceRoot
                ) else {
                    return .none(wrappedTypeName: name)
                }
                return .some(
                    .native(ObjCBox(ProjectDataAssetObject(asset))),
                    wrappedTypeName: name)
            }
            if name == "UserDefaults" || name == "NSUserDefaults",
               args.labeled("suiteName")?.stringValue != nil {
                return .native(ObjCBox(ephemeralDefaults))
            }
            guard args.arguments.isEmpty else {
                throw RuntimeError(message: "\(name)(…): only () init is bridged automatically")
            }
            return .native(ObjCBox(
                cls.init(), generatedReferenceTypeName: name))
        }
    }

    /// `UserDefaults.standard` reads/writes an EPHEMERAL per-process suite,
    /// wiped at first use each run: round-trips stay real WITHIN a run (the
    /// doctrine), but nothing persists across runs — corpus determinism
    /// (nextcloud's onboarding flags and apple-browsers' cached feature
    /// state were flipping later runs through ~/Library/Preferences).
    static let ephemeralSuiteName = "DynamicSwiftUI.ephemeral"

    static let ephemeralDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: ephemeralSuiteName) ?? .standard
        defaults.removePersistentDomain(forName: ephemeralSuiteName)
        return defaults
    }()

    /// Per-verification wipe — project N's writes must not reach N+1.
    static func resetEphemeralDefaults() {
        ephemeralDefaults.removePersistentDomain(forName: ephemeralSuiteName)
    }

    /// `UserDefaults.standard` — class singletons/statics via candidates.
    static func staticMember(_ name: String, onClassNamed className: String) -> RuntimeValue? {
        guard let cls = resolveClass(className) else { return nil }
        if name == "standard", className == "UserDefaults" || className == "NSUserDefaults" {
            return .native(ObjCBox(ephemeralDefaults))
        }
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
        return method(name, on: box)
    }

    /// Methods-only lookup for overload resolution. Unlike `member`, this
    /// never executes a same-named zero-argument getter while merely forming
    /// a candidate family; selector shape remains deferred until invocation
    /// supplies the argument labels and values.
    static func method(_ name: String, on box: ObjCBox) -> RuntimeValue {
        let object = box.object
        return .hostFunction(HostFunction(name: name) { args, ctx in
            // No matching selector / unmarshalable argument = a Swift-only
            // or unbridgeable member: absorb inert (the doctrine), so
            // Combine surfaces like NotificationCenter.publisher keep
            // flowing as markers instead of erroring.
            guard let result = try invokeIfBridgeable(name, on: object, box: box, args: args, ctx: ctx) else {
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
        guard let unmanaged = try? performCatching({ object.perform(selector) }) else {
            return .none()
        }
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

    /// Generated Foundation property contracts supply the declared enum type;
    /// BridgeGen supplies every available imported case's native raw value.
    /// KVC then performs the ABI-safe NSNumber-to-scalar unboxing that
    /// perform(_:with:) cannot provide for non-object Objective-C setters.
    static func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String,
        value: RuntimeValue, on box: ObjCBox
    ) throws -> Bool {
        let setter = Selector(
            "set\(name.prefix(1).uppercased())\(name.dropFirst()):")
        guard box.object.responds(to: setter) else { return false }

        let nativeValue: Any?
        if case .implicitMember(let member) = value {
            guard let cases = GeneratedFoundationReferenceProperties
                .implicitEnumRawValuesByTypeAndCase[declaredType]
            else { return false }
            guard let raw = cases[member] else {
                throw RuntimeError(message:
                    "unknown generated Foundation enum member "
                        + "'\(declaredType).\(member)'")
            }
            nativeValue = raw
        } else if value.isNil {
            nativeValue = nil
        } else {
            guard let marshaled = marshalToObjC(value) else { return false }
            nativeValue = marshaled
        }

        if let exception = DSUICatchObjCException({
            box.object.setValue(nativeValue, forKey: name)
        }) {
            throw RuntimeError(message:
                "ObjC exception: \(exception.name.rawValue) — "
                    + (exception.reason ?? "no reason"))
        }
        return true
    }

    private static func invokeIfBridgeable(
        _ name: String, on object: NSObject, box: ObjCBox, args: CallArguments, ctx: EvalContext
    ) throws -> RuntimeValue? {
        let positionals = args.arguments
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
        var marshaled: [AnyObject?] = []
        for argument in positionals {
            // Interpreted closures marshal as BLOCKS: the completion returns
            // into the interpreter with the closure's own declared arity.
            if case .closure(let closure) = argument.value {
                marshaled.append(blockShim(for: closure, ctx: ctx))
                continue
            }
            if argument.value.isNil {
                marshaled.append(nil) // ObjC nil, not NSNull
                continue
            }
            guard let value = marshalToObjC(argument.value) else { return nil }
            marshaled.append(value)
        }
        guard marshaled.count <= 4 else { return nil }
        let firstLabel = positionals.first?.label ?? ""
        guard let selector = matchSelector(
            on: object, arity: positionals.count,
            exact: expectedParts.isEmpty ? head : expectedParts.map { $0 + ":" }.joined(),
            prefixParts: expectedParts, arguments: marshaled,
            firstHead: head, firstLabel: firstLabel) else { return nil }
        let result: Unmanaged<AnyObject>? = try performCatching {
            callIMP(object, selector, marshaled)
        }
        // perform() on a VOID method returns garbage — only read the result
        // when the encoding says an object comes back. An object-returning
        // method that hands back nil IS nil (fresh UserDefaults
        // .object(forKey:) — nothing persisted), never ().
        guard returnsObject(object, selector: selector) else { return .void }
        guard let returned = result?.takeUnretainedValue() else { return .none() }
        return marshalToRuntime(returned)
    }

    /// Direct IMP calls: all-object encodings are pointer-uniform in the C
    /// ABI, so fixed-shape casts cover arity 0-4 (perform() stops at 2).
    private static func callIMP(_ object: NSObject, _ selector: Selector, _ args: [AnyObject?]) -> Unmanaged<AnyObject>? {
        guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return nil }
        let imp = method_getImplementation(method)
        typealias F0 = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        typealias F1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
        typealias F2 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        typealias F3 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        typealias F4 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        switch args.count {
        case 0: return unsafeBitCast(imp, to: F0.self)(object, selector)
        case 1: return unsafeBitCast(imp, to: F1.self)(object, selector, args[0])
        case 2: return unsafeBitCast(imp, to: F2.self)(object, selector, args[0], args[1])
        case 3: return unsafeBitCast(imp, to: F3.self)(object, selector, args[0], args[1], args[2])
        default: return unsafeBitCast(imp, to: F4.self)(object, selector, args[0], args[1], args[2], args[3])
        }
    }

    /// A completion block of the interpreted closure's own arity; arguments
    /// marshal back and delivery hops to the main actor.
    private static func blockShim(for closure: ClosureValue, ctx: EvalContext) -> AnyObject {
        let deliver: ([AnyObject?]) -> Void = { raw in
            let run = {
                MainActor.assumeIsolated {
                    let mapped = raw.map { any -> RuntimeValue in
                        any.map { marshalToRuntime($0) } ?? .none()
                    }
                    InterpretedHostCallback(
                        closure: closure,
                        context: ctx,
                        diagnosticContext: "Objective-C completion"
                    ).call(arguments: mapped)
                }
            }
            if Thread.isMainThread {
                run()
            } else {
                DispatchQueue.main.async(execute: run)
            }
        }
        switch closure.parameters.count {
        case 0:
            let block: @convention(block) () -> Void = { deliver([]) }
            return block as AnyObject
        case 1:
            let block: @convention(block) (AnyObject?) -> Void = { deliver([$0]) }
            return block as AnyObject
        case 2:
            let block: @convention(block) (AnyObject?, AnyObject?) -> Void = { deliver([$0, $1]) }
            return block as AnyObject
        default:
            let block: @convention(block) (AnyObject?, AnyObject?, AnyObject?) -> Void = { deliver([$0, $1, $2]) }
            return block as AnyObject
        }
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
        on object: NSObject, arity: Int, exact: String, prefixParts: [String], arguments: [AnyObject?],
        firstHead: String = "", firstLabel: String = ""
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
                    let partsMatch = zip(parts, prefixParts).enumerated().allSatisfy { index, pair in
                        let (part, prefix) = pair
                        if part.lowercased().hasPrefix(prefix.lowercased()) { return true }
                        // First part also matches the head + fused-type +
                        // label shape: post(name:) → postNotificationName.
                        if index == 0, !firstHead.isEmpty,
                           part.lowercased().hasPrefix(firstHead.lowercased()),
                           firstLabel.isEmpty || part.lowercased().contains(firstLabel.lowercased()) {
                            return true
                        }
                        return false
                    }
                    guard partsMatch else { continue }
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
        _ parts: [String], _ prefixes: [String], _ arguments: [AnyObject?]
    ) -> Bool {
        for (index, (part, prefix)) in zip(parts, prefixes).enumerated() {
            guard index < arguments.count else { break }
            // Parts matched via the head+label rule (post → postNotificationName)
            // have no clean type-tail to audit — the label containment already
            // agreed with the argument.
            guard part.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let suffix = String(part.dropFirst(prefix.count))
            guard !suffix.isEmpty else { continue }
            guard let argument = arguments[index] else { continue } // nil fits any slot
            let allowed: Set<String>
            switch argument {
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
        if case .optional(let optional) = value {
            return optional.wrapped.flatMap(marshalToObjC)
        }
        // `NSNotification.Name("ping")` / `Notification.Name(...)` markers —
        // toll-free NSString.
        if case .host(let any) = value, let call = any as? ImplicitMemberCall,
           call.name == "Name" || call.name == "init",
           let text = call.arguments.positional(0)?.stringValue {
            return text as NSString
        }
        if let text = value.stringValue { return text as NSString }
        if let number = value.intValue { return NSNumber(value: number) }
        if let number = value.doubleValue { return NSNumber(value: number) }
        if let flag = value.boolValue { return NSNumber(value: flag) }
        // Arrays FIRST: a Swift [RuntimeValue] bridges to NSObject
        // (NSArray) and would smuggle interpreter boxes into Foundation —
        // elements must marshal individually.
        if let array = value.arrayValue {
            return array.compactMap { marshalToObjC($0) } as NSArray
        }
        if let set = value.setValue {
            return set.elements.compactMap { marshalToObjC($0) } as NSArray
        }
        if case .host(let any) = value {
            if any is [RuntimeValue] { return nil } // guarded above; belt+braces
            if let date = any as? Date { return date as NSDate }
            if let url = any as? URL { return url as NSURL }
            if let data = any as? Data { return data as NSData }
            if let box = any as? ObjCBox { return box.object }
            if let object = any as? NSObject { return object }
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

/// NSObject-shaped stand-in for an immutable catalog data entry. Existing
/// runtime metadata dispatch serves its properties, so the adapter adds no
/// hand-written member table.
@objcMembers
private final class ProjectDataAssetObject: NSObject {
    let name: String
    let data: Data
    let typeIdentifier: String

    init(_ resource: BundleBox.DataAssetResource) {
        name = resource.name
        data = resource.data
        typeIdentifier = resource.typeIdentifier
    }
}

/// A live NSObject riding through the interpreter.
public final class ObjCBox: GeneratedReferencePropertyCarrier {
    let object: NSObject
    let generatedReferenceTypeName: String
    var generatedReferencePropertyValues: [String: RuntimeValue] = [:]

    init(
        _ object: NSObject,
        generatedReferenceTypeName: String? = nil
    ) {
        self.object = object
        self.generatedReferenceTypeName = generatedReferenceTypeName
            ?? String(describing: type(of: object))
    }

    func applyGeneratedReferenceProperty(
        _ name: String, declaredType: String, value: RuntimeValue
    ) throws -> Bool {
        try ObjCTrampoline.applyGeneratedReferenceProperty(
            name, declaredType: declaredType, value: value, on: self)
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
func objcTrampolineMethod(_ name: String, on value: Any) -> RuntimeValue? {
    guard let box = value as? ObjCBox else { return nil }
    return ObjCTrampoline.method(name, on: box)
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
