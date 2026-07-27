import CoreGraphics
import Foundation
import SwiftInterpreter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Owned representation of an SDK pointer result. The originating framework
/// value is retained for the pointer's lifetime, and all access is expressed
/// as bounded byte copies through the interpreter's shared raw-memory
/// protocol.
private final class GeneratedPlatformRawMemory: HostRawMemory,
    CustomStringConvertible
{
    private let pointer: UnsafeRawPointer
    private let mutablePointer: UnsafeMutableRawPointer?
    private let owner: Any?

    init(pointer: UnsafeRawPointer, mutablePointer: UnsafeMutableRawPointer?, owner: Any?) {
        self.pointer = pointer
        self.mutablePointer = mutablePointer
        self.owner = owner
    }

    var description: String { "<retained SDK memory>" }

    func readBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw RuntimeError(message: "raw-memory read count cannot be negative")
        }
        return Data(bytes: pointer, count: count)
    }

    func writeBytes(_ data: Data, count: Int) throws {
        guard let mutablePointer else {
            throw RuntimeError(message: "raw-memory region is read-only")
        }
        guard count >= 0, count <= data.count else {
            throw RuntimeError(message:
                "raw-memory write count \(count) exceeds \(data.count) source bytes")
        }
        data.withUnsafeBytes { bytes in
            guard count > 0, let source = bytes.baseAddress else { return }
            mutablePointer.copyMemory(from: source, byteCount: count)
        }
    }
}

/// Common capability for a target-platform value which can cross a generated
/// SwiftUI initializer while the interpreter renders on another host.
///
/// The framework/type pair retains the swiftinterface contract. A native
/// payload drives the exact initializer when that framework is present; a
/// semantic View value lets an off-host adapter preserve renderable content
/// without identifying an initializer or SDK type in dispatch.
protocol GeneratedPlatformSemanticCarrier {
    var generatedPlatformFramework: String { get }
    var generatedPlatformTypeName: String { get }
    var generatedPlatformNativePayload: Any? { get }
    var generatedPlatformViewValue: Any? { get }
}

/// A semantic carrier can expose a native value by its RESULT TYPE when the
/// target SDK property is the unique property of that type on the receiver.
/// The generated property table supplies both sides of that proof; carriers
/// never name an SDK member. This is the reusable off-platform path for
/// semantic values such as a decoded raster's Core Graphics backing image.
struct GeneratedPlatformTypedPropertyValue {
    let typeName: String
    let value: RuntimeValue

    static func optional<T>(
        _ value: T?,
        as type: T.Type,
        framework: String
    ) -> GeneratedPlatformTypedPropertyValue {
        var typeName = String(describing: type)
        // Clang reference types surface as `CGImageRef.self` while their
        // swiftinterface contract uses `CGImage`. Normalize the importer
        // convention itself rather than enumerating SDK type identities.
        let isImportedReference = typeName.hasSuffix("Ref")
        if isImportedReference {
            typeName.removeLast(3)
        }
        let wrapped = value.map { value -> RuntimeValue in
            guard isImportedReference else {
                return .native(value)
            }
            // The Objective-C runtime erases imported CF reference classes
            // to `__NSCFType`. Retain the swiftinterface-facing nominal beside
            // the native payload so HostSignature can validate the result.
            return .native(GeneratedPlatformValue(
                framework: framework,
                typeName: typeName,
                isValueType: false,
                payload: value))
        }
        return GeneratedPlatformTypedPropertyValue(
            typeName: typeName,
            value: .optional(
                wrapped,
                wrappedTypeName: typeName))
    }
}

protocol GeneratedPlatformTypedPropertyCarrier:
    GeneratedPlatformSemanticCarrier
{
    var generatedPlatformTypedPropertyValues:
        [GeneratedPlatformTypedPropertyValue] { get }
}

/// An opaque reference bag whose source SDK roles are known even though no
/// native object exists on this host. Generated property lookup uses those
/// roles to select a swiftinterface contract; unknown members remain ordinary
/// fallback capabilities.
protocol GeneratedPlatformOpaqueReferenceCarrier: AnyObject {
    var generatedPlatformOpaqueTypeNames: [String] { get }
    var generatedPlatformOpaqueConfiguration: [String: RuntimeValue] {
        get set
    }
}

/// A platform value whose API contract came from BridgeGen's platform SDK
/// symbol-graph sweep. On the framework's native platform `payload` is the
/// real SDK value. On the opposite platform it is nil and the same generated
/// contract supplies deterministic, typed inert behavior.
final class GeneratedPlatformValue: InertCallable, HostValueSemantic, HostRuntimeEquatable,
    CustomStringConvertible, GeneratedPlatformSemanticCarrier
{
    enum SemanticRole: Hashable {
        /// Framework-owned application/window/scene objects configured by the
        /// headless launch environment rather than constructed by source.
        case applicationShell
    }

    let framework: String
    let typeName: String
    let isValueType: Bool
    var payload: Any?
    var config: [String: RuntimeValue]
    let semanticRoles: Set<SemanticRole>
    let interpretedLifecycleEntryPoint: String?
    let interpretedLifecycleAction: RuntimeValue?

    init(
        framework: String,
        typeName: String,
        isValueType: Bool,
        payload: Any?,
        config: [String: RuntimeValue] = [:],
        semanticRoles: Set<SemanticRole> = [],
        interpretedLifecycleEntryPoint: String? = nil,
        interpretedLifecycleAction: RuntimeValue? = nil
    ) {
        self.framework = framework
        self.typeName = typeName
        self.isValueType = isValueType
        self.payload = payload
        self.config = config
        self.semanticRoles = semanticRoles
        self.interpretedLifecycleEntryPoint =
            interpretedLifecycleEntryPoint
        self.interpretedLifecycleAction = interpretedLifecycleAction
    }

    var description: String {
        payload.map(String.init(describing:)) ?? "<\(framework).\(typeName) stub>"
    }

    var generatedPlatformFramework: String { framework }
    var generatedPlatformTypeName: String { typeName }
    var generatedPlatformNativePayload: Any? { payload }
    var generatedPlatformViewValue: Any? { nil }

    func copiedHostValue() -> Any {
        guard isValueType else { return self }
        return GeneratedPlatformValue(
            framework: framework,
            typeName: typeName,
            isValueType: true,
            payload: payload,
            config: config.mapValues { $0.copiedForValueSemantics() },
            semanticRoles: semanticRoles,
            interpretedLifecycleEntryPoint:
                interpretedLifecycleEntryPoint,
            interpretedLifecycleAction:
                interpretedLifecycleAction?.copiedForValueSemantics())
    }

    func runtimeEquals(_ other: Any) -> Bool? {
        guard let other = other as? GeneratedPlatformValue else { return nil }
        guard framework == other.framework, typeName == other.typeName else {
            return false
        }
        guard let otherPayload = other.payload else { return nil }
        return payloadEquals(otherPayload)
    }

    func runtimeEquals(implicitMemberNamed name: String) -> Bool? {
        guard let member = GeneratedPlatformBridge.enumPayload(
            framework: framework, type: typeName, member: name)
        else { return nil }
        return payloadEquals(member)
    }

    private func payloadEquals(_ other: Any) -> Bool? {
        guard let payload else { return nil }
        if let equal = GeneratedPlatformBridge.payloadsEqual(
            framework: framework, type: typeName,
            payload, other)
        {
            return equal
        }
        if let left = payload as? AnyHashable,
           let right = other as? AnyHashable {
            return left == right
        }
        if !isValueType {
            return (payload as AnyObject) === (other as AnyObject)
        }
        return nil
    }
}

/// Per-interpreter application objects. SDK interfaces describe the members
/// of NSApplication/UIApplication, but not the launch environment's ownership
/// or timing: the process singleton must not run/terminate the verifier, and a
/// storyboard-created AppKit main menu exists before delegate launch hooks.
///
/// This is the complete interface-inexpressible application-shell allowlist.
/// Its members are generated platform values, so constructors, methods,
/// properties, types, and coercions continue to dispatch from BridgeGen
/// metadata rather than accumulating another handwritten application API.
final class FrameworkApplicationShellStore {
    private struct LaunchObject {
        let member: String
        let type: String
        let isOptional: Bool
    }

    private struct Specification {
        let framework: String
        let applicationType: String
        let windowType: String
        let sceneType: String?
        let controllerType: String?
        let viewType: String?
        let launchObjects: [LaunchObject]
    }

    private static let specifications: [String: Specification] = [
        "NSApplication": Specification(
            framework: "AppKit",
            applicationType: "NSApplication",
            windowType: "NSWindow",
            sceneType: nil,
            controllerType: nil,
            viewType: nil,
            // Main.storyboard is loaded before will/did-finish-launching, but
            // neither that ownership nor its non-nil timing is in the SDK
            // declaration `var mainMenu: NSMenu?`.
            launchObjects: [LaunchObject(
                member: "mainMenu", type: "NSMenu", isOptional: true)]),
        "UIApplication": Specification(
            framework: "UIKit",
            applicationType: "UIApplication",
            windowType: "UIWindow",
            sceneType: "UIWindowScene",
            controllerType: "UIViewController",
            viewType: "UIView",
            launchObjects: []),
    ]

    private var applications: [String: GeneratedPlatformValue] = [:]

    func sharedApplication(ofType typeName: String) -> GeneratedPlatformValue? {
        guard let specification = Self.specifications[typeName] else { return nil }
        if let application = applications[typeName] { return application }

        func shellValue(_ type: String) -> GeneratedPlatformValue {
            GeneratedPlatformValue(
                framework: specification.framework,
                typeName: type,
                isValueType: GeneratedPlatformBridge.isValueType(
                    framework: specification.framework, type: type),
                payload: nil,
                semanticRoles: [.applicationShell])
        }

        let application = shellValue(specification.applicationType)
        let window = shellValue(specification.windowType)
        let windowValue = RuntimeValue.native(window)
        application.config["windows"] = .native([windowValue])
        application.config["keyWindow"] = .some(
            windowValue, wrappedTypeName: specification.windowType)
        application.config["mainWindow"] = .some(
            windowValue, wrappedTypeName: specification.windowType)
        window.config["isKeyWindow"] = .native(true)

        if let controllerType = specification.controllerType {
            let controllerShell = shellValue(controllerType)
            if let viewType = specification.viewType {
                let view = RuntimeValue.native(shellValue(viewType))
                controllerShell.config["view"] = .some(
                    view, wrappedTypeName: viewType)
                controllerShell.config["viewIfLoaded"] = .some(
                    view, wrappedTypeName: viewType)
            }
            let controller = RuntimeValue.native(controllerShell)
            window.config["rootViewController"] = .some(
                controller, wrappedTypeName: controllerType)
            window.config["rootController"] = controller
        }

        if let sceneType = specification.sceneType {
            let scene = shellValue(sceneType)
            scene.config["windows"] = .native([windowValue])
            scene.config["keyWindow"] = .some(
                windowValue, wrappedTypeName: specification.windowType)
            scene.config["activationState"] = .implicitMember("foregroundActive")
            application.config["connectedScenes"] = .native([
                RuntimeValue.native(scene),
            ])
        }

        for launchObject in specification.launchObjects {
            let value = RuntimeValue.native(shellValue(launchObject.type))
            application.config[launchObject.member] = launchObject.isOptional
                ? .some(value, wrappedTypeName: launchObject.type)
                : value
        }

        applications[typeName] = application
        return application
    }
}

struct GeneratedPlatformTypeKey: Hashable {
    let framework: String
    let type: String
}

struct GeneratedPlatformMemberKey: Hashable {
    let framework: String
    let type: String
    let member: String
}

struct GeneratedPlatformConstructorEntry {
    let framework: String
    let type: String
    let function: HostFunction
}

typealias GeneratedPlatformConstructorSemanticAdapter = @MainActor
    ([RuntimeValue], EvalContext) throws -> RuntimeValue?

struct GeneratedPlatformMethodEntry {
    typealias Invoke = @MainActor
        (GeneratedPlatformValue, [RuntimeValue], EvalContext) throws -> RuntimeValue
    typealias SemanticAdapter = @MainActor
        (GeneratedPlatformValue, [RuntimeValue], EvalContext) throws -> RuntimeValue?

    let signature: HostSignature
    let framework: String
    let resultType: String
    let semanticAdapter: SemanticAdapter?
    let invoke: Invoke

    func bound(to base: GeneratedPlatformValue) throws -> HostFunction {
        try HostFunction(signature: signature) { arguments, context in
            let values = arguments.arguments.map(\.value)
            if let result = try semanticAdapter?(base, values, context) {
                return result
            }
            if !GeneratedPlatformBridge.frameworkIsNative(framework)
                || base.payload == nil
            {
                return GeneratedPlatformBridge.fallbackResult(
                    framework: framework, type: resultType)
            }
            return try invoke(base, values, context)
        }
    }
}

struct GeneratedPlatformStaticMethodEntry {
    typealias Invoke = @MainActor
        ([RuntimeValue], EvalContext) throws -> RuntimeValue

    let signature: HostSignature
    let framework: String
    let resultType: String
    let invoke: Invoke

    func function() throws -> HostFunction {
        try HostFunction(signature: signature) { arguments, context in
            guard GeneratedPlatformBridge.frameworkIsNative(framework) else {
                return GeneratedPlatformBridge.fallbackResult(
                    framework: framework, type: resultType)
            }
            return try invoke(arguments.arguments.map(\.value), context)
        }
    }
}

struct GeneratedPlatformGlobalFunctionEntry {
    typealias Invoke = @MainActor
        ([RuntimeValue], EvalContext) throws -> RuntimeValue

    let signature: HostSignature
    let framework: String
    let resultType: String
    let invoke: Invoke

    func function(
        fallbackRuntime: GeneratedPlatformFallbackRuntime,
        fallbackEffect: GeneratedPlatformGlobalFallbackEffect
    ) throws -> HostFunction {
        try HostFunction(signature: signature) { arguments, context in
            guard GeneratedPlatformBridge.frameworkIsNative(framework) else {
                return fallbackRuntime.result(
                    for: fallbackEffect,
                    framework: framework,
                    resultType: resultType)
            }
            return try invoke(arguments.arguments.map(\.value), context)
        }
    }
}

struct GeneratedPlatformGlobalPropertyEntry {
    typealias Get = @MainActor () throws -> RuntimeValue

    let framework: String
    let name: String
    let resultType: String
    let isImplicitlyUnwrapped: Bool
    let get: Get
}

/// Per-registry state for deterministic opposite-platform behavior inferred
/// from generated global-function families. Keeping this beside the registry
/// isolates one interpreter session's context stack from every other session.
final class GeneratedPlatformFallbackRuntime {
    private var contextDepths: [String: Int] = [:]

    func result(
        for effect: GeneratedPlatformGlobalFallbackEffect,
        framework: String,
        resultType: String
    ) -> RuntimeValue {
        func key(_ context: String) -> String { "\(framework)|\(context)" }

        switch effect {
        case .plain:
            return GeneratedPlatformBridge.fallbackResult(
                framework: framework, type: resultType)
        case .pushContext(let context):
            let contextKey = key(context)
            contextDepths[contextKey, default: 0] += 1
            return GeneratedPlatformBridge.fallbackResult(
                framework: framework, type: resultType)
        case .popContext(let context):
            let contextKey = key(context)
            if let depth = contextDepths[contextKey], depth > 1 {
                contextDepths[contextKey] = depth - 1
            } else {
                contextDepths.removeValue(forKey: contextKey)
            }
            return GeneratedPlatformBridge.fallbackResult(
                framework: framework, type: resultType)
        case .currentContextValue(let context):
            guard contextDepths[key(context), default: 0] > 0,
                  let wrappedType = RuntimeOptionalValue.wrappedType(in: resultType)
            else {
                return GeneratedPlatformBridge.fallbackResult(
                    framework: framework, type: resultType)
            }
            return .some(
                GeneratedPlatformBridge.fallbackResult(
                    framework: framework, type: wrappedType),
                wrappedTypeName: wrappedType)
        }
    }
}

enum GeneratedPlatformGlobalFallbackEffect {
    case plain
    case pushContext(String)
    case popContext(String)
    case currentContextValue(String)
}

private struct GeneratedPlatformGlobalFunctionKey: Hashable {
    let framework: String
    let name: String
}

enum GeneratedPlatformPropertyFallbackSemantic {
    case renderingScale

    @MainActor
    func result() -> RuntimeValue {
        switch self {
        case .renderingScale:
            return .native(
                GeneratedPlatformEnvironmentValueProvider.renderingScale)
        }
    }
}

/// Host-side values for interface-inexpressible ambient platform semantics.
/// Generated metadata selects a semantic role; this provider knows only the
/// role and the native host environment, never the target SDK API identity.
private enum GeneratedPlatformEnvironmentValueProvider {
    @MainActor
    static var renderingScale: CGFloat {
        let candidate: CGFloat?
#if canImport(AppKit)
        candidate = NSScreen.main?.backingScaleFactor
#elseif canImport(UIKit)
        candidate = UITraitCollection.current.displayScale
#else
        candidate = nil
#endif
        guard let candidate, candidate > 0 else { return 1 }
        return candidate
    }
}

struct GeneratedPlatformPropertyEntry {
    typealias Get = @MainActor (Any) throws -> RuntimeValue
    typealias Set = @MainActor
        (inout Any, RuntimeValue, EvalContext) throws -> Void

    let framework: String
    let type: String
    let resultType: String
    let isImplicitlyUnwrapped: Bool
    let contract: HostProperty
    let semanticCarrierContract: HostProperty
    let opaqueReferenceContract: HostProperty
}

struct GeneratedPlatformStaticPropertyEntry {
    typealias Get = @MainActor () throws -> RuntimeValue

    let framework: String
    let type: String
    let name: String
    let resultType: String
    let isImplicitlyUnwrapped: Bool
    let get: Get
}

struct GeneratedPlatformEnumEntry {
    let framework: String
    let type: String
    let name: String
    let get: @MainActor () -> Any
}

struct GeneratedPlatformEqualityAdapter {
    let equals: @MainActor (Any, Any) -> Bool?
}

/// Runtime half of the generated platform bridge. The generated file only
/// contains metadata-derived registrations and statically compiled SDK calls;
/// selection, opposite-platform fallback, and value ownership live here once.
enum GeneratedPlatformBridge {
    private static let constructors = buildConstructors()
    private static let methods = buildMethods()
    private static let properties = buildProperties()
    private static let staticMethods = buildStaticMethods()
    private static let globalFunctions = buildGlobalFunctions()
    private static let globalProperties = buildGlobalProperties()
    private static let globalFallbackEffects = inferGlobalFallbackEffects(
        from: globalFunctions)
    private static let staticProperties = buildStaticProperties()
    private static let enumValues = buildEnumValues()
    private static let equalityAdapters = buildEqualityAdapters()
    private static let knownMembers = buildKnownMembers()
    private static let nominalKinds = buildNominalKinds()
    private static let supertypes = buildSupertypes()
    private static let typeAliases = buildTypeAliases()
    private static let nativeFrameworks = buildNativeFrameworks()

    static func canonicalTypeName(_ name: String) -> String {
        var current = name
        var visited: Set<String> = []
        while visited.insert(current).inserted,
              let canonical = typeAliases[current] {
            current = canonical
        }
        return current
    }

    /// A platform-call argument/result which uses the generator's direct
    /// contract representation remains a native Swift value instead of a
    /// `GeneratedPlatformValue`. Recover its interface nominal from the same
    /// generated type classification so subsequent source extensions can
    /// dispatch without an API- or runtime-type allowlist here.
    static func directRuntimeTypeName(of value: Any) -> String? {
        let observed = canonicalTypeName(
            GeneratedMembers.keyTypeName(of: value))
        return platformDirectRuntimeTypeNames.contains(observed)
            ? observed : nil
    }

    static func frameworkIsNative(_ framework: String) -> Bool {
        nativeFrameworks.contains(framework)
    }

    private static var frameworkPreference: [String] {
        let nativeSurfaces = platformFrameworkOrder.filter {
            platformSurfaceFrameworks.contains($0)
                && frameworkIsNative($0)
        }
        let support = platformFrameworkOrder.filter {
            !platformSurfaceFrameworks.contains($0)
        }
        let unavailableSurfaces = platformFrameworkOrder.filter {
            platformSurfaceFrameworks.contains($0)
                && !frameworkIsNative($0)
        }
        return nativeSurfaces + support + unavailableSurfaces
    }

    static func globalFunction(
        named name: String,
        fallbackRuntime: GeneratedPlatformFallbackRuntime
    ) -> HostFunction? {
        guard let entries = globalFunctions[name], !entries.isEmpty else {
            return nil
        }
        let ordered = frameworkPreference.flatMap { framework in
            entries.filter { $0.framework == framework }
        }
        guard !ordered.isEmpty else { return nil }
        do {
            let functions = try ordered.map { entry in
                let effect = globalFallbackEffects[
                    GeneratedPlatformGlobalFunctionKey(
                        framework: entry.framework, name: name)
                ] ?? .plain
                return try entry.function(
                    fallbackRuntime: fallbackRuntime,
                    fallbackEffect: effect)
            }
            return functions.count == 1
                ? functions[0] : try HostFunction(overloads: functions)
        } catch {
            preconditionFailure(
                "invalid generated global function set '\(name)': \(error)")
        }
    }

    /// Clang global APIs commonly express balanced state using
    /// `Begin…Context`/`End…Context` and
    /// `Get…FromCurrent…Context` naming. Infer only complete families present
    /// in the generated symbol-graph surface, so the runtime contains no SDK
    /// function-name allowlist and unrelated optional results remain nil.
    private static func inferGlobalFallbackEffects(
        from functions: [String: [GeneratedPlatformGlobalFunctionEntry]]
    ) -> [GeneratedPlatformGlobalFunctionKey: GeneratedPlatformGlobalFallbackEffect] {
        var namesByFramework: [String: Set<String>] = [:]
        for (name, entries) in functions {
            for entry in entries {
                namesByFramework[entry.framework, default: []].insert(name)
            }
        }

        var effects: [
            GeneratedPlatformGlobalFunctionKey: GeneratedPlatformGlobalFallbackEffect
        ] = [:]
        for (framework, names) in namesByFramework {
            func entries(named name: String) -> [GeneratedPlatformGlobalFunctionEntry] {
                (functions[name] ?? []).filter { $0.framework == framework }
            }

            var endNamesByContext: [String: [String]] = [:]
            for name in names {
                if let context = endContextKey(in: name),
                   entries(named: name).allSatisfy({
                       $0.resultType == "Void" && $0.signature.parameters.isEmpty
                   }) {
                    endNamesByContext[context, default: []].append(name)
                }
            }
            let endContexts = endNamesByContext.compactMapValues { names in
                names.count == 1 ? names[0] : nil
            }
            let begins = names.compactMap { name -> (String, String)? in
                guard let context = beginContextKey(in: name),
                      endContexts[context] != nil,
                      entries(named: name).allSatisfy({ $0.resultType == "Void" })
                else { return nil }
                return (name, context)
            }
            let activeContexts = Set(begins.map(\.1))
            for (name, context) in begins {
                effects[.init(framework: framework, name: name)] =
                    .pushContext(context)
            }
            for context in activeContexts {
                if let name = endContexts[context] {
                    effects[.init(framework: framework, name: name)] =
                        .popContext(context)
                }
            }
            for name in names {
                guard let context = currentContextKey(in: name),
                      activeContexts.contains(context),
                      entries(named: name).allSatisfy({
                          $0.signature.parameters.isEmpty
                              && RuntimeOptionalValue.wrappedType(
                                  in: $0.resultType) != nil
                      })
                else { continue }
                effects[.init(framework: framework, name: name)] =
                    .currentContextValue(context)
            }
        }
        return effects
    }

    private static func beginContextKey(in name: String) -> String? {
        guard let marker = name.range(of: "Begin") else { return nil }
        let prefix = name[..<marker.lowerBound]
        let remainder = name[marker.upperBound...]
        guard let context = remainder.range(of: "Context") else { return nil }
        let suffix = remainder[context.upperBound...]
        guard suffix.isEmpty || suffix.hasPrefix("With") else { return nil }
        return String(prefix + remainder[..<context.upperBound])
    }

    private static func endContextKey(in name: String) -> String? {
        guard let marker = name.range(of: "End") else { return nil }
        let prefix = name[..<marker.lowerBound]
        let remainder = name[marker.upperBound...]
        guard remainder.hasSuffix("Context") else { return nil }
        return String(prefix + remainder)
    }

    private static func currentContextKey(in name: String) -> String? {
        guard let get = name.range(of: "Get"),
              let current = name.range(
                  of: "FromCurrent", range: get.upperBound..<name.endIndex)
        else { return nil }
        let prefix = name[..<get.lowerBound]
        let context = name[current.upperBound...]
        guard context.hasSuffix("Context") else { return nil }
        return String(prefix + context)
    }

    static func nativeConstructor(named name: String) -> HostFunction? {
        constructor(named: name, nativeOnly: true)
    }

    /// A source subclass cannot itself cross into native storage, but its
    /// inherited SDK properties can use a native base instance when the
    /// generated interface proves that base is zero-argument constructible.
    /// Select from the raw generated entries so compatibility constructor
    /// fallbacks cannot manufacture that proof.
    static func hostSuperclassBacking(
        named rawName: String, in context: EvalContext
    ) throws -> RuntimeValue? {
        let name = generatedNominalName(rawName)
        guard let entries = constructors[name] else { return nil }
        let arguments = CallArguments()
        for framework in frameworkPreference where frameworkIsNative(framework) {
            for entry in entries where entry.framework == framework {
                guard entry.function.signatures.contains(where: {
                    $0.match(arguments: arguments, in: context) != nil
                }) else { continue }
                return try entry.function.invoke(arguments, context)
            }
        }
        return nil
    }

    static func constructor(named name: String) -> HostFunction? {
        constructor(named: name, nativeOnly: false)
    }

    private static func constructor(
        named name: String, nativeOnly: Bool
    ) -> HostFunction? {
        guard let entries = constructors[name] else { return nil }
        for framework in frameworkPreference {
            if nativeOnly, !frameworkIsNative(framework) { continue }
            let candidates = entries.filter { $0.framework == framework }
            guard !candidates.isEmpty else { continue }
            do {
                let typed = candidates.count == 1
                    ? candidates[0].function
                    : try HostFunction(overloads: candidates.map(\.function))
                let type = candidates[0].type
                // Symbol graphs omit some inherited/importer-synthesized
                // initializer shapes. Preserve the established compiled-import
                // absorber only when none of the generated declarations can
                // accept this call; matched calls retain the full typed
                // contract and statically compiled native implementation.
                return HostFunction(name: name) { arguments, context in
                    if typed.signatures.contains(where: {
                        $0.match(arguments: arguments, in: context) != nil
                    }) {
                        return try typed.invoke(arguments, context)
                    }
                    var config: [String: RuntimeValue] = [:]
                    for (index, argument) in arguments.arguments.enumerated() {
                        config[argument.label ?? "_\(index)"] = argument.value
                    }
                    return .native(GeneratedPlatformValue(
                        framework: framework,
                        typeName: type,
                        isValueType: isValueType(framework: framework, type: type),
                        payload: nil,
                        config: config))
                }
            } catch {
                preconditionFailure(
                    "invalid generated \(framework) constructor set '\(name)': \(error)")
            }
        }
        return nil
    }

    static func globalValue(
        named name: String,
        applicationShells: FrameworkApplicationShellStore
    ) -> RuntimeValue? {
        guard let entries = globalProperties[name], !entries.isEmpty else {
            return nil
        }
        for framework in frameworkPreference {
            guard let entry = entries.first(where: { $0.framework == framework }) else {
                continue
            }
            let valueType = optionalWrappedType(entry.resultType) ?? entry.resultType
            if let application = applicationShells.sharedApplication(
                ofType: valueType) {
                let value = RuntimeValue.native(application)
                return applyingImplicitlyUnwrappedOptional(
                    .some(value, wrappedTypeName: valueType),
                    resultType: entry.resultType,
                    isImplicitlyUnwrapped: entry.isImplicitlyUnwrapped)
            }
            guard frameworkIsNative(entry.framework) else {
                return applyingImplicitlyUnwrappedOptional(
                    fallbackResult(
                        framework: entry.framework, type: entry.resultType),
                    resultType: entry.resultType,
                    isImplicitlyUnwrapped: entry.isImplicitlyUnwrapped)
            }
            do {
                return applyingImplicitlyUnwrappedOptional(
                    try entry.get(), resultType: entry.resultType,
                    isImplicitlyUnwrapped: entry.isImplicitlyUnwrapped)
            } catch {
                preconditionFailure(
                    "generated \(entry.framework) global property '\(name)' threw \(error)")
            }
        }
        return nil
    }

    /// A value minted by one framework's sweep can be a type OWNED by
    /// another (MKMapCamera.centerCoordinate returns CoreLocation's
    /// CLLocationCoordinate2D) — member lookup searches the owning
    /// framework first, then every other swept framework.
    private static func memberSearchFrameworks(
        for base: GeneratedPlatformValue
    ) -> [String] {
        [base.framework] + frameworkPreference.filter { $0 != base.framework }
    }

    static func member(_ name: String, on base: GeneratedPlatformValue) -> RuntimeValue? {
        if let stored = base.config[name] { return stored }
        let entries = memberSearchFrameworks(for: base).lazy
            .flatMap { framework in
                typeCandidates(framework: framework, type: base.typeName)
                    .compactMap {
                        methods[GeneratedPlatformMemberKey(
                            framework: framework, type: $0, member: name)]
                    }
            }.first { !$0.isEmpty }
        guard let entries else {
            return unresolvedKnownMember(name, on: base)
        }
        do {
            let functions = try entries.map { try $0.bound(to: base) }
            return .hostFunction(
                functions.count == 1 ? functions[0] : try HostFunction(overloads: functions))
        } catch {
            preconditionFailure(
                "invalid generated \(base.framework) member set '\(base.typeName).\(name)': \(error)")
        }
    }

    static func method(_ name: String, on base: GeneratedPlatformValue) -> RuntimeValue? {
        let entries = memberSearchFrameworks(for: base).lazy
            .flatMap { framework in
                typeCandidates(framework: framework, type: base.typeName)
                    .compactMap {
                        methods[GeneratedPlatformMemberKey(
                            framework: framework, type: $0, member: name)]
                    }
            }.first { !$0.isEmpty }
        guard let entries else {
            return unresolvedKnownMember(name, on: base, callableOnly: true)
        }
        do {
            let functions = try entries.map { try $0.bound(to: base) }
            return .hostFunction(
                functions.count == 1 ? functions[0] : try HostFunction(overloads: functions))
        } catch {
            preconditionFailure(
                "invalid generated \(base.framework) method set '\(base.typeName).\(name)': \(error)")
        }
    }

    static func property(_ name: String, on base: GeneratedPlatformValue) -> HostProperty? {
        for framework in memberSearchFrameworks(for: base) {
            for type in typeCandidates(framework: framework, type: base.typeName) {
                if let property = properties[GeneratedPlatformMemberKey(
                    framework: framework, type: type, member: name)] {
                    return property.contract
                }
            }
        }
        return nil
    }

    /// Match a semantic carrier by generated receiver metadata. An exact
    /// typed value is usable only when that result type identifies one unique
    /// property on the receiver; every other property keeps the generated
    /// interface fallback rather than becoming an untyped missing member.
    static func property(
        _ name: String,
        onSemanticCarrier base: any GeneratedPlatformTypedPropertyCarrier
    ) -> HostProperty? {
        let frameworks = [base.generatedPlatformFramework]
            + frameworkPreference.filter {
                $0 != base.generatedPlatformFramework
            }
        for framework in frameworks {
            let receiverTypes = typeCandidates(
                framework: framework,
                type: base.generatedPlatformTypeName)
            for receiverType in receiverTypes {
                let key = GeneratedPlatformMemberKey(
                    framework: framework,
                    type: receiverType,
                    member: name)
                guard let property = properties[key] else { continue }
                let resultType = generatedNominalName(property.resultType)
                let hasTypedValue =
                    base.generatedPlatformTypedPropertyValues.contains(
                    where: {
                        generatedNominalName($0.typeName) == resultType
                    })
                if hasTypedValue {
                    let matchingMembers = Set(properties.compactMap {
                        candidateKey, candidate -> String? in
                        guard candidateKey.framework == framework,
                              receiverTypes.contains(candidateKey.type),
                              generatedNominalName(candidate.resultType)
                                == resultType
                        else {
                            return nil
                        }
                        return candidateKey.member
                    })
                    guard matchingMembers == Set([name]) else { continue }
                }
                return property.semanticCarrierContract
            }
        }
        return nil
    }

    /// Select a generated property from an opaque carrier's declared SDK
    /// roles. Only non-native reference nominals qualify: a native framework
    /// must still receive its concrete object, while an off-host reference
    /// executes the same typed fallback result as GeneratedPlatformValue.
    static func property(
        _ name: String,
        onOpaqueReference base: any GeneratedPlatformOpaqueReferenceCarrier
    ) -> HostProperty? {
        for rawType in base.generatedPlatformOpaqueTypeNames {
            let typeName = generatedNominalName(rawType)
            guard let owner = owningFramework(
                    ofType: typeName, preferring: frameworkPreference[0]),
                  !frameworkIsNative(owner),
                  nominalKinds[GeneratedPlatformTypeKey(
                    framework: owner, type: typeName)] == false
            else {
                continue
            }
            let frameworks = [owner] + frameworkPreference.filter {
                $0 != owner
            }
            for framework in frameworks {
                for type in typeCandidates(
                    framework: framework, type: typeName
                ) {
                    if let property = properties[
                        GeneratedPlatformMemberKey(
                            framework: framework, type: type, member: name)
                    ] {
                        // Interface optionality permits absence; without a
                        // payload it does not prove that this opaque runtime
                        // value is absent. Preserve explicitly configured
                        // optionals, but otherwise leave unknown presence to
                        // the carrier's established fallback policy.
                        guard base.generatedPlatformOpaqueConfiguration[
                                name] != nil
                                || (optionalWrappedType(
                                    property.resultType) == nil
                                    && !property.isImplicitlyUnwrapped)
                        else {
                            continue
                        }
                        return property.opaqueReferenceContract
                    }
                }
            }
        }
        return nil
    }

    private static func unresolvedKnownMember(
        _ name: String,
        on base: GeneratedPlatformValue,
        callableOnly: Bool = false
    ) -> RuntimeValue? {
        for framework in memberSearchFrameworks(for: base) {
        for type in typeCandidates(framework: framework, type: base.typeName)
        {
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: name)
            guard let isCallable = knownMembers[key],
                  !callableOnly || isCallable else { continue }
            return .native(ChainedImplicitCall(
                base: .native(base), member: name,
                arguments: CallArguments()))
        }
        }
        return nil
    }

    static func staticMember(_ name: String, typeName: String) -> RuntimeValue? {
        for framework in frameworkPreference {
            for type in typeCandidates(framework: framework, type: typeName) {
                let key = GeneratedPlatformMemberKey(
                    framework: framework, type: type, member: name)
                if let property = staticProperties[key] {
                    if frameworkIsNative(framework) {
                        return try? applyingImplicitlyUnwrappedOptional(
                            property.get(), resultType: property.resultType,
                            isImplicitlyUnwrapped:
                                property.isImplicitlyUnwrapped)
                    }
                    return staticPropertyFallback(property)
                }
                if let cases = enumValues[key], let value = cases.first {
                    if frameworkIsNative(framework) {
                        return generatedPlatformResult(
                            value.get(), framework: framework,
                            declaredType: value.type)
                    }
                    return fallbackResult(framework: framework, type: value.type)
                }
                if let entries = staticMethods[key], !entries.isEmpty {
                    do {
                        let functions = try entries.map { try $0.function() }
                        return .hostFunction(
                            functions.count == 1
                                ? functions[0]
                                : try HostFunction(overloads: functions))
                    } catch {
                        preconditionFailure(
                            "invalid generated \(framework) static set '\(typeName).\(name)': \(error)")
                    }
                }
            }
        }
        return nil
    }

    static func enumPayload(
        framework: String, type: String, member: String
    ) -> Any? {
        let key = GeneratedPlatformMemberKey(
            framework: framework, type: type, member: member)
        guard frameworkIsNative(framework), let value = enumValues[key]?.first else {
            return nil
        }
        return value.get()
    }

    static func payloadsEqual(
        framework: String, type: String,
        _ lhs: Any, _ rhs: Any
    ) -> Bool? {
        equalityAdapters[GeneratedPlatformTypeKey(
            framework: framework, type: type)]?.equals(lhs, rhs)
    }

    static func isValueType(framework: String, type: String) -> Bool {
        guard let owner = owningFramework(ofType: type, preferring: framework) else {
            return true
        }
        return nominalKinds[GeneratedPlatformTypeKey(framework: owner, type: type)] ?? true
    }

    static func isPlatformNominal(framework: String, type: String) -> Bool {
        owningFramework(ofType: type, preferring: framework) != nil
    }

    /// Match a concrete generated carrier through its metadata-derived
    /// superclass graph. This is registry type-system data, not Swift type
    /// identity: opposite-platform values deliberately have no SDK payload.
    static func value(_ value: Any, matchesType rawType: String) -> Bool {
        guard let platform = value as? GeneratedPlatformValue else {
            return false
        }
        let expected = generatedNominalName(rawType)
        return typeCandidates(
            framework: platform.framework, type: platform.typeName
        ).contains { generatedNominalName($0) == expected }
    }

    /// Traverse the generated nominal graph by type property rather than by
    /// runtime identity. The graph intentionally unions framework entries:
    /// an SDK type imported by another module (WKWebView -> UIKit.UIView) has
    /// its direct edge in the declaring framework and the rest of its ancestry
    /// in the parent's framework.
    static func importedType(
        named rawType: String, matchesType rawExpectedType: String
    ) -> Bool {
        let expected = generatedNominalName(rawExpectedType)
        var queue = [generatedNominalName(rawType)]
        var seen = Set<String>()
        while !queue.isEmpty {
            let type = queue.removeFirst()
            guard seen.insert(type).inserted else { continue }
            if type == expected { return true }
            for (key, parents) in supertypes
            where generatedNominalName(key.type) == type {
                queue.append(contentsOf: parents.map(generatedNominalName))
            }
        }
        return false
    }

    /// An opaque imported object may stand in for a generated reference
    /// nominal only when that framework is absent on this host. Generated
    /// dispatch then takes its typed inert path and never attempts a native
    /// cast. Value types stay strict because their observable data shape is
    /// encoded by the interface and must be coercible.
    static func acceptsOpaqueReference(for rawType: String) -> Bool {
        let type = generatedNominalName(rawType)
        guard let owner = owningFramework(
            ofType: type, preferring: frameworkPreference[0]
        ) else { return false }
        return !frameworkIsNative(owner)
            && nominalKinds[GeneratedPlatformTypeKey(
                framework: owner, type: type)] == false
    }

    /// Source type context turns an unresolved compiled-import chain into the
    /// same generated carrier used by an off-host SDK call. Nominal kind,
    /// framework ownership, and native availability all come from swept
    /// metadata; callers never classify a concrete SDK type by identity.
    static func contextualizedOpaqueReference(
        named rawType: String
    ) -> RuntimeValue? {
        let type = generatedNominalName(rawType)
        guard let owner = owningFramework(
                ofType: type, preferring: frameworkPreference[0]),
              !frameworkIsNative(owner),
              nominalKinds[GeneratedPlatformTypeKey(
                  framework: owner, type: type)] == false
        else {
            return nil
        }
        return .native(GeneratedPlatformValue(
            framework: owner,
            typeName: type,
            isValueType: false,
            payload: nil))
    }

    private static func generatedNominalName(_ rawType: String) -> String {
        var type = (optionalWrappedType(rawType) ?? rawType)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for framework in frameworkPreference
        where type.hasPrefix(framework + ".") {
            type.removeFirst(framework.count + 1)
            break
        }
        return canonicalTypeName(type)
    }

    /// The framework whose sweep DECLARED a type. A member of one framework
    /// can return a type owned by another (MKMapCamera.centerCoordinate is
    /// CoreLocation's CLLocationCoordinate2D) — results are minted under the
    /// owning framework so member lookup finds the type's surface.
    static func owningFramework(
        ofType type: String, preferring framework: String
    ) -> String? {
        if nominalKinds[GeneratedPlatformTypeKey(framework: framework, type: type)] != nil {
            return framework
        }
        return frameworkPreference.first {
            nominalKinds[GeneratedPlatformTypeKey(framework: $0, type: type)] != nil
        }
    }

    static func typeCandidates(framework: String, type: String) -> [String] {
        var result: [String] = []
        var queue: [String] = [type]
        var seen = Set<String>()
        while !queue.isEmpty {
            let value = queue.removeFirst()
            guard seen.insert(value).inserted else { continue }
            result.append(value)
            queue.append(contentsOf: supertypes[GeneratedPlatformTypeKey(
                framework: framework, type: value)] ?? [])
        }
        return result
    }

    static func fallbackResult(framework: String, type rawType: String) -> RuntimeValue {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wrapped = optionalWrappedType(type) {
            return .none(wrappedTypeName: wrapped)
        }
        if dictionaryComponentTypes(type) != nil {
            return .native(DictValue())
        }
        if collectionElementType(type) != nil { return .native([RuntimeValue]()) }
        switch type {
        case "Void", "()": return .void
        case "Bool": return .native(false)
        case "String", "Substring", "Character": return .native("")
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return .native(0)
        case "Double", "Float", "CGFloat", "TimeInterval":
            return .native(0.0)
        case "CGPoint": return .native(CGPoint.zero)
        case "CGSize": return .native(CGSize.zero)
        case "CGRect": return .native(CGRect.zero)
        case "CGVector": return .native(CGVector.zero)
        case "CGAffineTransform": return .native(CGAffineTransform.identity)
        case "NSRange": return .native(NSRange(location: 0, length: 0))
        default:
            return .native(GeneratedPlatformValue(
                framework: framework,
                typeName: type,
                isValueType: isValueType(framework: framework, type: type),
                payload: nil))
        }
    }

    /// Swift symbol graphs preserve imported `T!` spelling even though the
    /// executable bridge contract uses `T?`. Reapply that source semantic at
    /// the shared dispatch boundary so native payloads, inert fallbacks, and
    /// configured launch-shell values all behave identically.
    private static func applyingImplicitlyUnwrappedOptional(
        _ value: RuntimeValue,
        resultType: String,
        isImplicitlyUnwrapped: Bool
    ) -> RuntimeValue {
        guard isImplicitlyUnwrapped else { return value }
        let wrappedType = optionalWrappedType(resultType) ?? resultType
        switch value {
        case .optional(let optional):
            return .optional(
                optional.wrapped,
                wrappedTypeName: optional.wrappedTypeName ?? wrappedType,
                isImplicitlyUnwrapped: true)
        case .nilValue:
            return .none(
                wrappedTypeName: wrappedType,
                isImplicitlyUnwrapped: true)
        default:
            return .some(
                value, wrappedTypeName: wrappedType,
                isImplicitlyUnwrapped: true)
        }
    }

    /// Static SDK strings are commonly identity-bearing constants rather than
    /// user-visible empty text (URL schemes, notification names, pasteboard
    /// types, and similar tokens). On the opposite platform their bytes are
    /// unknowable, so preserve the generated symbol as an opaque value instead
    /// of inventing `""`. Gateways such as `URL(string:)` can then propagate
    /// that uncertainty without turning a valid native constant into `nil`.
    private static func staticPropertyFallback(
        _ property: GeneratedPlatformStaticPropertyEntry
    ) -> RuntimeValue {
        let resultType = property.resultType.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard resultType == "String" || resultType == "Substring"
                || resultType == "Character" else {
            return applyingImplicitlyUnwrappedOptional(
                fallbackResult(
                    framework: property.framework, type: property.resultType),
                resultType: property.resultType,
                isImplicitlyUnwrapped: property.isImplicitlyUnwrapped)
        }
        return .native(ChainedImplicitCall(
            base: .implicitMember("\(property.framework).\(property.type)"),
            member: property.name,
            arguments: CallArguments()))
    }

    // MARK: Generated registration API

    static func registerConstructor(
        _ table: inout [String: [GeneratedPlatformConstructorEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        semanticAdapter:
            GeneratedPlatformConstructorSemanticAdapter? = nil,
        invoke: @escaping @MainActor
            ([RuntimeValue], EvalContext) throws -> RuntimeValue
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            let function = try HostFunction(signature: signature) { arguments, context in
                let values = arguments.arguments.map(\.value)
                if let result = try semanticAdapter?(values, context) {
                    return signature.isFailable
                        ? .some(result, wrappedTypeName: resultType)
                        : result
                }
                if !frameworkIsNative(framework) {
                    var config: [String: RuntimeValue] = [:]
                    for argument in arguments.arguments {
                        if let label = argument.label { config[label] = argument.value }
                    }
                    let value = RuntimeValue.native(GeneratedPlatformValue(
                        framework: framework,
                        typeName: resultType,
                        isValueType: isValueType(framework: framework, type: resultType),
                        payload: nil,
                        config: config))
                    return signature.isFailable
                        ? .some(value, wrappedTypeName: resultType)
                        : value
                }
                return try invoke(values, context)
            }
            table[signature.callableName, default: []].append(
                GeneratedPlatformConstructorEntry(
                    framework: framework, type: resultType, function: function))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform constructor '\(declaration)': \(error)")
        }
    }

    static func registerMethod(
        _ table: inout [GeneratedPlatformMemberKey: [GeneratedPlatformMethodEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        semanticAdapter: GeneratedPlatformMethodEntry.SemanticAdapter? = nil,
        invoke: @escaping GeneratedPlatformMethodEntry.Invoke
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard let type = signature.receiverType else {
                preconditionFailure("generated platform method has no receiver: \(declaration)")
            }
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: signature.name)
            table[key, default: []].append(GeneratedPlatformMethodEntry(
                signature: signature, framework: framework,
                resultType: resultType,
                semanticAdapter: semanticAdapter,
                invoke: invoke))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform method '\(declaration)': \(error)")
        }
    }

    static func registerStaticMethod(
        _ table: inout [GeneratedPlatformMemberKey: [GeneratedPlatformStaticMethodEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        invoke: @escaping GeneratedPlatformStaticMethodEntry.Invoke
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard let type = signature.receiverType else {
                preconditionFailure("generated platform static method has no receiver: \(declaration)")
            }
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: signature.name)
            table[key, default: []].append(GeneratedPlatformStaticMethodEntry(
                signature: signature, framework: framework,
                resultType: resultType, invoke: invoke))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform static method '\(declaration)': \(error)")
        }
    }

    static func registerGlobalFunction(
        _ table: inout [String: [GeneratedPlatformGlobalFunctionEntry]],
        framework: String,
        declaration: String,
        resultType: String,
        invoke: @escaping GeneratedPlatformGlobalFunctionEntry.Invoke
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            table[signature.callableName, default: []].append(
                GeneratedPlatformGlobalFunctionEntry(
                    signature: signature, framework: framework,
                    resultType: resultType, invoke: invoke))
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform global '\(declaration)': \(error)")
        }
    }

    static func registerGlobalProperty(
        _ table: inout [String: [GeneratedPlatformGlobalPropertyEntry]],
        framework: String,
        name: String,
        resultType: String,
        isImplicitlyUnwrapped: Bool,
        get: @escaping GeneratedPlatformGlobalPropertyEntry.Get
    ) {
        table[name, default: []].append(GeneratedPlatformGlobalPropertyEntry(
            framework: framework,
            name: name,
            resultType: resultType,
            isImplicitlyUnwrapped: isImplicitlyUnwrapped,
            get: get))
    }

    static func registerProperty(
        _ table: inout [GeneratedPlatformMemberKey: GeneratedPlatformPropertyEntry],
        framework: String,
        declaration: String,
        resultType: String,
        isImplicitlyUnwrapped: Bool = false,
        fallbackSemantic: GeneratedPlatformPropertyFallbackSemantic? = nil,
        get: @escaping GeneratedPlatformPropertyEntry.Get,
        set: GeneratedPlatformPropertyEntry.Set?
    ) {
        do {
            let signature = try HostSignature(parsing: declaration)
            guard let type = signature.receiverType else {
                preconditionFailure("generated platform property has no receiver: \(declaration)")
            }
            let propertySetter: HostProperty.Setter?
            if let set {
                propertySetter = { receiver, value, context in
                    guard case .host(let any) = receiver,
                          let base = any as? GeneratedPlatformValue else {
                        throw RuntimeError(
                            message: "generated platform property setter receiver mismatch",
                            fatal: true)
                    }
                    guard frameworkIsNative(framework), var payload = base.payload else {
                        base.config[signature.name] = value
                        return
                    }
                    try set(&payload, value, context)
                    base.payload = payload
                }
            } else {
                propertySetter = nil
            }
            let contract = try HostProperty(
                signature: signature,
                get: { receiver, _ in
                    guard case .host(let any) = receiver,
                          let base = any as? GeneratedPlatformValue else {
                        throw RuntimeError(
                            message: "generated platform property receiver mismatch",
                            fatal: true)
                    }
                    if let stored = base.config[signature.name] {
                        return applyingImplicitlyUnwrappedOptional(
                            stored, resultType: resultType,
                            isImplicitlyUnwrapped: isImplicitlyUnwrapped)
                    }
                    guard frameworkIsNative(framework), let payload = base.payload else {
                        return applyingImplicitlyUnwrappedOptional(
                            fallbackSemantic?.result()
                                ?? fallbackResult(
                                    framework: framework, type: resultType),
                            resultType: resultType,
                            isImplicitlyUnwrapped: isImplicitlyUnwrapped)
                    }
                    return applyingImplicitlyUnwrappedOptional(
                        try get(payload), resultType: resultType,
                        isImplicitlyUnwrapped: isImplicitlyUnwrapped)
                },
                set: propertySetter)
            let semanticCarrierSetter: HostProperty.Setter?
            if set != nil {
                semanticCarrierSetter = { _, _, _ in
                    throw RuntimeError(
                        message: "generated platform semantic properties "
                            + "are read-only",
                        fatal: true)
                }
            } else {
                semanticCarrierSetter = nil
            }
            let semanticCarrierContract = try HostProperty(
                signature: signature,
                get: { receiver, _ in
                    guard case .host(let any) = receiver,
                          let base = any as?
                            any GeneratedPlatformTypedPropertyCarrier
                    else {
                        throw RuntimeError(
                            message: "generated platform semantic property "
                                + "receiver mismatch",
                            fatal: true)
                    }
                    let expectedType = generatedNominalName(resultType)
                    let value = base.generatedPlatformTypedPropertyValues
                        .first {
                            generatedNominalName($0.typeName) == expectedType
                        }?.value
                        ?? fallbackResult(
                            framework: framework, type: resultType)
                    return applyingImplicitlyUnwrappedOptional(
                        value, resultType: resultType,
                        isImplicitlyUnwrapped: isImplicitlyUnwrapped)
                },
                set: semanticCarrierSetter)
            let opaqueReferenceSetter: HostProperty.Setter?
            if set != nil {
                opaqueReferenceSetter = { receiver, value, _ in
                    guard case .host(let any) = receiver,
                          let base = any as?
                            any GeneratedPlatformOpaqueReferenceCarrier
                    else {
                        throw RuntimeError(
                            message: "generated platform opaque property "
                                + "setter receiver mismatch",
                            fatal: true)
                    }
                    var configuration =
                        base.generatedPlatformOpaqueConfiguration
                    configuration[signature.name] = value
                    base.generatedPlatformOpaqueConfiguration = configuration
                }
            } else {
                opaqueReferenceSetter = nil
            }
            let opaqueReferenceContract = try HostProperty(
                signature: signature,
                get: { receiver, _ in
                    guard case .host(let any) = receiver,
                          let base = any as?
                            any GeneratedPlatformOpaqueReferenceCarrier
                    else {
                        throw RuntimeError(
                            message: "generated platform opaque property "
                                + "receiver mismatch",
                            fatal: true)
                    }
                    let value = base.generatedPlatformOpaqueConfiguration[
                        signature.name
                    ] ?? fallbackResult(
                        framework: framework, type: resultType)
                    return applyingImplicitlyUnwrappedOptional(
                        value, resultType: resultType,
                        isImplicitlyUnwrapped: isImplicitlyUnwrapped)
                },
                set: opaqueReferenceSetter)
            let key = GeneratedPlatformMemberKey(
                framework: framework, type: type, member: signature.name)
            table[key] = GeneratedPlatformPropertyEntry(
                framework: framework, type: type,
                resultType: resultType,
                isImplicitlyUnwrapped: isImplicitlyUnwrapped,
                contract: contract,
                semanticCarrierContract: semanticCarrierContract,
                opaqueReferenceContract: opaqueReferenceContract)
        } catch {
            preconditionFailure(
                "BridgeGen emitted an invalid platform property '\(declaration)': \(error)")
        }
    }

    static func registerStaticProperty(
        _ table: inout [GeneratedPlatformMemberKey: GeneratedPlatformStaticPropertyEntry],
        framework: String,
        type: String,
        name: String,
        resultType: String,
        isImplicitlyUnwrapped: Bool = false,
        get: @escaping GeneratedPlatformStaticPropertyEntry.Get
    ) {
        table[GeneratedPlatformMemberKey(
            framework: framework, type: type, member: name)] =
            GeneratedPlatformStaticPropertyEntry(
                framework: framework, type: type, name: name,
                resultType: resultType,
                isImplicitlyUnwrapped: isImplicitlyUnwrapped,
                get: get)
    }

    static func registerEnumValue(
        _ table: inout [GeneratedPlatformMemberKey: [GeneratedPlatformEnumEntry]],
        framework: String,
        type: String,
        name: String,
        get: @escaping @MainActor () -> Any
    ) {
        let key = GeneratedPlatformMemberKey(
            framework: framework, type: type, member: name)
        table[key, default: []].append(GeneratedPlatformEnumEntry(
            framework: framework, type: type, name: name, get: get))
    }

    static func registerEqualityAdapter<T: Equatable>(
        _ table: inout [GeneratedPlatformTypeKey: GeneratedPlatformEqualityAdapter],
        framework: String,
        type: String,
        _: T.Type
    ) {
        table[GeneratedPlatformTypeKey(framework: framework, type: type)] =
            GeneratedPlatformEqualityAdapter { lhs, rhs in
                guard let lhs = lhs as? T, let rhs = rhs as? T else { return nil }
                return lhs == rhs
            }
    }
}

// MARK: - Generated argument/result conversions

/// Submit an interpreter-owned lifecycle object through the same delivery
/// policy as other host schedulers. The generator emits this handoff only
/// when SDK metadata says the receiver conforms to `Scheduler` and its sole
/// parameter type declares the supplied zero-argument lifecycle entry point.
/// Native parameter values continue through the statically compiled SDK call.
@MainActor
func generatedPlatformScheduleInterpretedLifecycle(
    _ value: RuntimeValue,
    entryPoint: String,
    context: EvalContext
) -> Bool {
    let action: ActionValue
    if case .instance(let instance) = value,
       let interpreter = context as? Interpreter {
        action = ActionValue(run: {
            _ = try? interpreter.callMethod(
                named: entryPoint, on: instance, arguments: [])
        })
    } else if case .host(let raw) = value,
              let platform = raw as? GeneratedPlatformValue,
              platform.interpretedLifecycleEntryPoint == entryPoint,
              let closure =
                platform.interpretedLifecycleAction?.closureValue {
        action = ActionValue(run: {
            _ = try? context.callHostCallback(closure, arguments: [])
        })
    } else {
        return false
    }
    MainQueueDrain.schedule(
        action,
        after: 0,
        mode: MainQueueDrain.deliveryMode(for: context))
    return true
}

/// Preserve an interpreted action carried by a generated SDK subclass until
/// its metadata-derived lifecycle scheduler submits it. The generated
/// constructor selects this adapter only for a single-action initializer on a
/// subclass of a scheduler's lifecycle parameter, so neither a type nor a
/// constructor identity is encoded here.
@MainActor
func generatedPlatformDeferredLifecycleAction(
    _ value: RuntimeValue,
    framework: String,
    type: String,
    entryPoint: String
) -> RuntimeValue? {
    guard value.closureValue != nil else { return nil }
    return .native(GeneratedPlatformValue(
        framework: framework,
        typeName: type,
        isValueType: false,
        payload: nil,
        interpretedLifecycleEntryPoint: entryPoint,
        interpretedLifecycleAction: value))
}

/// Closure counterpart to the lifecycle-object adapter above. SDK metadata
/// selects this only for a Scheduler's single action parameter; callback
/// execution then follows the registry's one actor-safe delivery policy.
@MainActor
func generatedPlatformScheduleInterpretedAction(
    _ value: RuntimeValue,
    context: EvalContext
) -> Bool {
    guard let closure = value.closureValue else { return false }
    let action = ActionValue(run: {
        _ = try? context.callHostCallback(closure, arguments: [])
    })
    MainQueueDrain.schedule(
        action,
        after: 0,
        mode: MainQueueDrain.deliveryMode(for: context))
    return true
}

private protocol GeneratedPlatformRuntimeConvertible {
    static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any
}

extension Optional: GeneratedPlatformRuntimeConvertible {
    fileprivate static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any {
        let wrappedType = optionalWrappedType(typeName) ?? typeName
        switch value.optionalState {
        case .none:
            let result: Wrapped? = nil
            return result as Any
        case .some(let wrapped, _):
            let result: Wrapped? = try generatedPlatformArgument(
                wrapped, as: Wrapped.self, framework: framework,
                typeName: wrappedType, context: context)
            return result as Any
        case .notOptional:
            let result: Wrapped? = try generatedPlatformArgument(
                value, as: Wrapped.self, framework: framework,
                typeName: wrappedType, context: context)
            return result as Any
        }
    }
}

extension Array: GeneratedPlatformRuntimeConvertible {
    fileprivate static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any {
        guard let values = value.collectionElements else {
            throw RuntimeError(message: "expected an Array for '\(typeName)'")
        }
        let elementType = collectionElementType(typeName) ?? "Element"
        return try values.map {
            try generatedPlatformArgument(
                $0, as: Element.self, framework: framework,
                typeName: elementType, context: context)
        }
    }
}

extension Dictionary: GeneratedPlatformRuntimeConvertible {
    fileprivate static func generatedPlatformValue(
        from value: RuntimeValue,
        framework: String,
        typeName: String,
        context: EvalContext
    ) throws -> Any {
        guard let dictionary = value.dictValue else {
            throw RuntimeError(message: "expected a Dictionary for '\(typeName)'")
        }
        let componentTypes = dictionaryComponentTypes(typeName)
            ?? (String(describing: Key.self), String(describing: Value.self))
        var result: [Key: Value] = [:]
        for (key, entry) in zip(dictionary.keys, dictionary.values) {
            result[try generatedPlatformArgument(
                key, as: Key.self, framework: framework,
                typeName: componentTypes.0, context: context)] =
                try generatedPlatformArgument(
                    entry, as: Value.self, framework: framework,
                    typeName: componentTypes.1, context: context)
        }
        return result
    }
}

func generatedPlatformWithUnsafeRawPointer(
    _ value: RuntimeValue,
    context _: EvalContext,
    body: (UnsafeRawPointer) throws -> RuntimeValue
) throws -> RuntimeValue {
    let data = try RuntimeABIMemory.data(from: value)
    return try data.withUnsafeBytes { bytes in
        guard let pointer = bytes.baseAddress else {
            throw RuntimeError(message: "cannot pass an empty value as an unsafe pointer")
        }
        return try body(pointer)
    }
}

func generatedPlatformPointerResult(
    _ pointer: UnsafeMutableRawPointer,
    owner: Any?,
    declaredType _: String
) -> RuntimeValue {
    .native(GeneratedPlatformRawMemory(
        pointer: UnsafeRawPointer(pointer), mutablePointer: pointer, owner: owner))
}

func generatedPlatformPointerResult(
    _ pointer: UnsafeRawPointer,
    owner: Any?,
    declaredType _: String
) -> RuntimeValue {
    .native(GeneratedPlatformRawMemory(
        pointer: pointer, mutablePointer: nil, owner: owner))
}

func generatedPlatformPointerResult(
    _ pointer: UnsafeMutableRawPointer?,
    owner: Any?,
    declaredType: String
) -> RuntimeValue {
    let wrappedType = optionalWrappedType(declaredType) ?? "Any"
    guard let pointer else { return .none(wrappedTypeName: wrappedType) }
    return .some(
        generatedPlatformPointerResult(
            pointer, owner: owner, declaredType: wrappedType),
        wrappedTypeName: wrappedType)
}

func generatedPlatformPointerResult(
    _ pointer: UnsafeRawPointer?,
    owner: Any?,
    declaredType: String
) -> RuntimeValue {
    let wrappedType = optionalWrappedType(declaredType) ?? "Any"
    guard let pointer else { return .none(wrappedTypeName: wrappedType) }
    return .some(
        generatedPlatformPointerResult(
            pointer, owner: owner, declaredType: wrappedType),
        wrappedTypeName: wrappedType)
}

func generatedPlatformPointerResult(
    _ pointer: UnsafeMutablePointer<UInt8>,
    owner: Any?,
    declaredType _: String
) -> RuntimeValue {
    let raw = UnsafeMutableRawPointer(pointer)
    return .native(GeneratedPlatformRawMemory(
        pointer: UnsafeRawPointer(raw), mutablePointer: raw, owner: owner))
}

func generatedPlatformPointerResult(
    _ pointer: UnsafeMutablePointer<UInt8>?,
    owner: Any?,
    declaredType: String
) -> RuntimeValue {
    let wrappedType = optionalWrappedType(declaredType) ?? "Any"
    guard let pointer else { return .none(wrappedTypeName: wrappedType) }
    return .some(
        generatedPlatformPointerResult(
            pointer, owner: owner, declaredType: wrappedType),
        wrappedTypeName: wrappedType)
}

func generatedPlatformArgument<T>(
    _ value: RuntimeValue,
    as _: T.Type,
    framework: String,
    typeName: String,
    context: EvalContext
) throws -> T {
    // Unwrap our typed carrier before attempting a direct dynamic cast.
    // Clang-imported reference typedefs can report a vacuous conditional cast
    // from arbitrary host objects; letting that cast see the carrier itself
    // fabricates a reference instead of recovering its native payload.
    if case .host(let any) = value,
       let box = any as? GeneratedPlatformValue,
       let payload = box.payload as? T {
        return payload
    }
    if let direct = value.hostPayload as? T { return direct }
    if let backing = value.importedSuperclassBacking {
        return try generatedPlatformArgument(
            backing, as: T.self, framework: framework,
            typeName: typeName, context: context)
    }
    if let carrier = value.hostPayload as? GeneratedMemberCarrier,
       let payload = carrier.generatedMemberValue as? T {
        return payload
    }
    if T.self == CGFloat.self, let number = value.doubleValue {
        return CGFloat(number) as! T
    }
    if T.self == Float.self, let number = value.doubleValue {
        return Float(number) as! T
    }
    if T.self == Double.self, let number = value.doubleValue {
        return number as! T
    }
    if T.self == Int.self, let number = value.intValue {
        return number as! T
    }
    if T.self == Int8.self, let number = value.intValue,
       let converted = Int8(exactly: number) {
        return converted as! T
    }
    if T.self == Int16.self, let number = value.intValue,
       let converted = Int16(exactly: number) {
        return converted as! T
    }
    if T.self == Int32.self, let number = value.intValue,
       let converted = Int32(exactly: number) {
        return converted as! T
    }
    if T.self == Int64.self, let number = value.intValue {
        return Int64(number) as! T
    }
    if T.self == UInt.self, let number = value.intValue,
       let converted = UInt(exactly: number) {
        return converted as! T
    }
    if T.self == UInt8.self, let number = value.intValue,
       let converted = UInt8(exactly: number) {
        return converted as! T
    }
    if T.self == UInt16.self, let number = value.intValue,
       let converted = UInt16(exactly: number) {
        return converted as! T
    }
    if T.self == UInt32.self, let number = value.intValue,
       let converted = UInt32(exactly: number) {
        return converted as! T
    }
    if T.self == UInt64.self, let number = value.intValue,
       let converted = UInt64(exactly: number) {
        return converted as! T
    }
    if T.self == String.self, let string = value.stringValue {
        return string as! T
    }
    if T.self == Substring.self, let string = value.stringValue {
        return Substring(string) as! T
    }
    if T.self == Character.self, let string = value.stringValue,
       string.count == 1, let character = string.first {
        return character as! T
    }
    if T.self == Unicode.Scalar.self, let string = value.stringValue,
       let scalar = Unicode.Scalar(string) {
        return scalar as! T
    }
    if T.self == Bool.self, let flag = value.boolValue {
        return flag as! T
    }
    if case .implicitMember(let member) = value,
       let payload = GeneratedPlatformBridge.enumPayload(
           framework: framework,
           type: optionalWrappedType(typeName) ?? typeName,
           member: member) as? T {
        return payload
    }
    if let convertible = T.self as? GeneratedPlatformRuntimeConvertible.Type,
       let converted = try convertible.generatedPlatformValue(
           from: value, framework: framework, typeName: typeName,
           context: context) as? T {
        return converted
    }
    throw RuntimeError(message:
        "cannot convert '\(value.stringified)' to generated \(framework) type '\(typeName)'")
}

func generatedPlatformResult<T>(
    _ value: T,
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let type = declaredType.trimmingCharacters(in: .whitespacesAndNewlines)
    let any: Any = value
    if let scalar = any as? Unicode.Scalar {
        return .native(String(scalar))
    }
    // Optional<[Element]> reaches this overload with an erased generic
    // Wrapped type. Normalize it here as well as in the statically selected
    // Array overload so SDK collections never leak out as opaque host arrays.
    if let elementType = collectionElementType(type) {
        if let values = any as? [RuntimeValue] { return .native(values) }
        if let values = any as? [Any] {
            return .native(values.map {
                generatedPlatformResult(
                    $0, framework: framework, declaredType: elementType)
            })
        }
    }
    if let owner = GeneratedPlatformBridge.owningFramework(
        ofType: type, preferring: framework)
    {
        return .native(GeneratedPlatformValue(
            framework: owner,
            typeName: type,
            isValueType: GeneratedPlatformBridge.isValueType(
                framework: owner, type: type),
            payload: value))
    }
    if let amount = any as? CGFloat { return .native(Double(amount)) }
    if let amount = any as? Float { return .native(Double(amount)) }
    if let amount = any as? Int8 { return .native(Int(amount)) }
    if let amount = any as? Int16 { return .native(Int(amount)) }
    if let amount = any as? Int32 { return .native(Int(amount)) }
    if let amount = any as? Int64 { return .native(Int(amount)) }
    if let amount = any as? UInt { return .native(Int(amount)) }
    if let amount = any as? UInt8 { return .native(Int(amount)) }
    if let amount = any as? UInt16 { return .native(Int(amount)) }
    if let amount = any as? UInt32 { return .native(Int(amount)) }
    if let amount = any as? UInt64, amount <= UInt64(Int.max) {
        return .native(Int(amount))
    }
    return .native(any)
}

func generatedPlatformResult<Wrapped>(
    _ value: Wrapped?,
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let wrappedType = optionalWrappedType(declaredType) ?? declaredType
    guard let value else { return .none(wrappedTypeName: wrappedType) }
    return .some(
        generatedPlatformResult(
            value, framework: framework, declaredType: wrappedType),
        wrappedTypeName: wrappedType)
}

func generatedPlatformResult<Element>(
    _ value: [Element],
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let elementType = collectionElementType(declaredType) ?? "Element"
    return .native(value.map {
        generatedPlatformResult(
            $0, framework: framework, declaredType: elementType)
    })
}

func generatedPlatformResult<Key, Value>(
    _ value: [Key: Value],
    framework: String,
    declaredType: String
) -> RuntimeValue {
    let componentTypes = dictionaryComponentTypes(declaredType)
        ?? (String(describing: Key.self), String(describing: Value.self))
    var keys: [RuntimeValue] = []
    var values: [RuntimeValue] = []
    for (key, entry) in value {
        keys.append(generatedPlatformResult(
            key, framework: framework, declaredType: componentTypes.0))
        values.append(generatedPlatformResult(
            entry, framework: framework, declaredType: componentTypes.1))
    }
    return .native(DictValue(keys: keys, values: values))
}

private func optionalWrappedType(_ type: String) -> String? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("?") { return String(trimmed.dropLast()) }
    guard trimmed.hasPrefix("Optional<"), trimmed.hasSuffix(">") else {
        return nil
    }
    return String(trimmed.dropFirst("Optional<".count).dropLast())
}

private func collectionElementType(_ type: String) -> String? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains(":") {
        return String(trimmed.dropFirst().dropLast())
    }
    guard trimmed.hasPrefix("Array<"), trimmed.hasSuffix(">") else {
        return nil
    }
    return String(trimmed.dropFirst("Array<".count).dropLast())
}

private func dictionaryComponentTypes(
    _ type: String
) -> (String, String)? {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var angleDepth = 0
    var squareDepth = 0
    var parenDepth = 0
    for index in inner.indices {
        switch inner[index] {
        case "<": angleDepth += 1
        case ">": angleDepth -= 1
        case "[": squareDepth += 1
        case "]": squareDepth -= 1
        case "(": parenDepth += 1
        case ")": parenDepth -= 1
        case ":" where angleDepth == 0 && squareDepth == 0 && parenDepth == 0:
            let key = String(inner[..<index])
                .trimmingCharacters(in: .whitespaces)
            let value = String(inner[inner.index(after: index)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return (key, value)
        default: break
        }
    }
    return nil
}
