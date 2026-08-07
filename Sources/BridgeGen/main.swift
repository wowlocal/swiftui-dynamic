import Foundation
import SwiftParser
import SwiftSyntax

// BridgeGen: parse SwiftUI's SDK interfaces and declared cross-import overlays,
// classify every `extension View` modifier against the bridge's coercible-type
// whitelist, report coverage, and (with --emit) generate statically-compiled
// gateway tables. Generated calls compile against the real SDK, so a wrong
// signature fails at build time, never in a user session.

let emitMode = CommandLine.arguments.contains("--emit")

func argumentValue(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

let jsonReportPath = argumentValue(after: "--report-json")

// MARK: - Locate & parse interfaces

func run(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let sdk = run("/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "macosx"])
let hostArchitecture = run("/usr/bin/uname", ["-m"])

func interfacePath(framework: String) -> String? {
    let moduleDir = "\(sdk)/System/Library/Frameworks/\(framework).framework/Modules/\(framework).swiftmodule"
    let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: moduleDir)) ?? [])
        .filter { $0.hasSuffix("-apple-macos.swiftinterface") }
        .sorted()
    let architecturePrefix = hostArchitecture == "arm64" ? "arm64" : hostArchitecture
    guard let name = candidates.first(where: { $0.hasPrefix(architecturePrefix) }) ?? candidates.first else {
        return nil
    }
    return "\(moduleDir)/\(name)"
}

struct CrossImportInterface {
    let triggeringModule: String
    let overlayModule: String
    let syntax: SourceFileSyntax
}

/// A framework opts into SwiftUI cross-import behavior with public SDK
/// metadata at `Modules/<Framework>.swiftcrossimport/SwiftUI.swiftoverlay`.
/// Discover every such framework and overlay from that property; neither the
/// trigger, private overlay module, nor any API name is maintained by hand.
let swiftUICrossImportFiles: [CrossImportInterface] = {
    let frameworksDirectory = "\(sdk)/System/Library/Frameworks"
    let frameworkEntries = (
        (try? FileManager.default.contentsOfDirectory(
            atPath: frameworksDirectory)) ?? []
    ).filter { $0.hasSuffix(".framework") }.sorted()
    var seenPairs: Set<String> = []

    return frameworkEntries.flatMap {
        entry -> [CrossImportInterface] in
        let triggeringModule = String(
            entry.dropLast(".framework".count))
        let metadataPath = "\(frameworksDirectory)/\(entry)/Modules/"
            + "\(triggeringModule).swiftcrossimport/SwiftUI.swiftoverlay"
        guard let metadata = try? String(
            contentsOfFile: metadataPath, encoding: .utf8) else {
            return []
        }
        let overlayModules = metadata
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- name:") else { return nil }
                let name = trimmed.dropFirst("- name:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"'"))
                return name.isEmpty ? nil : name
            }

        return overlayModules.compactMap { overlayModule in
            let pair = "\(triggeringModule)|\(overlayModule)"
            guard seenPairs.insert(pair).inserted,
                  let path = interfacePath(framework: overlayModule),
                  let source = try? String(
                    contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            print(
                "parsing \(overlayModule) "
                    + "(SwiftUI cross-import via \(triggeringModule), "
                    + "\(source.count) chars)…")
            return CrossImportInterface(
                triggeringModule: triggeringModule,
                overlayModule: overlayModule,
                syntax: Parser.parse(source: source))
        }
    }.sorted {
        ($0.triggeringModule, $0.overlayModule)
            < ($1.triggeringModule, $1.overlayModule)
    }
}()

/// SwiftUI's Catalyst-only overlays live under the SDK's iOSSupport tree,
/// separate from the macOS interface. They contain target constructors such
/// as platform-value conversions that a macOS-hosted interpreter must still
/// recognize without compiling UIKit into the host binary.
func catalystOverlayInterfacePath(framework: String) -> String? {
    let moduleDirectories = [
        "\(sdk)/System/iOSSupport/System/Library/Frameworks/"
            + "\(framework).framework/Modules/\(framework).swiftmodule",
        "\(sdk)/System/Library/Frameworks/"
            + "\(framework).framework/Modules/\(framework).swiftmodule",
    ]
    let architecturePrefix = hostArchitecture == "arm64"
        ? "arm64" : hostArchitecture
    for moduleDir in moduleDirectories {
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            atPath: moduleDir)) ?? [])
            .filter { $0.hasSuffix("-apple-ios-macabi.swiftinterface") }
            .sorted()
        guard let name = candidates.first(where: {
            $0.hasPrefix(architecturePrefix)
        }) ?? candidates.first else { continue }
        return "\(moduleDir)/\(name)"
    }
    return nil
}

/// Some SDK interfaces are implementation-detail modules whose public import
/// name is declared in the interface flags (for example, a split framework
/// module can retain its own declaration qualifiers while being imported
/// through its public umbrella). Honor that metadata instead of assuming the
/// textual module name is directly importable.
func publicImportModule(
    declaredModule: String, interfaceSource: String
) -> String {
    let flagTokens = interfaceSource.prefix(4096).split(
        whereSeparator: { $0.isWhitespace }
    ).map(String.init)
    for flag in ["-public-module-name", "-module-abi-name"] {
        guard let index = flagTokens.firstIndex(of: flag),
              flagTokens.indices.contains(index + 1) else { continue }
        return flagTokens[index + 1]
    }
    return declaredModule
}

let primaryInterfaceFiles = ["SwiftUICore", "SwiftUI", "Charts"].compactMap {
    framework
        -> (module: String, importModule: String, file: SourceFileSyntax)? in
    guard let path = interfacePath(framework: framework),
          let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("warning: no swiftinterface for \(framework)")
        return nil
    }
    print("parsing \(framework) (\(source.count) chars)…")
    return (
        framework,
        publicImportModule(
            declaredModule: framework, interfaceSource: source),
        Parser.parse(source: source))
}
let interfaceFiles = primaryInterfaceFiles.map(\.file)

let targetOverlayInterfaceFiles = primaryInterfaceFiles.compactMap {
    primary
        -> (module: String, importModule: String, file: SourceFileSyntax)? in
    let framework = primary.module
    guard let path = catalystOverlayInterfacePath(framework: framework),
          let source = try? String(contentsOfFile: path, encoding: .utf8)
    else {
        print("warning: no Catalyst overlay swiftinterface for \(framework)")
        return nil
    }
    print("parsing \(framework) Catalyst overlay (\(source.count) chars)…")
    return (
        framework,
        publicImportModule(
            declaredModule: framework, interfaceSource: source),
        Parser.parse(source: source))
}
let targetOverlayFiles = targetOverlayInterfaceFiles.map(\.file)

// MARK: - Type normalization & mapping

// Longest first: "CoreFoundation." must strip before "Foundation." matches
// inside it (ditto SwiftUICore/SwiftUI).
let modulePrefixes = [
    "UniformTypeIdentifiers.", "DeveloperToolsSupport.",
    "CoreTransferable.",
    "CoreFoundation.", "CoreGraphics.", "Charts.",
    "Observation.", "SwiftUICore.", "Foundation.", "CoreData.", "SwiftUI.",
    "_Concurrency.",
    "AppKit.", "UIKit.", "Metal.", "QuartzCore.", "ObjectiveC.",
    "Combine.", "Swift.", "os.",
] + swiftUICrossImportFiles.map { "\($0.overlayModule)." }

func normalize(_ type: String) -> String {
    var out = type
    for prefix in modulePrefixes {
        out = out.replacingOccurrences(of: prefix, with: "")
    }
    return out.trimmingCharacters(in: .whitespaces)
}

/// tag = ParamTag raw value in the bridge; cast = call-site expression with %@
/// standing in for the coerced `v[i]` slot.
struct TypeMapping {
    let tag: String
    let cast: String
    let requiredFramework: String?
    /// The concrete interface type that supplies contextual leading-dot
    /// members. This is carried into generated dispatch rather than inferred
    /// from a handwritten tag-to-type table.
    let contextualType: String?
    /// Whether the interface wraps this concrete parameter type in Optional.
    /// The coercion tag continues to describe the wrapped value; generated
    /// dispatch and invocation preserve absence without inventing a
    /// type-specific nil case.
    let isOptional: Bool

    init(
        tag: String, cast: String, requiredFramework: String? = nil,
        contextualType: String? = nil, isOptional: Bool = false
    ) {
        self.tag = tag
        self.cast = cast
        self.requiredFramework = requiredFramework
        self.contextualType = contextualType
        self.isOptional = isOptional
    }

    func contextualized(as type: String) -> TypeMapping {
        .init(
            tag: tag, cast: cast, requiredFramework: requiredFramework,
            contextualType: type, isOptional: isOptional)
    }

    func optionalized() -> TypeMapping {
        .init(
            tag: tag, cast: cast, requiredFramework: requiredFramework,
            contextualType: contextualType, isOptional: true)
    }
}

/// Filled from the same platform symbol graphs that generate SDK gateways.
/// SwiftUI initializers/modifiers can then accept any selected AppKit/UIKit
/// nominal without maintaining a second type-name allowlist.
var platformTypeFrameworks: [String: Set<String>] = [:]

/// Public, deployment-compatible contextual SDK values. Enum cases and
/// same-type static properties have the same leading-dot call semantics, so
/// one interface-derived table drives both without nominal allowlists.
var sdkEnumCases: [String: [String]] = [:]
var sdkEnumFrameworkRequirements: [String: Set<String>] = [:]
var sdkEnumMinimumTargetAvailabilities:
    [String: Set<GeneratedTargetAvailability>] = [:]
/// Member guards keep one target-only static from gating its whole nominal.
var sdkEnumMemberFrameworkRequirements: [String: [String: Set<String>]] = [:]
var sdkEnumMemberMinimumTargetAvailabilities: [String: [String: Set<GeneratedTargetAvailability>]] = [:]
/// Contextual SDK value types whose interface conformance makes Swift array
/// literals a composition of same-typed members (`[.isButton, .isImage]`).
/// This remains separate from member discovery so composition is enabled by
/// the nominal's structural contract, never by its SDK identity.
var sdkSetAlgebraTypes: Set<String> = []

/// A leading-dot value manufactured by a protocol extension constrained to a
/// concrete `Self`, for example `P where Self == Concrete { static var x:
/// Concrete }`. The declaring protocol controls contextual visibility; the
/// concrete type's conformances determine whether it satisfies a generic
/// parameter's full protocol composition.
struct SDKProtocolContextualValue: Hashable {
    let member: String
    let concreteType: String
    let declaringProtocol: String
}

/// The CALL-shaped counterpart of `SDKProtocolContextualValue`: the same
/// `P where Self == Concrete` extension may manufacture its concrete value
/// from arguments (`static func units(width:maximumUnitCount:) -> Self`)
/// rather than from storage (`static var number: Self`). Only the declaration
/// kind differs, so the two are collected side by side from one sweep; the
/// parameter shape is analyzed later, with the rest of the emittable surface.
struct SDKProtocolContextualFactoryDecl {
    let concreteType: String
    let declaringProtocol: String
    let function: FunctionDeclSyntax
}

/// A method that CONSUMES a protocol value passed as a bare generic argument:
/// `func formatted<S>(_ v: S) -> S.FormatOutput where S: FormatStyle`.
///
/// The receiver decides nothing here — what makes the call recognizable is the
/// PARAMETER's constraint, so the method name is recorded against the protocol
/// it is constrained to and the interesting protocols are selected later, when
/// the refinement closure is known. Only the name is kept: the receiver types
/// are exactly the types some style already accepts, which the style's own
/// `FormatInput` answers at the call, so recording them would restate a
/// constraint the value already carries.
struct SDKProtocolConsumingMethod: Hashable {
    let name: String
    let constraintProtocol: String
}

var sdkProtocols: Set<String> = []
var sdkProtocolRefinements: [String: Set<String>] = [:]
var sdkNominalConformances: [String: Set<String>] = [:]
var sdkProtocolContextualValues: Set<SDKProtocolContextualValue> = []
var sdkProtocolContextualFactoryDecls: [SDKProtocolContextualFactoryDecl] = []
var sdkProtocolConsumingMethods: Set<SDKProtocolConsumingMethod> = []

/// Interface metadata for specializing public associated-type relationships.
struct SDKAssociatedConformance {
    let nominalBase: String, protocolType: String
    let genericParameters: [String]
    let associatedTypes: [String: String]
}

var sdkNominalGenericParameters: [String: [String]] = [:],
    sdkNominalTypealiases: [String: [String: String]] = [:]
var sdkAssociatedConformances: [SDKAssociatedConformance] = []

func genericTypeParts(_ raw: String) -> (base: String, arguments: [String])? {
    guard let open = raw.firstIndex(of: "<"), raw.last == ">" else { return nil }
    let base = String(raw[..<open]).trimmingCharacters(in: .whitespaces)
    let end = raw.index(before: raw.endIndex)
    var arguments: [String] = [], depth = 0
    var start = raw.index(after: open), cursor = start
    while cursor < end {
        switch raw[cursor] {
        case "<", "(", "[": depth += 1
        case ">", ")", "]": depth -= 1
        case "," where depth == 0:
            arguments.append(String(raw[start..<cursor]).trimmingCharacters(in: .whitespaces))
            start = raw.index(after: cursor)
        default: break
        }
        cursor = raw.index(after: cursor)
    }
    arguments.append(String(raw[start..<end]).trimmingCharacters(in: .whitespaces))
    return base.isEmpty || arguments.contains(where: \.isEmpty) ? nil : (base, arguments)
}

func substitutingTypeIdentifiers(_ raw: String, _ substitutions: [String: String]) -> String {
    guard !substitutions.isEmpty else { return raw }
    var result = raw
    for (token, replacement) in substitutions {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
        let expression = try! NSRegularExpression(pattern: pattern)
        result = expression.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result),
            withTemplate: replacement)
    }
    return result
}

/// Resolve a nested type through an interface-declared nominal typealias.
/// `IntegerFormatStyle<Int>.Configuration.Notation`, for example, becomes
/// `NumberFormatStyleConfiguration.Notation` without naming either family.
func resolvingSDKTypealiases(_ raw: String) -> String {
    var value = normalize(raw)
    for _ in 0..<4 {
        let components = value.split(separator: ".").map(String.init)
        var replacement: String?
        for aliasIndex in components.indices.dropFirst().reversed() {
            let owner = components[..<aliasIndex].joined(separator: ".")
            let after = components.index(after: aliasIndex)
            let suffix = after < components.endIndex
                ? "." + components[after...].joined(separator: ".") : ""
            let parts = genericTypeParts(owner)
            let base = parts?.base ?? owner
            guard let target = sdkNominalTypealiases[base]?[components[aliasIndex]]
            else { continue }
            let names = sdkNominalGenericParameters[base] ?? []
            let arguments = parts?.arguments ?? []
            let substitutions = names.count == arguments.count ?
                Dictionary(uniqueKeysWithValues: zip(names, arguments)) : [:]
            replacement = substitutingTypeIdentifiers(target, substitutions) + suffix
            break
        }
        guard let replacement, replacement != value else { break }
        value = normalize(replacement)
    }
    return value
}

/// A framework protocol whose interface describes the reusable SwiftUI style
/// shape: an associated View body, a concrete Configuration alias, and one
/// ViewBuilder requirement mapping that configuration to the body. The
/// framework supplies the configuration at runtime; BridgeGen carries every
/// other fact, including the requirement spelling, directly from the
/// interface.
struct SDKFrameworkConfigurationProtocol: Hashable {
    let protocolType: String
    let configurationType: String
    let bodyMethod: String
    let configurationLabel: String?
}

var sdkFrameworkConfigurationProtocols:
    [String: SDKFrameworkConfigurationProtocol] = [:]
var sdkFrameworkConfigurationTypes: Set<String> = []

/// A public instance property on a framework-supplied Configuration nominal.
/// The enclosing protocol selects the nominal; the interface alone selects
/// the member spelling and declared type.
struct SDKFrameworkConfigurationMember: Hashable {
    let name: String
    let type: String
}

var sdkFrameworkConfigurationMembers:
    [String: Set<SDKFrameworkConfigurationMember>] = [:]

/// Only compositions selected by emitted gateways are carried into generated
/// coercion code. The key is a stable, sorted `P&Q` spelling.
var sdkProtocolCompositionValues:
    [String: [SDKProtocolContextualValue]] = [:]

func protocolClosure(of name: String) -> Set<String> {
    var result: Set<String> = []
    var pending = [name]
    while let current = pending.popLast() {
        guard result.insert(current).inserted else { continue }
        pending.append(contentsOf: sdkProtocolRefinements[current] ?? [])
    }
    return result
}

func nominal(_ type: String, satisfies required: Set<String>) -> Bool {
    let normalized = normalize(type)
    let base = genericTypeParts(normalized)?.base ?? normalized
    let conformances = (sdkNominalConformances[type] ?? [])
        .union(sdkNominalConformances[normalized] ?? [])
        .union(sdkNominalConformances[base] ?? [])
    let closure = conformances.reduce(into: Set<String>()) {
        $0.formUnion(protocolClosure(of: $1))
    }
    return required.isSubset(of: closure)
}

/// Map an interface-declared protocol-constrained generic to an existential
/// that Swift can open again at the native generic call boundary. Contextual
/// members are admitted only when their declaring protocol is visible from
/// the constraint set and exactly one satisfying concrete type owns that
/// spelling, mirroring native ambiguity rather than picking by identity.
func sdkProtocolMapping(for constraints: Set<String>) -> TypeMapping? {
    guard !constraints.isEmpty else {
        return nil
    }

    // Primary SwiftUI interfaces normalize their own module qualifiers before
    // parameter analysis, while contextual protocol metadata retains canonical
    // module-qualified identities. Resolve only a unique canonical protocol;
    // same-suffix declarations across modules remain ambiguous and blocked.
    let canonicalConstraints = constraints.compactMap { constraint -> String? in
        if sdkProtocols.contains(constraint) {
            return constraint
        }
        let candidates = sdkProtocols.filter {
            normalize($0) == constraint
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    guard canonicalConstraints.count == constraints.count else {
        return nil
    }
    let requiredProtocols = Set(canonicalConstraints)
    let visibleProtocols = requiredProtocols.reduce(into: Set<String>()) {
        $0.formUnion(protocolClosure(of: $1))
    }
    let candidates = sdkProtocolContextualValues.filter {
        visibleProtocols.contains($0.declaringProtocol)
            && nominal($0.concreteType, satisfies: requiredProtocols)
    }
    let byMember = Dictionary(grouping: candidates, by: \.member)
    let unambiguous = byMember.values.compactMap {
        values -> SDKProtocolContextualValue? in
        let concreteTypes = Set(values.map(\.concreteType))
        guard concreteTypes.count == 1 else { return nil }
        return values.sorted {
            ($0.concreteType, $0.declaringProtocol)
                < ($1.concreteType, $1.declaringProtocol)
        }.first
    }.sorted { ($0.member, $0.concreteType) < ($1.member, $1.concreteType) }
    let ordered = requiredProtocols.sorted()
    let key = ordered.joined(separator: "&")
    let hasFrameworkConfigurationAdapter =
        requiredProtocols.count == 1
        && requiredProtocols.allSatisfy {
            sdkFrameworkConfigurationProtocols[$0] != nil
        }
    guard !unambiguous.isEmpty
            || hasFrameworkConfigurationAdapter else {
        return nil
    }
    sdkProtocolCompositionValues[key] = unambiguous
    return .init(
        tag: "sdkProtocolValue(\"\(key)\")",
        cast: "%@ as! any \(ordered.joined(separator: " & "))",
        contextualType: ordered.joined(separator: " & "))
}

/// Supporting SDK interfaces are collected under their module-qualified
/// paths, while a consuming declaration may spell the same contextual type
/// without that module. Resolve only a unique suffix match: ambiguity remains
/// blocked exactly as it would at a native import boundary.
func contextualSDKTypeName(matching normalized: String) -> String? {
    if sdkEnumCases[normalized] != nil { return normalized }
    let matches = sdkEnumCases.keys.filter {
        $0.hasSuffix("." + normalized)
            || normalized.hasSuffix("." + $0)
    }
    return matches.count == 1 ? matches[0] : nil
}

/// Extract either Swift array spelling; dictionary/tuple shapes stay blocked.
func arrayElementType(_ normalized: String) -> String? {
    let inner = normalized.first == "[" && normalized.last == "]"
        ? normalized.dropFirst().dropLast()
        : normalized.hasPrefix("Array<") && normalized.last == ">"
            ? normalized.dropFirst("Array<".count).dropLast() : nil
    guard let inner, !inner.isEmpty,
          !inner.contains(where: { $0 == ":" || $0 == "," }) else { return nil }
    return String(inner)
}

/// Public, non-generic native values declared by SwiftUI's interfaces.
var concreteNativeSwiftUIValueTypes: Set<String> = []
/// Generic SDK value structs, by declared arity. `SharePreview<Image, Icon>`
/// is not a type; `SharePreview<InterpretedTransferableValue, Never>` is.
var genericNativeSwiftUIValueTypeArity: [String: Int] = [:]
/// Value types the deployment target cannot name without a guard.
var newerOSNativeValueTypes: Set<String> = []
/// Where a generic type declares that one of its own parameters may be the
/// uninhabited type, by argument position: `extension SwiftUI.SharePreview
/// where Icon == Swift.Never` says position 1 is an ABSENT SLOT, and the
/// initializers that extension carries (`init(_:image:)`) are the ones that
/// build that shape. This is the declaration's own statement about which
/// instantiations exist, which is stronger evidence than `Never` merely
/// conforming to the constraint — and it is readable from the interfaces
/// already parsed, while the conformance itself lives in CoreTransferable.
var sdkNominalNeverPositions: [String: Set<Int>] = [:]

/// A property wrapper whose PROJECTION the interface publishes as a parameter
/// type but gives no way to build. Collected by shape further down; declared
/// here because `directMapping` consults it.
struct WrapperProjection {
    let wrapper: String
    /// The interface offers `init() where Value == Bool` and `init<T>() where
    /// Value == T?, T: Hashable`, so a projection is reachable in exactly two
    /// value shapes. Which one applies is read from the generic argument at
    /// each use site, not stored here.
    let hasBoolValue: Bool
    let hasOptionalHashableValue: Bool
}
var wrapperProjectionWrappers: [String: WrapperProjection] = [:]

/// The value types some interface declares a `Binding` over, collected as the
/// mappings are made rather than listed. Each one needs a generated adapter,
/// because `Binding<Value>` is the one parameter shape no argument conversion
/// can satisfy — see `GeneratedBindingValueSupport` — and driving it needs the
/// concrete `Value` spelled in real Swift somewhere.
var bindingValueTypes: Set<String> = []

/// `Binding<Value>` for a `Value` this table already maps, which is every
/// instantiation the interfaces declare beyond the four spelled by hand above.
/// Those four each carry a value CONVERSION and so cannot come from here; the
/// rest carry the value type's own coercion in both directions.
func bindingValueMapping(for normalized: String) -> TypeMapping? {
    guard normalized.hasPrefix("Binding<"), normalized.hasSuffix(">") else {
        return nil
    }
    let valueType = String(normalized.dropFirst("Binding<".count).dropLast())
    // Fail closed on availability for the same reason the generic-value branch
    // below does: the emitted adapter spells `Binding<Value>` and `Value.self`
    // unguarded, so a value type the deployment target cannot name makes the
    // whole instantiation unspellable.
    guard !newerOSNativeValueTypes.contains(valueType),
          let value = directMapping(for: valueType),
          !value.isOptional,
          value.requiredFramework == nil
    else { return nil }
    bindingValueTypes.insert(valueType)
    return .init(
        tag: "bindingValue(.\(value.tag), \(String(reflecting: valueType)))",
        cast: "%@ as! \(normalized)")
}

func directMapping(for normalized: String) -> TypeMapping? {
    if let elementType = arrayElementType(normalized),
       let element = directMapping(for: elementType),
       !element.isOptional {
        let elementCast = element.cast.replacingOccurrences(of: "%@", with: "element")
        return .init(
            tag: "array(.\(element.tag), \"\(elementType)\")",
            cast: "(%@ as! [Any]).map { element in \(elementCast) }",
            requiredFramework: element.requiredFramework)
    }
    switch normalized {
    case "String", "StringProtocol": return .init(tag: "string", cast: "%@ as! String")
    // Localization keys convert exactly like String and are tagged apart from
    // it for one reason: a literal bound to one of these parameters is read as
    // a KEY, whose interpolations format under the current locale. The two
    // readings are the same runtime String, so only the declared type can
    // distinguish them.
    case "LocalizedStringKey":
        return .init(tag: "localizationKey", cast: "LocalizedStringKey(%@ as! String)")
    case "LocalizedStringResource":
        return .init(
            tag: "localizationKey",
            cast: "LocalizedStringResource(stringLiteral: %@ as! String)")
    case "ImageResource":
        return .init(tag: "string", cast: "ImageResource(name: %@ as! String, bundle: .main)")
    case "Text": return .init(tag: "text", cast: "%@ as! Text")
    case "Bool": return .init(tag: "bool", cast: "%@ as! Bool")
    case "Int": return .init(tag: "int", cast: "%@ as! Int")
    case "Double": return .init(tag: "double", cast: "%@ as! Double")
    case "CGFloat": return .init(tag: "cgFloat", cast: "%@ as! CGFloat")
    case "TaskPriority": return .init(
        tag: "taskPriority", cast: "%@ as! TaskPriority")
    case "ClosedRange<Double>": return .init(tag: "doubleRange", cast: "%@ as! ClosedRange<Double>")
    case "Color": return .init(tag: "color", cast: "%@ as! Color")
    case "Font": return .init(tag: "font", cast: "%@ as! Font")
    case "Font.Weight": return .init(tag: "fontWeight", cast: "%@ as! Font.Weight")
    case "Angle": return .init(tag: "angle", cast: "%@ as! Angle")
    case "Animation": return .init(tag: "animation", cast: "%@ as! Animation")
    case "Alignment": return .init(tag: "alignment", cast: "%@ as! Alignment")
    case "TextAlignment": return .init(tag: "textAlignment", cast: "%@ as! TextAlignment")
    case "Edge.Set": return .init(tag: "edgeSet", cast: "%@ as! Edge.Set")
    case "UnitPoint": return .init(tag: "unitPoint", cast: "%@ as! UnitPoint")
    case "ContentMode": return .init(tag: "contentMode", cast: "%@ as! ContentMode")
    case "Image.Scale": return .init(tag: "imageScale", cast: "%@ as! Image.Scale")
    case "SymbolRenderingMode": return .init(tag: "symbolRenderingMode", cast: "%@ as! SymbolRenderingMode")
    case "Visibility": return .init(tag: "visibility", cast: "%@ as! Visibility")
    case "Axis.Set": return .init(tag: "axisSet", cast: "%@ as! Axis.Set")
    case "EdgeInsets": return .init(tag: "edgeInsets", cast: "%@ as! EdgeInsets")
    case "Gradient": return .init(tag: "gradient", cast: "%@ as! Gradient")
    case "[GridItem]": return .init(tag: "gridItems", cast: "%@ as! [GridItem]")
    case "ButtonRole": return .init(tag: "buttonRole", cast: "%@ as! ButtonRole")
    case "Axis": return .init(tag: "axis", cast: "%@ as! Axis")
    case "AnnotationPosition": return .init(tag: "annotationPosition", cast: "%@ as! AnnotationPosition")
    // The optional-of-a-constraint binding every selection-shaped modifier
    // declares (`scrollPosition(id:)`, and the same shape wherever a generic
    // is constrained to Hashable). The carrier is the one the wrapper
    // projections already drive; only the spelling that reaches it is new.
    case "Binding<InterpretedHashableValue?>":
        return .init(
            tag: "bindingHashableOptional",
            cast: "%@ as! Binding<InterpretedHashableValue?>")
    case "Binding<Bool>": return .init(tag: "bindingBool", cast: "%@ as! Binding<Bool>")
    case "Binding<String>": return .init(tag: "bindingString", cast: "%@ as! Binding<String>")
    case "Binding<Double>": return .init(tag: "bindingDouble", cast: "%@ as! Binding<Double>")
    case "AnyShapeStyle": return .init(tag: "shapeStyle", cast: "%@ as! AnyShapeStyle")
    case "URL": return .init(tag: "url", cast: "%@ as! URL")
    case "Date": return .init(tag: "date", cast: "%@ as! Date")
    case "Data": return .init(tag: "data", cast: "%@ as! Data")
    default:
        // A projection of a wrapper the interface leaves uninitializable: the
        // carrier declares the wrapper, so what crosses is an ordinary binding.
        if let projection = wrapperProjectionMapping(for: normalized) {
            return projection
        }
        if let frameworks = platformTypeFrameworks[normalized],
           frameworks.count == 1, let framework = frameworks.first {
            return .init(
                tag: "platformValue(\"\(framework)\", \"\(normalized)\")",
                cast: "%@ as! \(normalized)",
                requiredFramework: framework)
        }
        if let contextualType =
                contextualSDKTypeName(matching: normalized) {
            let requirements =
                sdkEnumFrameworkRequirements[contextualType] ?? []
            return .init(
                tag: "sdkEnum(\"\(contextualType)\")",
                cast: "%@ as! \(contextualType)",
                requiredFramework: requirements.count == 1
                    ? requirements.first : nil)
        }
        // A binding over any value type this table maps. It precedes the
        // generic-value branch because `Binding<Color>` satisfies that branch's
        // test — every argument supplied — and the tag it produces there asks
        // whether the ARGUMENT ALREADY IS the native value, which an
        // interpreted projection onto interpreted storage never is. The
        // parameter was therefore not merely unbridged but unmatchable.
        if let binding = bindingValueMapping(for: normalized) {
            return binding
        }
        // A generic SDK value struct whose every argument is supplied is a
        // concrete type, and the emitted call spells it exactly. An argument
        // is supplied when it is a carrier standing in for a constraint, the
        // uninhabited type filling an absent slot, or any type this table
        // already maps.
        if let parts = genericTypeParts(normalized),
           let arity = genericNativeSwiftUIValueTypeArity[parts.base],
           arity == parts.arguments.count,
           // Fail closed on availability: the emitted call spells every one of
           // these names, so an argument the deployment target cannot see makes
           // the whole instantiation unspellable regardless of how available
           // the declaration that uses it is.
           !newerOSNativeValueTypes.contains(parts.base),
           parts.arguments.allSatisfy({
               !newerOSNativeValueTypes.contains($0)
                   && ($0 == "Never" || constraintCarrierTypes.contains($0)
                       || directMapping(for: $0) != nil)
           }) {
            return .init(
                tag: "nativeSwiftUIValue(\"\(normalized)\")",
                cast: "%@ as! \(normalized)")
        }
        guard concreteNativeSwiftUIValueTypes.contains(normalized)
        else { return nil }
        return .init(
            tag: "nativeSwiftUIValue(\"\(normalized)\")",
            cast: "%@ as! \(normalized)")
    }
}

/// Rewrite every opaque parameter written IN PLACE inside a compound type to
/// the canonical concrete carrier for its constraint, so the result maps like
/// any other compound type: `Binding<(some Hashable)?>` becomes
/// `Binding<InterpretedHashableValue?>`.
///
/// Returns nil unless EVERY occurrence has a carrier. A partially specialized
/// type must never reach a mapping: `Binding<some Plottable>` has no carrier
/// for `Plottable`, and rewriting nothing would leave `some ` in a type the
/// emitter would then spell into generated Swift.
func specializingInPlaceOpaqueParameters(in type: String) -> String? {
    let pattern = try! NSRegularExpression(
        pattern: #"\(?\bsome\s+([A-Za-z_][A-Za-z0-9_.]*)\)?"#)
    let source = type as NSString
    let matches = pattern.matches(
        in: type, range: NSRange(location: 0, length: source.length))
    guard !matches.isEmpty else { return nil }
    var specialized = type
    // Replace from the end so earlier ranges stay valid.
    for match in matches.reversed() {
        guard match.numberOfRanges > 1,
              let concrete = constraintConcreteType(
                for: normalize(source.substring(with: match.range(at: 1))))
        else { return nil }
        specialized = (specialized as NSString)
            .replacingCharacters(in: match.range, with: concrete)
    }
    return specialized
}

/// Specialize EVERY generic argument of a compound type, in order, and return
/// each instantiation the interface admits.
///
/// `Binding<V>` (V: Hashable) and `SharePreview<Image, Icon>` (both
/// Transferable) differ only in how many arguments there are to substitute —
/// substitution itself is per-argument. The single-argument spelling was the
/// only one recognized, so every two-argument compound stayed blocked on the
/// whole type, which is why all six `ShareLink(item:…preview:)` initializers
/// reported `SharePreview<PreviewImage, PreviewIcon>` as their blocker.
///
/// An argument specializes to its constraint's carrier, and ALSO to `Never` at
/// any position the RECEIVING TYPE declares may be absent — read off
/// `extension SharePreview where Icon == Never`, the same extension that
/// carries the `init(_:image:)` building that shape. `Never` is admissible
/// there precisely because it is uninhabited: a compound can be instantiated
/// at a phantom argument no call has to supply, while a bare parameter of that
/// type could never receive a value. Returns every combination; the caller
/// keeps whichever the mapping table recognizes, so a spelling the SDK does
/// not declare simply finds no mapping and is dropped.
func specializingGenericArguments(
    in type: String, generics: Generics
) -> [String] {
    guard let parts = genericTypeParts(type), parts.arguments.count > 1
    else { return [] }
    let neverPositions = sdkNominalNeverPositions[parts.base] ?? []
    var candidatesPerArgument: [[String]] = []
    for (position, argument) in parts.arguments.enumerated() {
        guard let facts = generics[argument] else {
            // Already concrete: it substitutes to itself.
            candidatesPerArgument.append([argument])
            continue
        }
        switch facts {
        case .concrete(let concrete):
            candidatesPerArgument.append([concrete])
        case .constraints(let set):
            guard set.count == 1, let constraint = set.first,
                  let carrier = constraintConcreteType(for: constraint)
            else { return [] }
            var candidates = [carrier]
            if neverPositions.contains(position) { candidates.append("Never") }
            candidatesPerArgument.append(candidates)
        }
    }
    var results = [""]
    for candidates in candidatesPerArgument {
        results = results.flatMap { prefix in
            candidates.map { prefix.isEmpty ? $0 : prefix + ", " + $0 }
        }
    }
    return results.map { "\(parts.base)<\($0)>" }
}

/// The canonical concrete type a lone conformance constraint specializes
/// to when it appears INSIDE a compound type (`ClosedRange<V>` with
/// V: BinaryFloatingPoint → ClosedRange<Double>).
func constraintConcreteType(for constraint: String) -> String? {
    constraintConcreteTypes[constraint]
}

let constraintConcreteTypes: [String: String] = [
    "BinaryFloatingPoint": "Double",
    "FloatingPoint": "Double",
    "StringProtocol": "String",
    "BinaryInteger": "Int",
    "Transferable": "InterpretedTransferableValue",
    "Equatable": "InterpretedEquatableValue",
    "Hashable": "InterpretedHashableValue",
]

/// The concrete types a constraint specializes TO. These stand in for a
/// generic rather than being SDK types themselves, so they carry no direct
/// mapping of their own and a compound type holding one must recognize them
/// by identity.
let constraintCarrierTypes = Set(constraintConcreteTypes.values)

/// The constraint a carrier stands in for. Only the carriers that are NOT
/// themselves SDK types need this — `Double` and `String` already map as
/// themselves, so the first spelling wins and the reverse lookup is only
/// consulted when a direct mapping found nothing.
let constraintOfCarrier: [String: String] = constraintConcreteTypes.reduce(
    into: [:]
) { result, entry in
    if result[entry.value] == nil { result[entry.value] = entry.key }
}

/// The value a bridged callback hands back to the framework when the
/// interpreted callback FAILED — it threw, or produced something that is not
/// the declared result type. The call is already wrong at that point and the
/// recorded diagnostic is the signal; what this supplies is the obligation the
/// framework's declaration imposes, that a synchronous callback must return
/// something.
///
/// It is derived from the result type's declared structure — an empty option
/// set, a numeric or boolean zero, or, for a payload-free enum, its first case
/// under the same total order the contextual-value table is already kept in.
/// That last choice is arbitrary in the sense that no case is more correct
/// after a failure; it is deliberately NOT a case the generator recognizes by
/// name, and it is emitted into the generated source so what a failed callback
/// returns is visible at the call site rather than decided at runtime.
///
/// A result with no such value returns nil, and the overload stays
/// ungeneratable: a callback result the generator cannot produce without the
/// interpreter is one whose failure would have no defined behavior.
func interpretedFailureValue(
    for normalized: String, _ mapping: TypeMapping
) -> String? {
    // Keyed on the TAG the type mapping already resolved, not on the result's
    // spelling: the tag is what the scan derived from the interface, so a
    // scalar reachable under another name is covered without being named here
    // a second time.
    switch mapping.tag {
    case "bool": return "false"
    case "int", "double", "cgFloat": return "0"
    default: break
    }
    let contextual = callbackResultContextualType(normalized, mapping)
    if sdkSetAlgebraTypes.contains(contextual) { return "[]" }
    guard let first = sdkEnumCases[contextual]?.first else { return nil }
    return "\(contextual).\(first)"
}

/// The concrete type a callback result's leading-dot members resolve against.
/// A contextual-value tag already carries the table key it was matched to,
/// which can differ from the spelling at the use site.
func callbackResultContextualType(
    _ normalized: String, _ mapping: TypeMapping
) -> String {
    let prefix = "sdkEnum(\""
    let suffix = "\")"
    if mapping.tag.hasPrefix(prefix), mapping.tag.hasSuffix(suffix) {
        return String(
            mapping.tag.dropFirst(prefix.count).dropLast(suffix.count))
    }
    return mapping.contextualType ?? normalized
}

func constraintMapping(for constraint: String) -> TypeMapping? {
    switch constraint {
    case "ShapeStyle":
        return .init(
            tag: "genericShapeStyle",
            cast: "%@ as! any ShapeStyle")
    case "View": return .init(tag: "anyView", cast: "%@ as! AnyView")
    case "StringProtocol": return .init(tag: "string", cast: "%@ as! String")
    case "BinaryFloatingPoint": return .init(tag: "double", cast: "%@ as! Double")
    case "Equatable": return .init(tag: "equatable", cast: "%@ as! InterpretedEquatableValue")
    // Hashable refines Equatable, so the same retain-the-payload carrier
    // answers it — with the hashing the refinement adds.
    case "Hashable": return .init(tag: "hashable", cast: "%@ as! InterpretedHashableValue")
    case "Shape": return .init(tag: "shape", cast: "%@ as! AnyShape")
    case "Transferable":
        return .init(
            tag: "transferable",
            cast: "%@ as! InterpretedTransferableValue")
    default: return nil
    }
}

// MARK: - Generics

/// What we know about a generic parameter: conformance constraints, or a
/// concrete substitution from a same-type requirement (`where Label == Text`).
enum GenericFacts {
    case constraints(Set<String>)
    case concrete(String)
}
typealias Generics = [String: GenericFacts]

/// Non-View result-builder requirements demanded by generated SDK call
/// signatures. The key and value both come from the swiftinterface:
/// result protocol -> builder attribute.
var interfaceResultBuilders: [String: String] = [:]

func addConstraint(_ generics: inout Generics, _ name: String, _ constraint: String) {
    switch generics[name] {
    case .concrete:
        break
    case .constraints(var set):
        set.insert(constraint)
        generics[name] = .constraints(set)
    case nil:
        generics[name] = .constraints(constraint.isEmpty ? [] : [constraint])
    }
}

func collectWhereClause(_ whereClause: GenericWhereClauseSyntax?, into generics: inout Generics) {
    guard let whereClause else { return }
    for requirement in whereClause.requirements {
        if let conformance = requirement.requirement.as(ConformanceRequirementSyntax.self) {
            addConstraint(&generics, normalize(conformance.leftType.trimmedDescription),
                          normalize(conformance.rightType.trimmedDescription))
        } else if let sameType = requirement.requirement.as(SameTypeRequirementSyntax.self) {
            generics[normalize(sameType.leftType.trimmedDescription)] =
                .concrete(normalize(sameType.rightType.trimmedDescription))
        }
    }
}

func collectGenericClause(_ clause: GenericParameterClauseSyntax?, into generics: inout Generics) {
    guard let clause else { return }
    for parameter in clause.parameters {
        addConstraint(&generics, parameter.name.text,
                      normalize(parameter.inheritedType?.trimmedDescription ?? ""))
    }
}

/// Whether a normalized type expression contains a declared generic as a
/// complete identifier. Token boundaries cover nested spellings such as
/// `[T]`, tuples, and `Result<T, Error>` without confusing a concrete type
/// whose name merely contains the same letters.
func referencesGenericIdentifier(_ type: String, generics: Generics) -> Bool {
    let identifiers = Set(type.split {
        !($0.isLetter || $0.isNumber || $0 == "_")
    }.map(String.init))
    return !identifiers.isDisjoint(with: generics.keys)
}

func sdkAssociatedType(_ name: String, of concreteType: String,
                       conformingTo protocolType: String) -> String? {
    let concrete = normalize(concreteType)
    let parts = genericTypeParts(concrete)
    let resolved = sdkAssociatedConformances.compactMap { conformance -> String? in
        guard conformance.nominalBase == (parts?.base ?? concrete),
              conformance.protocolType == normalize(protocolType),
              let associated = conformance.associatedTypes[name],
              conformance.genericParameters.count == (parts?.arguments.count ?? 0)
        else { return nil }
        let values = Dictionary(uniqueKeysWithValues: zip(
            conformance.genericParameters, parts?.arguments ?? []))
        return resolvingSDKTypealiases(substitutingTypeIdentifiers(associated, values))
    }
    let unique = Set(resolved)
    return unique.count == 1 ? unique.first : nil
}

/// Concrete contextual values reached by associated-generic consumers.
var associatedGenericConcreteTypes: Set<String> = []

/// Fan a declaration out over the instantiations an absent slot allows.
///
/// `ShareLink(item:preview:)` declares `preview: SharePreview<PreviewImage,
/// PreviewIcon>` with both generics constrained to `Transferable`, and the
/// value that actually arrives depends on which `SharePreview` initializer
/// built it: `SharePreview(_:image:)` yields `<Image, Never>`, `(_:icon:)`
/// yields `<Never, Icon>`. One instantiation per declaration would type-check
/// and then fail every cast but one.
///
/// A generic gets the extra `Never` instantiation only where it lands in an
/// argument position the receiving type itself declares may be absent, and
/// only where it is a PHANTOM — nested inside a compound parameter type, never
/// a parameter's own type. An uninhabited parameter could receive no argument;
/// an uninhabited generic ARGUMENT merely selects a shape.
func uninhabitedGenericSpecializations(
    _ generics: Generics, parameters: FunctionParameterListSyntax
) -> [Generics] {
    let parameterTypes = parameters.map { normalize($0.type.trimmedDescription) }
    /// The generic names sitting at a declared-absent argument position.
    var absentSlotNames: Set<String> = []
    for parameterType in parameterTypes {
        guard let parts = genericTypeParts(parameterType),
              let neverPositions = sdkNominalNeverPositions[parts.base]
        else { continue }
        for position in neverPositions
        where parts.arguments.indices.contains(position) {
            absentSlotNames.insert(parts.arguments[position])
        }
    }
    let phantoms = generics.compactMap { name, facts -> String? in
        guard case .constraints(let set) = facts, set.count == 1,
              let constraint = set.first,
              absentSlotNames.contains(name),
              constraintConcreteType(for: constraint) != nil,
              // Never the parameter's own type, but present inside one.
              !parameterTypes.contains(name)
        else { return nil }
        return name
    }.sorted()
    // Two is what the SDK declares (`SharePreview<Image, Icon>`); a wider
    // product would be guessing at shapes rather than enumerating them.
    guard !phantoms.isEmpty, phantoms.count <= 2 else { return [generics] }
    var results = [generics]
    for name in phantoms {
        results = results.flatMap { specialization -> [Generics] in
            var withNever = specialization
            withNever[name] = .concrete("Never")
            return [specialization, withNever]
        }
    }
    return results
}

func associatedGenericSpecializations(_ generics: Generics,
                                      parameters: FunctionParameterListSyntax) -> [Generics] {
    let parameterTypes = parameters.map { normalize($0.type.trimmedDescription) }
    let relational = generics.compactMap { name, facts
        -> (name: String, protocols: Set<String>)? in
        guard !name.contains("."),
              case .constraints(let constraints) = facts,
              parameterTypes.contains(where: { $0 == name }),
              parameterTypes.contains(where: { $0.hasPrefix(name + ".") })
        else { return nil }
        let protocols = Set(constraints.map(normalize))
        return protocols.isEmpty ? nil : (name, protocols)
    }
    // Multiple independent families require a Cartesian product; fail closed.
    guard relational.count == 1, let relation = relational.first else { return [generics] }

    let associatedFacts = generics.filter { $0.key.hasPrefix(relation.name + ".") }
    let candidates = sdkProtocolContextualValues.filter {
        relation.protocols.contains(normalize($0.declaringProtocol)) }
    var results: [Generics] = []
    for concreteType in Set(candidates.map(\.concreteType)).sorted() {
        let concrete = normalize(concreteType)
        var associated: [String: String] = [:]
        var matches = true
        for (path, facts) in associatedFacts {
            let associatedName = String(path.dropFirst(relation.name.count + 1))
            let values = relation.protocols.compactMap {
                sdkAssociatedType(associatedName, of: concrete, conformingTo: $0)
            }
            guard Set(values).count == 1, let value = values.first
            else { matches = false; break }
            if case .concrete(let required) = facts,
               normalize(value) != normalize(required) {
                matches = false; break
            }
            associated[path] = normalize(value)
        }
        guard matches, !associated.isEmpty, associated.values.allSatisfy({
            directMapping(for: $0) != nil
        }) else { continue }
        let members = candidates.filter { normalize($0.concreteType) == concrete }.map(\.member)
        sdkEnumCases[concrete] = Array(Set(
            (sdkEnumCases[concrete] ?? []) + members)).sorted()
        associatedGenericConcreteTypes.insert(concrete)

        var specialized = generics
        specialized[relation.name] = .concrete(concrete)
        associated.forEach { specialized[$0.key] = .concrete($0.value) }
        results.append(specialized)
    }
    return results
}

// MARK: - Parameter analysis

struct AnalyzedParam {
    let label: String?
    let mapping: TypeMapping?
    let hasDefault: Bool
    let blocker: String?
    let usesGeneric: String?
    /// The concrete type this parameter's mapping instantiates its generic
    /// to — repeats of one generic are legal when they all agree.
    let genericConcrete: String?
    let contractType: String?

    init(
        label: String?, mapping: TypeMapping?, hasDefault: Bool,
        blocker: String?, usesGeneric: String?, genericConcrete: String? = nil,
        contractType: String? = nil
    ) {
        self.label = label
        self.mapping = mapping
        self.hasDefault = hasDefault
        self.blocker = blocker
        self.usesGeneric = usesGeneric
        self.genericConcrete = genericConcrete
        self.contractType = contractType
    }
}

struct ParameterSelection {
    let params: [AnalyzedParam]
    /// Swift can skip an unlabeled default before a final closure only when
    /// that closure uses trailing-closure syntax. Preserve that source shape
    /// so emission does not accidentally bind the closure positionally.
    let trailingClosureIndex: Int?
}

/// Every Swift call shape obtainable by omitting mapped or unmapped defaulted
/// parameters. Defaults are not restricted to a trailing suffix: declarations
/// such as `VStack(alignment:spacing:content:)` allow `alignment` to be omitted
/// while `spacing` and the required builder remain present.
func parameterSelections(_ analyzed: [AnalyzedParam]) -> [ParameterSelection] {
    var selections: [ParameterSelection] = []

    func visit(
        _ index: Int,
        _ selected: [AnalyzedParam],
        omittedUnlabeledDefault: Bool,
        trailingClosureIndex: Int?
    ) {
        guard index < analyzed.count else {
            selections.append(.init(
                params: selected,
                trailingClosureIndex: trailingClosureIndex))
            return
        }

        let parameter = analyzed[index]
        if parameter.hasDefault {
            visit(
                index + 1,
                selected,
                omittedUnlabeledDefault: omittedUnlabeledDefault || parameter.label == nil,
                trailingClosureIndex: trailingClosureIndex)
        }
        // Swift cannot skip an unlabeled default and then bind a later
        // unlabeled argument positionally. A final closure is the structural
        // exception: trailing-closure syntax binds it after the omitted slot.
        let closureTag = parameter.mapping?.tag ?? ""
        let isFinalClosure = index == analyzed.count - 1
            && ([
                    "builder", "action", "asyncAction",
                    "syncVoidClosure",
                    "equatableAction1", "equatableAction2",
                ].contains(closureTag)
                || closureTag.hasPrefix("resultBuilder(")
                || closureTag.hasPrefix("syncClosure("))
        let requiresTrailingClosure = omittedUnlabeledDefault
            && parameter.label == nil
            && isFinalClosure
        if parameter.mapping != nil,
           !(omittedUnlabeledDefault && parameter.label == nil)
            || requiresTrailingClosure {
            visit(
                index + 1,
                selected + [parameter],
                omittedUnlabeledDefault: omittedUnlabeledDefault,
                trailingClosureIndex: requiresTrailingClosure
                    ? selected.count : trailingClosureIndex)
        }
    }

    visit(
        0, [], omittedUnlabeledDefault: false,
        trailingClosureIndex: nil)
    return selections
}

func analyzeParameter(_ param: FunctionParameterSyntax, generics: Generics) -> AnalyzedParam {
    let labelText = param.firstName.text
    let label: String? = labelText == "_" ? nil : labelText
    let hasDefault = param.defaultValue != nil

    var type = param.type
    var builderAttribute: String?
    var isAutoclosure = false

    // Result-builder and closure attributes are represented on the parameter
    // by current SwiftSyntax, while older interfaces/parsers may attach them
    // to AttributedTypeSyntax. Read both locations so generation follows the
    // SDK declaration rather than a parser-layout accident.
    func inspectAttributes(_ attributes: AttributeListSyntax) {
        for attribute in attributes {
            let name = attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription ?? ""
            let normalizedName = normalize(name)
            if normalizedName.hasSuffix("Builder") {
                builderAttribute = normalizedName
            }
            if normalizedName == "autoclosure" { isAutoclosure = true }
        }
    }
    inspectAttributes(param.attributes)
    while let attributed = type.as(AttributedTypeSyntax.self) {
        inspectAttributes(attributed.attributes)
        type = attributed.baseType
    }
    var normalized = normalize(type.trimmedDescription)
    var isOptional = false
    if normalized.hasSuffix("?") {
        normalized = String(normalized.dropLast())
        isOptional = true
    }

    func preservingOptional(_ mapping: TypeMapping) -> TypeMapping {
        // Optional protocol-constrained generics need their concrete dynamic
        // type reopened before wrapping. Keep their existing non-Optional
        // adapter until that distinct existential-opening shape is modeled;
        // concrete mapped values can preserve Optional mechanically.
        guard mapping.tag != "genericShapeStyle",
              !mapping.tag.hasPrefix("sdkProtocolValue(") else {
            return mapping
        }
        return isOptional ? mapping.optionalized() : mapping
    }

    if isAutoclosure {
        // Swift's call-site expression has the autoclosure's RESULT type.
        // Map that result like any ordinary parameter; the emitted native SDK
        // call then re-forms the autoclosure from the coerced value. This is a
        // function-shape rule and applies independently of the API name.
        guard let closure = type.as(FunctionTypeSyntax.self),
              closure.parameters.isEmpty else {
            return .init(
                label: label, mapping: nil, hasDefault: hasDefault,
                blocker: "@autoclosure input", usesGeneric: nil)
        }
        type = closure.returnClause.type
        normalized = normalize(type.trimmedDescription)
        if normalized.hasSuffix("?") {
            normalized = String(normalized.dropLast())
            isOptional = true
        }
    }
    if let builderAttribute {
        // Builders with framework-supplied inputs (GeometryProxy,
        // AsyncImagePhase, collection elements, accessibility content, …)
        // need a semantic adapter that can manufacture the input value.
        // A generated zero-argument closure would compile incorrectly or
        // silently discard data, so only the ordinary `() -> View` shape is
        // mechanical.
        guard let closure = type.as(FunctionTypeSyntax.self),
              closure.parameters.isEmpty else {
            return .init(
                label: label, mapping: nil, hasDefault: hasDefault,
                blocker: "@\(builderAttribute) input closure",
                usesGeneric: nil)
        }
        let resultType = normalize(
            closure.returnClause.type.trimmedDescription)
        if builderAttribute.hasSuffix("ViewBuilder") {
            return .init(
                label: label,
                mapping: .init(tag: "builder", cast: "{ %@ as! AnyView }"),
                hasDefault: hasDefault, blocker: nil,
                usesGeneric: generics[normalized] != nil
                    ? normalized : nil
            )
        }
        guard case .constraints(let constraints)? = generics[resultType],
              constraints.count == 1,
              let resultProtocol = constraints.first else {
            return .init(
                label: label, mapping: nil, hasDefault: hasDefault,
                blocker: "@\(builderAttribute) result protocol",
                usesGeneric: nil)
        }
        interfaceResultBuilders[resultProtocol] = builderAttribute
        return .init(
            label: label,
            mapping: .init(
                tag: "resultBuilder(\"\(builderAttribute)\", "
                    + "\"\(resultProtocol)\")",
                cast: "%@"),
            hasDefault: hasDefault, blocker: nil,
            usesGeneric: generics[normalized] != nil ? normalized : nil
        )
    }
    if normalized == "() -> Void" {
        return .init(
            label: label,
            mapping: .init(tag: "action", cast: "generatedAction(%@)"),
            hasDefault: hasDefault, blocker: nil, usesGeneric: nil
        )
    }
    if normalized == "() async -> Void" {
        return .init(
            label: label,
            mapping: .init(
                tag: "asyncAction", cast: "generatedAsyncAction(%@)"),
            hasDefault: hasDefault, blocker: nil, usesGeneric: nil
        )
    }
    if let closure = type.as(FunctionTypeSyntax.self),
       (1...2).contains(closure.parameters.count),
       normalize(closure.returnClause.type.trimmedDescription) == "Void",
       let generic = closure.parameters.first.map({ normalize($0.type.trimmedDescription) }),
       closure.parameters.allSatisfy({ normalize($0.type.trimmedDescription) == generic }),
       case .constraints(let constraints)? = generics[generic],
       constraints == ["Equatable"] {
        let arity = closure.parameters.count
        return .init(
            label: label,
            mapping: .init(tag: "equatableAction\(arity)",
                           cast: "generatedEquatableAction\(arity)(%@)"),
            hasDefault: hasDefault, blocker: nil, usesGeneric: generic,
            genericConcrete: "InterpretedEquatableValue", contractType: normalized)
    }
    // Framework-owned synchronous callbacks share one argument adapter. The
    // SDK supplies the inputs and consumes the result, and BOTH ends resolve
    // through the same coercion vocabulary every ordinary parameter uses — so
    // a callback returning a bridged SDK value needs no entry of its own.
    // Driven by closure structure, not by modifier, input or result identity.
    if let closure = type.as(FunctionTypeSyntax.self),
       (0...1).contains(closure.parameters.count),
       closure.parameters.allSatisfy({ parameter in
           parameter.type.as(AttributedTypeSyntax.self)?
               .specifiers.isEmpty != false
               && !referencesGenericIdentifier(
                   normalize(parameter.type.trimmedDescription),
                   generics: generics)
       }) {
        let result = normalize(
            closure.returnClause.type.trimmedDescription)
        // A Void result is the one genuinely distinct shape: there is nothing
        // to coerce back, so it needs no result adapter and no failed-call
        // value.
        if result == "Void", closure.parameters.count == 1 {
            return .init(
                label: label,
                mapping: .init(
                    tag: "syncVoidClosure",
                    cast: "generatedSyncVoidClosure(%@)"),
                hasDefault: hasDefault, blocker: nil, usesGeneric: nil,
                contractType: normalized)
        }
        if result != "Void",
           // Effects are only disqualifying once there is a value to hand
           // back: the result has to EXIST by the time the framework's call
           // returns, and an `async` callback cannot promise that. The `Void`
           // shape above is unaffected — it produces nothing, and a
           // non-`async` closure already converts to an `async` parameter, so
           // restricting it would un-bridge callbacks that work today.
           closure.effectSpecifiers == nil,
           let resultMapping = directMapping(for: result),
           // Only bridge a result the generator can also produce WITHOUT the
           // interpreter. A callback that fails still has to return something
           // to the framework, and inventing that value at runtime would hide
           // the failure behind a guess this file never made.
           let fallback = interpretedFailureValue(for: result, resultMapping) {
            let contextual = callbackResultContextualType(
                result, resultMapping)
            let tag = "syncClosure(inputs: \(closure.parameters.count), "
                + "result: .\(resultMapping.tag))"
            return .init(
                label: label,
                mapping: .init(
                    tag: tag,
                    cast: "generatedSyncClosure"
                        + "\(closure.parameters.count)(%@, "
                        + "result: .\(resultMapping.tag), "
                        + "contextualType: \"\(contextual)\", "
                        + "fallback: \(fallback))",
                    requiredFramework: resultMapping.requiredFramework),
                hasDefault: hasDefault, blocker: nil, usesGeneric: nil,
                contractType: normalized)
        }
    }
    // A generic parameter can legally shadow a concrete SDK type (`Data` is
    // common in collection initializers). Resolve declared generics first so
    // it is never mistaken for Foundation.Data or another direct mapping.
    if let facts = generics[normalized] {
        switch facts {
        case .concrete(let concrete):
            if let mapping = directMapping(for: concrete)?
                .contextualized(as: concrete) {
                return .init(label: label, mapping: preservingOptional(mapping), hasDefault: hasDefault, blocker: nil, usesGeneric: normalized, genericConcrete: concrete)
            }
            // A generic BOUND to a carrier is the same parameter as a generic
            // CONSTRAINED to what that carrier stands for — binding it is how
            // an instantiation is requested, not a different kind of type. The
            // carrier has no direct mapping of its own because it is not an SDK
            // type, so the constraint's mapping is what answers it.
            if let constraint = constraintOfCarrier[concrete],
               let mapping = constraintMapping(for: constraint) {
                return .init(
                    label: label, mapping: preservingOptional(mapping),
                    hasDefault: hasDefault, blocker: nil,
                    usesGeneric: normalized, genericConcrete: concrete)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "== \(concrete)", usesGeneric: normalized)
        case .constraints(let set):
            if set.count == 1, let mapping = constraintMapping(for: set.first!) {
                return .init(label: label, mapping: preservingOptional(mapping), hasDefault: hasDefault, blocker: nil, usesGeneric: normalized, genericConcrete: constraintConcreteType(for: set.first!))
            }
            if let mapping = sdkProtocolMapping(for: set) {
                return .init(
                    label: label, mapping: preservingOptional(mapping),
                    hasDefault: hasDefault, blocker: nil,
                    usesGeneric: normalized)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault,
                         blocker: "<\(set.sorted().joined(separator: "&"))>", usesGeneric: normalized)
        }
    }
    // Opaque parameter syntax is an anonymous generic whose conformance is
    // written in place (`shape: some Shape`). Reuse the same protocol-driven
    // mapping as named generic parameters; the emitted adapter supplies its
    // canonical concrete carrier without depending on the consuming API.
    if normalized.hasPrefix("some ") {
        let constraint = String(normalized.dropFirst("some ".count))
        let constraints = Set(
            constraint.split(separator: "&").map {
                normalize(String($0))
                    .trimmingCharacters(in: CharacterSet(
                        charactersIn: "()"))
            })
        if constraints.count == 1,
           let protocolName = constraints.first,
           let mapping = constraintMapping(for: protocolName)?
            .contextualized(as: protocolName) {
            return .init(
                label: label, mapping: preservingOptional(mapping),
                hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
        }
        if let mapping = sdkProtocolMapping(for: constraints) {
            return .init(
                label: label, mapping: preservingOptional(mapping),
                hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
        }
    }
    // The same anonymous generic, written in place INSIDE a compound type
    // (`Binding<(some Hashable)?>`). SE-0341 defines `some P` in parameter
    // position as sugar for an unnamed generic constrained to P, so this is
    // the identical rule the loop below already applies to a NAMED generic
    // (`Binding<V>` with `V: Hashable`) — only the spelling differs, and only
    // because this one never gets a name to key on. Specializing first lets
    // one carrier answer both spellings, exactly as the bare case above and
    // `matchedTransitionSource`'s two spellings already share theirs.
    if normalized.contains("some "), !normalized.hasPrefix("some "),
       let specialized = specializingInPlaceOpaqueParameters(in: normalized),
       let mapping = directMapping(for: specialized)?
        .contextualized(as: specialized) {
        return .init(
            label: label, mapping: preservingOptional(mapping),
            hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
    }
    if let mapping = directMapping(for: normalized)?
        .contextualized(as: normalized) {
        return .init(label: label, mapping: preservingOptional(mapping), hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
    }
    // Compound types over constrained generics (`ClosedRange<V>` with
    // V: BinaryFloatingPoint) specialize to their canonical concrete form
    // and then map like any direct type.
    for (name, facts) in generics where normalized.contains("<\(name)>") {
        let concrete: String?
        switch facts {
        case .concrete(let c):
            concrete = c
        case .constraints(let set):
            concrete = set.count == 1 ? constraintConcreteType(for: set.first!) : nil
        }
        let specialized = concrete.map {
            normalized.replacingOccurrences(of: "<\(name)>", with: "<\($0)>")
        }
        if let specialized,
           let mapping = directMapping(for: specialized)?
            .contextualized(as: specialized) {
            return .init(label: label, mapping: preservingOptional(mapping), hasDefault: hasDefault, blocker: nil, usesGeneric: name, genericConcrete: concrete)
        }
    }
    // The same substitution where the compound carries MORE THAN ONE generic
    // argument (`SharePreview<Image, Icon>`). The loop above rewrites the sole
    // argument `<V>`, which no two-argument spelling ever matches — yet
    // substitution is per-argument and each argument is answered by exactly
    // the rule that loop applies. Doing it argument-wise subsumes the arity-1
    // case; it is kept above only because it also honours a same-type
    // requirement that resolves to a type with no carrier.
    for specialized in specializingGenericArguments(
        in: normalized, generics: generics) {
        if let mapping = directMapping(for: specialized)?
            .contextualized(as: specialized) {
            return .init(
                label: label, mapping: preservingOptional(mapping),
                hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
        }
    }
    return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: normalized, usesGeneric: nil)
}

func genericConstraints(of function: FunctionDeclSyntax) -> Generics {
    var generics: Generics = [:]
    collectGenericClause(function.genericParameterClause, into: &generics)
    collectWhereClause(function.genericWhereClause, into: &generics)
    return generics
}

/// Return module qualifiers from a type expression. A qualifier is only a
/// candidate here; `interfacePath` below proves that it names an SDK framework
/// before the generator reads it.
func qualifiedModuleNames(in type: String) -> Set<String> {
    let expression = try! NSRegularExpression(
        pattern: #"(?:^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\."#)
    let source = type as NSString
    return Set(expression.matches(
        in: type, range: NSRange(location: 0, length: source.length)
    ).compactMap {
        guard $0.numberOfRanges > 1 else { return nil }
        return source.substring(with: $0.range(at: 1))
    })
}

/// Discover support frameworks from qualified generic constraints in the
/// primary interfaces. Already-mapped constraints need no auxiliary metadata;
/// unknown qualified protocols can contribute contextual `Self == Concrete`
/// factories and conformance relationships without joining a module allowlist.
func collectQualifiedConstraintModules(
    in syntax: Syntax, into modules: inout Set<String>
) {
    var generics: Generics?
    if let function = syntax.as(FunctionDeclSyntax.self) {
        generics = genericConstraints(of: function)
    } else if let initializer = syntax.as(InitializerDeclSyntax.self) {
        var collected: Generics = [:]
        collectGenericClause(
            initializer.genericParameterClause, into: &collected)
        collectWhereClause(initializer.genericWhereClause, into: &collected)
        generics = collected
    } else if let nominal = syntax.as(StructDeclSyntax.self) {
        var collected: Generics = [:]
        collectGenericClause(nominal.genericParameterClause, into: &collected)
        collectWhereClause(nominal.genericWhereClause, into: &collected)
        generics = collected
    } else if let nominal = syntax.as(EnumDeclSyntax.self) {
        var collected: Generics = [:]
        collectGenericClause(nominal.genericParameterClause, into: &collected)
        collectWhereClause(nominal.genericWhereClause, into: &collected)
        generics = collected
    } else if let nominal = syntax.as(ClassDeclSyntax.self) {
        var collected: Generics = [:]
        collectGenericClause(nominal.genericParameterClause, into: &collected)
        collectWhereClause(nominal.genericWhereClause, into: &collected)
        generics = collected
    } else if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
        var collected: Generics = [:]
        collectWhereClause(
            extensionDecl.genericWhereClause, into: &collected)
        generics = collected
    }
    for facts in generics.map({ Array($0.values) }) ?? [] {
        guard case .constraints(let constraints) = facts,
              constraints.count > 1 else { continue }
        for constraint in constraints
        where constraintMapping(for: constraint) == nil {
            modules.formUnion(qualifiedModuleNames(in: constraint))
        }
    }
    for child in syntax.children(viewMode: .sourceAccurate) {
        collectQualifiedConstraintModules(in: child, into: &modules)
    }
}

let primaryInterfaceFrameworks = Set(primaryInterfaceFiles.map(\.module))
var qualifiedConstraintModules: Set<String> = []
for file in interfaceFiles {
    collectQualifiedConstraintModules(
        in: Syntax(file), into: &qualifiedConstraintModules)
}
let supportingInterfaceFiles:
    [(module: String, importModule: String, file: SourceFileSyntax)] =
        qualifiedConstraintModules.sorted().compactMap { module in
            guard !primaryInterfaceFrameworks.contains(module),
                  let path = interfacePath(framework: module),
                  let source = try? String(
                    contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            print("parsing contextual support \(module) (\(source.count) chars)…")
            return (
                module,
                publicImportModule(
                    declaredModule: module, interfaceSource: source),
                Parser.parse(source: source))
        }

let foundationInterfaceFile:
    (module: String, importModule: String, file: SourceFileSyntax)? = {
        let module = "Foundation"
        guard let path = interfacePath(framework: module),
              let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("warning: no swiftinterface for \(module)")
            return nil
        }
        print("parsing \(module) (\(source.count) chars)…")
        return (module, publicImportModule(
                declaredModule: module, interfaceSource: source),
            Parser.parse(source: source))
    }()
let foundationFile = foundationInterfaceFile?.file
let stdlibInterfaceFile:
    (module: String, importModule: String, file: SourceFileSyntax)? = {
        let moduleDir = "\(sdk)/usr/lib/swift/Swift.swiftmodule"
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: moduleDir)) ?? [])
            .filter { $0.hasSuffix("-apple-macos.swiftinterface") }
            .sorted()
        let architecturePrefix = hostArchitecture == "arm64" ? "arm64" : hostArchitecture
        guard let name = candidates.first(where: { $0.hasPrefix(architecturePrefix) }) ?? candidates.first,
              let source = try? String(contentsOfFile: "\(moduleDir)/\(name)", encoding: .utf8) else {
            print("warning: no swiftinterface for the Swift stdlib")
            return nil
        }
        print("parsing Swift stdlib (\(source.count) chars)…")
        return ("Swift", "Swift", Parser.parse(source: source))
    }()
let stdlibFile = stdlibInterfaceFile?.file
// MARK: - Availability

let deploymentTarget = 15

/// A versioned deprecation is still a usable declaration before that
/// version. SDK compatibility spellings use a far-future sentinel (100000)
/// for this exact purpose; treating the presence of the word `deprecated` as
/// immediate unavailability erases source-valid API from generated coverage.
func deprecationIsActive(_ availability: String) -> Bool {
    guard availability.contains("deprecated") else { return false }
    guard let range = availability.range(of: "deprecated:") else {
        return true
    }
    let version = availability[range.upperBound...]
        .drop(while: { $0.isWhitespace })
        .prefix { $0.isNumber || $0 == "." }
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard let major = parts.first else { return true }
    let minor = parts.count > 1 ? parts[1] : 0
    return (major, minor) <= (deploymentTarget, 0)
}

func isUsable(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        if attr.attributeName.trimmedDescription == "available" {
            // This generator consumes the macOS SwiftUI interface. An API
            // being unavailable on iOS/tvOS/watchOS is evidence that it is
            // platform-specific, not that it is unusable here.
            let appliesToMacOS = text.contains("macOS")
                || text.hasPrefix("@available(*,")
            if appliesToMacOS,
               text.contains("unavailable") || deprecationIsActive(text)
                || text.contains("obsoleted") {
                return false
            }
        }
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") { return false }
    }
    return true
}

/// GeneratedSDKEnumCoercions is compiled for the package's supported Apple
/// platforms (iOS and macOS). Availability exclusions for unrelated platforms
/// do not erase a value that exists on both of those targets.
func isUniversallyUsable(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        let appliesToPackagePlatform = text.contains("iOS")
            || text.contains("macOS") || text.hasPrefix("@available(*,")
        if appliesToPackagePlatform
            && (text.contains("unavailable") || deprecationIsActive(text)
                || text.contains("obsoleted")) {
            return false
        }
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") { return false }
    }
    return true
}

func introducedVersion(
    in availability: String, platform: String
) -> (major: Int, minor: Int)? {
    let directMarker = "\(platform) "
    let versionText: Substring?
    if let range = availability.range(of: directMarker) {
        versionText = availability[range.upperBound...]
            .prefix { $0.isNumber || $0 == "." }
    } else if availability.contains("\(platform),"),
              let range = availability.range(of: "introduced:") {
        versionText = availability[range.upperBound...]
            .drop(while: { $0.isWhitespace })
            .prefix { $0.isNumber || $0 == "." }
    } else {
        versionText = nil
    }
    guard let versionText, !versionText.isEmpty else { return nil }
    let parts = versionText.split(separator: ".").compactMap { Int($0) }
    guard let major = parts.first else { return nil }
    return (major, parts.count > 1 ? parts[1] : 0)
}

/// Availability for target overlays is evaluated against the interpreted iOS
/// deployment, independently of the macOS host. Newer declarations remain
/// source-valid inside availability checks; BridgeGen carries their minimum
/// versions into generated runtime guards instead of deleting their call
/// shapes at generation time.
func isUsableIOSOverlay(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") {
            return false
        }
        guard attr.attributeName.trimmedDescription == "available" else {
            continue
        }
        // A universal `@available(*, unavailable)` is unavailable on the iOS
        // overlay too — the platform-specific spellings below are the narrower
        // case, not the whole rule. `isUsable` already reads the universal form
        // for the macOS tier; without the same reading here an overlay
        // declaration the SDK forbids compiles into the emitted table and the
        // Catalyst build fails on it.
        if text.hasPrefix("@available(*,"),
           text.contains("unavailable") || text.contains("obsoleted") {
            return false
        }
        if text.contains("iOS, unavailable")
            || text.contains("iOS unavailable")
            || text.contains("iOS, obsoleted") {
            return false
        }
    }
    return true
}

func needsAvailabilityGuard(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self),
              attr.attributeName.trimmedDescription == "available" else { continue }
        let text = attr.trimmedDescription
        guard let range = text.range(of: "macOS ") else { continue }
        let version = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { continue }
        let minor = parts.count > 1 ? parts[1] : 0
        if (major, minor) > (deploymentTarget, 0) { return true }
    }
    return false
}

/// Compile-time framework requirements encoded by cross-platform availability.
/// The generator reads the macOS interface, so `iOS, unavailable` means the
/// emitted declaration must stay behind `canImport(AppKit)` on shared builds.
func platformFrameworkRequirements(
    _ attributes: AttributeListSyntax
) -> Set<String> {
    var result: Set<String> = []
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self),
              attr.attributeName.trimmedDescription == "available" else {
            continue
        }
        let text = attr.trimmedDescription
        if text.contains("iOS"), text.contains("unavailable") {
            result.insert("AppKit")
        }
    }
    return result
}

/// Target environments are a distinct availability axis from importable
/// frameworks. Preserve interface-declared exclusions in generated compile
/// guards so an overlay can be native on iOS/macOS while unavailable in a
/// Catalyst compilation of the same package.
func unavailableTargetEnvironments(
    _ attributes: AttributeListSyntax
) -> Set<String> {
    var result: Set<String> = []
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self),
              attr.attributeName.trimmedDescription == "available" else {
            continue
        }
        let text = attr.trimmedDescription
        if text.contains("macCatalyst"), text.contains("unavailable") {
            result.insert("macCatalyst")
        }
    }
    return result
}

struct GeneratedTargetAvailability: Hashable {
    let platform: String
    let major: Int
    let minor: Int

    var clause: String {
        "\(platform) \(major).\(minor)"
    }
}

func targetAvailabilityClauses(_ values: Set<GeneratedTargetAvailability>) -> [String] {
    values.sorted {
        ($0.platform, $0.major, $0.minor) < ($1.platform, $1.major, $1.minor)
    }.map(\.clause)
}

/// Deployment floors of the checked-in generated bridge. Availability newer
/// than these floors stays as an interface-derived runtime guard so the same
/// source compiles on every package target without dropping the contract.
let generatedTargetDeployments: [
    String: (major: Int, minor: Int)
] = [
    "iOS": (18, 0),
    "macCatalyst": (18, 0),
    // The generator reads the macOS interface and the generated bridge is
    // compiled for the macOS host too, so the host's own floor belongs in the
    // same table. Its absence was not a design: a declaration newer than
    // macOS 15 could state no clause, so `needsAvailabilityGuard` had nothing
    // to fall back to and the declaration was dropped instead of guarded.
    "macOS": (15, 0),
]

/// The availability an interface declares for a NOMINAL, keyed by its name.
/// Availability is a property of the declaration, not of the pass that happens
/// to scan it, and several passes compute the same `guarded` verdict from the
/// same attributes — so the clause each verdict came from is recorded once
/// here and read back where a guard can be emitted.
var interfaceAvailabilitiesByType: [String: Set<GeneratedTargetAvailability>] =
    [:]

func recordInterfaceAvailability(
    of typeName: String, _ attributes: AttributeListSyntax
) {
    let availabilities = minimumTargetAvailabilities(attributes)
    guard !availabilities.isEmpty else { return }
    interfaceAvailabilitiesByType[typeName, default: []]
        .formUnion(availabilities)
}

func minimumTargetAvailabilities(
    _ attributes: AttributeListSyntax
) -> Set<GeneratedTargetAvailability> {
    var result: Set<GeneratedTargetAvailability> = []
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self),
              attr.attributeName.trimmedDescription == "available" else {
            continue
        }
        let text = attr.trimmedDescription
        for (platform, deployment) in generatedTargetDeployments {
            guard let range = text.range(of: "\(platform) ") else { continue }
            let version = text[range.upperBound...]
                .prefix { $0.isNumber || $0 == "." }
            let parts = version.split(separator: ".").compactMap { Int($0) }
            guard let major = parts.first else { continue }
            let minor = parts.count > 1 ? parts[1] : 0
            guard (major, minor) > (deployment.major, deployment.minor) else {
                continue
            }
            result.insert(GeneratedTargetAvailability(
                platform: platform, major: major, minor: minor))
        }
    }
    return result
}

// MARK: - Protocol-constrained contextual SDK values

func topLevelSDKNames(in file: SourceFileSyntax) -> Set<String> {
    Set(file.statements.compactMap { statement -> String? in
        guard case .decl(let decl) = statement.item else { return nil }
        if let value = decl.as(ProtocolDeclSyntax.self) {
            return value.name.text
        }
        if let value = decl.as(StructDeclSyntax.self) {
            return value.name.text
        }
        if let value = decl.as(EnumDeclSyntax.self) {
            return value.name.text
        }
        if let value = decl.as(ClassDeclSyntax.self) {
            return value.name.text
        }
        if let value = decl.as(ActorDeclSyntax.self) {
            return value.name.text
        }
        return nil
    })
}

/// Preserve an explicit module qualifier. Unqualified names whose root is
/// declared by the support interface are qualified with that interface's
/// module; imported protocols such as `Hashable` remain unqualified.
func canonicalSDKType(
    _ raw: String, module: String, localTopLevelNames: Set<String>
) -> String {
    let type = normalize(raw)
    guard type != "Self", !type.hasPrefix("\(module).") else {
        return type
    }
    guard let root = type.split(separator: ".").first.map(String.init),
          localTopLevelNames.contains(root) else {
        return type
    }
    return "\(module).\(type)"
}

func nestedSDKPath(
    for canonicalType: String, module: String
) -> [String] {
    let prefix = "\(module)."
    let local = canonicalType.hasPrefix(prefix)
        ? String(canonicalType.dropFirst(prefix.count))
        : canonicalType
    return local.split(separator: ".").map(String.init)
}

func publicSDKTypealiases(in members: MemberBlockItemListSyntax, module: String,
                          localTopLevelNames: Set<String>) -> [String: String] {
    Dictionary(uniqueKeysWithValues: members.compactMap {
        guard let alias = $0.decl.as(TypeAliasDeclSyntax.self),
              isPublicSDKDecl(alias.modifiers),
              isUniversallyUsable(alias.attributes) else { return nil }
        return (alias.name.text, canonicalSDKType(
            alias.initializer.value.trimmedDescription, module: module,
            localTopLevelNames: localTopLevelNames))
    })
}

func recordSDKNominalShape(type canonicalType: String,
                           genericClause: GenericParameterClauseSyntax?,
                           members: MemberBlockItemListSyntax, module: String,
                           localTopLevelNames: Set<String>) {
    let type = normalize(canonicalType)
    if let genericClause {
        sdkNominalGenericParameters[type] = genericClause.parameters.map(\.name.text)
    }
    sdkNominalTypealiases[type, default: [:]].merge(
        publicSDKTypealiases(in: members, module: module,
            localTopLevelNames: localTopLevelNames)) { _, latest in latest }
}

struct SDKNominalParts {
    let name: String
    let modifiers: DeclModifierListSyntax
    let attributes: AttributeListSyntax
    let members: MemberBlockItemListSyntax
    let inheritance: InheritanceClauseSyntax?
    let generics: GenericParameterClauseSyntax?
    let isProtocol: Bool
}

func sdkNominalParts(_ decl: DeclSyntax) -> SDKNominalParts? {
    if let value = decl.as(ProtocolDeclSyntax.self) {
        return .init(name: value.name.text, modifiers: value.modifiers, attributes: value.attributes,
            members: value.memberBlock.members,
            inheritance: value.inheritanceClause, generics: nil, isProtocol: true)
    }
    if let value = decl.as(StructDeclSyntax.self) {
        return .init(name: value.name.text, modifiers: value.modifiers, attributes: value.attributes,
            members: value.memberBlock.members, inheritance: value.inheritanceClause,
            generics: value.genericParameterClause, isProtocol: false)
    }
    if let value = decl.as(EnumDeclSyntax.self) {
        return .init(name: value.name.text, modifiers: value.modifiers, attributes: value.attributes,
            members: value.memberBlock.members, inheritance: value.inheritanceClause,
            generics: value.genericParameterClause, isProtocol: false)
    }
    if let value = decl.as(ClassDeclSyntax.self) {
        return .init(name: value.name.text, modifiers: value.modifiers, attributes: value.attributes,
            members: value.memberBlock.members, inheritance: value.inheritanceClause,
            generics: value.genericParameterClause, isProtocol: false)
    }
    if let value = decl.as(ActorDeclSyntax.self) {
        return .init(name: value.name.text, modifiers: value.modifiers, attributes: value.attributes,
            members: value.memberBlock.members, inheritance: value.inheritanceClause,
            generics: value.genericParameterClause, isProtocol: false)
    }
    return nil
}

func collectSDKProtocolDeclarations(
    in members: MemberBlockItemListSyntax,
    module: String,
    path: [String],
    localTopLevelNames: Set<String>,
    guarded: Bool
) {
    for member in members {
        collectSDKProtocolDeclarations(
            in: member.decl, module: module, path: path,
            localTopLevelNames: localTopLevelNames, guarded: guarded)
    }
}

/// Discover the framework-supplied configuration pattern without depending on
/// a protocol, modifier, configuration, or requirement name. Requiring a
/// unique matching requirement keeps ambiguous protocols fail-closed.
func frameworkConfigurationProtocol(
    _ declaration: ProtocolDeclSyntax,
    protocolType: String,
    module: String,
    localTopLevelNames: Set<String>
) -> SDKFrameworkConfigurationProtocol? {
    let members = declaration.memberBlock.members
    let hasViewBody = members.contains { member in
        guard let associated = member.decl.as(
            AssociatedTypeDeclSyntax.self
        ), associated.name.text == "Body" else {
            return false
        }
        return associated.inheritanceClause?.inheritedTypes.contains {
            normalize($0.type.trimmedDescription) == "View"
        } == true
    }
    guard hasViewBody else { return nil }

    let configurations = members.compactMap {
        member -> String? in
        guard let alias = member.decl.as(TypeAliasDeclSyntax.self),
              alias.name.text == "Configuration" else {
            return nil
        }
        return canonicalSDKType(
            alias.initializer.value.trimmedDescription,
            module: module,
            localTopLevelNames: localTopLevelNames)
    }
    guard Set(configurations).count == 1,
          let configurationType = configurations.first else {
        return nil
    }

    let requirements = members.compactMap {
        member -> (method: String, label: String?)? in
        guard let function = member.decl.as(FunctionDeclSyntax.self),
              function.attributes.contains(where: { element in
                  guard let attribute = element.as(AttributeSyntax.self)
                  else { return false }
                  return normalize(
                    attribute.attributeName.trimmedDescription)
                    == "ViewBuilder"
              }),
              function.signature.returnClause.map({
                  normalize($0.type.trimmedDescription)
              }) == "Self.Body" else {
            return nil
        }
        let parameters = Array(
            function.signature.parameterClause.parameters)
        guard parameters.count == 1,
              normalize(parameters[0].type.trimmedDescription)
                == "Self.Configuration" else {
            return nil
        }
        let rawLabel = parameters[0].firstName.text
        return (
            function.name.text,
            rawLabel == "_" ? nil : rawLabel)
    }
    guard requirements.count == 1, let requirement = requirements.first
    else {
        return nil
    }
    return .init(
        protocolType: protocolType,
        configurationType: configurationType,
        bodyMethod: requirement.method,
        configurationLabel: requirement.label)
}

/// First pass: establish every locally declared protocol before interpreting
/// nominal/extension conformance clauses, whose order is not semantically
/// significant in a swiftinterface.
func collectSDKProtocolDeclarations(
    in decl: DeclSyntax,
    module: String,
    path: [String],
    localTopLevelNames: Set<String>,
    guarded inheritedGuarded: Bool
) {
    if let nominal = sdkNominalParts(decl) {
        guard isPublicSDKDecl(nominal.modifiers),
              isUniversallyUsable(nominal.attributes) else { return }
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(nominal.attributes)
        let childPath = path + [nominal.name]
        let type = "\(module).\(childPath.joined(separator: "."))"
        if nominal.isProtocol {
            guard !guarded, let protocolDecl = decl.as(ProtocolDeclSyntax.self)
            else { return }
            sdkProtocols.insert(type)
            let refinements = nominal.inheritance?.inheritedTypes.map {
                canonicalSDKType($0.type.trimmedDescription, module: module,
                    localTopLevelNames: localTopLevelNames)
            } ?? []
            sdkProtocolRefinements[type, default: []].formUnion(refinements)
            if let configuration = frameworkConfigurationProtocol(
                protocolDecl, protocolType: type, module: module,
                localTopLevelNames: localTopLevelNames) {
                sdkFrameworkConfigurationProtocols[type] = configuration
                sdkFrameworkConfigurationTypes.insert(configuration.configurationType)
            }
        } else {
            recordSDKNominalShape(type: type, genericClause: nominal.generics,
                members: nominal.members, module: module,
                localTopLevelNames: localTopLevelNames)
        }
        collectSDKProtocolDeclarations(
            in: nominal.members, module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: guarded)
        return
    }
    if let extensionDecl = decl.as(ExtensionDeclSyntax.self),
       isUniversallyUsable(extensionDecl.attributes) {
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(extensionDecl.attributes)
        let extended = canonicalSDKType(
            extensionDecl.extendedType.trimmedDescription,
            module: module, localTopLevelNames: localTopLevelNames)
        recordSDKNominalShape(
            type: extended, genericClause: nil,
            members: extensionDecl.memberBlock.members,
            module: module,
            localTopLevelNames: localTopLevelNames)
        collectSDKProtocolDeclarations(
            in: extensionDecl.memberBlock.members,
            module: module, path: nestedSDKPath(
                for: extended, module: module),
            localTopLevelNames: localTopLevelNames, guarded: guarded)
    }
}

func sameTypeConcrete(
    in whereClause: GenericWhereClauseSyntax?,
    module: String,
    localTopLevelNames: Set<String>
) -> String? {
    let candidates = whereClause?.requirements.compactMap {
        requirement -> String? in
        guard let sameType = requirement.requirement.as(
            SameTypeRequirementSyntax.self) else { return nil }
        let left = canonicalSDKType(
            sameType.leftType.trimmedDescription, module: module,
            localTopLevelNames: localTopLevelNames)
        let right = canonicalSDKType(
            sameType.rightType.trimmedDescription, module: module,
            localTopLevelNames: localTopLevelNames)
        if left == "Self", right != "Self" { return right }
        if right == "Self", left != "Self" { return left }
        return nil
    } ?? []
    let unique = Set(candidates)
    return unique.count == 1 ? unique.first : nil
}

/// Records a method whose SOLE argument is a bare generic constrained to a
/// protocol — the shape that makes a leading-dot value the whole call:
/// `formatted(.units(width: .narrow))` names its style and nothing else.
///
/// Such a call cannot be dispatched by argument TYPE, because the argument is
/// written as a leading dot and has no type until the protocol picks one. The
/// method NAME is therefore the only thing that identifies the position, and
/// the interface is what states it — 12 declarations spell `formatted` across
/// Date, URL, Decimal, Duration, Measurement, PersonNameComponents and the
/// numeric protocols, under three different parameter names (`format`,
/// `style`, `v`). The parameter LABEL is not usable and the parameter NAME is
/// not stable, so neither is matched; the constraint is.
func recordSDKProtocolConsumingMethod(
    _ function: FunctionDeclSyntax,
    module: String,
    localTopLevelNames: Set<String>,
    guarded: Bool
) {
    guard isPublicSDKDecl(function.modifiers),
          !hasModifier(function.modifiers, "static"),
          isUniversallyUsable(function.attributes),
          !guarded,
          !needsAvailabilityGuard(function.attributes),
          let first = function.name.text.first, first.isLetter,
          !function.name.text.hasPrefix("_"),
          let generics = function.genericParameterClause?.parameters,
          function.signature.parameterClause.parameters.count == 1,
          let parameter = function.signature.parameterClause.parameters.first,
          parameter.firstName.text == "_" else { return }

    // The argument is written as the generic itself, not as something
    // containing it: `_ v: S` consumes a style, `_ v: Array<S>` does not.
    let parameterType = parameter.type.trimmedDescription
    guard generics.contains(where: { $0.name.text == parameterType }) else {
        return
    }

    // The constraint may be spelled inline (`<S: FormatStyle>`) or in the
    // where clause; both are the same fact and both are read.
    var constraints = Set<String>()
    for generic in generics where generic.name.text == parameterType {
        if let inherited = generic.inheritedType?.trimmedDescription {
            constraints.insert(canonicalSDKType(
                inherited, module: module,
                localTopLevelNames: localTopLevelNames))
        }
    }
    for requirement in function.genericWhereClause?.requirements ?? [] {
        guard let conformance = requirement.requirement.as(
            ConformanceRequirementSyntax.self),
            canonicalSDKType(
                conformance.leftType.trimmedDescription, module: module,
                localTopLevelNames: localTopLevelNames) == parameterType
        else { continue }
        constraints.insert(canonicalSDKType(
            conformance.rightType.trimmedDescription, module: module,
            localTopLevelNames: localTopLevelNames))
    }

    for constraint in constraints where sdkProtocols.contains(constraint) {
        sdkProtocolConsumingMethods.insert(.init(
            name: function.name.text, constraintProtocol: constraint))
    }
}

func recordSDKNominalConformances(
    type: String,
    inheritanceClause: InheritanceClauseSyntax?,
    module: String,
    localTopLevelNames: Set<String>
) {
    let conformances = Set(inheritanceClause?.inheritedTypes.map {
        canonicalSDKType(
            $0.type.trimmedDescription, module: module,
            localTopLevelNames: localTopLevelNames)
    } ?? []).intersection(sdkProtocols)
    sdkNominalConformances[type, default: []].formUnion(conformances)
}

func collectSDKProtocolMetadata(
    in members: MemberBlockItemListSyntax,
    module: String,
    path: [String],
    localTopLevelNames: Set<String>,
    guarded: Bool
) {
    for member in members {
        collectSDKProtocolMetadata(
            in: member.decl, module: module, path: path,
            localTopLevelNames: localTopLevelNames, guarded: guarded)
    }
}

/// Second pass: collect nominal conformances and public same-type protocol
/// factories. Every decision is a relationship present in the support
/// swiftinterface; no modifier, protocol, concrete type, or member spelling is
/// privileged.
func collectSDKProtocolMetadata(
    in decl: DeclSyntax,
    module: String,
    path: [String],
    localTopLevelNames: Set<String>,
    guarded inheritedGuarded: Bool
) {
    func usable(
        _ modifiers: DeclModifierListSyntax,
        _ attributes: AttributeListSyntax
    ) -> Bool {
        isPublicSDKDecl(modifiers)
            && isUniversallyUsable(attributes)
            && !inheritedGuarded
            && !needsAvailabilityGuard(attributes)
    }

    if let nominal = sdkNominalParts(decl) {
        guard usable(nominal.modifiers, nominal.attributes) else { return }
        let childPath = path + [nominal.name]
        if !nominal.isProtocol {
            recordSDKNominalConformances(
                type: "\(module).\(childPath.joined(separator: "."))",
                inheritanceClause: nominal.inheritance, module: module,
                localTopLevelNames: localTopLevelNames)
        }
        collectSDKProtocolMetadata(
            in: nominal.members, module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: false)
        return
    }

    if let function = decl.as(FunctionDeclSyntax.self) {
        recordSDKProtocolConsumingMethod(
            function, module: module,
            localTopLevelNames: localTopLevelNames, guarded: inheritedGuarded)
        return
    }

    guard let extensionDecl = decl.as(ExtensionDeclSyntax.self),
          isUniversallyUsable(extensionDecl.attributes),
          !inheritedGuarded,
          !needsAvailabilityGuard(extensionDecl.attributes) else { return }
    let extended = canonicalSDKType(
        extensionDecl.extendedType.trimmedDescription,
        module: module, localTopLevelNames: localTopLevelNames)
    recordSDKNominalConformances(
        type: extended, inheritanceClause: extensionDecl.inheritanceClause,
        module: module, localTopLevelNames: localTopLevelNames)

    let associatedTypes = publicSDKTypealiases(
        in: extensionDecl.memberBlock.members, module: module,
        localTopLevelNames: localTopLevelNames)
    if !associatedTypes.isEmpty {
        let base = normalize(extended)
        let conformances = extensionDecl.inheritanceClause?.inheritedTypes
            .map { inherited in
                canonicalSDKType(inherited.type.trimmedDescription,
                    module: module, localTopLevelNames: localTopLevelNames)
            }.filter { sdkProtocols.contains($0) } ?? []
        for conformance in conformances {
            sdkAssociatedConformances.append(.init(
                nominalBase: base,
                protocolType: normalize(conformance),
                genericParameters: sdkNominalGenericParameters[base] ?? [],
                associatedTypes: associatedTypes))
        }
    }

    if sdkProtocols.contains(extended),
       let concrete = sameTypeConcrete(
        in: extensionDecl.genericWhereClause, module: module,
        localTopLevelNames: localTopLevelNames) {
        for member in extensionDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  isPublicSDKDecl(variable.modifiers),
                  variable.modifiers.contains(where: {
                      $0.name.text == "static"
                  }),
                  isUniversallyUsable(variable.attributes),
                  !needsAvailabilityGuard(variable.attributes) else {
                continue
            }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(
                    IdentifierPatternSyntax.self),
                    let annotation = binding.typeAnnotation,
                    canonicalSDKType(
                        annotation.type.trimmedDescription,
                        module: module,
                        localTopLevelNames: localTopLevelNames
                    ) == concrete else { continue }
                sdkProtocolContextualValues.insert(.init(
                    member: identifier.identifier.text.trimmingCharacters(
                        in: CharacterSet(charactersIn: "`")),
                    concreteType: concrete,
                    declaringProtocol: extended))
            }
        }
        // The same extension's static FUNCS manufacture the same concrete
        // type from arguments. `Self` is the only return spelling the
        // constraint permits, so matching it needs no type table; a generic
        // factory is skipped because its own parameter would have to be
        // solved for before the concrete type is known.
        for member in extensionDecl.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  isPublicSDKDecl(function.modifiers),
                  hasModifier(function.modifiers, "static"),
                  isUniversallyUsable(function.attributes),
                  !needsAvailabilityGuard(function.attributes),
                  function.genericParameterClause == nil,
                  function.genericWhereClause == nil,
                  function.signature.effectSpecifiers == nil,
                  let first = function.name.text.first, first.isLetter,
                  !function.name.text.hasPrefix("_"),
                  let declaredReturn = function.signature.returnClause?.type
                    .trimmedDescription else { continue }
            let normalizedReturn = canonicalSDKType(
                declaredReturn, module: module,
                localTopLevelNames: localTopLevelNames)
            guard normalizedReturn == "Self"
                    || normalizedReturn == concrete else { continue }
            sdkProtocolContextualFactoryDecls.append(.init(
                concreteType: concrete,
                declaringProtocol: extended,
                function: function))
        }
    }

    collectSDKProtocolMetadata(
        in: extensionDecl.memberBlock.members,
        module: module,
        path: nestedSDKPath(for: extended, module: module),
        localTopLevelNames: localTopLevelNames, guarded: false)
}

func collectSDKFrameworkConfigurationMembers(
    in members: MemberBlockItemListSyntax,
    configurationType: String,
    module: String,
    localTopLevelNames: Set<String>,
    guarded: Bool
) {
    guard !guarded else { return }
    for member in members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              isPublicSDKDecl(variable.modifiers),
              !variable.modifiers.contains(where: {
                  $0.name.text == "static" || $0.name.text == "class"
              }),
              isUniversallyUsable(variable.attributes),
              !needsAvailabilityGuard(variable.attributes) else {
            continue
        }
        for binding in variable.bindings {
            guard let identifier = binding.pattern.as(
                IdentifierPatternSyntax.self),
                let annotation = binding.typeAnnotation else {
                continue
            }
            sdkFrameworkConfigurationMembers[
                configurationType, default: []
            ].insert(.init(
                name: identifier.identifier.text.trimmingCharacters(
                    in: CharacterSet(charactersIn: "`")),
                type: canonicalSDKType(
                    annotation.type.trimmedDescription,
                    module: module,
                    localTopLevelNames: localTopLevelNames)))
        }
    }
}

/// Third pass: project the public value surface of every Configuration
/// selected by the protocol-shape pass. Nominals and extensions use the same
/// property rule, so coverage grows with interface metadata rather than a
/// handwritten list of style or member identities.
func collectSDKFrameworkConfigurationMembers(
    in decl: DeclSyntax,
    module: String,
    path: [String],
    localTopLevelNames: Set<String>,
    guarded inheritedGuarded: Bool
) {
    func collect(
        name: String,
        modifiers: DeclModifierListSyntax,
        attributes: AttributeListSyntax,
        members: MemberBlockItemListSyntax
    ) {
        guard isPublicSDKDecl(modifiers),
              isUniversallyUsable(attributes) else { return }
        let childPath = path + [name]
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(attributes)
        let type = "\(module).\(childPath.joined(separator: "."))"
        if sdkFrameworkConfigurationTypes.contains(type) {
            collectSDKFrameworkConfigurationMembers(
                in: members,
                configurationType: type,
                module: module,
                localTopLevelNames: localTopLevelNames,
                guarded: guarded)
        }
        for member in members {
            collectSDKFrameworkConfigurationMembers(
                in: member.decl,
                module: module,
                path: childPath,
                localTopLevelNames: localTopLevelNames,
                guarded: guarded)
        }
    }

    if let nominal = sdkNominalParts(decl) {
        collect(
            name: nominal.name,
            modifiers: nominal.modifiers,
            attributes: nominal.attributes,
            members: nominal.members)
        return
    }
    guard let extensionDecl = decl.as(ExtensionDeclSyntax.self),
          isUniversallyUsable(extensionDecl.attributes) else { return }
    let guarded = inheritedGuarded
        || needsAvailabilityGuard(extensionDecl.attributes)
    let extended = canonicalSDKType(
        extensionDecl.extendedType.trimmedDescription,
        module: module,
        localTopLevelNames: localTopLevelNames)
    if sdkFrameworkConfigurationTypes.contains(extended) {
        collectSDKFrameworkConfigurationMembers(
            in: extensionDecl.memberBlock.members,
            configurationType: extended,
            module: module,
            localTopLevelNames: localTopLevelNames,
            guarded: guarded)
    }
    for member in extensionDecl.memberBlock.members {
        collectSDKFrameworkConfigurationMembers(
            in: member.decl,
            module: module,
            path: nestedSDKPath(for: extended, module: module),
            localTopLevelNames: localTopLevelNames,
            guarded: guarded)
    }
}

let protocolMetadataInterfaceFiles =
    primaryInterfaceFiles + supportingInterfaceFiles
    + [foundationInterfaceFile, stdlibInterfaceFile].compactMap { $0 }
for support in protocolMetadataInterfaceFiles {
    let localNames = topLevelSDKNames(in: support.file)
    for statement in support.file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        collectSDKProtocolDeclarations(
            in: decl, module: support.module, path: [],
            localTopLevelNames: localNames, guarded: false)
    }
    for statement in support.file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        collectSDKProtocolMetadata(
            in: decl, module: support.module, path: [],
            localTopLevelNames: localNames, guarded: false)
    }
    for statement in support.file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        collectSDKFrameworkConfigurationMembers(
            in: decl, module: support.module, path: [],
            localTopLevelNames: localNames, guarded: false)
    }
}

// MARK: - Automatically coercible contextual SDK values

func isPublicSDKDecl(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.text == "public" }
}

/// Contextual values follow the same interface provenance as the declaration
/// that consumes them. Package-universal values must compile on both package
/// platforms; iOS-overlay values may be absent from the macOS host as long as
/// their generated native coercion remains behind the overlay framework guard.
enum SDKContextualSweep {
    case packageUniversal
    case iOSOverlay

    func isUsable(_ attributes: AttributeListSyntax) -> Bool {
        switch self {
        case .packageUniversal:
            return isUniversallyUsable(attributes)
        case .iOSOverlay:
            return isUsableIOSOverlay(attributes)
        }
    }

    func needsGuard(_ attributes: AttributeListSyntax) -> Bool {
        switch self {
        case .packageUniversal:
            return needsAvailabilityGuard(attributes)
        case .iOSOverlay:
            // Target-overlay declarations retain their target availability
            // separately. A macOS availability guard would erase the
            // target-only declaration we are modeling.
            return false
        }
    }

    func isTargetOnly(_ attributes: AttributeListSyntax) -> Bool {
        self == .iOSOverlay
            && (!isUniversallyUsable(attributes)
                || !minimumTargetAvailabilities(attributes).isEmpty)
    }
}

func recordSDKContextualValues(
    type: String, members: [String],
    frameworkRequirements: Set<String>
) {
    guard !members.isEmpty else { return }
    sdkEnumCases[type] = Array(Set(
        (sdkEnumCases[type] ?? []) + members
    )).sorted()
    sdkEnumFrameworkRequirements[type, default: []]
        .formUnion(frameworkRequirements)
}

func recordSDKContextualMember(
    type: String, member: String,
    frameworkRequirements: Set<String>, minimumTargetAvailabilities:
        Set<GeneratedTargetAvailability>
) {
    recordSDKContextualValues(
        type: type, members: [member], frameworkRequirements: [])
    sdkEnumMemberFrameworkRequirements[type, default: [:]][member, default: []]
        .formUnion(frameworkRequirements)
    sdkEnumMemberMinimumTargetAvailabilities[type, default: [:]][member, default: []]
        .formUnion(minimumTargetAvailabilities)
}

func recordSDKContextualAvailability(
    type: String, attributes: AttributeListSyntax
) {
    sdkEnumMinimumTargetAvailabilities[type, default: []]
        .formUnion(minimumTargetAvailabilities(attributes))
}

/// A nested declaration cannot exist before any of its enclosing nominals.
/// Swift interfaces commonly put availability on the outer nominal only, so
/// derive the effective floor from every lexical type prefix rather than
/// requiring each nested declaration to repeat the attribute.
func minimumSDKContextualAvailabilities(
    for type: String
) -> Set<GeneratedTargetAvailability> {
    let components = type.split(separator: ".").map(String.init)
    return components.indices.reduce(into: []) { result, index in
        let prefix = components[...index].joined(separator: ".")
        result.formUnion(sdkEnumMinimumTargetAvailabilities[prefix] ?? [])
    }
}

func recordSDKSetAlgebraConformance(
    type: String, inheritanceClause: InheritanceClauseSyntax?, guarded: Bool
) {
    guard !guarded,
          inheritanceClause?.inheritedTypes.contains(where: {
              let inherited = normalize($0.type.trimmedDescription)
              return inherited == "SetAlgebra" || inherited == "OptionSet"
          }) == true else { return }
    sdkSetAlgebraTypes.insert(type)
}

/// A declaration such as `public static let all: VerticalEdge.Set` is the
/// value-struct/OptionSet equivalent of a payload-free enum case. The defining
/// property is structural: public static storage whose declared type is the
/// enclosing nominal, including declarations supplied by extensions.
func collectSameTypeSDKStatics(
    in members: MemberBlockItemListSyntax, type: String, guarded: Bool,
    frameworkRequirements: Set<String>,
    sweep: SDKContextualSweep, recordsValues: Bool,
    targetOnly inheritedTargetOnly: Bool,
    minimumTargetAvailabilities inheritedAvailabilities: Set<GeneratedTargetAvailability>
) {
    guard !guarded else { return }
    for member in members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              isPublicSDKDecl(variable.modifiers),
              variable.modifiers.contains(where: { $0.name.text == "static" }),
              sweep.isUsable(variable.attributes),
              !sweep.needsGuard(variable.attributes) else { continue }
        let declarationTargetOnly = sweep.isTargetOnly(variable.attributes)
        let targetOnly = inheritedTargetOnly || declarationTargetOnly
        guard recordsValues || targetOnly else { continue }
        for binding in variable.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  let annotation = binding.typeAnnotation else {
                continue
            }
            let annotatedType = normalize(
                annotation.type.trimmedDescription)
            guard annotatedType == type
                    || annotatedType.hasSuffix("." + type) else {
                continue
            }
            let name = identifier.identifier.text.trimmingCharacters(
                in: CharacterSet(charactersIn: "`"))
            if recordsValues {
                recordSDKContextualValues(
                    type: type, members: [name],
                    frameworkRequirements: frameworkRequirements)
            }
            if !recordsValues || declarationTargetOnly {
                recordSDKContextualMember(
                    type: type, member: name,
                    frameworkRequirements: frameworkRequirements,
                    minimumTargetAvailabilities:
                        inheritedAvailabilities.union(
                            minimumTargetAvailabilities(
                                variable.attributes)))
            }
        }
    }
}

func collectSDKEnums(
    in members: MemberBlockItemListSyntax, path: [String], guarded: Bool,
    frameworkRequirements: Set<String>,
    sweep: SDKContextualSweep = .packageUniversal,
    targetOnly inheritedTargetOnly: Bool = false
) {
    for member in members {
        collectSDKEnums(
            in: member.decl, path: path, guarded: guarded,
            frameworkRequirements: frameworkRequirements,
            sweep: sweep, targetOnly: inheritedTargetOnly)
    }
}

func collectSDKEnums(
    in decl: DeclSyntax, path: [String], guarded inheritedGuarded: Bool,
    frameworkRequirements inheritedRequirements: Set<String>,
    sweep: SDKContextualSweep = .packageUniversal,
    targetOnly inheritedTargetOnly: Bool = false
) {
    func collectNominal(
        name: String, modifiers: DeclModifierListSyntax,
        attributes: AttributeListSyntax,
        inheritanceClause: InheritanceClauseSyntax?,
        members: MemberBlockItemListSyntax,
        recordsSetAlgebra: Bool
    ) {
        guard isPublicSDKDecl(modifiers), sweep.isUsable(attributes),
              !name.hasPrefix("_") else { return }
        let childPath = path + [name]
        let guarded = inheritedGuarded || sweep.needsGuard(attributes)
        let targetOnly = inheritedTargetOnly
            || sweep.isTargetOnly(attributes)
        let recordsValues = sweep == .packageUniversal || targetOnly
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(attributes))
        let type = childPath.joined(separator: ".")
        recordSDKContextualAvailability(type: type, attributes: attributes)
        if recordsSetAlgebra {
            recordSDKSetAlgebraConformance(
                type: type, inheritanceClause: inheritanceClause,
                guarded: guarded || !recordsValues)
        }
        collectSameTypeSDKStatics(
            in: members, type: type, guarded: guarded,
            frameworkRequirements: requirements,
            sweep: sweep, recordsValues: recordsValues,
            targetOnly: targetOnly,
            minimumTargetAvailabilities:
                minimumSDKContextualAvailabilities(for: type))
        collectSDKEnums(
            in: members, path: childPath, guarded: guarded,
            frameworkRequirements: requirements,
            sweep: sweep, targetOnly: targetOnly)
    }

    if let enumDecl = decl.as(EnumDeclSyntax.self) {
        guard isPublicSDKDecl(enumDecl.modifiers),
              sweep.isUsable(enumDecl.attributes),
              !enumDecl.name.text.hasPrefix("_") else { return }
        let path = path + [enumDecl.name.text]
        let guarded = inheritedGuarded || sweep.needsGuard(enumDecl.attributes)
        let targetOnly = inheritedTargetOnly
            || sweep.isTargetOnly(enumDecl.attributes)
        let recordsValues = sweep == .packageUniversal || targetOnly
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(enumDecl.attributes))
        let type = path.joined(separator: ".")
        recordSDKContextualAvailability(
            type: type, attributes: enumDecl.attributes)
        recordSDKSetAlgebraConformance(
            type: type, inheritanceClause: enumDecl.inheritanceClause,
            guarded: guarded || !recordsValues)
        collectSameTypeSDKStatics(
            in: enumDecl.memberBlock.members, type: type, guarded: guarded,
            frameworkRequirements: requirements,
            sweep: sweep, recordsValues: recordsValues,
            targetOnly: targetOnly,
            minimumTargetAvailabilities:
                minimumSDKContextualAvailabilities(for: type))
        if !guarded, recordsValues {
            var cases: [String] = []
            for member in enumDecl.memberBlock.members {
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
                      sweep.isUsable(caseDecl.attributes),
                      !sweep.needsGuard(caseDecl.attributes) else { continue }
                for element in caseDecl.elements where element.parameterClause == nil {
                    cases.append(element.name.text.trimmingCharacters(in: CharacterSet(charactersIn: "`")))
                }
            }
            recordSDKContextualValues(
                type: type, members: cases,
                frameworkRequirements: requirements)
        }
        collectSDKEnums(
            in: enumDecl.memberBlock.members, path: path, guarded: guarded,
            frameworkRequirements: requirements,
            sweep: sweep, targetOnly: targetOnly)
        return
    }

    if let nominal = sdkNominalParts(decl) {
        collectNominal(
            name: nominal.name, modifiers: nominal.modifiers,
            attributes: nominal.attributes,
            inheritanceClause: nominal.inheritance,
            members: nominal.members,
            recordsSetAlgebra: !nominal.isProtocol)
        return
    }

    if let extensionDecl = decl.as(ExtensionDeclSyntax.self),
       sweep.isUsable(extensionDecl.attributes) {
        let extendedPath = normalize(extensionDecl.extendedType.trimmedDescription)
            .split(separator: ".").map(String.init)
        let guarded = inheritedGuarded
            || sweep.needsGuard(extensionDecl.attributes)
        let targetOnly = inheritedTargetOnly
            || sweep.isTargetOnly(extensionDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(extensionDecl.attributes))
        // A target-only extension can add a member to a package-universal
        // nominal, but it cannot change the nominal's own availability.
        // Recording the extension floor against the type would incorrectly
        // make every older case unavailable. Nested target-only declarations
        // still inherit the extension provenance through `targetOnly`.
        let recordsOwnValues = sweep == .packageUniversal
        if recordsOwnValues {
            recordSDKSetAlgebraConformance(
                type: extendedPath.joined(separator: "."),
                inheritanceClause: extensionDecl.inheritanceClause,
                guarded: guarded)
        }
        collectSameTypeSDKStatics(
            in: extensionDecl.memberBlock.members,
            type: extendedPath.joined(separator: "."), guarded: guarded,
            frameworkRequirements: requirements,
            sweep: sweep, recordsValues: recordsOwnValues,
            targetOnly: targetOnly,
            minimumTargetAvailabilities:
                minimumSDKContextualAvailabilities(
                    for: extendedPath.joined(separator: ".")
                ).union(minimumTargetAvailabilities(
                    extensionDecl.attributes)))
        collectSDKEnums(
            in: extensionDecl.memberBlock.members,
            path: extendedPath,
            guarded: guarded, frameworkRequirements: requirements,
            sweep: sweep, targetOnly: targetOnly)
    }
}

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        collectSDKEnums(
            in: decl, path: [], guarded: false,
            frameworkRequirements: [])
    }
}
for support in supportingInterfaceFiles {
    for statement in support.file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        collectSDKEnums(
            in: decl, path: [support.module], guarded: false,
            frameworkRequirements: [])
    }
}
// The target-overlay modifier sweep below must see the contextual values its
// own signatures consume. Traverse the same Catalyst interface with iOS
// availability, but record only declarations that are target-only (directly
// or through an enclosing nominal). Package-universal values were already
// collected above and must not acquire a spurious UIKit requirement merely
// because the Catalyst interface repeats them.
for file in targetOverlayFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        collectSDKEnums(
            in: decl, path: [], guarded: false,
            frameworkRequirements: ["UIKit"],
            sweep: .iOSOverlay)
    }
}

// AppKit/UIKit are predominantly Clang-imported Objective-C APIs, so their
// textual Swift overlays do not contain the declarations Swift source sees.
// Build that metadata model before sweeping SwiftUI so platform-valued
// SwiftUI parameters reuse the exact same selected nominal set.
let platformGeneration = try generatePlatformBridge()
platformTypeFrameworks = platformGeneration.typeFrameworks
let foundationReferencePropertyGeneration =
    try generateFoundationReferenceProperties()

/// Writable EnvironmentValues are dynamic only at the interpreted source
/// boundary. Their concrete key paths and value types are fully declared by
/// the swiftinterfaces, so generate one native writer for every mappable
/// property instead of teaching the handwritten gateway individual keys.
typealias EnvironmentValueVariant = (name: String, type: String, mapping: TypeMapping)
var environmentValueVariants: [String: EnvironmentValueVariant] = [:]
func collectEnvironmentValues(
    from members: MemberBlockItemListSyntax, attributes: AttributeListSyntax
) {
    guard isUniversallyUsable(attributes),
          !needsAvailabilityGuard(attributes) else { return }
    let setters = Set(["set", "_modify", "modify"])
    for member in members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              isPublicSDKDecl(variable.modifiers),
              !hasModifier(variable.modifiers, "static"),
              !hasModifier(variable.modifiers, "class"),
              isUniversallyUsable(variable.attributes),
              !needsAvailabilityGuard(variable.attributes) else { continue }
        for binding in variable.bindings {
            guard let identifier =
                    binding.pattern.as(IdentifierPatternSyntax.self),
                  let annotation = binding.typeAnnotation,
                  case .accessors(let accessors)? =
                    binding.accessorBlock?.accessors,
                  accessors.contains(where: {
                      setters.contains($0.accessorSpecifier.text)
                  }) else { continue }
            let declared = normalize(annotation.type.trimmedDescription)
            let isOptional = declared.hasSuffix("?")
            let type = isOptional ? String(declared.dropLast()) : declared
            guard var mapping = directMapping(for: type)?
                    .contextualized(as: type),
                  mapping.requiredFramework == nil else { continue }
            if isOptional { mapping = mapping.optionalized() }
            let name = identifier.identifier.text.trimmingCharacters(
                in: CharacterSet(charactersIn: "`"))
            environmentValueVariants[name] = (name, type, mapping)
        }
    }
}
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        let surface: (AttributeListSyntax, MemberBlockItemListSyntax)?
        if let nominal = declaration.as(StructDeclSyntax.self),
           normalize(nominal.name.text) == "EnvironmentValues" {
            surface = (nominal.attributes, nominal.memberBlock.members)
        } else if let ext = declaration.as(ExtensionDeclSyntax.self),
                  normalize(ext.extendedType.trimmedDescription)
                    == "EnvironmentValues" {
            surface = (ext.attributes, ext.memberBlock.members)
        } else { surface = nil }
        if let (attributes, members) = surface {
            collectEnvironmentValues(
                from: members, attributes: attributes)
        }
    }
}

// MARK: - Sweep

struct EmittableParam {
    let label: String?
    let tag: String
    let cast: String
    let isOptional: Bool
    /// The concrete type accepted by a generated Foundation gateway. View
    /// modifiers and constructors still use their ParamTag-only boundary.
    let contractType: String?
    let requiredFramework: String?
    let contextualType: String?

    init(
        label: String?, tag: String, cast: String,
        contractType: String? = nil, requiredFramework: String? = nil,
        contextualType: String? = nil, isOptional: Bool = false
    ) {
        self.label = label
        self.tag = tag
        self.cast = cast
        self.isOptional = isOptional
        self.contractType = contractType
        self.requiredFramework = requiredFramework
        self.contextualType = contextualType
    }

    init(analyzed value: AnalyzedParam) {
        let mapping = value.mapping!
        self.init(label: value.label, tag: mapping.tag, cast: mapping.cast,
            requiredFramework: mapping.requiredFramework,
            contextualType: mapping.contextualType, isOptional: mapping.isOptional)
    }
}

struct Variant {
    let name: String
    let params: [EmittableParam]
    let trailingClosureIndex: Int?
    /// Swift's overload solver ranks declarations carrying
    /// `@_disfavoredOverload` after otherwise viable peers. Preserve that
    /// interface metadata instead of depending on declaration discovery
    /// order in the generated table.
    let isDisfavoredOverload: Bool
    let inheritedFrameworkRequirements: Set<String>
    /// Imports required by the interpreted source target. Unlike compile-time
    /// framework guards, these survive into generated dispatch so a
    /// macOS-hosted interpreter can distinguish iOS source from macOS source.
    let targetImportRequirements: Set<String>
    /// Target environments explicitly excluded by interface availability.
    /// These complement framework import guards at generated compile time.
    let unavailableTargetEnvironments: Set<String>
    /// Target-specific minimum versions inherited from the declaration or
    /// its enclosing extension. Generated runtime guards preserve the
    /// contract below those versions without compiling an unavailable call.
    let minimumTargetAvailabilities: Set<GeneratedTargetAvailability>
    /// Values that are structurally both View and ShapeStyle must remain their
    /// concrete semantic value; erasing them to AnyView loses later style use.
    let preservesSemanticValue: Bool

    var key: String {
        name + "|" + params.map {
            "\($0.label ?? "_"):\($0.tag)\($0.isOptional ? "?" : "")"
        }.joined(separator: ",")
    }

    var requiredFrameworks: [String] {
        Array(inheritedFrameworkRequirements.union(
            params.compactMap(\.requiredFramework))).sorted()
    }
}

/// Names never emitted (compile problems or intentionally hand-only).
let denyNames: Set<String> = []

var variants: [Variant] = []
var seenKeys = Set<String>()

var modifierTotal = 0
var modifierGeneratable = 0
var modifierGuarded = 0
var modifierNames = Set<String>()
var generatableNames = Set<String>()
var modifierBlockers: [String: Int] = [:]

func acceptableModifierReturn(_ type: String) -> Bool {
    let normalized = normalize(type)
    return normalized.contains("some View") || normalized.hasPrefix("ModifiedContent<")
}

func processModifier(
    _ function: FunctionDeclSyntax, guarded: Bool,
    frameworkRequirements: Set<String>,
    targetImportRequirements: Set<String> = [],
    inheritedTargetEnvironmentExclusions: Set<String> = [],
    inheritedTargetAvailabilities: Set<GeneratedTargetAvailability> = [],
    retainsNewerTargetAvailability: Bool = false
) {
    guard isPublicSDKDecl(function.modifiers) else { return }
    let name = function.name.text
    guard !name.hasPrefix("_") else { return } // SPI-adjacent underscore APIs
    modifierTotal += 1
    modifierNames.insert(name)

    let generics = genericConstraints(of: function)
    let parameters = function.signature.parameterClause.parameters
    if parameters.contains(where: { $0.ellipsis != nil }) {
        modifierBlockers["variadic", default: 0] += 1
        return
    }
    let analyzed = parameters.map { analyzeParameter($0, generics: generics) }
    // A generic used by more than one parameter can't be instantiated
    // independently per-argument — skip those signatures.
    // A generic used by more than one parameter is legal only when every
    // use instantiates it to the SAME concrete type.
    let byGeneric = Dictionary(grouping: analyzed.filter { $0.usesGeneric != nil }, by: { $0.usesGeneric! })
    for (_, uses) in byGeneric {
        let concretes = Set(uses.map(\.genericConcrete))
        let actionAnchored = !uses.contains {
            $0.mapping?.tag.hasPrefix("equatableAction") == true
        } || uses.contains { $0.mapping?.tag == "equatable" }
        if !actionAnchored || (uses.count > 1
            && (concretes.count != 1 || concretes.first == nil)) {
            modifierBlockers["<shared generic>", default: 0] += 1
            return
        }
    }

    if let firstBlocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        modifierBlockers[firstBlocked.blocker ?? "?", default: 0] += 1
        if ProcessInfo.processInfo.environment[
            "BRIDGEGEN_DUMP_BLOCKED"
        ] != nil {
            print(
                "   blocked[\(firstBlocked.blocker ?? "?")] modifier "
                    + "\(name)\(parameters.trimmedDescription)")
        }
        return
    }
    if guarded
        || (needsAvailabilityGuard(function.attributes)
            && !retainsNewerTargetAvailability) {
        modifierGuarded += 1
        if ProcessInfo.processInfo.environment[
            "BRIDGEGEN_DUMP_BLOCKED"
        ] != nil {
            print(
                "   blocked[availability] modifier "
                    + "\(name)\(parameters.trimmedDescription)")
        }
        return
    }
    modifierGeneratable += 1
    generatableNames.insert(name)
    guard !denyNames.contains(name) else { return }

    for selection in parameterSelections(analyzed) {
        let variant = Variant(
            name: name,
            params: selection.params.map {
                .init(
                    label: $0.label, tag: $0.mapping!.tag,
                    cast: $0.mapping!.cast,
                    requiredFramework: $0.mapping!.requiredFramework,
                    contextualType: $0.mapping!.contextualType,
                    isOptional: $0.mapping!.isOptional)
            },
            trailingClosureIndex: selection.trailingClosureIndex,
            isDisfavoredOverload: function.attributes.contains {
                $0.as(AttributeSyntax.self)?
                    .attributeName.trimmedDescription
                    == "_disfavoredOverload"
            },
            inheritedFrameworkRequirements: frameworkRequirements.union(
                platformFrameworkRequirements(function.attributes)),
            targetImportRequirements: targetImportRequirements,
            unavailableTargetEnvironments:
                inheritedTargetEnvironmentExclusions.union(
                    unavailableTargetEnvironments(function.attributes)),
            minimumTargetAvailabilities:
                inheritedTargetAvailabilities.union(
                    minimumTargetAvailabilities(function.attributes)),
            preservesSemanticValue: false
        )
        if seenKeys.insert(variant.key).inserted {
            variants.append(variant)
        }
    }
}

// MARK: - SwiftUI constructor sweep

var initVariants: [Variant] = []
var initSeenKeys = Set<String>()
var initTotal = 0
var initGeneratable = 0
var initGuarded = 0
/// Newer-OS inits that are now EMITTED, behind the availability their own
/// interface declares. Reported separately from `initGuarded` so the two
/// dispositions — "guarded and reachable" and "unstatable, still dropped" —
/// can never be read as one number.
var initRuntimeGuarded = 0
/// Selections dropped because the nominal's own overload set makes the call
/// ambiguous — the compiler would reject the spelling too.
var initAmbiguous = 0

/// One declared initializer parameter, as the interface spells it.
struct InitParameterFact: Hashable {
    let label: String?
    let type: String
    let hasDefault: Bool
}

/// Every usable initializer a nominal declares, so a selection that omits
/// defaulted parameters can be checked against the SIBLINGS it would compete
/// with. Dropping a defaulted parameter is only legal when the remaining
/// labels still name exactly one initializer: `ConcentricRectangle` declares
/// several all-defaulted inits that share `topLeadingCorner:`, so
/// `ConcentricRectangle(topLeadingCorner:)` is ambiguous to the real compiler
/// and must not be emitted at all.
///
/// Only candidates the compiler would actually PREFER compete. A deprecated
/// or disfavored sibling loses overload resolution rather than making the call
/// ambiguous — `ScrollView(content:)` resolves today precisely because the
/// sibling accepting `content:` is `deprecated: 100000.0`.
var interfaceInitSignatures: [String: [[InitParameterFact]]] = [:]
var interfaceInitSignatureKeys: [String: Set<String>] = [:]

/// Whether an initializer is a candidate overload resolution would prefer.
func isPreferredOverloadCandidate(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let name = attr.attributeName.trimmedDescription
        if name == "_disfavoredOverload" { return false }
        guard name == "available" else { continue }
        let text = attr.trimmedDescription
        if text.contains("deprecated") || text.contains("obsoleted")
            || text.contains("unavailable") {
            return false
        }
    }
    return true
}
/// The initializer each emitted variant came from, so ambiguity is judged
/// against the declared types at the selected labels rather than labels alone
/// (two inits sharing a label but not its type are what the compiler resolves,
/// and they must keep both variants).
var initVariantOwnerSignature: [String: [InitParameterFact]] = [:]

func recordInterfaceInitSignature(
    of typeName: String, _ signature: [InitParameterFact],
    attributes: AttributeListSyntax
) {
    guard isPreferredOverloadCandidate(attributes) else { return }
    let key = signature.map {
        "\($0.label ?? "_"):\($0.type):\($0.hasDefault)"
    }.joined(separator: ",")
    guard interfaceInitSignatureKeys[typeName, default: []]
        .insert(key).inserted else { return }
    interfaceInitSignatures[typeName, default: []].append(signature)
}

/// Whether `signature` could satisfy a call that passes exactly `labels`,
/// with the declared types `reference` gives those labels.
func initSignature(
    _ signature: [InitParameterFact],
    accepts labels: [String],
    typedAs reference: [InitParameterFact]
) -> Bool {
    var remaining = signature
    for label in labels {
        guard let index = remaining.firstIndex(where: { $0.label == label }),
              let referenced = reference.first(where: { $0.label == label }),
              remaining[index].type == referenced.type
        else { return false }
        remaining.remove(at: index)
    }
    return remaining.allSatisfy(\.hasDefault)
}
var viewStructs = Set<String>()
var valueStructs = Set<String>()
/// A value struct's generic parameter names, in declaration order, so a
/// demanded instantiation's arguments can be bound positionally.
var valueStructGenericParameterNames: [String: [String]] = [:]
var generatableStructs = Set<String>()
var initBlockers: [String: Int] = [:]

/// Struct names never emitted (compile problems or hand-only semantics).
let denyStructs: Set<String> = []

func structGenerics(_ structDecl: StructDeclSyntax) -> Generics {
    var generics: Generics = [:]
    collectGenericClause(structDecl.genericParameterClause, into: &generics)
    collectWhereClause(structDecl.genericWhereClause, into: &generics)
    return generics
}

func processInit(
    _ structName: String, _ initDecl: InitializerDeclSyntax,
    generics baseGenerics: Generics, guarded: Bool,
    frameworkRequirements: Set<String>,
    preservesSemanticValue: Bool,
    requiresPlatformParameter: Bool = false
) {
    guard isPublicSDKDecl(initDecl.modifiers) else { return }
    initTotal += 1
    guard initDecl.optionalMark == nil else { return } // failable inits

    // Struct-level generics + the init's own clause: this is what unblocks
    // `@ViewBuilder content: () -> Content` where Content lives on the struct,
    // and `where Label == Text` same-type substitutions.
    var generics = baseGenerics
    collectGenericClause(initDecl.genericParameterClause, into: &generics)
    collectWhereClause(initDecl.genericWhereClause, into: &generics)

    let parameters = initDecl.signature.parameterClause.parameters
    let declaredSignature = parameters.map { parameter in
        InitParameterFact(
            label: parameter.firstName.text == "_"
                ? nil : parameter.firstName.text,
            type: normalize(parameter.type.trimmedDescription),
            hasDefault: parameter.defaultValue != nil)
    }
    recordInterfaceInitSignature(
        of: structName, declaredSignature,
        attributes: initDecl.attributes)
    if parameters.contains(where: { $0.ellipsis != nil }) {
        initBlockers["variadic", default: 0] += 1
        return
    }
    var generated = false
    var firstBlocker: String?
    let availabilityClauses = interfaceAvailabilitiesByType[
        structName, default: []
    ].union(minimumTargetAvailabilities(initDecl.attributes))
    for specialization in associatedGenericSpecializations(
        generics, parameters: parameters
    ).flatMap({
        uninhabitedGenericSpecializations($0, parameters: parameters)
    }) {
        let analyzed = parameters.map { analyzeParameter(
            $0, generics: specialization) }
        if requiresPlatformParameter,
           !analyzed.contains(where: { $0.mapping?.requiredFramework != nil }) {
            continue
        }
        let sharedGenericBlocked = Dictionary(
            grouping: analyzed.filter { $0.usesGeneric != nil },
            by: { $0.usesGeneric! }).values.contains { uses in
            let concretes = Set(uses.map(\.genericConcrete))
            let actionAnchored = !uses.contains {
                $0.mapping?.tag.hasPrefix("equatableAction") == true
            } || uses.contains { $0.mapping?.tag == "equatable" }
            return !actionAnchored || (uses.count > 1
                && (concretes.count != 1 || concretes.first == nil))
        }
        if sharedGenericBlocked {
            firstBlocker = firstBlocker ?? "<shared generic>"; continue
        }
        if let blocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
            firstBlocker = firstBlocker ?? blocked.blocker ?? "?"; continue
        }
        // Availability is the one obstacle that is not a missing mapping: the
        // parameters resolve, the call is spellable, and the only question is
        // whether the host running the generated bridge has the type. That is
        // a runtime question, and the interface states it — so state it back,
        // exactly as the target-overlay modifier tier already does. A verdict
        // with no clause behind it (a platform outside the generated floors)
        // still cannot be spelled, so it stays skipped.
        if guarded || needsAvailabilityGuard(initDecl.attributes) {
            guard !availabilityClauses.isEmpty else {
                initGuarded += 1; return
            }
            initRuntimeGuarded += 1
        }
        generated = true
        guard !denyStructs.contains(structName) else { continue }
        for selection in parameterSelections(analyzed) {
            let variant = Variant(
                name: structName,
                params: selection.params.map { .init(analyzed: $0) },
                trailingClosureIndex: selection.trailingClosureIndex,
                isDisfavoredOverload: initDecl.attributes.contains {
                    $0.as(AttributeSyntax.self)?
                        .attributeName.trimmedDescription
                        == "_disfavoredOverload"
                },
                inheritedFrameworkRequirements: frameworkRequirements.union(
                    platformFrameworkRequirements(initDecl.attributes)),
                targetImportRequirements: [],
                unavailableTargetEnvironments: [],
                // Only a declaration the generator would otherwise have
                // dropped carries a clause. An ordinary init stays
                // unconditional, so nothing already reachable becomes
                // conditional on the host's OS version.
                minimumTargetAvailabilities:
                    guarded || needsAvailabilityGuard(initDecl.attributes)
                        ? availabilityClauses : [],
                preservesSemanticValue: preservesSemanticValue)
            if initSeenKeys.insert(variant.key).inserted {
                initVariantOwnerSignature[variant.key] = declaredSignature
                initVariants.append(variant)
            }
        }
    }
    if generated { initGeneratable += 1; generatableStructs.insert(structName) }
    else if let firstBlocker {
        initBlockers[firstBlocker, default: 0] += 1
        if ProcessInfo.processInfo.environment["BRIDGEGEN_DUMP_BLOCKED"] != nil {
            print(
                "   blocked[\(firstBlocker)] init \(structName)"
                    + "\(initDecl.signature.parameterClause.trimmedDescription)")
        }
    }
}

// MARK: - Same-type static factories

/// A static whose declared result IS its enclosing nominal is a second
/// spelling of that type's constructor (`ContentUnavailableView.search(text:)`
/// beside `ContentUnavailableView(_:systemImage:)`). It needs its own emitted
/// surface because a leading-dot marker only ever resolves against a
/// parameter's expected type, and the positions these reach — a View body, a
/// `some View` result — declare no such type. Both interface spellings are
/// swept: the `static var` answers a value position, the `static func`
/// answers a call.
struct StaticFactoryVariant {
    let type: String
    let member: String
    /// A `static var`: emitted without a call, matched at arity zero.
    let isProperty: Bool
    let variant: Variant

    var key: String { type + "." + member + "|" + variant.key }
}

var staticFactoryVariants: [StaticFactoryVariant] = []
var staticFactorySeenKeys = Set<String>()
var staticFactoryTotal = 0
var staticFactoryBlockers: [String: Int] = [:]

/// The declared result names the enclosing nominal itself, whatever generic
/// arguments the constrained extension bound (`ContentUnavailableView<Label,
/// Description, Actions>` and `ContentUnavailableView<SearchUnavailableContent
/// .Label, …>` are both `ContentUnavailableView`). Swift infers those
/// arguments at the generated call site exactly as it does in source.
func staticFactoryReturnsEnclosingType(
    _ resultType: String, _ typeName: String
) -> Bool {
    let normalized = normalize(resultType)
        .trimmingCharacters(in: .whitespaces)
    if normalized == typeName { return true }
    guard let parts = genericTypeParts(normalized) else { return false }
    return parts.base == typeName
}

func processStaticFactory(
    _ typeName: String, _ function: FunctionDeclSyntax,
    generics baseGenerics: Generics, guarded: Bool,
    frameworkRequirements: Set<String>,
    preservesSemanticValue: Bool
) {
    // An operator's static declaration (`static func + (lhs:rhs:) -> Text`)
    // is same-type too, but it is spelled as an operator at every use site
    // and reaches the interpreter through operator dispatch, never as a
    // member read.
    guard isPublicSDKDecl(function.modifiers),
          hasModifier(function.modifiers, "static"),
          case .identifier = function.name.tokenKind,
          !function.name.text.hasPrefix("_"),
          function.signature.effectSpecifiers == nil,
          let returnType = function.signature.returnClause?.type.trimmedDescription,
          staticFactoryReturnsEnclosingType(returnType, typeName) else { return }
    staticFactoryTotal += 1
    guard !guarded, !needsAvailabilityGuard(function.attributes),
          isUsable(function.attributes) else { return }

    var generics = baseGenerics
    collectGenericClause(function.genericParameterClause, into: &generics)
    collectWhereClause(function.genericWhereClause, into: &generics)

    let parameters = function.signature.parameterClause.parameters
    guard !parameters.contains(where: { $0.ellipsis != nil }) else {
        staticFactoryBlockers["variadic", default: 0] += 1
        return
    }
    let analyzed = parameters.map { analyzeParameter($0, generics: generics) }
    if let blocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        staticFactoryBlockers[blocked.blocker ?? "?", default: 0] += 1
        return
    }
    for selection in parameterSelections(analyzed) {
        let candidate = StaticFactoryVariant(
            type: typeName,
            member: function.name.text,
            isProperty: false,
            variant: Variant(
                name: typeName + "." + function.name.text,
                params: selection.params.map { .init(analyzed: $0) },
                trailingClosureIndex: selection.trailingClosureIndex,
                isDisfavoredOverload: false,
                inheritedFrameworkRequirements: frameworkRequirements.union(
                    platformFrameworkRequirements(function.attributes)),
                targetImportRequirements: [],
                unavailableTargetEnvironments: [],
                minimumTargetAvailabilities: [],
                preservesSemanticValue: preservesSemanticValue))
        if staticFactorySeenKeys.insert(candidate.key).inserted {
            staticFactoryVariants.append(candidate)
        }
    }
}

func processStaticFactory(
    _ typeName: String, _ variable: VariableDeclSyntax,
    guarded: Bool, frameworkRequirements: Set<String>,
    preservesSemanticValue: Bool
) {
    guard isPublicSDKDecl(variable.modifiers),
          hasModifier(variable.modifiers, "static") else { return }
    for binding in variable.bindings {
        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
              !identifier.identifier.text.hasPrefix("_"),
              let annotation = binding.typeAnnotation,
              staticFactoryReturnsEnclosingType(
                  annotation.type.trimmedDescription, typeName) else { continue }
        staticFactoryTotal += 1
        guard !guarded, !needsAvailabilityGuard(variable.attributes),
              isUsable(variable.attributes) else { continue }
        let candidate = StaticFactoryVariant(
            type: typeName,
            member: identifier.identifier.text,
            isProperty: true,
            variant: Variant(
                name: typeName + "." + identifier.identifier.text,
                params: [],
                trailingClosureIndex: nil,
                isDisfavoredOverload: false,
                inheritedFrameworkRequirements: frameworkRequirements.union(
                    platformFrameworkRequirements(variable.attributes)),
                targetImportRequirements: [],
                unavailableTargetEnvironments: [],
                minimumTargetAvailabilities: [],
                preservesSemanticValue: preservesSemanticValue))
        if staticFactorySeenKeys.insert(candidate.key).inserted {
            staticFactoryVariants.append(candidate)
        }
    }
}

/// Sweep one member block for same-type statics. Struct declarations and
/// their constrained extensions supply the same shapes, so both passes of the
/// View sweep call this.
func collectStaticFactories(
    in members: MemberBlockItemListSyntax, type typeName: String,
    generics: Generics, guarded: Bool,
    frameworkRequirements: Set<String>,
    preservesSemanticValue: Bool
) {
    for member in members {
        if let function = member.decl.as(FunctionDeclSyntax.self) {
            processStaticFactory(
                typeName, function, generics: generics, guarded: guarded,
                frameworkRequirements: frameworkRequirements,
                preservesSemanticValue: preservesSemanticValue)
        }
        if let variable = member.decl.as(VariableDeclSyntax.self) {
            processStaticFactory(
                typeName, variable, guarded: guarded,
                frameworkRequirements: frameworkRequirements,
                preservesSemanticValue: preservesSemanticValue)
        }
    }
}

struct ViewConformanceInfo {
    let generics: Generics
    let guarded: Bool
    let frameworkRequirements: Set<String>
}

// View-producing protocols form an interface-declared refinement graph:
// Shape → View, InsettableShape → Shape, and so on. A constructor belongs in
// the View tier whenever its declared conformance reaches View transitively;
// requiring the literal `: View` spelling misses those ordinary SDK values.
let viewProtocolNames: Set<String> = {
    var names: Set<String> = ["View"]
    names.formUnion(sdkProtocols.compactMap { protocolName in
        protocolClosure(of: protocolName).contains(where: {
            normalize($0) == "View"
        }) ? normalize(protocolName) : nil
    })
    return names
}()

func includesViewConformance(_ conformances: Set<String>) -> Bool {
    !conformances.isDisjoint(with: viewProtocolNames)
}

// A public type's protocol conformances are frequently emitted separately
// from its declaration in a swiftinterface (`struct Image { ... }` followed
// by `extension Image: View`). Discover those conformances before looking at
// declarations so the constructor sweep is driven by interface semantics,
// independent of which spelling the SDK chose.
var extensionViewConformances: [String: ViewConformanceInfo] = [:]
var extensionShapeStyleConformances: Set<String> = []
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item,
              let ext = decl.as(ExtensionDeclSyntax.self),
              isUsable(ext.attributes) else { continue }
        let conformances = Set(
            ext.inheritanceClause?.inheritedTypes.map {
                normalize($0.type.trimmedDescription)
            } ?? [])
        let extendedType = normalize(ext.extendedType.trimmedDescription)
        if conformances.contains("ShapeStyle") {
            extensionShapeStyleConformances.insert(extendedType)
        }
        guard includesViewConformance(conformances) else { continue }
        var generics: Generics = [:]
        collectWhereClause(ext.genericWhereClause, into: &generics)
        extensionViewConformances[extendedType] = ViewConformanceInfo(
            generics: generics,
            guarded: needsAvailabilityGuard(ext.attributes),
            frameworkRequirements: platformFrameworkRequirements(
                ext.attributes))
    }
}

// A native nominal can flow through any consuming interface declaration
// without a type- or consumer-specific adapter. NESTING is not a property of
// the value: a consuming declaration spells `Namespace.ID` exactly as it
// spells `Color`, so the sweep walks nominal nesting and keys each type by
// the declaration path a parameter can name it with. Every enclosing nominal
// must itself be public and non-generic, since that path is what the emitted
// call site writes.
func collectConcreteNativeValueTypes(
    in declaration: DeclSyntax,
    path: [String],
    into found: inout Set<String>
) {
    func visit(_ members: MemberBlockItemListSyntax, path: [String]) {
        for member in members {
            collectConcreteNativeValueTypes(
                in: member.decl, path: path, into: &found)
        }
    }
    if let structure = declaration.as(StructDeclSyntax.self) {
        guard isPublicSDKDecl(structure.modifiers),
              isUsable(structure.attributes),
              !structure.name.text.hasPrefix("_") else { return }
        let nested = path + [structure.name.text]
        // A declaration's own availability guards the declaration; a type
        // NAMED inside a generic instantiation carries its own, and the two
        // can differ (`Binding<Chart3DPose>` is spelled by an initializer with
        // no guard at all, while `Chart3DPose` is macOS 26). Record it so a
        // specialized instantiation can fail closed on what it names.
        if needsAvailabilityGuard(structure.attributes) {
            newerOSNativeValueTypes.insert(nested.joined(separator: "."))
        }
        // A GENERIC struct is not a type until its arguments are supplied, so
        // it never joins the concrete set. Record its arity instead: a fully
        // specialized instantiation of it IS concrete, and that is what
        // `directMapping` needs to recognize below.
        guard structure.genericParameterClause == nil else {
            genericNativeSwiftUIValueTypeArity[nested.joined(separator: ".")] =
                structure.genericParameterClause?.parameters.count ?? 0
            visit(structure.memberBlock.members, path: nested)
            return
        }
        found.insert(nested.joined(separator: "."))
        visit(structure.memberBlock.members, path: nested)
        return
    }
    // An enum carries no value of its own into this tier — the SDK-enum tier
    // owns those — but it is an ordinary container for nested structs.
    if let enumeration = declaration.as(EnumDeclSyntax.self) {
        guard isPublicSDKDecl(enumeration.modifiers),
              isUsable(enumeration.attributes),
              enumeration.genericParameterClause == nil,
              !enumeration.name.text.hasPrefix("_") else { return }
        visit(
            enumeration.memberBlock.members,
            path: path + [enumeration.name.text])
    }
}

concreteNativeSwiftUIValueTypes = []
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        collectConcreteNativeValueTypes(
            in: declaration, path: [],
            into: &concreteNativeSwiftUIValueTypes)
    }
}

// Every argument position a generic type declares may be the uninhabited
// type. Read off `extension <Base> where <Parameter> == Never`, so which
// shapes exist is the interface's statement and not a list kept here.
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let extensionDeclaration = declaration.as(ExtensionDeclSyntax.self)
        else { continue }
        let base = normalize(
            extensionDeclaration.extendedType.trimmedDescription)
        guard let parameterNames = sdkNominalGenericParameters[base] else {
            continue
        }
        for requirement in extensionDeclaration.genericWhereClause?
            .requirements ?? [] {
            guard let sameType = requirement.requirement.as(
                SameTypeRequirementSyntax.self),
                  normalize(sameType.rightType.trimmedDescription) == "Never",
                  let position = parameterNames.firstIndex(
                    of: normalize(sameType.leftType.trimmedDescription))
            else { continue }
            sdkNominalNeverPositions[base, default: []].insert(position)
        }
    }
}

/// A property wrapper the FRAMEWORK, not the declaration, supplies a value
/// for. `@Namespace var ns` passes the wrapper no input and reads nothing
/// back but `wrappedValue`, so the interface alone settles what the storage
/// holds: a no-argument `init()`, a get-only `wrappedValue` of a concrete
/// type, and `DynamicProperty` conformance saying the framework owns the
/// storage. Nothing here names a wrapper; the shape selects them.
struct FrameworkSuppliedWrapper {
    let name: String
    let valueType: String
}
var frameworkSuppliedWrappers: [FrameworkSuppliedWrapper] = []
var frameworkSuppliedWrapperNames: Set<String> = []
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let structure = declaration.as(StructDeclSyntax.self),
              isPublicSDKDecl(structure.modifiers),
              isUniversallyUsable(structure.attributes),
              !needsAvailabilityGuard(structure.attributes),
              structure.genericParameterClause == nil,
              !structure.name.text.hasPrefix("_"),
              structure.attributes.contains(where: {
                  $0.as(AttributeSyntax.self)?.attributeName
                      .trimmedDescription == "propertyWrapper"
              }),
              structure.inheritanceClause?.inheritedTypes.contains(where: {
                  normalize($0.type.trimmedDescription) == "DynamicProperty"
              }) == true else { continue }
        let members = structure.memberBlock.members
        let takesNoInput = members.contains { member in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self),
                  isPublicSDKDecl(initializer.modifiers),
                  initializer.optionalMark == nil,
                  initializer.genericParameterClause == nil,
                  initializer.signature.effectSpecifiers == nil else {
                return false
            }
            return initializer.signature.parameterClause.parameters.isEmpty
        }
        let valueType = members.lazy.compactMap { member -> String? in
            guard let property = member.decl.as(VariableDeclSyntax.self),
                  isPublicSDKDecl(property.modifiers),
                  let binding = property.bindings.first,
                  binding.pattern.trimmedDescription == "wrappedValue",
                  let declared = binding.typeAnnotation?.type
                      .trimmedDescription else { return nil }
            let normalized = normalize(declared)
            // A generic or optional wrappedValue is not something the
            // framework can hand over without being told anything.
            guard !normalized.contains("<"), !normalized.hasSuffix("?"),
                  !normalized.contains("some ") else { return nil }
            return normalized
        }.first
        guard takesNoInput, let valueType,
              frameworkSuppliedWrapperNames.insert(structure.name.text)
                  .inserted else { continue }
        frameworkSuppliedWrappers.append(
            .init(name: structure.name.text, valueType: valueType))
    }
}
frameworkSuppliedWrappers.sort { $0.name < $1.name }

/// A property wrapper whose PROJECTION the interface publishes as a parameter
/// type but gives no way to build. `FocusState<Value>.Binding` stores a
/// `private var _binding` and declares `wrappedValue`/`projectedValue` and no
/// initializer at all, so a parameter of that type cannot be satisfied by
/// converting an argument — only by DECLARING the enclosing wrapper somewhere
/// real and passing what SwiftUI hands back.
///
/// That is the property collected here, and nothing below names a wrapper: an
/// initializer-less nested `@propertyWrapper` inside a generic
/// `@propertyWrapper` selects them. The generated carrier for each is what
/// makes such a parameter reachable at all.
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let structure = declaration.as(StructDeclSyntax.self),
              isPublicSDKDecl(structure.modifiers),
              isUsable(structure.attributes),
              structure.genericParameterClause != nil,
              !structure.name.text.hasPrefix("_"),
              structure.attributes.contains(where: {
                  $0.as(AttributeSyntax.self)?.attributeName
                      .trimmedDescription == "propertyWrapper"
              }) else { continue }
        // The nested projection type: itself a property wrapper, public, and
        // declaring no initializer any caller could reach.
        let projections = structure.memberBlock.members.compactMap {
            member -> StructDeclSyntax? in
            guard let nested = member.decl.as(StructDeclSyntax.self),
                  isPublicSDKDecl(nested.modifiers),
                  nested.attributes.contains(where: {
                      $0.as(AttributeSyntax.self)?.attributeName
                          .trimmedDescription == "propertyWrapper"
                  }),
                  !nested.memberBlock.members.contains(where: {
                      guard let initializer = $0.decl
                          .as(InitializerDeclSyntax.self) else { return false }
                      return isPublicSDKDecl(initializer.modifiers)
                  }) else { return nil }
            return nested
        }
        guard let projection = projections.first else { continue }
        // Which value shapes the ENCLOSING wrapper can actually be declared
        // in, since the carrier has to declare it: `Value == Bool` and
        // `Value == T?, T: Hashable` are the two the interface permits.
        var hasBool = false
        var hasOptionalHashable = false
        for member in structure.memberBlock.members {
            guard let initializer = member.decl
                .as(InitializerDeclSyntax.self),
                  isPublicSDKDecl(initializer.modifiers),
                  initializer.signature.parameterClause.parameters.isEmpty,
                  let whereClause = initializer.genericWhereClause else {
                continue
            }
            // What `Value` is pinned to by this initializer's same-type
            // requirement. The interface spells it `Swift.Bool` and leaves a
            // separator on all but the last requirement, so both go through
            // the same normalization every other type here does.
            let boundValues = whereClause.requirements.compactMap {
                requirement -> String? in
                let text = requirement.trimmedDescription
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                let sides = text.components(separatedBy: "==")
                guard sides.count == 2,
                      normalize(sides[0].trimmingCharacters(
                          in: .whitespaces)) == "Value" else { return nil }
                return normalize(sides[1].trimmingCharacters(in: .whitespaces))
            }
            if boundValues.contains("Bool") { hasBool = true }
            // `Value == T?` with `T: Hashable` — the generic is the wrapper's
            // own, so the shape, not the spelling, is what identifies it.
            if boundValues.contains(where: { $0.hasSuffix("?") }) {
                hasOptionalHashable = true
            }
        }
        guard hasBool || hasOptionalHashable else { continue }
        wrapperProjectionWrappers[
            "\(structure.name.text).\(projection.name.text)"
        ] = .init(
            wrapper: structure.name.text,
            hasBoolValue: hasBool,
            hasOptionalHashableValue: hasOptionalHashable)
    }
}

/// Read a use-site parameter type (`FocusState<Bool>.Binding`,
/// `AccessibilityFocusState<Value>.Binding`) back to the collected wrapper and
/// the value shape its generic argument asks for.
func wrapperProjectionMapping(for normalized: String) -> TypeMapping? {
    guard let open = normalized.firstIndex(of: "<"),
          let close = normalized.lastIndex(of: ">") else { return nil }
    let base = String(normalized[normalized.startIndex..<open])
    let nested = String(normalized[normalized.index(after: close)...])
    guard nested.hasPrefix("."),
          let projection = wrapperProjectionWrappers[base + nested]
    else { return nil }
    let argument = String(normalized[normalized.index(after: open)..<close])
    // `Bool` names the concrete shape; anything else at this position is the
    // declaration's own generic parameter, which the interface constrains to
    // Hashable and the wrapper can only hold as an optional.
    let isBoolShape = argument == "Bool"
    guard isBoolShape ? projection.hasBoolValue
        : projection.hasOptionalHashableValue else { return nil }
    return .init(
        tag: "wrapperProjection(\"\(projection.wrapper)\", \(!isBoolShape))",
        cast: isBoolShape
            ? "%@ as! Binding<Bool>"
            : "%@ as! Binding<InterpretedHashableValue?>")
}

// Pass A: View-extension modifiers + View structs (recording their generics
// so pass B can process extension-declared inits, where most of them live).
var viewStructInfo: [String: (
    generics: Generics,
    guarded: Bool,
    frameworkRequirements: Set<String>,
    preservesSemanticValue: Bool
)] = [:]

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item else { continue }

        if let ext = decl.as(ExtensionDeclSyntax.self),
           normalize(ext.extendedType.trimmedDescription) == "View",
           isUsable(ext.attributes) {
            let extGuarded = needsAvailabilityGuard(ext.attributes)
            for member in ext.memberBlock.members {
                guard let function = member.decl.as(FunctionDeclSyntax.self),
                      isUsable(function.attributes),
                      let returnType = function.signature.returnClause?.type.trimmedDescription,
                      acceptableModifierReturn(returnType) else { continue }
                processModifier(
                    function, guarded: extGuarded,
                    frameworkRequirements: platformFrameworkRequirements(
                        ext.attributes),
                    inheritedTargetAvailabilities:
                        minimumTargetAvailabilities(ext.attributes))
            }
        }

        if let structDecl = decl.as(StructDeclSyntax.self),
           isPublicSDKDecl(structDecl.modifiers),
           isUsable(structDecl.attributes),
           !structDecl.name.text.hasPrefix("_") {
            let name = structDecl.name.text
            let directConformances = Set(
                structDecl.inheritanceClause?.inheritedTypes.map {
                    normalize($0.type.trimmedDescription)
                } ?? [])
            let directlyConforms = includesViewConformance(
                directConformances)
            let extensionConformance = extensionViewConformances[name]
            guard directlyConforms || extensionConformance != nil else {
                continue
            }
            viewStructs.insert(name)
            let guarded = needsAvailabilityGuard(structDecl.attributes)
                || (extensionConformance?.guarded ?? false)
            recordInterfaceAvailability(of: name, structDecl.attributes)
            let frameworkRequirements = platformFrameworkRequirements(
                structDecl.attributes).union(
                    extensionConformance?.frameworkRequirements ?? [])
            var generics = structGenerics(structDecl)
            for (name, facts) in extensionConformance?.generics ?? [:] {
                generics[name] = facts
            }
            let preservesSemanticValue = directConformances.contains(
                "ShapeStyle")
                || extensionShapeStyleConformances.contains(name)
            viewStructInfo[name] = (
                generics, guarded, frameworkRequirements,
                preservesSemanticValue)
            collectStaticFactories(
                in: structDecl.memberBlock.members, type: name,
                generics: generics, guarded: guarded,
                frameworkRequirements: frameworkRequirements,
                preservesSemanticValue: preservesSemanticValue)
            for member in structDecl.memberBlock.members {
                guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                      isUsable(initDecl.attributes) else { continue }
                processInit(
                    name, initDecl, generics: generics, guarded: guarded,
                    frameworkRequirements: frameworkRequirements,
                    preservesSemanticValue: preservesSemanticValue)
            }
        }
    }
}

// Pass B: inits declared in extensions of known View structs (e.g.
// `extension GroupBox where Label == Text { init(_ titleKey:content:) }`).
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item,
              let ext = decl.as(ExtensionDeclSyntax.self),
              isUsable(ext.attributes) else { continue }
        let extendedName = normalize(ext.extendedType.trimmedDescription)
        guard let info = viewStructInfo[extendedName] else { continue }
        var generics = info.generics
        collectWhereClause(ext.genericWhereClause, into: &generics)
        let guarded = info.guarded || needsAvailabilityGuard(ext.attributes)
        let frameworkRequirements = info.frameworkRequirements.union(
            platformFrameworkRequirements(ext.attributes))
        collectStaticFactories(
            in: ext.memberBlock.members, type: extendedName,
            generics: generics, guarded: guarded,
            frameworkRequirements: frameworkRequirements,
            preservesSemanticValue: info.preservesSemanticValue)
        for member in ext.memberBlock.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                  isUsable(initDecl.attributes) else { continue }
            processInit(
                extendedName, initDecl, generics: generics, guarded: guarded,
                frameworkRequirements: frameworkRequirements,
                preservesSemanticValue: info.preservesSemanticValue)
        }
    }
}

// Pass RB: concrete leaves of interface-declared non-View result builders.
// Their native values must retain protocol conformance until the generated
// typed carrier composes them. Eligibility comes from the demanded builder
// result protocols and the SDK conformance graph; no leaf type is named.
var extensionResultBuilderConformances: [
    String: (
        protocols: Set<String>,
        generics: Generics,
        guarded: Bool,
        frameworkRequirements: Set<String>
    )
] = [:]
let demandedResultBuilderProtocols = Set(interfaceResultBuilders.keys)

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let ext = declaration.as(ExtensionDeclSyntax.self),
              isUsable(ext.attributes) else {
            continue
        }
        let protocols = Set(
            ext.inheritanceClause?.inheritedTypes.map {
                normalize($0.type.trimmedDescription)
            } ?? []
        ).intersection(demandedResultBuilderProtocols)
        guard !protocols.isEmpty else { continue }
        let type = normalize(ext.extendedType.trimmedDescription)
        var generics = extensionResultBuilderConformances[type]?.generics
            ?? [:]
        collectWhereClause(ext.genericWhereClause, into: &generics)
        let previous = extensionResultBuilderConformances[type]
        extensionResultBuilderConformances[type] = (
            protocols.union(previous?.protocols ?? []),
            generics,
            needsAvailabilityGuard(ext.attributes)
                || (previous?.guarded ?? false),
            platformFrameworkRequirements(ext.attributes).union(
                previous?.frameworkRequirements ?? [])
        )
    }
}

var resultBuilderContentInfo: [
    String: (
        protocols: Set<String>,
        generics: Generics,
        guarded: Bool,
        frameworkRequirements: Set<String>
    )
] = [:]

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let structure = declaration.as(StructDeclSyntax.self),
              isPublicSDKDecl(structure.modifiers),
              isUsable(structure.attributes),
              !structure.name.text.hasPrefix("_") else {
            continue
        }
        let name = structure.name.text
        let direct = Set(
            structure.inheritanceClause?.inheritedTypes.map {
                normalize($0.type.trimmedDescription)
            } ?? []
        ).intersection(demandedResultBuilderProtocols)
        let extensionInfo = extensionResultBuilderConformances[name]
        guard !direct.isEmpty || extensionInfo != nil,
              !viewStructs.contains(name) else {
            continue
        }
        var generics = structGenerics(structure)
        for (generic, facts) in extensionInfo?.generics ?? [:] {
            generics[generic] = facts
        }
        let guarded = needsAvailabilityGuard(structure.attributes)
            || (extensionInfo?.guarded ?? false)
        recordInterfaceAvailability(of: name, structure.attributes)
        let frameworks = platformFrameworkRequirements(
            structure.attributes
        ).union(extensionInfo?.frameworkRequirements ?? [])
        resultBuilderContentInfo[name] = (
            direct.union(extensionInfo?.protocols ?? []),
            generics, guarded, frameworks)
    }
}

// Cross-import overlay modifiers are ordinary interface-derived API whose
// declarations live outside both public modules. Keep the triggering import
// as a runtime availability property and the overlay's declared target
// exclusions as compile guards.
for overlay in swiftUICrossImportFiles {
    for statement in overlay.syntax.statements {
        guard case .decl(let decl) = statement.item,
              let ext = decl.as(ExtensionDeclSyntax.self),
              normalize(ext.extendedType.trimmedDescription) == "View",
              isUsable(ext.attributes) else { continue }
        let extGuarded = needsAvailabilityGuard(ext.attributes)
        for member in ext.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  isUsable(function.attributes),
                  let returnType = function.signature.returnClause?.type
                    .trimmedDescription,
                  acceptableModifierReturn(returnType) else { continue }
            processModifier(
                function,
                guarded: extGuarded,
                frameworkRequirements:
                    platformFrameworkRequirements(ext.attributes).union(
                        [overlay.triggeringModule]),
                targetImportRequirements: [overlay.triggeringModule],
                inheritedTargetEnvironmentExclusions:
                    unavailableTargetEnvironments(ext.attributes),
                inheritedTargetAvailabilities:
                    minimumTargetAvailabilities(ext.attributes))
        }
    }
}

// Target-overlay View modifiers are ordinary interface-derived API even when
// the macOS host interface marks them unavailable. Generate their real calls
// where the platform framework can compile, plus a reusable receiver-
// preserving adapter for a host rendering that target off-platform. Runtime
// selection retains the overlay's import requirement, so this does not make
// the target-only source spelling legal for a macOS interpreter.
for file in targetOverlayFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item,
              let ext = decl.as(ExtensionDeclSyntax.self),
              normalize(ext.extendedType.trimmedDescription) == "View",
              isUsableIOSOverlay(ext.attributes) else { continue }
        for member in ext.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  isUsableIOSOverlay(function.attributes),
                  let returnType = function.signature.returnClause?.type
                    .trimmedDescription,
                  acceptableModifierReturn(returnType) else { continue }
            processModifier(
                function,
                guarded: false,
                frameworkRequirements: ["UIKit"],
                targetImportRequirements: ["UIKit"],
                inheritedTargetAvailabilities:
                    minimumTargetAvailabilities(ext.attributes),
                retainsNewerTargetAvailability: true)
        }
    }
}

// Pass C: target-only overlay initializers on View types known from the host
// interface. Exact native calls stay framework-guarded; a later structural
// adapter keeps View+ShapeStyle values usable when this interpreter renders a
// target whose platform framework is unavailable on the host.
for file in targetOverlayFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item,
              let ext = decl.as(ExtensionDeclSyntax.self),
              isUsableIOSOverlay(ext.attributes),
              minimumTargetAvailabilities(ext.attributes).isEmpty else {
            continue
        }
        let extendedName = normalize(ext.extendedType.trimmedDescription)
        guard let info = viewStructInfo[extendedName] else { continue }
        var generics = info.generics
        collectWhereClause(ext.genericWhereClause, into: &generics)
        for member in ext.memberBlock.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                  isUsableIOSOverlay(initDecl.attributes),
                  minimumTargetAvailabilities(
                    initDecl.attributes).isEmpty else {
                continue
            }
            processInit(
                extendedName, initDecl, generics: generics, guarded: false,
                frameworkRequirements: info.frameworkRequirements.union(
                    ["UIKit"]),
                preservesSemanticValue: info.preservesSemanticValue,
                requiresPlatformParameter: true)
        }
    }
}

// Pass D: value types that generated SwiftUI declarations consume as concrete
// parameters. Their public, mechanically coercible initializers belong to the
// same generated constructor table, so contextual leading-dot arguments use
// the interface-declared parameter type before any native coercion. Selection
// is demand-derived from emitted parameter metadata; no value-type or
// initializer identity is encoded here.
let generatedParameterValueTypes = Set(
    (variants + initVariants).flatMap {
        $0.params.compactMap(\.contextualType)
    }
).filter {
    !viewStructs.contains($0) && directMapping(for: $0) != nil
}
var valueStructInfo: [String: (
    generics: Generics,
    guarded: Bool,
    frameworkRequirements: Set<String>
)] = [:]

/// A demanded value type may be a generic INSTANTIATION
/// (`SharePreview<InterpretedTransferableValue, Never>`), while scanning is
/// keyed on the struct. Record the argument list each struct was demanded at,
/// so its own generic parameters can be bound to those arguments before its
/// initializers are read — left unbound they are ordinary constrained
/// generics and every initializer blocks on them, which is the state that made
/// `SharePreview` unscannable and `ShareLink(item:…preview:)` unreachable.
var demandedValueStructArguments: [String: Set<[String]>] = [:]
for demanded in generatedParameterValueTypes {
    guard let parts = genericTypeParts(demanded) else { continue }
    demandedValueStructArguments[parts.base, default: []]
        .insert(parts.arguments)
}

/// Bind a struct's generic parameters, in declaration order, to one demanded
/// argument list. Returns nil when a binding would contradict a requirement
/// the declaration already states — an extension constrained `where Icon ==
/// Never` says nothing about the instantiation that supplies an icon.
func specializedValueStructGenerics(
    _ base: Generics, parameterNames: [String], arguments: [String]
) -> Generics? {
    guard parameterNames.count == arguments.count else { return nil }
    var specialized = base
    for (name, argument) in zip(parameterNames, arguments) {
        if case .concrete(let required)? = base[name],
           normalize(required) != normalize(argument) {
            return nil
        }
        specialized[name] = .concrete(argument)
    }
    return specialized
}

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let structure = declaration.as(StructDeclSyntax.self),
              isPublicSDKDecl(structure.modifiers),
              isUsable(structure.attributes),
              !structure.name.text.hasPrefix("_") else {
            continue
        }
        let name = structure.name.text
        let demandedArguments = demandedValueStructArguments[name] ?? []
        guard generatedParameterValueTypes.contains(name)
                || !demandedArguments.isEmpty else {
            continue
        }
        let guarded = needsAvailabilityGuard(structure.attributes)
        recordInterfaceAvailability(of: name, structure.attributes)
        let frameworkRequirements = platformFrameworkRequirements(
            structure.attributes)
        let generics = structGenerics(structure)
        let parameterNames = structure.genericParameterClause?
            .parameters.map(\.name.text) ?? []
        valueStructs.insert(name)
        valueStructInfo[name] = (
            generics, guarded, frameworkRequirements)
        valueStructGenericParameterNames[name] = parameterNames
        // A non-generic struct is demanded by name and scanned once; a generic
        // one is scanned once per instantiation it was demanded at.
        let specializations: [Generics] = demandedArguments.isEmpty
            ? [generics]
            : demandedArguments.compactMap {
                specializedValueStructGenerics(
                    generics, parameterNames: parameterNames, arguments: $0)
            }
        for member in structure.memberBlock.members {
            guard let initializer = member.decl.as(
                InitializerDeclSyntax.self),
                  isUsable(initializer.attributes) else {
                continue
            }
            for specialization in specializations {
                processInit(
                    name, initializer, generics: specialization,
                    guarded: guarded,
                    frameworkRequirements: frameworkRequirements,
                    preservesSemanticValue: true)
            }
        }
    }
}

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let extensionDeclaration = declaration.as(
                ExtensionDeclSyntax.self),
              isUsable(extensionDeclaration.attributes) else {
            continue
        }
        let extendedName = normalize(
            extensionDeclaration.extendedType.trimmedDescription)
        guard let info = valueStructInfo[extendedName] else {
            continue
        }
        var generics = info.generics
        collectWhereClause(
            extensionDeclaration.genericWhereClause, into: &generics)
        let guarded = info.guarded
            || needsAvailabilityGuard(extensionDeclaration.attributes)
        let frameworkRequirements = info.frameworkRequirements.union(
            platformFrameworkRequirements(
                extensionDeclaration.attributes))
        // The where-clause is read FIRST, so a demanded instantiation that
        // contradicts it drops out here rather than emitting an initializer
        // this extension does not declare: `extension SharePreview where Icon
        // == Never` offers `init(_:image:)` to the icon-less instantiation
        // only.
        let demandedArguments = demandedValueStructArguments[extendedName] ?? []
        let specializations: [Generics] = demandedArguments.isEmpty
            ? [generics]
            : demandedArguments.compactMap {
                specializedValueStructGenerics(
                    generics,
                    parameterNames: valueStructGenericParameterNames[
                        extendedName] ?? [],
                    arguments: $0)
            }
        for member in extensionDeclaration.memberBlock.members {
            guard let initializer = member.decl.as(
                InitializerDeclSyntax.self),
                  isUsable(initializer.attributes) else {
                continue
            }
            for specialization in specializations {
                processInit(
                    extendedName, initializer, generics: specialization,
                    guarded: guarded,
                    frameworkRequirements: frameworkRequirements,
                    preservesSemanticValue: true)
            }
        }
    }
}

struct PlatformSemanticAdapterVariant {
    enum ResultKind {
        case shapeStyle
        case view
    }

    let variant: Variant
    let unavailableFramework: String
    let resultKind: ResultKind
}

/// A one-parameter platform initializer carries enough structural information
/// to ask its argument for off-host semantics. View+ShapeStyle results retain
/// style behavior; every other View result accepts only a payload which
/// explicitly advertises a transferable primitive View. The generated adapter
/// exists only where the exact native initializer cannot compile, and no
/// target/member identity participates.
let platformSemanticAdapterVariants: [PlatformSemanticAdapterVariant] = {
    var seen: Set<String> = []
    return initVariants.compactMap {
        (variant: Variant) -> PlatformSemanticAdapterVariant? in
        guard variant.params.count == 1,
              let parameter = variant.params.first,
              parameter.tag.hasPrefix("platformValue("),
              let framework = parameter.requiredFramework else { return nil }
        let semanticParameter = EmittableParam(
            label: parameter.label,
            tag: parameter.tag.replacingOccurrences(
                of: "platformValue(", with: "platformSemanticValue("),
            cast: "%@", requiredFramework: nil,
            contextualType: parameter.contextualType,
            isOptional: parameter.isOptional)
        let adapter = Variant(
            name: variant.name, params: [semanticParameter],
            trailingClosureIndex: nil,
            isDisfavoredOverload: variant.isDisfavoredOverload,
            inheritedFrameworkRequirements: [],
            targetImportRequirements: [],
            unavailableTargetEnvironments: [],
            minimumTargetAvailabilities: [],
            preservesSemanticValue: true)
        let key = "\(framework)|\(adapter.key)"
        guard seen.insert(key).inserted else { return nil }
        return PlatformSemanticAdapterVariant(
            variant: adapter,
            unavailableFramework: framework,
            resultKind: variant.preservesSemanticValue ? .shapeStyle : .view)
    }
}()

// MARK: - SDK member sweep

/// Foundation value types whose instance surface the generated-members tier
/// serves.
/// Receiver downcasts run against the host's dynamic type, so only types a
/// `.host` value actually carries belong here (boxes like URLComponentsBox
/// keep their own dynamic type and never reach this table).
let foundationMemberTypes: Set<String> = [
    "URL", "Data", "Date", "UUID", "Calendar", "TimeZone", "Locale",
    "DateComponents", "DateInterval", "URLComponents", "URLQueryItem",
    "URLRequest", "CharacterSet", "IndexSet",
    "Decimal", "IndexPath", "PersonNameComponents",
    // AttributedString is already carried by the bridge for mutable styling.
    // Sweep its value surface plus the element type reached through its
    // interface-declared `Runs: BidirectionalCollection` property.
    "AttributedString", "AttributedString.Runs.Run",
    // Generic value carrier (genericStructCarriers): swept with UnitType
    // substituted to Dimension, constructed/cast as Measurement<Dimension>.
    "Measurement",
    // Charts value-plane carrier (swept from the Charts swiftinterface):
    // interpreted axis builders hand its thresholds straight back to real
    // AxisMarks. NumberBins stays out — it is generic over Value.
    "DateBins",
]

/// A non-generic SDK View can cross the runtime as its real native value.
/// Sweep only members whose result preserves that receiver type; this is the
/// interface-derived concrete-semantics tier for APIs such as an Image
/// transform, without enumerating a View type or member name.
let concreteViewMemberTypes = Set(viewStructInfo.compactMap {
    name, info in info.generics.isEmpty ? name : nil
})

/// Protocol extensions serve their CONCRETE runtime carriers: the
/// interpreter's numeric payloads are Int and Double, so members Foundation
/// publishes on the numeric protocols (`formatted()` and the FormatStyle
/// family) register once per carrier the dispatch can actually receive.
/// While sweeping a protocol extension for a concrete carrier, `Self`
/// params/returns mean the carrier (`isMultiple(of other: Self)`).
var currentSelfCarrier: String?
var currentConcreteViewMemberReceiver = false

let protocolReceivers: [String: [String]] = [
    "BinaryInteger": ["Int"],
    "SignedInteger": ["Int"],
    "FixedWidthInteger": ["Int"],
    "BinaryFloatingPoint": ["Double"],
    "FloatingPoint": ["Double"],
]

/// Generic value STRUCTS served through one concrete runtime carrier —
/// the protocolReceivers idea applied to generic receivers. While
/// sweeping the type, the generic parameter substitutes to the carrier
/// argument, and emitted receiver casts use the full carrier spelling.
struct GenericStructCarrier {
    let generic: String        // "UnitType"
    let substitute: String     // "Dimension"
    let carrier: String        // "Measurement<Dimension>"
}

var genericStructCarriers: [String: GenericStructCarrier] = [
    "Measurement": .init(
        generic: "UnitType", substitute: "Dimension",
        carrier: "Measurement<Dimension>"),
]
let foundationalGenericStructCarrierKeys = Set(genericStructCarriers.keys)

/// Admit only an interface-proven, unambiguous single-parameter carrier.
let associatedPlainMemberTypes = Set(
    associatedGenericConcreteTypes.filter { !$0.contains("<") })
let associatedGenericCarrierCandidates = Dictionary(grouping:
    associatedGenericConcreteTypes.compactMap {
        concrete -> (base: String, carrier: String, generic: String, argument: String)? in
    guard let parts = genericTypeParts(concrete),
          let generics = sdkNominalGenericParameters[parts.base],
          generics.count == 1, parts.arguments.count == 1 else { return nil }
    return (parts.base, concrete, generics[0], parts.arguments[0])
}, by: \.base)
for (base, candidates) in associatedGenericCarrierCandidates
where candidates.count == 1 {
    let candidate = candidates[0]
    genericStructCarriers[base] = .init(generic: candidate.generic,
        substitute: candidate.argument, carrier: candidate.carrier)
}
let associatedMemberTypeKeys = associatedPlainMemberTypes.union(
    Set(genericStructCarriers.keys).subtracting(
        foundationalGenericStructCarrierKeys))
let memberTypes = foundationMemberTypes
    .union(concreteViewMemberTypes).union(associatedMemberTypeKeys)

var currentGenericSubstitution: (from: String, to: String)?
var currentAssociatedMemberReceiver = false

/// The Swift spelling emitted receiver casts use for a member-table type.
func memberReceiverCast(for type: String) -> String {
    genericStructCarriers[type]?.carrier ?? type
}

func memberMapping(for normalized: String) -> TypeMapping? {
    if normalized == "Self", let carrier = currentSelfCarrier {
        return memberMapping(for: carrier)
    }
    var normalized = normalized
    if let sub = currentGenericSubstitution, normalized.contains(sub.from) {
        normalized = normalized.replacingOccurrences(of: sub.from, with: sub.to)
    }
    normalized = resolvingSDKTypealiases(normalized)
    switch normalized {
    case "String", "StringProtocol": return .init(tag: "string", cast: "%@ as! String")
    case "Bool": return .init(tag: "bool", cast: "%@ as! Bool")
    case "Int": return .init(tag: "int", cast: "%@ as! Int")
    case "Double", "TimeInterval": return .init(tag: "double", cast: "%@ as! Double")
    case "Date": return .init(tag: "date", cast: "%@ as! Date")
    case "URL": return .init(tag: "url", cast: "%@ as! URL")
    case "Data": return .init(tag: "data", cast: "%@ as! Data")
    case "[String]": return .init(tag: "stringArray", cast: "%@ as! [String]")
    case "Decimal": return .init(tag: "decimal", cast: "%@ as! Decimal")
    case "CharacterSet": return .init(tag: "characterSet", cast: "%@ as! CharacterSet")
    case "IndexSet": return .init(tag: "indexSet", cast: "%@ as! IndexSet")
    case "DateComponents": return .init(tag: "dateComponents", cast: "%@ as! DateComponents")
    case "DateInterval": return .init(tag: "dateInterval", cast: "%@ as! DateInterval")
    case "IndexPath": return .init(tag: "indexPath", cast: "%@ as! IndexPath")
    // Collection-position typealiases that resolve to Int. NOT
    // IndexSet.Index — that one is an opaque struct (the twin's compile
    // caught the difference).
    case "IndexSet.Element", "IndexPath.Element", "IndexPath.Index":
        return .init(tag: "int", cast: "%@ as! Int")
    case "[Int]", "[IndexPath.Element]", "Array<IndexPath.Element>", "[IndexSet.Element]":
        return .init(tag: "intArray", cast: "%@ as! [Int]")
    case "Range<Int>", "Range<IndexSet.Element>", "Range<IndexPath.Element>":
        return .init(tag: "intRange", cast: "%@ as! Range<Int>")
    case "Dimension":
        return .init(tag: "dimension", cast: "%@ as! Dimension")
    case "Measurement<Dimension>":
        return .init(tag: "measurement", cast: "%@ as! Measurement<Dimension>")
    case "Calendar.Component":
        return .init(tag: "calendarComponent", cast: "%@ as! Calendar.Component")
    case "Set<Calendar.Component>":
        return .init(tag: "calendarComponentSet", cast: "%@ as! Set<Calendar.Component>")
    default:
        // Concrete View members reuse the complete SwiftUI coercion model.
        // Foundation stays on its deliberately narrower value-plane mapping,
        // so growing this tier cannot silently widen unrelated SDK methods.
        return currentConcreteViewMemberReceiver
                || currentAssociatedMemberReceiver
            ? directMapping(for: normalized) : nil
    }
}

/// Typealiases whose runtime representation is deliberately narrower than
/// the SDK spelling. Contracts describe what the interpreter actually
/// carries across the boundary while generated static code still compiles
/// against the original declaration.
func memberContractType(for normalized: String) -> String {
    if let sub = currentGenericSubstitution, normalized.contains(sub.from) {
        return memberContractType(
            for: normalized.replacingOccurrences(of: sub.from, with: sub.to))
    }
    if normalized.hasSuffix("?") {
        return memberContractType(for: String(normalized.dropLast())) + "?"
    }
    switch normalized {
    case "StringProtocol":
        return "String"
    case "IndexSet.Element", "IndexPath.Element", "IndexPath.Index":
        return "Int"
    case "[IndexPath.Element]", "Array<IndexPath.Element>", "[IndexSet.Element]":
        return "[Int]"
    case "Range<IndexSet.Element>", "Range<IndexPath.Element>":
        return "Range<Int>"
    default:
        return normalized
    }
}

func analyzeMemberParameter(_ param: FunctionParameterSyntax) -> AnalyzedParam {
    let labelText = param.firstName.text
    let label: String? = labelText == "_" ? nil : labelText
    let hasDefault = param.defaultValue != nil
    var type = param.type
    if let attributed = type.as(AttributedTypeSyntax.self) {
        // `inout`/`borrowing` slots can't take a coerced temporary.
        guard attributed.specifiers.isEmpty else {
            return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "inout", usesGeneric: nil)
        }
        type = attributed.baseType
    }
    var normalized = normalize(type.trimmedDescription)
    if normalized.hasSuffix("?") { normalized = String(normalized.dropLast()) }
    if let mapping = memberMapping(for: normalized) {
        return .init(
            label: label, mapping: mapping, hasDefault: hasDefault,
            blocker: nil, usesGeneric: nil,
            contractType: memberContractType(for: normalized))
    }
    return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: normalized, usesGeneric: nil)
}

struct MemberVariant {
    let type: String
    let name: String
    let returnType: String
    let params: [EmittableParam]

    var key: String {
        type + "." + name + "|" + params.map { "\($0.label ?? "_"):\($0.tag)" }.joined(separator: ",")
    }
}

/// "Type.member" keys never emitted: hand-written coverage below the registry
/// (the core's nativeMember stdlib table) that the generated table would
/// otherwise shadow with a narrower overload set. Hand-written wins.
let denyMembers: Set<String> = [
    "Date.formatted", // nativeMember serves formatted(date:time:); the sweep can't map FormatStyle
]

var memberMethodVariants: [MemberVariant] = []
var memberMethodSeen = Set<String>()
struct MemberProperty {
    let type: String
    let name: String
    let returnType: String
    let isSettable: Bool
}
var memberProperties: [MemberProperty] = []
var memberPropertySeen = Set<String>()
var memberSettablePropertyTypes: [String: Int] = [:]
var memberBlockers: [String: Int] = [:]
var memberMethodTotal = 0
var memberPropertyTotal = 0

func hasModifier(_ modifiers: DeclModifierListSyntax, _ keyword: String) -> Bool {
    modifiers.contains { $0.name.text == keyword }
}

/// Members use the same version-aware availability rule as generated
/// modifiers and constructors. A declaration remains source-valid until its
/// deprecation version; active or unversioned deprecations stay excluded.
func memberIsUsable(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        if text.contains("unavailable") || text.contains("obsoleted")
            || deprecationIsActive(text) { return false }
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") { return false }
    }
    return true
}

struct CarrierInit {
    let type: String            // member-table key ("Measurement")
    let params: [AnalyzedParam]
}

var carrierInits: [CarrierInit] = []

/// Concrete SDK value types reached as parameters of an interface-declared
/// throwing initializer. Their own public, mechanically coercible initializers
/// are generated below so overload validation receives the real native value
/// instead of an interpreted storage-shaped surrogate.
var throwingConstructorValueParameterTypes: Set<String> = []

struct NativeValueInit {
    let type: String
    let params: [AnalyzedParam]

    var key: String {
        type + "|" + params.map {
            "\($0.label ?? "_"):\($0.mapping?.tag ?? "?")"
        }.joined(separator: ",")
    }
}

var nativeValueInits: [NativeValueInit] = []
var nativeValueInitSeen: Set<String> = []

/// Throwing constructor contracts for the Foundation value tier. Their
/// native implementation may still live in a compatibility box, but labels,
/// defaults, and argument types come from the SDK interface so an opaque
/// imported value cannot silently enter a concrete native initializer.
var throwingConstructorContracts: [String: Set<String>] = [:]

func processThrowingConstructorContract(
    _ typeName: String,
    _ initDecl: InitializerDeclSyntax,
    guarded: Bool
) {
    let effects = initDecl.signature.effectSpecifiers?.trimmedDescription ?? ""
    guard hasModifier(initDecl.modifiers, "public"),
          effects.contains("throws") || effects.contains("rethrows"),
          !effects.contains("async"),
          initDecl.genericParameterClause == nil,
          initDecl.genericWhereClause == nil,
          !initDecl.signature.parameterClause.parameters.contains(where: {
              $0.ellipsis != nil
          }),
          !guarded,
          !needsAvailabilityGuard(initDecl.attributes)
    else { return }

    let optionalMark = initDecl.optionalMark?.text ?? ""
    let declaration = "init\(optionalMark) \(typeName)"
        + initDecl.signature.trimmedDescription
    throwingConstructorContracts[typeName, default: []].insert(declaration)

    for parameter in initDecl.signature.parameterClause.parameters {
        var type = parameter.type
        if let attributed = type.as(AttributedTypeSyntax.self) {
            type = attributed.baseType
        }
        var normalized = normalize(type.trimmedDescription)
        if normalized.hasSuffix("?") {
            normalized.removeLast()
        }
        throwingConstructorValueParameterTypes.insert(normalized)
    }
}

/// Initializers of generic-struct carrier types: swept with the generic
/// substituted, emitted as host constructors building the CARRIER spelling.
func processCarrierInitializer(_ typeName: String, _ initDecl: InitializerDeclSyntax, guarded: Bool) {
    guard hasModifier(initDecl.modifiers, "public"),
          initDecl.optionalMark == nil,
          initDecl.genericParameterClause == nil,
          initDecl.genericWhereClause == nil,
          initDecl.signature.effectSpecifiers == nil,
          !initDecl.signature.parameterClause.parameters.contains(where: { $0.ellipsis != nil })
    else { return }
    if guarded || needsAvailabilityGuard(initDecl.attributes) { return }
    let analyzed = initDecl.signature.parameterClause.parameters.map(analyzeMemberParameter)
    guard analyzed.allSatisfy({ $0.mapping != nil }) else { return }
    guard !analyzed.isEmpty else { return }
    carrierInits.append(CarrierInit(type: typeName, params: analyzed))
}

func processMemberFunction(_ typeName: String, _ function: FunctionDeclSyntax, guarded: Bool) {
    let name = function.name.text
    guard let first = name.first, first.isLetter, !name.hasPrefix("_") else { return } // operators, SPI
    guard hasModifier(function.modifiers, "public"),
          !hasModifier(function.modifiers, "static"), !hasModifier(function.modifiers, "class"),
          !hasModifier(function.modifiers, "mutating") else { return }
    // A concrete same-type overload must not shadow the View-wide imported
    // overload family. That family owns contextual static resolution and
    // diagnostics; this tier fills only interface-proven concrete gaps.
    if currentConcreteViewMemberReceiver, modifierNames.contains(name) {
        return
    }
    memberMethodTotal += 1
    guard function.signature.effectSpecifiers == nil else {
        memberBlockers["throws/async", default: 0] += 1
        if ProcessInfo.processInfo.environment["BRIDGEGEN_DUMP_BLOCKED"] != nil {
            let effects = function.signature.effectSpecifiers?.trimmedDescription ?? "?"
            print("   blocked[\(effects)] \(typeName).\(name)\(function.signature.parameterClause.trimmedDescription)")
        }
        return
    }
    guard function.genericParameterClause == nil, function.genericWhereClause == nil else {
        memberBlockers["<generic>", default: 0] += 1
        return
    }
    guard let declaredReturnType =
            function.signature.returnClause?.type.trimmedDescription else {
        memberBlockers["void return", default: 0] += 1
        return
    }
    let normalizedReturnType: String
    if currentConcreteViewMemberReceiver {
        let candidate = normalize(declaredReturnType)
        normalizedReturnType = candidate == "Self" ? typeName : candidate
        // Concrete preservation is a semantic property of the result, not a
        // license to sweep every API on the nominal.
        guard normalizedReturnType == typeName else { return }
    } else {
        guard !declaredReturnType.contains("some "),
              normalize(declaredReturnType) != "Self" else {
            memberBlockers["opaque/Self return", default: 0] += 1
            if ProcessInfo.processInfo.environment[
                "BRIDGEGEN_DUMP_BLOCKED"
            ] != nil {
                print(
                    "   blocked[void/opaque] \(typeName).\(name)"
                        + "\(function.signature.parameterClause.trimmedDescription)")
            }
            return
        }
        normalizedReturnType = normalize(declaredReturnType)
    }
    let parameters = function.signature.parameterClause.parameters
    if parameters.contains(where: { $0.ellipsis != nil }) {
        memberBlockers["variadic", default: 0] += 1
        return
    }
    let analyzed = parameters.map(analyzeMemberParameter)
    if let firstBlocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        memberBlockers[firstBlocked.blocker ?? "?", default: 0] += 1
        return
    }
    if guarded || needsAvailabilityGuard(function.attributes) { return }
    guard !denyMembers.contains(typeName + "." + name) else { return }

    for selection in parameterSelections(analyzed) {
        let variant = MemberVariant(
            type: typeName, name: name,
            returnType: memberContractType(for: normalizedReturnType),
            params: selection.params.map {
                .init(
                    label: $0.label, tag: $0.mapping!.tag,
                    cast: $0.mapping!.cast,
                    // Protocol-receiver expansion: `Self` params contract
                    // as the concrete carrier (Int.isMultiple(of: Int)).
                    contractType: $0.contractType == "Self" ? typeName : $0.contractType!)
            }
        )
        if memberMethodSeen.insert(variant.key).inserted {
            memberMethodVariants.append(variant)
        }
    }
}

func processMemberProperty(_ typeName: String, _ variable: VariableDeclSyntax, guarded: Bool) {
    guard hasModifier(variable.modifiers, "public"),
          !hasModifier(variable.modifiers, "static"), !hasModifier(variable.modifiers, "class") else { return }
    guard let binding = variable.bindings.first,
          let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return }
    let name = pattern.identifier.text
    guard !name.hasPrefix("_") else { return }
    memberPropertyTotal += 1
    guard var rawType = binding.typeAnnotation?.type.trimmedDescription else {
        memberBlockers["untyped property", default: 0] += 1
        return
    }
    if normalize(rawType) == "Self", currentSelfCarrier != nil {
        // Protocol-receiver expansion: Self-typed properties contract as
        // the concrete carrier (Int.bigEndian: Int).
        rawType = typeName
    }
    if rawType.contains("some ") {
        memberBlockers["opaque property", default: 0] += 1
        return
    }
    if guarded || needsAvailabilityGuard(variable.attributes) { return }
    let key = typeName + "." + name
    guard !denyMembers.contains(key) else { return }
    if memberPropertySeen.insert(key).inserted {
        let isSettable: Bool = {
            guard variable.bindingSpecifier.text == "var" else { return false }
            guard let accessorBlock = binding.accessorBlock else { return true }
            switch accessorBlock.accessors {
            case .getter:
                return false
            case .accessors(let accessors):
                return accessors.contains {
                    ["set", "_modify", "modify"]
                        .contains($0.accessorSpecifier.text)
                }
            }
        }()
        let returnType = memberContractType(for: normalize(rawType))
        memberProperties.append(MemberProperty(
            type: typeName, name: name,
            returnType: returnType, isSettable: isSettable))
        if isSettable {
            memberSettablePropertyTypes[returnType, default: 0] += 1
        }
    }
}

// Foundation is also the member/value source below, not merely a supporting
// constraint module. Collect its contextual enums under their native
// unqualified paths before analyzing transitive value constructors.
if let foundationFile {
    for statement in foundationFile.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        collectSDKEnums(
            in: declaration, path: [], guarded: false,
            frameworkRequirements: [])
    }
}

/// Foundation properties whose declared result conforms to a standard
/// sequence protocol cross into the interpreter's ordinary array plane. The
/// set is derived from extension conformances in Foundation.swiftinterface;
/// adding another collection-valued SDK property therefore needs no member
/// or result-type special case.
let foundationMaterializableSequenceTypes: Set<String> = {
    guard let foundationFile else { return [] }
    let sequenceProtocols: Set<String> = [
        "Sequence", "Collection", "BidirectionalCollection",
        "RandomAccessCollection",
    ]
    var result: Set<String> = []
    for statement in foundationFile.statements {
        guard case .decl(let declaration) = statement.item,
              let ext = declaration.as(ExtensionDeclSyntax.self),
              ext.inheritanceClause?.inheritedTypes.contains(where: {
                  sequenceProtocols.contains(normalize($0.type.trimmedDescription))
              }) == true else { continue }
        result.insert(normalize(ext.extendedType.trimmedDescription))
    }
    return result
}()

let foundationAttributedStringKeySurface = attributedStringKeySurface(
    in: foundationFile)
let foundationRuntimeAliasMap = foundationRuntimeTypeAliases(
    in: foundationFile,
    canonicalTypes: foundationMemberTypes.union(
        foundationMaterializableSequenceTypes))

func sweepMemberFile(_ file: SourceFileSyntax) {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        var typeNames: [String] = []
        var isProtocolExpansion = false
        var members: MemberBlockItemListSyntax?
        var guarded = false
        if let structDecl = decl.as(StructDeclSyntax.self),
           memberTypes.contains(structDecl.name.text), isUsable(structDecl.attributes) {
            typeNames = [structDecl.name.text]
            members = structDecl.memberBlock.members
            guarded = needsAvailabilityGuard(structDecl.attributes)
        } else if let ext = decl.as(ExtensionDeclSyntax.self),
                  isUsable(ext.attributes) {
            let extended = normalize(ext.extendedType.trimmedDescription)
            // A where clause blocks the sweep UNLESS the extended type is a
            // generic-struct carrier and the clause only re-states the
            // carrier's own constraint (`where UnitType : Dimension` on
            // Measurement — the Dimension carrier satisfies it).
            let whereAllowed: Bool
            if let clause = ext.genericWhereClause {
                if let entry = genericStructCarriers[extended] {
                    let normalizedClause = normalize(clause.trimmedDescription)
                    whereAllowed = normalizedClause
                        .replacingOccurrences(of: " ", with: "")
                        == "where\(entry.generic):\(entry.substitute)"
                } else {
                    whereAllowed = false
                }
            } else {
                whereAllowed = true
            }
            if whereAllowed {
                if memberTypes.contains(extended) {
                    typeNames = [extended]
                } else if let carriers = protocolReceivers[extended] {
                    typeNames = carriers
                    isProtocolExpansion = true
                }
            }
            if !typeNames.isEmpty {
                members = ext.memberBlock.members
                guarded = needsAvailabilityGuard(ext.attributes)
            }
        }
        guard !typeNames.isEmpty, let members else { continue }
        for typeName in typeNames {
            currentSelfCarrier = isProtocolExpansion ? typeName : nil
            currentConcreteViewMemberReceiver =
                concreteViewMemberTypes.contains(typeName)
            currentAssociatedMemberReceiver =
                associatedMemberTypeKeys.contains(typeName)
            if let entry = genericStructCarriers[typeName] {
                currentGenericSubstitution = (entry.generic, entry.substitute)
            }
            for member in members {
                if let function = member.decl.as(FunctionDeclSyntax.self), memberIsUsable(function.attributes) {
                    processMemberFunction(typeName, function, guarded: guarded)
                } else if !currentConcreteViewMemberReceiver,
                          !currentAssociatedMemberReceiver,
                          let variable = member.decl.as(
                            VariableDeclSyntax.self),
                          memberIsUsable(variable.attributes) {
                    processMemberProperty(typeName, variable, guarded: guarded)
                } else if !currentConcreteViewMemberReceiver,
                          !currentAssociatedMemberReceiver,
                          let initDecl = member.decl.as(
                    InitializerDeclSyntax.self
                ), memberIsUsable(initDecl.attributes) {
                    processThrowingConstructorContract(
                        typeName, initDecl, guarded: guarded)
                    if foundationalGenericStructCarrierKeys.contains(typeName) {
                        processCarrierInitializer(
                            typeName, initDecl, guarded: guarded)
                    }
                }
            }
            currentSelfCarrier = nil
            currentGenericSubstitution = nil
            currentConcreteViewMemberReceiver = false
            currentAssociatedMemberReceiver = false
        }
    }
}

if let foundationFile {
    sweepMemberFile(foundationFile)
}
for file in interfaceFiles {
    sweepMemberFile(file)
}

func processNativeValueInitializer(
    typeName: String,
    _ initDecl: InitializerDeclSyntax,
    guarded: Bool
) {
    guard hasModifier(initDecl.modifiers, "public"),
          initDecl.optionalMark == nil,
          initDecl.genericParameterClause == nil,
          initDecl.genericWhereClause == nil,
          initDecl.signature.effectSpecifiers == nil,
          !initDecl.signature.parameterClause.parameters.contains(where: {
              $0.ellipsis != nil
          }),
          !guarded,
          !needsAvailabilityGuard(initDecl.attributes)
    else { return }

    let analyzed = initDecl.signature.parameterClause.parameters.map {
        analyzeParameter($0, generics: [:])
    }
    guard analyzed.allSatisfy({ $0.mapping != nil }) else { return }

    for selection in parameterSelections(analyzed)
    where selection.trailingClosureIndex == nil {
        let entry = NativeValueInit(
            type: typeName, params: selection.params)
        if nativeValueInitSeen.insert(entry.key).inserted {
            nativeValueInits.append(entry)
        }
    }
}

/// Walk nominal nesting and extensions from the Foundation swiftinterface.
/// Selection is demand-derived from throwing-constructor parameter types;
/// traversal never keys on an SDK nominal or initializer label.
func collectNativeValueInitializers(
    in declaration: DeclSyntax,
    path inheritedPath: [String],
    guarded inheritedGuarded: Bool,
    candidates: Set<String>
) {
    func visitMembers(
        _ members: MemberBlockItemListSyntax,
        path: [String],
        guarded: Bool
    ) {
        let typeName = path.joined(separator: ".")
        for member in members {
            if candidates.contains(typeName),
               let initializer = member.decl.as(
                InitializerDeclSyntax.self
               ),
               memberIsUsable(initializer.attributes) {
                processNativeValueInitializer(
                    typeName: typeName, initializer, guarded: guarded)
            } else {
                collectNativeValueInitializers(
                    in: member.decl,
                    path: path,
                    guarded: guarded,
                    candidates: candidates)
            }
        }
    }

    if let structure = declaration.as(StructDeclSyntax.self) {
        guard isPublicSDKDecl(structure.modifiers),
              isUniversallyUsable(structure.attributes),
              !structure.name.text.hasPrefix("_") else { return }
        let path = inheritedPath + [structure.name.text]
        visitMembers(
            structure.memberBlock.members,
            path: path,
            guarded: inheritedGuarded
                || needsAvailabilityGuard(structure.attributes))
        return
    }

    if let enumeration = declaration.as(EnumDeclSyntax.self) {
        guard isPublicSDKDecl(enumeration.modifiers),
              isUniversallyUsable(enumeration.attributes),
              !enumeration.name.text.hasPrefix("_") else { return }
        visitMembers(
            enumeration.memberBlock.members,
            path: inheritedPath + [enumeration.name.text],
            guarded: inheritedGuarded
                || needsAvailabilityGuard(enumeration.attributes))
        return
    }

    if let classDeclaration = declaration.as(ClassDeclSyntax.self) {
        guard isPublicSDKDecl(classDeclaration.modifiers),
              isUniversallyUsable(classDeclaration.attributes),
              !classDeclaration.name.text.hasPrefix("_") else { return }
        visitMembers(
            classDeclaration.memberBlock.members,
            path: inheritedPath + [classDeclaration.name.text],
            guarded: inheritedGuarded
                || needsAvailabilityGuard(classDeclaration.attributes))
        return
    }

    if let extensionDeclaration = declaration.as(
        ExtensionDeclSyntax.self
    ), isUniversallyUsable(extensionDeclaration.attributes) {
        let path = normalize(
            extensionDeclaration.extendedType.trimmedDescription)
            .split(separator: ".").map(String.init)
        visitMembers(
            extensionDeclaration.memberBlock.members,
            path: path,
            guarded: inheritedGuarded
                || needsAvailabilityGuard(
                    extensionDeclaration.attributes))
    }
}

if let foundationFile {
    let candidates = Set(
        throwingConstructorValueParameterTypes.filter {
            directMapping(for: $0) == nil
        })
    for statement in foundationFile.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        collectNativeValueInitializers(
            in: declaration, path: [], guarded: false,
            candidates: candidates)
    }
}
print(
    "Foundation native constructor parameters: "
        + "\(Set(nativeValueInits.map(\.type)).count) value types, "
        + "\(nativeValueInits.count) call shapes")

// Foundation's unit system: Dimension subclasses and their class-var unit
// instances (UnitTemperature.fahrenheit, …). Swept for the shared
// Coerce.dimension coercion so `Measurement(value:unit:)`'s bare
// `.fahrenheit` resolves to the real unit — the same closed-SDK-set idea
// as sdkEnum coercions, applied to a class hierarchy.
struct SweptUnitStatic {
    let container: String
    let name: String
}

var unitStatics: [SweptUnitStatic] = sweptFoundationDimensionStatics()
    .map { SweptUnitStatic(container: $0.container, name: $0.name) }
print("Foundation units: \(Set(unitStatics.map(\.container)).count) Dimension classes, \(unitStatics.count) unit statics")

// The STDLIB owns the numeric protocol surface (isMultiple(of:), …);
// Foundation only ADDS formatted(). Same sweep, same receiver gates.
if let stdlibFile {
    sweepMemberFile(stdlibFile)
}

/// Unsafe-memory APIs need runtime semantics that their declarations cannot
/// execute inside `RuntimeValue`, but the TYPES eligible for those semantics
/// are still interface facts. Derive them from `_Pointer` conformance and the
/// structural `init(start:pointer?, count:Int)` buffer shape so evaluator
/// dispatch never grows a hand-maintained SDK type-name list.
struct UnsafeMemorySurface {
    let pointerTypes: [String]
    let rawPointerTypes: [String]
    let bufferTypes: [String]
    let bufferRebindingMembers: [(name: String, metatypeLabel: String)]
    let mutableBufferCallbackMembers: [(
        name: String, argumentLabel: String
    )]
    let pointerBulkCopyMembers: [(
        name: String, sourceLabel: String, countLabel: String
    )]
}

func unsafeMemorySurface(in file: SourceFileSyntax?) -> UnsafeMemorySurface {
    guard let file else {
        return UnsafeMemorySurface(
            pointerTypes: [], rawPointerTypes: [], bufferTypes: [],
            bufferRebindingMembers: [], mutableBufferCallbackMembers: [],
            pointerBulkCopyMembers: [])
    }

    func nominalName(_ raw: String) -> String {
        var name = normalize(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name.removeLast()
        }
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name.split(separator: ".").last.map(String.init) ?? name
    }

    func inheritsPointer(_ clause: InheritanceClauseSyntax?) -> Bool {
        clause?.inheritedTypes.contains(where: {
            normalize($0.type.trimmedDescription)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("_Pointer")
        }) == true
    }

    func unwrappedType(_ type: TypeSyntax) -> TypeSyntax {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return unwrappedType(attributed.baseType)
        }
        return type
    }

    var nominals: [String: StructDeclSyntax] = [:]
    var pointerTypes = Set<String>()
    var extensions: [ExtensionDeclSyntax] = []
    for item in file.statements {
        guard case .decl(let declaration) = item.item else { continue }
        if let nominal = declaration.as(StructDeclSyntax.self) {
            let name = nominal.name.text
            nominals[name] = nominal
            if inheritsPointer(nominal.inheritanceClause) {
                pointerTypes.insert(name)
            }
        } else if let extensionDecl = declaration.as(ExtensionDeclSyntax.self) {
            extensions.append(extensionDecl)
        }
    }
    for extensionDecl in extensions where inheritsPointer(
        extensionDecl.inheritanceClause)
    {
        pointerTypes.insert(nominalName(
            extensionDecl.extendedType.trimmedDescription))
    }

    // A typed pointer is writable when one of its generic-valued properties
    // exposes a language-level write accessor. This derives mutability from
    // declaration shape instead of the pointer type's SDK spelling.
    var writablePointerTypes = Set<String>()
    func collectWritablePointerType(
        _ name: String, from members: MemberBlockItemListSyntax
    ) {
        guard pointerTypes.contains(name), let nominal = nominals[name] else {
            return
        }
        let genericNames = Set(
            nominal.genericParameterClause?.parameters.map(\.name.text) ?? [])
        guard !genericNames.isEmpty else { return }
        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindingSpecifier.text == "var" else { continue }
            for binding in variable.bindings {
                guard let type = binding.typeAnnotation?.type,
                      genericNames.contains(normalize(
                        unwrappedType(type).trimmedDescription)),
                      let accessorBlock = binding.accessorBlock,
                      case .accessors(let accessors) = accessorBlock.accessors,
                      accessors.contains(where: {
                        ["set", "_modify", "modify", "unsafeMutableAddress"]
                            .contains($0.accessorSpecifier.text)
                      }) else { continue }
                writablePointerTypes.insert(name)
            }
        }
    }
    for (name, nominal) in nominals {
        collectWritablePointerType(name, from: nominal.memberBlock.members)
    }
    for extensionDecl in extensions {
        collectWritablePointerType(
            nominalName(extensionDecl.extendedType.trimmedDescription),
            from: extensionDecl.memberBlock.members)
    }

    let rawPointerTypes = Set(pointerTypes.filter { name in
        guard let nominal = nominals[name],
              nominal.genericParameterClause == nil else { return false }
        return nominal.memberBlock.members.contains { member in
            guard let alias = member.decl.as(TypeAliasDeclSyntax.self),
                  alias.name.text == "Pointee" else { return false }
            return nominalName(alias.initializer.value.trimmedDescription)
                == "UInt8"
        }
    })

    var bufferPointerTypes: [String: Set<String>] = [:]
    for (name, nominal) in nominals {
        for member in nominal.memberBlock.members {
            guard let initializer = member.decl.as(InitializerDeclSyntax.self)
            else { continue }
            let parameters = initializer.signature.parameterClause.parameters
            guard parameters.count == 2 else { continue }
            let first = parameters[parameters.startIndex]
            let second = parameters[parameters.index(after: parameters.startIndex)]
            let pointerType = nominalName(first.type.trimmedDescription)
            guard first.firstName.text == "start"
                && pointerTypes.contains(pointerType)
                && second.firstName.text == "count"
                && nominalName(second.type.trimmedDescription) == "Int" else {
                continue
            }
            bufferPointerTypes[name, default: []].insert(pointerType)
        }
    }
    let bufferTypes = Set(bufferPointerTypes.keys)
    let mutableBufferTypes = Set(bufferPointerTypes.compactMap {
        name, pointerTypes in
        pointerTypes.isDisjoint(with: writablePointerTypes) ? nil : name
    })

    var bufferRebindingMembers = Set<String>()
    func collectBufferRebindingMembers(
        from members: MemberBlockItemListSyntax
    ) {
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  let result = function.signature.returnClause?.type,
                  bufferTypes.contains(nominalName(
                    result.trimmedDescription)) else {
                continue
            }
            let parameters = function.signature.parameterClause.parameters
            guard parameters.count == 1, let parameter = parameters.first else {
                continue
            }
            let genericNames = Set(
                function.genericParameterClause?.parameters.map(
                    \.name.text) ?? [])
            let parameterType = normalize(parameter.type.trimmedDescription)
            guard parameterType.hasSuffix(".Type"),
                  genericNames.contains(String(parameterType.dropLast(
                    ".Type".count))) else {
                continue
            }
            bufferRebindingMembers.insert(
                function.name.text + "\u{0}" + parameter.firstName.text)
        }
    }
    for (name, nominal) in nominals where bufferTypes.contains(name) {
        collectBufferRebindingMembers(from: nominal.memberBlock.members)
    }
    for extensionDecl in extensions where bufferTypes.contains(nominalName(
        extensionDecl.extendedType.trimmedDescription))
    {
        collectBufferRebindingMembers(
            from: extensionDecl.memberBlock.members)
    }
    let sortedBufferRebindingMembers = bufferRebindingMembers.sorted().map {
        let pieces = $0.split(separator: "\u{0}", omittingEmptySubsequences: false)
        return (name: String(pieces[0]), metatypeLabel: String(pieces[1]))
    }

    // A mutable-buffer callback is a public mutating method whose sole
    // callback consumes a structurally writable buffer and returns the same
    // generic result as that callback. Optional/fallback storage probes do not
    // satisfy the equal-result shape and therefore remain outside this hook.
    var mutableBufferCallbackLabels: [String: String] = [:]
    func collectMutableBufferCallbacks(
        from members: MemberBlockItemListSyntax
    ) {
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  hasModifier(function.modifiers, "public"),
                  hasModifier(function.modifiers, "mutating"),
                  !hasModifier(function.modifiers, "static"),
                  !hasModifier(function.modifiers, "class") else { continue }
            let parameters = function.signature.parameterClause.parameters
            guard parameters.count == 1, let parameter = parameters.first,
                  let callback = unwrappedType(parameter.type)
                    .as(FunctionTypeSyntax.self),
                  callback.parameters.count == 1,
                  let callbackParameter = callback.parameters.first,
                  mutableBufferTypes.contains(nominalName(
                    unwrappedType(callbackParameter.type)
                        .trimmedDescription)) else { continue }
            let result = normalize(function.signature.returnClause?.type
                .trimmedDescription ?? "")
            let callbackResult = normalize(
                callback.returnClause.type.trimmedDescription)
            let genericNames = Set(
                function.genericParameterClause?.parameters.map(
                    \.name.text) ?? [])
            guard result == callbackResult, genericNames.contains(result) else {
                continue
            }
            let label = parameter.firstName.text == "_"
                ? "" : parameter.firstName.text
            if let existing = mutableBufferCallbackLabels[function.name.text] {
                precondition(existing == label,
                    "conflicting mutable-buffer callback labels")
            } else {
                mutableBufferCallbackLabels[function.name.text] = label
            }
        }
    }
    for nominal in nominals.values {
        collectMutableBufferCallbacks(from: nominal.memberBlock.members)
    }
    for extensionDecl in extensions {
        collectMutableBufferCallbacks(
            from: extensionDecl.memberBlock.members)
    }
    let sortedMutableBufferCallbackMembers = mutableBufferCallbackLabels
        .sorted(by: { $0.key < $1.key })
        .map { (name: $0.key, argumentLabel: $0.value) }

    // Writable typed pointers advertise bulk-copy operations structurally: a
    // public void method accepting another declared pointer plus an Int. The
    // generated labels preserve the active SDK declaration at invocation.
    var pointerBulkCopyLabels: [String: String] = [:]
    func collectPointerBulkCopies(
        receiverName: String, from members: MemberBlockItemListSyntax
    ) {
        guard writablePointerTypes.contains(receiverName) else { return }
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  hasModifier(function.modifiers, "public"),
                  !hasModifier(function.modifiers, "static"),
                  !hasModifier(function.modifiers, "class") else { continue }
            let parameters = function.signature.parameterClause.parameters
            guard parameters.count == 2 else { continue }
            let source = parameters[parameters.startIndex]
            let count = parameters[parameters.index(after: parameters.startIndex)]
            let sourceType = nominalName(
                unwrappedType(source.type).trimmedDescription)
            let result = normalize(function.signature.returnClause?.type
                .trimmedDescription ?? "")
            guard pointerTypes.contains(sourceType),
                  nominalName(count.type.trimmedDescription) == "Int",
                  result.isEmpty || result == "Void" || result == "()" else {
                continue
            }
            let sourceLabel = source.firstName.text == "_"
                ? "" : source.firstName.text
            let countLabel = count.firstName.text == "_"
                ? "" : count.firstName.text
            let labels = sourceLabel + "\u{0}" + countLabel
            if let existing = pointerBulkCopyLabels[function.name.text] {
                precondition(existing == labels,
                    "conflicting pointer bulk-copy labels")
            } else {
                pointerBulkCopyLabels[function.name.text] = labels
            }
        }
    }
    for (name, nominal) in nominals {
        collectPointerBulkCopies(
            receiverName: name, from: nominal.memberBlock.members)
    }
    for extensionDecl in extensions {
        collectPointerBulkCopies(
            receiverName: nominalName(
                extensionDecl.extendedType.trimmedDescription),
            from: extensionDecl.memberBlock.members)
    }
    let sortedPointerBulkCopyMembers = pointerBulkCopyLabels
        .sorted(by: { $0.key < $1.key })
        .map { name, labels -> (
            name: String, sourceLabel: String, countLabel: String
        ) in
            let pieces = labels.split(
                separator: "\u{0}", omittingEmptySubsequences: false)
            return (name: name, sourceLabel: String(pieces[0]),
                    countLabel: String(pieces[1]))
        }

    return UnsafeMemorySurface(
        pointerTypes: pointerTypes.sorted(),
        rawPointerTypes: rawPointerTypes.sorted(),
        bufferTypes: bufferTypes.sorted(),
        bufferRebindingMembers: sortedBufferRebindingMembers,
        mutableBufferCallbackMembers: sortedMutableBufferCallbackMembers,
        pointerBulkCopyMembers: sortedPointerBulkCopyMembers)
}

let generatedUnsafeMemorySurface = unsafeMemorySurface(in: stdlibFile)
let generatedUnicodeDecodingSurface = unicodeDecodingSurface(in: stdlibFile)
let generatedIntegerIndexCollectionDefaults =
    integerIndexCollectionDefaults(in: stdlibFile)
let generatedNativeIndexMotionDefaults =
    nativeIndexMotionDefaults(in: stdlibFile)
let generatedIndexSearchDefaults =
    indexSearchDefaults(in: stdlibFile)
let generatedBooleanIndexEndpointEqualityCollectionDefaults =
    booleanIndexEndpointEqualityCollectionDefaults(in: stdlibFile)
let generatedOptionalElementCollectionDefaults =
    optionalElementCollectionDefaults(in: stdlibFile)
let generatedOptionalLastRemovalCollectionDefaults =
    optionalLastRemovalCollectionDefaults(in: stdlibFile)
let generatedRequiredEndpointRemovalCollectionDefaults =
    requiredEndpointRemovalCollectionDefaults(in: stdlibFile)
let generatedElementGenericCollectionNominals =
    elementGenericCollectionNominals(in: stdlibFile)
let generatedMaterializableSequenceProtocolNames =
    materializableSequenceProtocolNames(in: stdlibFile)
let generatedRepeatedElementSequenceFactories =
    repeatedElementSequenceFactories(in: stdlibFile)
let generatedNativeWritableStringCollectionViews =
    nativeWritableStringCollectionViews(in: stdlibFile)
let generatedNativeCollectionCarrierDefaults =
    nativeCollectionCarrierDefaults(in: stdlibFile)
let generatedNativeCollectionCarrierScalarVoidMutations =
    generatedNativeCollectionCarrierDefaults.scalarVoidMutations
let generatedNativeDictionaryKeyOptionalValueMutations =
    generatedNativeCollectionCarrierDefaults
        .dictionaryKeyOptionalValueMutations
let generatedRangeRemovalMutations =
    rangeRemovalMutations(in: stdlibFile)
let generatedCaseTransformOperations =
    caseTransformOperations(in: stdlibFile)

// Charts owns the axis value-plane carriers (DateBins/NumberBins) —
// interpreted axis builders read `.thresholds` and hand the dates back
// to real AxisMarks. Same sweep, same receiver gates.
let chartsFile: SourceFileSyntax? = {
    guard let path = interfacePath(framework: "Charts"),
          let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("warning: no swiftinterface for Charts")
        return nil
    }
    print("parsing Charts (\(source.count) chars)…")
    return Parser.parse(source: source)
}()

if let chartsFile {
    sweepMemberFile(chartsFile)
}

struct GeneratedResultBuilderCarrierDescriptor {
    let builder: String
    let resultProtocol: String
    let maximumArity: Int
    let availabilityAttributes: [String]
    let invocationAvailabilityAttributes: [String]

    var availabilityCondition: String? {
        let clauses = invocationAvailabilityAttributes.compactMap {
            attribute -> String? in
            guard attribute.hasPrefix("@available("),
                  attribute.hasSuffix(")"),
                  !attribute.contains("unavailable"),
                  !attribute.contains("deprecated"),
                  !attribute.contains("obsoleted") else {
                return nil
            }
            return String(attribute.dropFirst("@available(".count).dropLast())
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: ", ")
    }
}

let generatedResultBuilderCarriers: [
    String: GeneratedResultBuilderCarrierDescriptor
] = Dictionary(uniqueKeysWithValues: interfaceResultBuilders.compactMap {
    resultProtocol, builder
        -> (String, GeneratedResultBuilderCarrierDescriptor)? in
    var eraser: FunctionDeclSyntax?
    var eraserAcceptsExistentialDirectly = false
    var maximumArity = 0
    var hasVariadicBuildBlock = false
    var builderAvailabilityAttributes: [String] = []

    @MainActor
    func availabilityAttributes(
        from attributes: AttributeListSyntax
    ) -> [String] {
        attributes.compactMap { attribute -> String? in
            guard let syntax = attribute.as(AttributeSyntax.self),
                  syntax.attributeName.trimmedDescription == "available" else {
                return nil
            }
            return syntax.trimmedDescription
        }
    }

    @MainActor
    func inspectBuilderMembers(
        _ members: MemberBlockItemListSyntax,
        declarationAttributes: AttributeListSyntax
    ) {
        let functions = members.compactMap {
            $0.decl.as(FunctionDeclSyntax.self)
        }
        guard functions.contains(where: {
            $0.name.text == "buildLimitedAvailability"
                || $0.name.text == "buildBlock"
        }) else {
            return
        }
        builderAvailabilityAttributes.append(contentsOf:
            availabilityAttributes(from: declarationAttributes))
        for function in functions {
            if function.name.text == "buildLimitedAvailability",
               let parameter = function.signature.parameterClause
                .parameters.first {
                let parameterType = normalize(
                    parameter.type.trimmedDescription)
                    .replacingOccurrences(of: " ", with: "")
                let returnType = normalize(
                    function.signature.returnClause?.type
                        .trimmedDescription ?? "")
                    .replacingOccurrences(of: " ", with: "")
                let constraints = genericConstraints(of: function)
                let genericInput = constraints[parameterType].map {
                    facts -> Bool in
                    guard case .constraints(let protocols) = facts else {
                        return false
                    }
                    return protocols.contains(resultProtocol)
                } ?? false
                let directExistential =
                    parameterType == "any\(resultProtocol)"
                let opaqueInput =
                    parameterType == "some\(resultProtocol)"
                if returnType.contains(resultProtocol),
                   directExistential
                    || opaqueInput
                    || (genericInput
                        && !eraserAcceptsExistentialDirectly) {
                    eraser = function
                    eraserAcceptsExistentialDirectly = directExistential
                }
            }
            if function.name.text == "buildBlock" {
                if function.signature.parameterClause.parameters.contains(
                    where: {
                        normalize($0.type.trimmedDescription)
                            .contains("repeat each")
                    }) {
                    hasVariadicBuildBlock = true
                }
                let constraints = genericConstraints(of: function)
                let servesProtocol = constraints.values.contains {
                    facts in
                    guard case .constraints(let protocols) = facts else {
                        return false
                    }
                    return protocols.contains(resultProtocol)
                }
                if servesProtocol {
                    maximumArity = max(
                        maximumArity,
                        function.signature.parameterClause.parameters
                            .count)
                }
            }
        }
    }

    for file in interfaceFiles {
        for statement in file.statements {
            guard case .decl(let declaration) = statement.item else {
                continue
            }
            if let ext = declaration.as(ExtensionDeclSyntax.self),
               normalize(ext.extendedType.trimmedDescription) == builder {
                inspectBuilderMembers(
                    ext.memberBlock.members,
                    declarationAttributes: ext.attributes)
            } else if let structure = declaration.as(StructDeclSyntax.self),
                      normalize(structure.name.text) == builder {
                inspectBuilderMembers(
                    structure.memberBlock.members,
                    declarationAttributes: structure.attributes)
            }
        }
    }
    guard let eraser, maximumArity > 0,
          !hasVariadicBuildBlock || maximumArity > 1 else {
        return nil
    }
    let eraserAvailability = availabilityAttributes(
        from: eraser.attributes)
    let availability = Array(Set(
        builderAvailabilityAttributes
            + eraserAvailability
    )).sorted()
    return (
        resultProtocol,
        GeneratedResultBuilderCarrierDescriptor(
            builder: builder,
            resultProtocol: resultProtocol,
            maximumArity: maximumArity,
            availabilityAttributes: availability,
            invocationAvailabilityAttributes: eraserAvailability)
    )
})

let supportedResultBuilderProtocols = Set(
    generatedResultBuilderCarriers.keys)

// Only generate native leaves after proving that the interface also exposes
// a carrier shape capable of composing every result. Candidate builders with
// no existential eraser or only an unbounded parameter-pack block remain
// blocked instead of leaking partial constructors into generated output.
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let structure = declaration.as(StructDeclSyntax.self),
              let info = resultBuilderContentInfo[structure.name.text],
              !info.protocols.isDisjoint(
                with: supportedResultBuilderProtocols) else {
            continue
        }
        for member in structure.memberBlock.members {
            guard let initializer = member.decl.as(
                InitializerDeclSyntax.self),
                  isUsable(initializer.attributes) else {
                continue
            }
            processInit(
                structure.name.text,
                initializer,
                generics: info.generics,
                guarded: info.guarded,
                frameworkRequirements: info.frameworkRequirements,
                preservesSemanticValue: true)
        }
    }
}

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let declaration) = statement.item,
              let ext = declaration.as(ExtensionDeclSyntax.self),
              isUsable(ext.attributes) else {
            continue
        }
        let type = normalize(ext.extendedType.trimmedDescription)
        guard let info = resultBuilderContentInfo[type],
              !info.protocols.isDisjoint(
                with: supportedResultBuilderProtocols) else {
            continue
        }
        var generics = info.generics
        collectWhereClause(ext.genericWhereClause, into: &generics)
        let guarded = info.guarded
            || needsAvailabilityGuard(ext.attributes)
        let frameworks = info.frameworkRequirements.union(
            platformFrameworkRequirements(ext.attributes))
        for member in ext.memberBlock.members {
            guard let initializer = member.decl.as(
                InitializerDeclSyntax.self),
                  isUsable(initializer.attributes) else {
                continue
            }
            processInit(
                type,
                initializer,
                generics: generics,
                guarded: guarded,
                frameworkRequirements: frameworks,
                preservesSemanticValue: true)
        }
    }
}

func resultBuilderDescriptor(
    from tag: String
) -> (builder: String, resultProtocol: String)? {
    let prefix = "resultBuilder(\""
    let separator = "\", \""
    guard tag.hasPrefix(prefix), tag.hasSuffix("\")") else { return nil }
    let payload = String(tag.dropFirst(prefix.count).dropLast(2))
    let parts = payload.components(separatedBy: separator)
    guard parts.count == 2 else { return nil }
    return (parts[0], parts[1])
}

func supportsResultBuilders(_ variant: Variant) -> Bool {
    variant.params.allSatisfy {
        guard let descriptor = resultBuilderDescriptor(from: $0.tag) else {
            return true
        }
        return generatedResultBuilderCarriers[
            descriptor.resultProtocol
        ] != nil
    }
}

let emittedModifierVariants = variants.filter(supportsResultBuilders)

/// A selection that drops defaulted parameters is only emitted when the
/// remaining labels still name ONE initializer of that nominal. This is judged
/// here rather than inside `processInit` because the competing siblings are not
/// all scanned yet while any single initializer is being processed — the
/// verdict needs the nominal's complete declared overload set.
func initSelectionIsUnambiguous(_ variant: Variant) -> Bool {
    let labels = variant.params.compactMap(\.label)
    guard labels.count == variant.params.count, !labels.isEmpty,
          let owner = initVariantOwnerSignature[variant.key],
          let signatures = interfaceInitSignatures[variant.name],
          signatures.count > 1
    else { return true }
    let accepting = signatures.filter {
        initSignature($0, accepts: labels, typedAs: owner)
    }
    // Swift ranks a candidate that applies FEWER default arguments above one
    // that applies more, so a call is only ambiguous when the fewest-defaults
    // candidate is not unique: `AngularGradient(gradient:center:)` resolves to
    // the `angle:` init over the `startAngle:endAngle:` one, while
    // `ConcentricRectangle(topLeadingCorner:)` has two candidates tied at the
    // same count and is the spelling the compiler rejects.
    let fewestDefaults = accepting.map { $0.count - labels.count }.min()
    let contenders = accepting.filter {
        $0.count - labels.count == fewestDefaults
    }
    guard contenders.count > 1 else { return true }
    initAmbiguous += 1
    if ProcessInfo.processInfo.environment["BRIDGEGEN_DUMP_BLOCKED"] != nil {
        print(
            "   blocked[ambiguous] init \(variant.name)"
                + "(\(labels.map { "\($0):" }.joined()))")
    }
    return false
}

let emittedInitVariants = initVariants
    .filter(supportsResultBuilders)
    .filter(initSelectionIsUnambiguous)

// MARK: - Report

let parameterBlockers = modifierBlockers.merging(initBlockers, uniquingKeysWith: +)

print("""

═══ View-extension modifiers ═══
total overloads:        \(modifierTotal)  (\(modifierNames.count) distinct names)
generatable overloads:  \(modifierGeneratable)  (\(generatableNames.count) distinct names)
newer-OS (skipped):     \(modifierGuarded)
emitted variants:       \(emittedModifierVariants.count)

═══ SwiftUI constructors ═══
View structs:           \(viewStructs.count)
parameter value structs: \(valueStructs.count)
total inits:            \(initTotal)
generatable inits:      \(initGeneratable)  (across \(generatableStructs.count) structs)
newer-OS (skipped):     \(initGuarded)
newer-OS (guarded):     \(initRuntimeGuarded)
ambiguous selections:   \(initAmbiguous)
emitted variants:       \(emittedInitVariants.count)

═══ Top blocking types ═══
""")
for (type, count) in parameterBlockers.sorted(by: { $0.value > $1.value }).prefix(25) {
    print(String(format: "%5d  %@", count, type))
}

print("""

═══ Foundation members (generated tier) ═══
properties:             \(memberProperties.count)  (of \(memberPropertyTotal) public instance vars)
settable properties:    \(memberProperties.count(where: \.isSettable))
method variants:        \(memberMethodVariants.count)  (\(Set(memberMethodVariants.map { $0.type + "." + $0.name }).count) distinct members, of \(memberMethodTotal) candidates)

═══ Top member-blocking types ═══
""")
for (type, count) in memberBlockers.sorted(by: { $0.value > $1.value }).prefix(20) {
    print(String(format: "%5d  %@", count, type))
}
print("\n═══ Settable property types ═══")
for (type, count) in memberSettablePropertyTypes.sorted(by: {
    ($0.value, $0.key) > ($1.value, $1.key)
}) {
    print(String(format: "%5d  %@", count, type))
}

print("\n═══ AppKit/UIKit generated platform tier ═══")
for summary in platformGeneration.summaries {
    print(summary)
}

func sdkEnumType(from tag: String) -> String? {
    let prefix = "sdkEnum(\""
    let suffix = "\")"
    guard tag.hasPrefix(prefix), tag.hasSuffix(suffix) else { return nil }
    return String(tag.dropFirst(prefix.count).dropLast(suffix.count))
}

/// How many inputs a bridged synchronous callback tag declares, or nil when
/// the tag is not one. Arity is structural, so the trailing-closure form is
/// derived from it rather than listed per callback shape.
func syncClosureInputCount(from tag: String) -> Int? {
    let prefix = "syncClosure(inputs: "
    guard tag.hasPrefix(prefix) else { return nil }
    let rest = tag.dropFirst(prefix.count)
    guard let comma = rest.firstIndex(of: ",") else { return nil }
    return Int(rest[rest.startIndex..<comma])
}

func sdkProtocolComposition(from tag: String) -> String? {
    let prefix = "sdkProtocolValue(\""
    let suffix = "\")"
    guard tag.hasPrefix(prefix), tag.hasSuffix(suffix) else { return nil }
    return String(tag.dropFirst(prefix.count).dropLast(suffix.count))
}

/// A public instance method that returns its receiver's contextual SDK type
/// is a fluent value transform (`.regular.interactive()`,
/// `.member.transform(...)`). Keep these in the contextual-value generator:
/// the root static, method shape, defaults, argument coercions, and target
/// availability all come from the same swiftinterface.
struct SDKContextualMethodVariant {
    let type: String
    let name: String
    let params: [EmittableParam]
    let minimumTargetAvailabilities: Set<GeneratedTargetAvailability>

    var key: String {
        type + "." + name + "|" + params.map {
            "\($0.label ?? "_"):\($0.tag)"
        }.joined(separator: ",")
    }
}

/// Same-type fluent transforms from the ordinary generated member sweep.
let associatedSDKContextualMethodVariants:
    [SDKContextualMethodVariant] = {
        associatedGenericConcreteTypes.sorted().flatMap { concrete in
            let normalized = normalize(concrete)
            let memberType: String?
            if let parts = genericTypeParts(normalized),
               genericStructCarriers[parts.base]?.carrier == normalized {
                memberType = parts.base
            } else if associatedPlainMemberTypes.contains(normalized) {
                memberType = normalized
            } else {
                memberType = nil
            }
            return memberMethodVariants.compactMap { member -> SDKContextualMethodVariant? in
                guard member.type == memberType,
                      normalize(member.returnType) == normalized else { return nil }
                return SDKContextualMethodVariant(type: normalized, name: member.name,
                    params: member.params, minimumTargetAvailabilities: [])
            }
        }
    }()

/// A leading-dot FACTORY: `.units(width: .narrow, maximumUnitCount: 1)` is to
/// `.number` exactly what a call is to a value, and the interface says so in
/// one place — the `Self == Concrete` extension both are declared in. The
/// concrete type, the argument labels, their contextual types and their
/// defaults are all read from that declaration, so a style family the SDK
/// adds becomes constructible without an edit here.
let sdkContextualFactoryVariants: [SDKContextualMethodVariant] = {
    var variants: [SDKContextualMethodVariant] = []
    var seen: Set<String> = []
    for declaration in sdkProtocolContextualFactoryDecls {
        let analyzed = declaration.function.signature.parameterClause
            .parameters.map { analyzeParameter($0, generics: [:]) }
        let availabilities = minimumTargetAvailabilities(
            declaration.function.attributes)
        // Defaulted parameters are what make `.units(width:)` spell fewer
        // arguments than the declaration does; each admissible prefix is its
        // own overload, exactly as the contextual-method sweep treats them.
        for selection in parameterSelections(analyzed)
        where selection.trailingClosureIndex == nil {
            let variant = SDKContextualMethodVariant(
                type: normalize(declaration.concreteType),
                name: declaration.function.name.text,
                params: selection.params.map { .init(analyzed: $0) },
                minimumTargetAvailabilities: availabilities)
            if seen.insert(variant.key).inserted { variants.append(variant) }
        }
    }
    return variants.sorted {
        ($0.type, $0.name, $0.params.count, $0.key)
            < ($1.type, $1.name, $1.params.count, $1.key)
    }
}()
let sdkContextualFactoriesByType = Dictionary(
    grouping: sdkContextualFactoryVariants, by: \.type)

let emittedSDKEnumTypes = Set(
    (emittedModifierVariants + emittedInitVariants)
        .flatMap(\.params)
        .compactMap { sdkEnumType(from: $0.tag) }
        // A factory's own concrete type is reachable BY the factory: the
        // leading dot is the only spelling a caller ever writes for it.
        + sdkContextualFactoryVariants.map(\.type)
        + sdkContextualFactoryVariants.flatMap(\.params)
            .compactMap { sdkEnumType(from: $0.tag) }
        + associatedSDKContextualMethodVariants.flatMap(\.params)
            .compactMap { sdkEnumType(from: $0.tag) }
        + nativeValueInits.flatMap(\.params)
            .compactMap { parameter in
                parameter.mapping.flatMap {
                    sdkEnumType(from: $0.tag)
                }
            }
        + environmentValueVariants.values.compactMap {
            sdkEnumType(from: $0.mapping.tag)
        })

let targetSDKContextualMethodVariants: [SDKContextualMethodVariant] = {
    var variants: [SDKContextualMethodVariant] = []
    var seen: Set<String> = []

    @MainActor
    func recordMethods(
        _ members: MemberBlockItemListSyntax,
        type: String,
        inheritedTargetOnly: Bool,
        inheritedAvailabilities: Set<GeneratedTargetAvailability>
    ) {
        guard emittedSDKEnumTypes.contains(type) else { return }
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  isPublicSDKDecl(function.modifiers),
                  !hasModifier(function.modifiers, "static"),
                  !hasModifier(function.modifiers, "class"),
                  !hasModifier(function.modifiers, "mutating"),
                  isUsableIOSOverlay(function.attributes),
                  function.genericParameterClause == nil,
                  function.genericWhereClause == nil,
                  function.signature.effectSpecifiers == nil,
                  let first = function.name.text.first,
                  first.isLetter,
                  !function.name.text.hasPrefix("_"),
                  let declaredReturn = function.signature.returnClause?.type
                    .trimmedDescription else {
                continue
            }
            let normalizedReturn = normalize(declaredReturn)
            guard normalizedReturn == "Self"
                    || normalizedReturn == type
                    || normalizedReturn.hasSuffix("." + type) else {
                continue
            }
            let targetOnly = inheritedTargetOnly
                || SDKContextualSweep.iOSOverlay.isTargetOnly(
                    function.attributes)
            guard targetOnly else { continue }

            let analyzed = function.signature.parameterClause.parameters.map {
                analyzeParameter($0, generics: [:])
            }
            let availabilities = inheritedAvailabilities.union(
                minimumTargetAvailabilities(function.attributes))
            for selection in parameterSelections(analyzed)
            where selection.trailingClosureIndex == nil {
                let variant = SDKContextualMethodVariant(
                    type: type,
                    name: function.name.text,
                    params: selection.params.map { .init(analyzed: $0) },
                    minimumTargetAvailabilities: availabilities)
                if seen.insert(variant.key).inserted {
                    variants.append(variant)
                }
            }
        }
    }

    @MainActor
    func visit(
        _ declaration: DeclSyntax,
        path inheritedPath: [String],
        inheritedTargetOnly: Bool,
        inheritedAvailabilities: Set<GeneratedTargetAvailability>
    ) {
        @MainActor
        func visitNominal(
            name: String,
            modifiers: DeclModifierListSyntax,
            attributes: AttributeListSyntax,
            members: MemberBlockItemListSyntax
        ) {
            guard isPublicSDKDecl(modifiers),
                  isUsableIOSOverlay(attributes),
                  !name.hasPrefix("_") else {
                return
            }
            let path = inheritedPath + [name]
            let type = path.joined(separator: ".")
            let targetOnly = inheritedTargetOnly
                || SDKContextualSweep.iOSOverlay.isTargetOnly(attributes)
            let availabilities = inheritedAvailabilities.union(
                minimumTargetAvailabilities(attributes))
            recordMethods(
                members, type: type,
                inheritedTargetOnly: targetOnly,
                inheritedAvailabilities: availabilities)
            for member in members {
                visit(
                    member.decl, path: path,
                    inheritedTargetOnly: targetOnly,
                    inheritedAvailabilities: availabilities)
            }
        }

        if let nominal = sdkNominalParts(declaration), !nominal.isProtocol {
            visitNominal(
                name: nominal.name, modifiers: nominal.modifiers,
                attributes: nominal.attributes, members: nominal.members)
        } else if let extensionDeclaration = declaration.as(
            ExtensionDeclSyntax.self
        ), isUsableIOSOverlay(extensionDeclaration.attributes) {
            let path = normalize(
                extensionDeclaration.extendedType.trimmedDescription)
                .split(separator: ".").map(String.init)
            let type = path.joined(separator: ".")
            let targetOnly = inheritedTargetOnly
                || SDKContextualSweep.iOSOverlay.isTargetOnly(
                    extensionDeclaration.attributes)
            let availabilities = inheritedAvailabilities
                .union(minimumSDKContextualAvailabilities(for: type))
                .union(minimumTargetAvailabilities(
                    extensionDeclaration.attributes))
            recordMethods(
                extensionDeclaration.memberBlock.members,
                type: type,
                inheritedTargetOnly: targetOnly,
                inheritedAvailabilities: availabilities)
            for member in extensionDeclaration.memberBlock.members {
                visit(
                    member.decl, path: path,
                    inheritedTargetOnly: targetOnly,
                    inheritedAvailabilities: availabilities)
            }
        }
    }

    for file in targetOverlayFiles {
        for statement in file.statements {
            guard case .decl(let declaration) = statement.item else {
                continue
            }
            visit(
                declaration, path: [],
                inheritedTargetOnly: false,
                inheritedAvailabilities: [])
        }
    }
    return variants.sorted {
        ($0.type, $0.name, $0.params.count, $0.key)
            < ($1.type, $1.name, $1.params.count, $1.key)
    }
}()
let sdkContextualMethodVariants: [SDKContextualMethodVariant] = {
    var seen: Set<String> = []
    return (associatedSDKContextualMethodVariants
        + targetSDKContextualMethodVariants).filter {
            seen.insert($0.key).inserted
        }
}()
let sdkContextualMethodsByType = Dictionary(
    grouping: sdkContextualMethodVariants, by: \.type)

let emittedSDKProtocolCompositions = Set(
    (emittedModifierVariants + emittedInitVariants)
        .flatMap(\.params)
        .compactMap { sdkProtocolComposition(from: $0.tag) })
let emittedSDKFrameworkConfigurationProtocols =
    sdkFrameworkConfigurationProtocols
        .filter { emittedSDKProtocolCompositions.contains($0.key) }
let emittedSDKFrameworkConfigurationTypes = Set(
    emittedSDKFrameworkConfigurationProtocols.values.map(\.configurationType))
let supportingModules = Set(supportingInterfaceFiles.map(\.module))
let emittedSupportingModules = Set(
    emittedSDKEnumTypes.compactMap {
        $0.split(separator: ".").first.map(String.init)
    } + emittedSDKProtocolCompositions.flatMap {
        $0.split(separator: "&").compactMap {
            $0.split(separator: ".").first.map(String.init)
        }
    }
).intersection(supportingModules)
let emittedSupportingImports = emittedSupportingModules.sorted()
    .map { "import \($0)" }
    .joined(separator: "\n")
let emittedSupportingImportBlock = emittedSupportingImports.isEmpty
    ? "" : "\(emittedSupportingImports)\n"
let contextualImportModules = Dictionary(
    uniqueKeysWithValues: (primaryInterfaceFiles + supportingInterfaceFiles)
        .map { ($0.module, $0.importModule) })
let emittedSDKProtocolModules = Set(
    emittedSDKProtocolCompositions.flatMap {
        $0.split(separator: "&").compactMap {
            $0.split(separator: ".").first.map(String.init)
        }
    }.map { contextualImportModules[$0] ?? $0 })
let emittedSDKProtocolImports = emittedSDKProtocolModules.sorted()
    .map { "import \($0)" }
    .joined(separator: "\n")
let emittedSDKProtocolImportBlock = emittedSDKProtocolImports.isEmpty
    ? "" : "\(emittedSDKProtocolImports)\n"

// A stable, machine-readable surface inventory lets CI distinguish an SDK
// expansion from an accidental generator regression. It also makes the
// automatic/manual boundary inspectable without scraping the human report.
struct CoverageSection: Encodable {
    let scannedOverloads: Int
    let generatableOverloads: Int
    let emittedVariants: Int
    let emittedSignatures: [String]
    let blockers: [String: Int]
}

struct FoundationCoverageSection: Encodable {
    let scannedProperties: Int
    let emittedProperties: Int
    let scannedMethods: Int
    let emittedMethodVariants: Int
    let emittedPropertySignatures: [String]
    let emittedMethodSignatures: [String]
    let blockers: [String: Int]
}

struct BridgeCoverageReport: Encodable {
    let schemaVersion: Int
    let sdkPath: String
    let deploymentTarget: Int
    let modifiers: CoverageSection
    let constructors: CoverageSection
    let foundationMembers: FoundationCoverageSection
    let platformMembers: [String: PlatformCoverageSection]
    let generatedSDKEnums: [String: [String]]
}

if let jsonReportPath {
    let report = BridgeCoverageReport(
        schemaVersion: 2,
        sdkPath: sdk,
        deploymentTarget: deploymentTarget,
        modifiers: CoverageSection(
            scannedOverloads: modifierTotal,
            generatableOverloads: modifierGeneratable,
            emittedVariants: emittedModifierVariants.count,
            emittedSignatures: emittedModifierVariants.map(\.key).sorted(),
            blockers: modifierBlockers),
        constructors: CoverageSection(
            scannedOverloads: initTotal,
            generatableOverloads: initGeneratable,
            emittedVariants: emittedInitVariants.count,
            emittedSignatures: emittedInitVariants.map(\.key).sorted(),
            blockers: initBlockers),
        foundationMembers: FoundationCoverageSection(
            scannedProperties: memberPropertyTotal,
            emittedProperties: memberProperties.count,
            scannedMethods: memberMethodTotal,
            emittedMethodVariants: memberMethodVariants.count,
            emittedPropertySignatures: memberProperties
                .map { "\($0.type).\($0.name) -> \($0.returnType)" }.sorted(),
            emittedMethodSignatures: memberMethodVariants.map(\.key).sorted(),
            blockers: memberBlockers),
        platformMembers: platformGeneration.coverage,
        generatedSDKEnums: Dictionary(uniqueKeysWithValues: emittedSDKEnumTypes.sorted().compactMap { type in
            sdkEnumCases[type].map { (type, $0) }
        }))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: URL(fileURLWithPath: jsonReportPath), options: .atomic)
    print("\nwrote \(jsonReportPath) (coverage schema v2)")
}

// MARK: - Emit

guard emitMode else { exit(0) }

let cMemoryGeneration = try generateCMemoryBridge(sdkPath: sdk)

func paramSpecCode(_ parameter: EmittableParam) -> String {
    let label = parameter.label.map { "\"\($0)\"" } ?? "nil"
    let optional = parameter.isOptional ? ", isOptional: true" : ""
    let context = parameter.contextualType.map {
        ", contextualType: \"\($0)\""
    } ?? ""
    return "ParamSpec(\(label), .\(parameter.tag)\(optional)\(context))"
}

func generatedMappedValue(
    cast: String, isOptional: Bool, storage: String
) -> String {
    guard isOptional else {
        return cast.replacingOccurrences(of: "%@", with: storage)
    }
    let wrapped = cast.replacingOccurrences(of: "%@", with: "value")
    return "generatedOptionalArgument(\(storage)) { value in \(wrapped) }"
}

func generatedResultBuilderFunctionName(_ resultProtocol: String) -> String {
    let components = resultProtocol.split {
        !($0.isLetter || $0.isNumber)
    }
    let joined = components.map(String.init).joined()
    guard let first = joined.first else { return "result" }
    return first.lowercased() + joined.dropFirst()
}

func generatedCallPreamble(_ variant: Variant) -> [String] {
    var lines = variant.params.enumerated().compactMap { index, param in
        if param.tag == "builder" {
            return "        let b\(index) = try generatedBuilder(v[\(index)])"
        }
        if let descriptor = resultBuilderDescriptor(from: param.tag) {
            let function = generatedResultBuilderFunctionName(
                descriptor.resultProtocol)
            return "        let b\(index) = try "
                + "GeneratedResultBuilderCarriers.\(function)(v[\(index)])"
        }
        if generatedProtocolConstraint(from: param.tag) != nil {
            let cast = param.cast.replacingOccurrences(
                of: "%@", with: "v[\(index)]")
            return "        let p\(index) = \(cast)"
        }
        return nil
    }
    if let index = variant.trailingClosureIndex {
        switch variant.params[index].tag {
        case "action":
            lines.append("        let a\(index) = generatedAction(v[\(index)])")
        case "asyncAction":
            lines.append("        let a\(index) = generatedAsyncAction(v[\(index)])")
        default:
            break
        }
    }
    return lines
}

func generatedCall(_ callee: String, _ variant: Variant) -> String {
    let positionalEnd = variant.trailingClosureIndex ?? variant.params.count
    let argList = variant.params.prefix(positionalEnd).enumerated()
        .map { index, param in
            let value: String
            if param.tag == "builder"
                || resultBuilderDescriptor(from: param.tag) != nil {
                value = "{ b\(index) }"
            } else if generatedProtocolConstraint(from: param.tag) != nil {
                // A named existential is opened by Swift when passed to the
                // native generic call; an inline cast fixes the generic
                // argument to the existential type itself.
                value = "p\(index)"
            } else if param.tag.hasPrefix("wrapperProjection(") {
                // Bound by the enclosing carrier, which is the only thing that
                // can produce this parameter's type.
                value = "p\(index)"
            } else {
                value = generatedMappedValue(
                    cast: param.cast, isOptional: param.isOptional,
                    storage: "v[\(index)]")
            }
            return (param.label.map { "\($0): " } ?? "") + value
        }
        .joined(separator: ", ")
    guard let trailingIndex = variant.trailingClosureIndex else {
        return "\(callee)(\(argList))"
    }
    let head = argList.isEmpty ? callee : "\(callee)(\(argList))"
    // A bridged synchronous callback carries its whole adapter in its cast,
    // so the trailing form only has to apply it to the inputs the SDK will
    // supply.
    let syncAdapter = generatedMappedValue(
        cast: variant.params[trailingIndex].cast, isOptional: false,
        storage: "v[\(trailingIndex)]")
    let closure = switch variant.params[trailingIndex].tag {
    case "builder": "{ b\(trailingIndex) }"
    case let tag where resultBuilderDescriptor(from: tag) != nil:
        "{ b\(trailingIndex) }"
    case "action": "{ a\(trailingIndex)() }"
    case "asyncAction": "{ await a\(trailingIndex)() }"
    case "syncVoidClosure":
        "{ value in generatedSyncVoidClosure(v[\(trailingIndex)])(value) }"
    case let tag where syncClosureInputCount(from: tag) == 0:
        "{ \(syncAdapter)() }"
    case let tag where syncClosureInputCount(from: tag) == 1:
        "{ value in \(syncAdapter)(value) }"
    case "equatableAction1":
        "{ value in generatedEquatableAction1(v[\(trailingIndex)])(value) }"
    case "equatableAction2":
        "{ oldValue, newValue in "
            + "generatedEquatableAction2(v[\(trailingIndex)])"
            + "(oldValue, newValue) }"
    default: fatalError("trailing call argument is not a generated closure")
    }
    return "\(head) \(closure)"
}

/// Protocol constraints which retain the concrete runtime carrier through a
/// generated native generic call. SDK protocol compositions carry their
/// canonical interface names in the tag; ShapeStyle uses its rich coercion
/// adapter but participates in the same existential-opening mechanism.
func generatedProtocolConstraint(from tag: String) -> String? {
    if tag == "genericShapeStyle" {
        return "ShapeStyle"
    }
    return sdkProtocolComposition(from: tag)
}

/// Swift can implicitly open an existential at a generic call site, but an
/// opaque native result may still depend on that opened type and therefore
/// cannot escape the closure. Open every protocol-valued parameter in a local
/// generic function and erase the result before it crosses that boundary.
/// Both the constraints and the need for this adapter come from interface
/// metadata; no SDK declaration identity participates in the decision.
/// The carrier type for a wrapper projection, derived from the wrapper's own
/// name so the emitter and the call site agree without a lookup table. A
/// wrapper the SDK adds later lands here automatically; if its carrier were
/// somehow missing, the generated call would fail to compile against the real
/// SDK rather than fail in a session.
func generatedWrapperProjectionCarrierName(
    wrapper: String, isOptionalValue: Bool
) -> String {
    "Generated\(isOptionalValue ? "Optional" : "")\(wrapper)Projection"
}

/// The parameters a variant declares as uninitializable wrapper projections.
func wrapperProjectionParameters(
    _ variant: Variant
) -> [(index: Int, wrapper: String, isOptionalValue: Bool)] {
    variant.params.enumerated().compactMap { index, param in
        let prefix = "wrapperProjection(\""
        guard param.tag.hasPrefix(prefix), param.tag.hasSuffix(")") else {
            return nil
        }
        let inner = param.tag.dropFirst(prefix.count).dropLast()
        let parts = inner.components(separatedBy: "\", ")
        guard parts.count == 2 else { return nil }
        return (index, parts[0], parts[1] == "true")
    }
}

/// Wrap the receiver in the carrier that declares the wrapper, and hand the
/// modifier the projection SwiftUI produced. This restructures the RECEIVER
/// rather than converting the argument, which is the only move available when
/// the parameter's type admits no conversion at all.
func generatedWrapperProjectionCall(
    _ variant: Variant, returnedExpression: String
) -> [String]? {
    let projections = wrapperProjectionParameters(variant)
    guard let projection = projections.first else { return nil }
    guard projections.count == 1 else {
        fatalError(
            "\(variant.key) takes more than one wrapper projection; one "
                + "carrier cannot declare both wrappers")
    }
    let carrier = generatedWrapperProjectionCarrierName(
        wrapper: projection.wrapper,
        isOptionalValue: projection.isOptionalValue)
    let cast = variant.params[projection.index].cast
        .replacingOccurrences(of: "%@", with: "v[\(projection.index)]")
    return [
        "        return AnyView(\(carrier)(binding: \(cast)) { p\(projection.index) in",
        "            \(returnedExpression)",
        "        })",
    ]
}

func generatedProtocolOpeningCall(
    _ variant: Variant, resultType: String, returnedExpression: String
) -> [String]? {
    let protocolParameters = variant.params.enumerated().compactMap {
        index, parameter -> (index: Int, composition: String)? in
        guard let composition = generatedProtocolConstraint(
            from: parameter.tag)
        else { return nil }
        return (index, composition)
    }
    guard !protocolParameters.isEmpty else { return nil }
    let genericParameters = protocolParameters.map {
        let constraint = $0.composition.replacingOccurrences(
            of: "&", with: " & ")
        return "P\($0.index): \(constraint)"
    }.joined(separator: ", ")
    let parameters = protocolParameters.map {
        "_ p\($0.index): P\($0.index)"
    }.joined(separator: ", ")
    let arguments = protocolParameters.map {
        "p\($0.index)"
    }.joined(separator: ", ")
    return [
        "        func generatedInvoke<\(genericParameters)>(\(parameters)) -> \(resultType) {",
        "            return \(returnedExpression)",
        "        }",
        "        return generatedInvoke(\(arguments))",
    ]
}

enum SwiftUIMagicProtocolValueAdapter {
    case targetButtonMenuStyle
}

enum SwiftUIMagicModifierAdapter {
    case targetExplicitTint
}

/// Protocol-value behavior that a swiftinterface cannot describe. This
/// allowlist is intentionally keyed by the concrete semantic value discovered
/// from protocol extensions and conformances—not by the modifier consuming
/// it. Every entry states the absent framework behavior explicitly.
let swiftUIMagicProtocolValueAdapters: [
    String: (
        adapter: SwiftUIMagicProtocolValueAdapter,
        missingInterfaceSemantic: String
    )
] = [
    "SwiftUI.ButtonMenuStyle": (
        adapter: .targetButtonMenuStyle,
        missingInterfaceSemantic:
            "target framework default menu-indicator visibility"),
]

/// Modifier-level behavior with no structural carrier in the public
/// interface. Unlike ordinary API coverage, these entries are allowed only
/// for the missing SwiftUI runtime semantics stated alongside them.
let swiftUIMagicModifierAdapters: [
    String: (
        adapter: SwiftUIMagicModifierAdapter,
        missingInterfaceSemantic: String
    )
] = [
    "tint": (
        adapter: .targetExplicitTint,
        missingInterfaceSemantic:
            "whether a downstream target style received an explicit tint"),
]

func generatedModifierSemanticAdapter(_ variant: Variant) -> String? {
    var matches: [
        (
            parameter: Int,
            concreteType: String,
            specification: (
                adapter: SwiftUIMagicProtocolValueAdapter,
                missingInterfaceSemantic: String
            )
        )
    ] = []
    for (index, parameter) in variant.params.enumerated() {
        guard let composition = sdkProtocolComposition(from: parameter.tag)
        else { continue }
        for concreteType in Set(
            sdkProtocolCompositionValues[composition]?.map(\.concreteType) ?? []
        ).sorted() {
            guard let specification =
                    swiftUIMagicProtocolValueAdapters[concreteType]
            else { continue }
            matches.append((index, concreteType, specification))
        }
    }
    guard matches.count <= 1 else {
        fatalError(
            "\(variant.key) has ambiguous SwiftUI magic protocol values: "
                + matches.map(\.concreteType).joined(separator: ", "))
    }
    if let match = matches.first {
        switch match.specification.adapter {
        case .targetButtonMenuStyle:
            return ".targetButtonMenuStyle(parameter: \(match.parameter))"
        }
    }

    guard let specification = swiftUIMagicModifierAdapters[variant.name]
    else { return nil }
    switch specification.adapter {
    case .targetExplicitTint:
        let styleParameters = variant.params.enumerated().filter {
            $0.element.tag == "genericShapeStyle"
                || $0.element.tag == "shapeStyle"
                || $0.element.tag == "color"
        }
        guard styleParameters.count == 1,
              let parameter = styleParameters.first?.offset else {
            fatalError(
                "\(variant.key) lacks one tint-style parameter: "
                    + specification.missingInterfaceSemantic)
        }
        return ".targetExplicitTint(parameter: \(parameter))"
    }
}

func indentGeneratedSource(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "    " + $0 }
        .joined(separator: "\n")
}

func runtimeAvailabilityGuarded(
    _ exact: String, fallback: String, for variant: Variant
) -> String {
    let clauses = targetAvailabilityClauses(
        variant.minimumTargetAvailabilities)
    guard !clauses.isEmpty else { return exact }
    return """
        if #available(\(clauses.joined(separator: ", ")), *) {
    \(indentGeneratedSource(exact))
        } else {
    \(indentGeneratedSource(fallback))
        }
    """
}

func entryCode(_ variant: Variant) -> String {
    let specs = variant.params
        .map(paramSpecCode)
        .joined(separator: ", ")
    let imports = variant.targetImportRequirements.sorted()
        .map { "\"\($0)\"" }
        .joined(separator: ", ")
    let importArgument = variant.targetImportRequirements.isEmpty
        ? "" : ", requiredImports: [\(imports)]"
    let preferenceArgument = variant.isDisfavoredOverload
        ? ", isDisfavored: true" : ""
    let semanticAdapterArgument = generatedModifierSemanticAdapter(variant)
        .map { ", semanticAdapter: \($0)" } ?? ""
    var lines = [
        "    register(&t, \"\(variant.name)\", [\(specs)]\(importArgument)\(preferenceArgument)\(semanticAdapterArgument)) { view, v in"
    ]
    let preamble = generatedCallPreamble(variant)
    let returnedExpression =
        "AnyView(\(generatedCall("view.\(variant.name)", variant)))"
    var invocation: [String] = []
    if let carried = generatedWrapperProjectionCall(
        variant, returnedExpression: returnedExpression
    ) {
        invocation.append(contentsOf: carried)
    } else if let opened = generatedProtocolOpeningCall(
        variant, resultType: "AnyView",
        returnedExpression: returnedExpression
    ) {
        invocation.append(contentsOf: opened)
    } else {
        invocation.append("        return \(returnedExpression)")
    }
    let carrierConditions = Set(variant.params.compactMap {
        parameter -> String? in
        guard let descriptor = resultBuilderDescriptor(
            from: parameter.tag) else {
            return nil
        }
        return generatedResultBuilderCarriers[
            descriptor.resultProtocol
        ]?.availabilityCondition
    })
    if let condition = carrierConditions.first {
        guard carrierConditions.count == 1 else {
            fatalError(
                "\(variant.key) combines incompatible result-builder "
                    + "carrier availability")
        }
        lines.append("        if #available(\(condition)) {")
        lines.append(contentsOf: (preamble + invocation).map {
            "    " + $0
        })
        lines.append("        }")
        lines.append("        return AnyView(view)")
    } else {
        lines.append(contentsOf: preamble)
        lines.append(contentsOf: invocation)
    }
    lines.append("    }")
    let exact = lines.joined(separator: "\n")
    let fallback = """
    register(&t, "\(variant.name)", [\(specs)]\(importArgument)\(preferenceArgument), executesBuilderArguments: false) { view, _ in
        return AnyView(view)
    }
    """
    let available = runtimeAvailabilityGuarded(
        exact, fallback: fallback, for: variant)
    guard !variant.targetImportRequirements.isEmpty else {
        return compileGuarded(available, for: variant)
    }
    guard let condition = compileCondition(for: variant) else {
        return available
    }
    return "#if \(condition)\n\(available)\n#else\n\(fallback)\n#endif"
}

func compileCondition(for variant: Variant) -> String? {
    let conditions = variant.requiredFrameworks
        .map(platformNativeImportCondition)
        + variant.unavailableTargetEnvironments.sorted()
            .map { "!targetEnvironment(\($0))" }
    return conditions.isEmpty ? nil : conditions.joined(separator: " && ")
}

func compileGuarded(_ source: String, for variant: Variant) -> String {
    guard let condition = compileCondition(for: variant) else { return source }
    return "#if \(condition)\n\(source)\n#endif"
}

let sorted = emittedModifierVariants.sorted {
    ($0.name, $0.params.count) < ($1.name, $1.params.count)
}
let chunkSize = 40
let chunks = stride(from: 0, to: sorted.count, by: chunkSize).map {
    Array(sorted[$0..<min($0 + chunkSize, sorted.count)])
}

let generatedCrossImportTriggers = Set(
    swiftUICrossImportFiles.map(\.triggeringModule)
)
let emittedCrossImportTriggers = Set(
    emittedModifierVariants.flatMap(\.targetImportRequirements)
).intersection(generatedCrossImportTriggers)
let generatedCrossImportImports = emittedCrossImportTriggers.sorted().map {
    "#if canImport(\($0))\nimport \($0)\n#endif"
}.joined(separator: "\n")
let generatedCrossImportImportBlock = generatedCrossImportImports.isEmpty
    ? "" : "\(generatedCrossImportImports)\n"

var output = """
// GENERATED by BridgeGen from SwiftUI SDK interfaces and cross-import overlays.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sorted.count) modifier overload variants across \(Set(sorted.map(\.name)).count) names.
import Charts
import SwiftUI
\(emittedSupportingImportBlock)\(generatedCrossImportImportBlock)import SwiftInterpreter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

extension GeneratedModifiers {
    static func build() -> [String: [GeneratedOverload]] {
        var t: [String: [GeneratedOverload]] = [:]

"""
for index in chunks.indices {
    output += "        build\(index)(&t)\n"
}
output += "        return t\n    }\n"

for (index, chunk) in chunks.enumerated() {
    output += "\n    private static func build\(index)(_ t: inout [String: [GeneratedOverload]]) {\n"
    for variant in chunk {
        output += entryCode(variant) + "\n"
    }
    output += "    }\n"
}
output += "}\n"

let outputPath = "Sources/SwiftUIBridge/Generated/GeneratedModifiers.swift"
try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
print("\nwrote \(outputPath) (\(sorted.count) variants)")

// MARK: - Emit EnvironmentValues writers

let sortedEnvironmentValues = environmentValueVariants.values.sorted {
    $0.name < $1.name
}
var environmentWriters = ""
for variant in sortedEnvironmentValues {
    let coerced = "try GeneratedDispatch.coerce(.\(variant.mapping.tag), source, context, contextualType: \"\(variant.type)\")"
    let cast = variant.mapping.cast.replacingOccurrences(
        of: "%@", with: "coerced")
    let source = variant.mapping.isOptional
        ? """
                guard let source = value.unwrappedOptionalOrSelf else {
                    return AnyView(view.environment(\\.\(variant.name), nil))
                }
        """
        : "        let source = value"
    environmentWriters += """
            "\(variant.name)": .init(
                declaration: "var EnvironmentValues.\(variant.name): \(variant.type)\(variant.mapping.isOptional ? "?" : "") { get set }",
                valueType: "\(variant.type)",
                keyPathType: "WritableKeyPath<EnvironmentValues, \(variant.type)\(variant.mapping.isOptional ? "?" : "")>",
                isOptional: \(variant.mapping.isOptional),
                coercionTag: \(String(reflecting: variant.mapping.tag)),
                writer: { view, value, context in
        \(source)
                    let coerced = \(coerced)
                    return AnyView(view.environment(\\.\(variant.name), (\(cast))))
                }),

"""
}
var environmentValuesOutput = """
// GENERATED by BridgeGen from writable EnvironmentValues in SDK interfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sortedEnvironmentValues.count) interface-derived environment writers.
import SwiftUI
import SwiftInterpreter

extension GeneratedEnvironmentValues {
    static func build() -> [String: Descriptor] {
        [\(environmentWriters)        ]
    }
}
"""
let environmentValuesPath =
    "Sources/SwiftUIBridge/Generated/GeneratedEnvironmentValues.swift"
try environmentValuesOutput.write(toFile: environmentValuesPath,
    atomically: true, encoding: .utf8)
print("wrote \(environmentValuesPath) "
    + "(\(sortedEnvironmentValues.count) writers)")

// MARK: - Emit constructors

enum SwiftUIMagicConstructorAdapter {
    case targetScroll
}

/// Constructor semantics which the swiftinterface cannot encode. Keep this
/// allowlist small and explicit: every entry names the missing framework
/// behavior, while generated runtime dispatch still operates on declared
/// argument properties rather than the constructor identity.
let swiftUIMagicConstructorAdapters: [
    String: (
        adapter: SwiftUIMagicConstructorAdapter,
        missingInterfaceSemantic: String
    )
] = [
    "ScrollView": (
        adapter: .targetScroll,
        missingInterfaceSemantic:
            "target framework intrinsic cross-axis scroll extent"),
]

func swiftUIMagicConstructorAdapterCall(
    _ variant: Variant,
    constructed: String
) -> String? {
    guard let specification = swiftUIMagicConstructorAdapters[variant.name]
    else {
        return nil
    }
    switch specification.adapter {
    case .targetScroll:
        guard let builderIndex = variant.params.firstIndex(where: {
            $0.tag == "builder"
        }) else {
            fatalError(
                "\(variant.name) target-scroll adapter has no builder: "
                    + specification.missingInterfaceSemantic)
        }
        let axes = variant.params.firstIndex(where: {
            $0.tag == "axisSet"
        }).map {
            "v[\($0)] as! Axis.Set"
        } ?? "Axis.Set.vertical"
        let showsIndicators = variant.params.firstIndex(where: {
            $0.label == "showsIndicators" && $0.tag == "bool"
        }).map {
            "v[\($0)] as! Bool"
        } ?? "true"
        return """
        TargetPlatformScrollBridge.applyGenerated(
            to: AnyView(\(constructed)),
            axes: \(axes),
            showsIndicators: \(showsIndicators),
            builderValue: v[\(builderIndex)])
        """
    }
}

func initEntryCode(_ variant: Variant) -> String {
    let specs = variant.params
        .map(paramSpecCode)
        .joined(separator: ", ")
    let preferenceArgument = variant.isDisfavoredOverload
        ? ", isDisfavored: true" : ""
    var lines = [
        "    register(&t, \"\(variant.name)\", [\(specs)]\(preferenceArgument)) { v in"
    ]
    lines.append(contentsOf: generatedCallPreamble(variant))
    let constructed = generatedCall(variant.name, variant)
    if let adapted = swiftUIMagicConstructorAdapterCall(
        variant, constructed: constructed
    ) {
        lines.append(
            "        return " + adapted.replacingOccurrences(
                of: "\n", with: "\n        "))
    } else {
        // Generated View initializers retain their concrete native result.
        // ViewRegistry erases only when rendering; interface-generated
        // same-type members can therefore execute before that boundary.
        let returnedExpression = constructed
        if let opened = generatedProtocolOpeningCall(
            variant, resultType: "Any",
            returnedExpression: returnedExpression
        ) {
            lines.append(contentsOf: opened)
        } else {
            lines.append("        return \(returnedExpression)")
        }
    }
    lines.append("    }")
    return compileGuarded(
        runtimeAvailabilityRegistration(lines.joined(separator: "\n"),
                                        for: variant),
        for: variant)
}

/// A registration the host may be too old to run is registered only where the
/// type exists. Unlike the modifier tier's guard — which has a receiver to
/// fall back to and so needs an `else` — an absent constructor has no value to
/// stand in for: the entry simply is not there, and resolution reports the
/// initializer unresolved exactly as it did before this widening.
func runtimeAvailabilityRegistration(
    _ source: String, for variant: Variant
) -> String {
    let clauses = targetAvailabilityClauses(
        variant.minimumTargetAvailabilities)
    guard !clauses.isEmpty else { return source }
    return """
        if #available(\(clauses.joined(separator: ", ")), *) {
    \(indentGeneratedSource(source))
        }
    """
}

func platformSemanticAdapterEntryCode(
    _ adapter: PlatformSemanticAdapterVariant
) -> String {
    let variant = adapter.variant
    let specs = variant.params.map(paramSpecCode).joined(separator: ", ")
    let result = switch adapter.resultKind {
    case .shapeStyle:
        "generatedPlatformShapeStyleValue(v[0])"
    case .view:
        "try generatedPlatformViewValue(v[0])"
    }
    let source = """
    register(&t, "\(variant.name)", [\(specs)]) { v in
        return \(result)
    }
    """
    return "#if !canImport(\(adapter.unavailableFramework))\n\(source)\n#endif"
}

func staticFactoryEntryCode(_ factory: StaticFactoryVariant) -> String {
    let variant = factory.variant
    let specs = variant.params.map(paramSpecCode).joined(separator: ", ")
    var lines = [
        "    register(&t, \"\(variant.name)\", [\(specs)]) { v in"
    ]
    lines.append(contentsOf: generatedCallPreamble(variant))
    // A `static var` is read, never called; a `static func` takes the same
    // generated argument list as an initializer of the same nominal.
    let produced = factory.isProperty
        ? variant.name
        : generatedCall(variant.name, variant)
    lines.append("        return \(produced)")
    lines.append("    }")
    return compileGuarded(lines.joined(separator: "\n"), for: variant)
}

let sortedStaticFactories = staticFactoryVariants
    .filter { supportsResultBuilders($0.variant) }
    .sorted { $0.key < $1.key }

// `key` breaks the tie because name-and-arity does not: the eight
// `Binding(projectedValue:)` variants differ only in their value type, so
// without it their emitted order is whatever seed the upstream Set was
// iterated under, and two runs of the same binary disagree.
let sortedInits = emittedInitVariants.sorted {
    ($0.name, $0.params.count, $0.key) < ($1.name, $1.params.count, $1.key)
}
let initChunks = stride(from: 0, to: sortedInits.count, by: chunkSize).map {
    Array(sortedInits[$0..<min($0 + chunkSize, sortedInits.count)])
}

var viewsOutput = """
// GENERATED by BridgeGen from the SDK's SwiftUICore/SwiftUI swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sortedInits.count) initializer variants across \(Set(sortedInits.map(\.name)).count) SwiftUI structs.
// Charts is imported for the same reason the modifier table imports it: both
// tables are emitted from the same parsed primary interfaces, so either may
// name a type declared by any of them.
import Charts
import SwiftUI
\(emittedSupportingImportBlock)import SwiftInterpreter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

extension GeneratedConstructors {
    static func build() -> [String: [GeneratedConstructor]] {
        var t: [String: [GeneratedConstructor]] = [:]

"""
for index in initChunks.indices {
    viewsOutput += "        build\(index)(&t)\n"
}
if !platformSemanticAdapterVariants.isEmpty {
    viewsOutput += "        buildPlatformSemanticAdapters(&t)\n"
}
viewsOutput += "        return t\n    }\n"

for (index, chunk) in initChunks.enumerated() {
    viewsOutput += "\n    private static func build\(index)(_ t: inout [String: [GeneratedConstructor]]) {\n"
    for variant in chunk {
        viewsOutput += initEntryCode(variant) + "\n"
    }
    viewsOutput += "    }\n"
}
if !platformSemanticAdapterVariants.isEmpty {
    viewsOutput += "\n    private static func buildPlatformSemanticAdapters(_ t: inout [String: [GeneratedConstructor]]) {\n"
    for adapter in platformSemanticAdapterVariants.sorted(by: {
        ($0.variant.name, $0.variant.key, $0.unavailableFramework)
            < ($1.variant.name, $1.variant.key, $1.unavailableFramework)
    }) {
        viewsOutput += platformSemanticAdapterEntryCode(adapter) + "\n"
    }
    viewsOutput += "    }\n"
}
viewsOutput += "}\n"

viewsOutput += """

extension GeneratedStaticFactories {
    static func build() -> [String: [GeneratedConstructor]] {
        var t: [String: [GeneratedConstructor]] = [:]

"""
for factory in sortedStaticFactories {
    viewsOutput += staticFactoryEntryCode(factory) + "\n"
}
viewsOutput += "        return t\n    }\n}\n"

let viewsPath = "Sources/SwiftUIBridge/Generated/GeneratedViews.swift"
try viewsOutput.write(toFile: viewsPath, atomically: true, encoding: .utf8)
print("wrote \(viewsPath) (\(sortedInits.count) variants, "
    + "\(sortedStaticFactories.count) same-type static factories)")

var resultBuildersOutput = """
// GENERATED by BridgeGen from interface-declared non-View result builders.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(generatedResultBuilderCarriers.count) typed existential carriers.
import Charts
import SwiftUI
import SwiftInterpreter

"""

for descriptor in generatedResultBuilderCarriers.values.sorted(by: {
    ($0.resultProtocol, $0.builder)
        < ($1.resultProtocol, $1.builder)
}) {
    let resultProtocol = descriptor.resultProtocol
    let builder = descriptor.builder
    let carrier = resultProtocol.split {
        !($0.isLetter || $0.isNumber)
    }.map(String.init).joined() + "GeneratedCarrier"
    let function = generatedResultBuilderFunctionName(resultProtocol)
    let availability = descriptor.availabilityAttributes.map {
        $0 + "\n"
    }.joined()

    resultBuildersOutput += availability
    resultBuildersOutput += """
struct \(carrier): \(resultProtocol) {
    let values: [any \(resultProtocol)]

    @\(builder) var body: some \(resultProtocol) {

"""
    for index in 0..<descriptor.maximumArity {
        resultBuildersOutput += """
        if values.indices.contains(\(index)) {
            \(builder).buildLimitedAvailability(values[\(index)])
        }

"""
    }
    resultBuildersOutput += """
    }
}

"""
    resultBuildersOutput += availability
    resultBuildersOutput += """
extension GeneratedResultBuilderCarriers {
    @MainActor
    static func \(function)(_ value: Any) throws -> \(carrier) {
        guard let builder = value as? BuilderValue,
              let closure = builder.value.closureValue else {
            throw RuntimeError(message: "expected a result-builder closure")
        }
        let values = try builder.context.callResultBuilderClosure(
            closure, arguments: [], resultProtocol: "\(resultProtocol)"
        ).map { value -> any \(resultProtocol) in
            guard case .host(let payload) = value,
                  let content = payload as? any \(resultProtocol) else {
                throw RuntimeError(
                    message: "expected \(resultProtocol) builder content")
            }
            return content
        }
        return \(carrier)(values: values)
    }
}

"""
}

let generatedResultBuilderNominals = resultBuilderContentInfo.compactMap {
    name, info -> (String, [String])? in
    let protocols = info.protocols.intersection(
        supportedResultBuilderProtocols).sorted()
    return protocols.isEmpty ? nil : (name, protocols)
}.sorted { $0.0 < $1.0 }

resultBuildersOutput += """
extension GeneratedResultBuilderCarriers {
    private static let importedResultProtocolsByType: [String: Set<String>] = [

"""
for (name, protocols) in generatedResultBuilderNominals {
    let values = protocols.map { "\"\($0)\"" }.joined(separator: ", ")
    resultBuildersOutput += "        \"\(name)\": [\(values)],\n"
}
resultBuildersOutput += """
    ]

    static func importedType(
        named typeName: String, conformsTo protocolName: String
    ) -> Bool? {
        let nominal = typeName.split(separator: ".").last.map(String.init)
            ?? typeName
        guard let protocols = importedResultProtocolsByType[nominal] else {
            return nil
        }
        return protocols.contains {
            HostSignature.equivalentTypeName($0, protocolName)
        }
    }
}

"""

let resultBuildersPath =
    "Sources/SwiftUIBridge/Generated/GeneratedResultBuilderCarriers.swift"
try resultBuildersOutput.write(
    toFile: resultBuildersPath, atomically: true, encoding: .utf8)
print(
    "wrote \(resultBuildersPath) "
        + "(\(generatedResultBuilderCarriers.count) carriers)")

// MARK: - Emit contextual SDK value coercions

var enumsOutput = """
// GENERATED by BridgeGen from public SwiftUI SDK enum cases and same-type statics.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(emittedSDKEnumTypes.count) contextual value types.
import Charts
import SwiftUI
\(emittedSupportingImportBlock)import SwiftInterpreter

enum GeneratedSDKEnumCoercions {
    static func coerce(
        _ typeName: String, _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Any {
        switch typeName {

"""

/// The call-shaped arm of the same coercion: an `ImplicitMemberCall` is a
/// leading dot that carried arguments, so it resolves against the same
/// contextual type a bare `.implicitMember` would — through the factory the
/// interface declares rather than through storage.
func contextualFactoryDispatchCode(
    type: String, validationOnly: Bool
) -> String {
    guard let factories = sdkContextualFactoriesByType[type],
          !factories.isEmpty else {
        return ""
    }
    var output = ""
    output += "            if case .host(let any) = value,\n"
    output += "               let call = any as? ImplicitMemberCall,\n"
    output += "               let context {\n"
    for factory in factories {
        let specs = factory.params.map(paramSpecCode).joined(separator: ", ")
        let arguments = factory.params.enumerated().map {
            index, parameter -> String in
            let value = generatedMappedValue(
                cast: parameter.cast,
                isOptional: parameter.isOptional,
                storage: "arguments[\(index)]")
            return (parameter.label.map { "\($0): " } ?? "") + value
        }.joined(separator: ", ")
        let availability = targetAvailabilityClauses(
            factory.minimumTargetAvailabilities)
        if !validationOnly, !availability.isEmpty {
            output += "                if #available(\(availability.joined(separator: ", ")), *) {\n"
        }
        let indent = !validationOnly && !availability.isEmpty
            ? "                    " : "                "
        output += "\(indent)if call.name == \(String(reflecting: factory.name)),\n"
        output += "\(indent)   let arguments = GeneratedDispatch.contextualMethodArguments([\(specs)], call.arguments, context) {\n"
        if validationOnly {
            output += "\(indent)    return call\n"
        } else {
            output += "\(indent)    return \(type).`\(factory.name)`(\(arguments))\n"
        }
        output += "\(indent)}\n"
        if !validationOnly, !availability.isEmpty {
            output += "                }\n"
        }
    }
    output += "                throw RuntimeError(message: \"unknown \(type) contextual factory '.\\(call.name)'\")\n"
    output += "            }\n"
    return output
}

func contextualMethodDispatchCode(
    type: String, validationOnly: Bool
) -> String {
    guard let methods = sdkContextualMethodsByType[type],
          !methods.isEmpty else {
        return ""
    }
    var output = ""
    output += "            if case .host(let any) = value,\n"
    output += "               let chain = any as? ChainedImplicitCall,\n"
    output += "               let context {\n"
    if validationOnly {
        output += "                _ = try coerce(typeName, chain.base, context: context)\n"
    } else {
        output += "                let base = try coerce(typeName, chain.base, context: context) as! \(type)\n"
    }
    for method in methods {
        let specs = method.params.map(paramSpecCode).joined(separator: ", ")
        let arguments = method.params.enumerated().map {
            index, parameter -> String in
            let value = generatedMappedValue(
                cast: parameter.cast,
                isOptional: parameter.isOptional,
                storage: "arguments[\(index)]")
            return (parameter.label.map { "\($0): " } ?? "") + value
        }.joined(separator: ", ")
        let availability = targetAvailabilityClauses(
            method.minimumTargetAvailabilities)
        if !validationOnly, !availability.isEmpty {
            output += "                if #available(\(availability.joined(separator: ", ")), *) {\n"
        }
        let indent = !validationOnly && !availability.isEmpty
            ? "                    " : "                "
        output += "\(indent)if chain.member == \(String(reflecting: method.name)),\n"
        output += "\(indent)   let arguments = GeneratedDispatch.contextualMethodArguments([\(specs)], chain.arguments, context) {\n"
        if validationOnly {
            output += "\(indent)    return chain\n"
        } else {
            output += "\(indent)    return base.`\(method.name)`(\(arguments))\n"
        }
        output += "\(indent)}\n"
        if !validationOnly, !availability.isEmpty {
            output += "                }\n"
        }
    }
    output += "                throw RuntimeError(message: \"unknown \(type) contextual method '.\\(chain.member)'\")\n"
    output += "            }\n"
    return output
}

for type in emittedSDKEnumTypes.sorted() {
    let cases = sdkEnumCases[type] ?? []
    let factories = sdkContextualFactoriesByType[type] ?? []
    // A type whose whole contextual surface is call-shaped (`.units(…)` with
    // no payload-free sibling) still has a coercion to emit.
    guard !cases.isEmpty || !factories.isEmpty else { continue }
    enumsOutput += "        case \"\(type)\":\n"
    let frameworkCondition = (
        sdkEnumFrameworkRequirements[type] ?? []
    ).sorted().map(platformNativeImportCondition).joined(separator: " && ")
    let availabilityClauses = targetAvailabilityClauses(
        minimumSDKContextualAvailabilities(for: type))

    func validationFallback() -> String {
        var output = ""
        if sdkSetAlgebraTypes.contains(type) {
            output += "            if case .array(let elements) = value {\n"
            output += "                for element in elements { _ = try coerce(typeName, element, context: context) }\n"
            output += "                return elements\n"
            output += "            }\n"
        }
        output += contextualFactoryDispatchCode(
            type: type, validationOnly: true)
        output += contextualMethodDispatchCode(
            type: type, validationOnly: true)
        output += "            guard case .implicitMember(let member) = value else {\n"
        output += "                throw RuntimeError(message: \"expected a \(type) implicit member\")\n"
        output += "            }\n"
        guard !cases.isEmpty else {
            output += "            throw RuntimeError(message: \"unknown \(type) member '.\\(member)'\")\n"
            return output
        }
        output += "            switch member {\n"
        output += "            case \(cases.map { "\"\($0)\"" }.joined(separator: ", ")): return member\n"
        output += "            default:\n"
        output += "                throw RuntimeError(message: \"unknown \(type) member '.\\(member)'\")\n"
        output += "            }\n"
        return output
    }

    if !frameworkCondition.isEmpty {
        enumsOutput += "            #if \(frameworkCondition)\n"
    }
    if !availabilityClauses.isEmpty {
        enumsOutput += "            if #available(\(availabilityClauses.joined(separator: ", ")), *) {\n"
    }
    enumsOutput += "            if case .host(let any) = value, let typed = any as? \(type) { return typed }\n"
    enumsOutput += contextualFactoryDispatchCode(
        type: type, validationOnly: false)
    enumsOutput += contextualMethodDispatchCode(
        type: type, validationOnly: false)
    if sdkSetAlgebraTypes.contains(type) {
        enumsOutput += "            if case .array(let elements) = value {\n"
        enumsOutput += "                var result = \(type)()\n"
        enumsOutput += "                for element in elements {\n"
        enumsOutput += "                    result.formUnion(try coerce(typeName, element, context: context) as! \(type))\n"
        enumsOutput += "                }\n"
        enumsOutput += "                return result\n"
        enumsOutput += "            }\n"
    }
    enumsOutput += "            guard case .implicitMember(let member) = value else {\n"
    enumsOutput += "                throw RuntimeError(message: \"expected a \(type) implicit member\")\n"
    enumsOutput += "            }\n"
    enumsOutput += "            switch member {\n"
    for caseName in cases {
        // Backticks are valid around every identifier and cover SDK members
        // whose spelling is also a Swift keyword.
        let memberFrameworkCondition = (
            sdkEnumMemberFrameworkRequirements[type]?[caseName] ?? []
        ).sorted().map(platformNativeImportCondition)
            .joined(separator: " && ")
        let memberAvailabilityClauses = targetAvailabilityClauses(
            sdkEnumMemberMinimumTargetAvailabilities[type]?[caseName] ?? [])
        if memberFrameworkCondition.isEmpty,
           memberAvailabilityClauses.isEmpty {
            enumsOutput += "            case \"\(caseName)\": return \(type).`\(caseName)` as \(type)\n"
            continue
        }
        enumsOutput += "            case \"\(caseName)\":\n"
        if !memberFrameworkCondition.isEmpty {
            enumsOutput += "                #if \(memberFrameworkCondition)\n"
        }
        if !memberAvailabilityClauses.isEmpty {
            enumsOutput += "                if #available(\(memberAvailabilityClauses.joined(separator: ", ")), *) {\n"
            enumsOutput += "                    return \(type).`\(caseName)` as \(type)\n"
            enumsOutput += "                }\n"
        } else {
            enumsOutput += "                return \(type).`\(caseName)` as \(type)\n"
        }
        if !memberFrameworkCondition.isEmpty {
            enumsOutput += "                #endif\n"
            // Off-host adapters validate the same interface-derived member
            // inventory without naming a declaration unavailable to the host.
            enumsOutput += "                return member\n"
        } else if !memberAvailabilityClauses.isEmpty {
            enumsOutput += "                return member\n"
        }
    }
    enumsOutput += "            default:\n"
    enumsOutput += "                throw RuntimeError(message: \"unknown \(type) member '.\\(member)'\")\n"
    enumsOutput += "            }\n"
    if !availabilityClauses.isEmpty {
        enumsOutput += "            } else {\n"
        enumsOutput += validationFallback()
        enumsOutput += "            }\n"
    }
    if !frameworkCondition.isEmpty {
        // The target-only declaration cannot be named in this host
        // compilation. Its off-host generated adapter ignores native values,
        // but overload matching must still validate contextual spellings from
        // the same interface-derived case inventory.
        enumsOutput += "            #else\n"
        enumsOutput += validationFallback()
        enumsOutput += "            #endif\n"
    }
}
enumsOutput += """
        default:
            throw RuntimeError(message: "unknown generated SDK contextual type '\\(typeName)'")
        }
    }

"""

// Which contextual types are FORMAT STYLES is read from the conformance the
// interface declares, not from the positions that happen to consume one.
//
// A style is only ever written as a leading dot — `.number`, `.units(width:)`,
// `.relative(presentation:)` — so the type it denotes must be recovered from
// context, and the consumer scraped `format:` PARAMETERS to learn the
// candidates. That misses every style whose consuming parameter is unlabeled:
// `extension Swift.Duration { func formatted<S>(_ v: S) -> S.FormatOutput
// where S.FormatInput == Swift.Duration }` spells no `format:`, so no scrape
// can see `Duration.UnitsFormatStyle` however many styles the SDK adds.
//
// The conformance is the fact that actually defines the family, and reading it
// makes the two positions that accept a style — a localization key's
// interpolation and `formatted(_:)` — share one list instead of each deriving
// its own from the shape of its own call site.
//
// Conformances are recorded under MODULE-QUALIFIED keys while the emitted
// contextual types are normalized, so the two are matched by normalizing the
// conformance side rather than by querying with a name the map is not keyed
// by. The protocol itself is looked up the same way instead of spelling its
// qualified name, so a module rename cannot silently empty this list.
let formatStyleProtocolNames = sdkProtocols.filter {
    normalize($0) == "FormatStyle"
}
let sdkFormatStyleTypeNames = Set(
    sdkNominalConformances.compactMap { type, conformances -> String? in
        let closure = conformances.reduce(into: Set<String>()) {
            $0.formUnion(protocolClosure(of: $1))
        }
        return closure.isDisjoint(with: formatStyleProtocolNames)
            ? nil : normalize(type)
    })
let emittedFormatStyleTypes = emittedSDKEnumTypes
    .filter { sdkFormatStyleTypeNames.contains($0) }
    .sorted()
enumsOutput += """
    /// Every emitted contextual type the interface declares as a `FormatStyle`,
    /// sorted so candidate order cannot vary between runs.
    ///
    /// Which of these a given leading dot denotes is NOT decided here: a
    /// caller coerces against each in turn and the style's own `FormatInput`
    /// rules out the ones that cannot accept the value, exactly as the
    /// constraint solver would. So a style family added to the SDK is picked
    /// up by regenerating, with no table to keep in step.
    static let formatStyleTypeNames: [String] = [
\(emittedFormatStyleTypes.map { "        \"\($0)\",\n" }.joined())    ]

"""

// The call POSITION that consumes one of those styles, read from the same
// interface rather than spelled. `formatted(.units(width: .narrow))` carries
// its style as a leading dot, so the argument has no type until a style is
// chosen and the call cannot be recognized by its argument. The method name
// is what identifies it, and the interface states the name — under three
// different parameter names across a dozen declarations, which is exactly why
// the collector matches the CONSTRAINT and not the spelling.
let formatStyleConsumingMethods = sdkProtocolConsumingMethods
    .filter {
        !protocolClosure(of: $0.constraintProtocol)
            .isDisjoint(with: formatStyleProtocolNames)
    }
    .map(\.name)
let sortedFormatStyleConsumingMethods = Set(formatStyleConsumingMethods).sorted()
enumsOutput += """
    /// Every method name the interface declares as taking a bare `FormatStyle`
    /// generic as its only argument, sorted so order cannot vary between runs.
    ///
    /// A caller matches the name and then lets the style select itself against
    /// the receiver, so this never says which types may be formatted — the
    /// style's own `FormatInput` does, at the call.
    static let formatStyleConsumingMethodNames: [String] = [
\(sortedFormatStyleConsumingMethods.map { "        \"\($0)\",\n" }.joined())    ]
}
"""

let enumsPath = "Sources/SwiftUIBridge/Generated/GeneratedSDKEnums.swift"
try enumsOutput.write(toFile: enumsPath, atomically: true, encoding: .utf8)
print("wrote \(enumsPath) (\(emittedSDKEnumTypes.count) enum types, "
    + "\(emittedFormatStyleTypes.count) format styles, "
    + "\(sortedFormatStyleConsumingMethods.count) style-consuming methods)")

var protocolValuesOutput = """
// GENERATED by BridgeGen from interface-declared protocol shapes,
// conformances, and public protocol-extension `Self == Concrete` values.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(emittedSDKProtocolCompositions.count) protocol compositions.
\(emittedSDKProtocolImportBlock)import SwiftInterpreter

struct GeneratedSDKFrameworkConfigurationProtocol {
    let configurationType: String
    let bodyMethod: String
    let configurationLabel: String?
    let members: [String]
}


"""

func generatedFrameworkConfigurationWrapperName(
    _ protocolType: String
) -> String {
    let identifier = protocolType.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
    }.joined()
    return "GeneratedInterpreted_\(identifier)"
}

let generatedFrameworkConfigurationWrapperNames =
    emittedSDKFrameworkConfigurationProtocols.keys.map(
        generatedFrameworkConfigurationWrapperName)
precondition(
    Set(generatedFrameworkConfigurationWrapperNames).count
        == generatedFrameworkConfigurationWrapperNames.count,
    "framework configuration protocol wrapper identifiers collided")

for (protocolType, descriptor) in
    emittedSDKFrameworkConfigurationProtocols.sorted(
        by: { $0.key < $1.key }
    )
{
    let wrapper = generatedFrameworkConfigurationWrapperName(protocolType)
    let parameter = descriptor.configurationLabel.map {
        "\($0) generatedConfiguration"
    } ?? "_ generatedConfiguration"
    protocolValuesOutput += """
struct \(wrapper): \(protocolType) {
    private let carrier: InterpretedFrameworkConfigurationCarrier

    init(carrier: InterpretedFrameworkConfigurationCarrier) {
        self.carrier = carrier
    }

    nonisolated func \(descriptor.bodyMethod)(
        \(parameter): Configuration
    ) -> some View {
        nonisolated(unsafe) let carried = generatedConfiguration
        nonisolated(unsafe) var result = AnyView(EmptyView())
        MainActor.assumeIsolated {
            result = interpretedFrameworkConfigurationBody(
                carrier: carrier,
                configuration: carried,
                fallback: result)
        }
        return result
    }
}


"""
}

protocolValuesOutput += """
enum GeneratedSDKProtocolValueCoercions {
    static let frameworkConfigurationProtocols:
        [String: GeneratedSDKFrameworkConfigurationProtocol] = [

"""

for (protocolType, descriptor) in
    emittedSDKFrameworkConfigurationProtocols.sorted(
        by: { $0.key < $1.key }
    )
{
    let label = descriptor.configurationLabel.map { "\"\($0)\"" } ?? "nil"
    let members = (sdkFrameworkConfigurationMembers[
        descriptor.configurationType
    ] ?? []).map(\.name).sorted()
    let memberList = members.map { "\"\($0)\"" }.joined(separator: ", ")
    protocolValuesOutput += """
        "\(protocolType)": .init(
            configurationType: "\(descriptor.configurationType)",
            bodyMethod: "\(descriptor.bodyMethod)",
            configurationLabel: \(label),
            members: [\(memberList)]),

"""
}

protocolValuesOutput += """
    ]

    static func frameworkConfigurationMember(
        _ name: String, on value: Any
    ) -> RuntimeValue? {
        switch value {

"""

func generatedMemberAccess(_ name: String) -> String {
    name.hasPrefix("$") ? name : "`\(name)`"
}

for configurationType in emittedSDKFrameworkConfigurationTypes.sorted() {
    let members = (sdkFrameworkConfigurationMembers[
        configurationType
    ] ?? []).sorted {
        ($0.name, $0.type) < ($1.name, $1.type)
    }
    guard !members.isEmpty else { continue }
    protocolValuesOutput += """
        case let configuration as \(configurationType):
            switch name {

"""
    for member in members {
        protocolValuesOutput += """
            case "\(member.name)":
                return generatedFrameworkConfigurationRuntimeValue(
                    configuration.\(generatedMemberAccess(member.name)))

"""
    }
    protocolValuesOutput += """
            default:
                return nil
            }

"""
}

protocolValuesOutput += """
        default:
            return nil
        }
    }

    static func coerce(
        _ composition: String, _ value: RuntimeValue,
        context: EvalContext? = nil
    ) throws -> Any {
        if let context,
           let descriptor = frameworkConfigurationProtocols[composition],
           let carrier = interpretedFrameworkConfigurationConformer(
            value,
            protocolType: composition,
            descriptor: descriptor,
            context: context
           ) {
            switch composition {

"""

for (protocolType, _) in emittedSDKFrameworkConfigurationProtocols.sorted(
    by: { $0.key < $1.key }
) {
    let wrapper = generatedFrameworkConfigurationWrapperName(protocolType)
    protocolValuesOutput += """
            case "\(protocolType)":
                return \(wrapper)(carrier: carrier)

"""
}

protocolValuesOutput += """
            default:
                break
            }
        }
        switch composition {

"""

for composition in emittedSDKProtocolCompositions.sorted() {
    guard let values = sdkProtocolCompositionValues[composition],
          !values.isEmpty else { continue }
    protocolValuesOutput += "        case \"\(composition)\":\n"
    protocolValuesOutput += "            if case .host(let any) = value {\n"
    for concreteType in Set(values.map(\.concreteType)).sorted() {
        protocolValuesOutput += "                if let typed = any as? \(concreteType) { return typed }\n"
    }
    protocolValuesOutput += "            }\n"
    protocolValuesOutput += "            guard case .implicitMember(let member) = value else {\n"
    protocolValuesOutput += "                throw RuntimeError(message: \"expected a \(composition) implicit member\")\n"
    protocolValuesOutput += "            }\n"
    protocolValuesOutput += "            switch member {\n"
    for contextualValue in values {
        protocolValuesOutput += "            case \"\(contextualValue.member)\":\n"
        protocolValuesOutput += "                return \(contextualValue.concreteType).`\(contextualValue.member)`\n"
    }
    protocolValuesOutput += "            default:\n"
    protocolValuesOutput += "                throw RuntimeError(message: \"unknown \(composition) member '.\\(member)'\")\n"
    protocolValuesOutput += "            }\n"
}
protocolValuesOutput += """
        default:
            throw RuntimeError(
                message: "unknown generated SDK protocol composition '\\(composition)'")
        }
    }
}
"""

let protocolValuesPath =
    "Sources/SwiftUIBridge/Generated/GeneratedSDKProtocolValues.swift"
try protocolValuesOutput.write(
    toFile: protocolValuesPath, atomically: true, encoding: .utf8)
print(
    "wrote \(protocolValuesPath) "
        + "(\(emittedSDKProtocolCompositions.count) protocol compositions)")

// MARK: - Emit members

/// Array-typed contracts box element-wise into the interpreter's array
/// plane (`DateBins.thresholds`); every other return keeps its host
/// typing. The choice is made HERE at emit time — a type-directed
/// overload would re-rank member resolution inside the emitted closures
/// (Sequence.dropLast beating IndexPath.dropLast).
func memberResultCall(_ returnType: String) -> String {
    if returnType.hasPrefix("[") && returnType.hasSuffix("]")
        && !returnType.contains(":") {
        return "generatedMemberArrayResult"
    }
    if foundationMaterializableSequenceTypes.contains(returnType) {
        return "generatedMemberSequenceResult"
    }
    return "generatedMemberResult"
}

func memberPropertyCode(_ property: MemberProperty) -> String {
    if property.isSettable {
        return """
            registerProperty(&t, "var \(property.type).\(property.name): \(property.returnType) { get set }", get: { base in
                (base as? \(memberReceiverCast(for: property.type))).map { \(memberResultCall(property.returnType))($0.\(property.name)) }
            }, mutate: { base, newValue in
                guard var copy = base as? \(memberReceiverCast(for: property.type)) else {
                    throw RuntimeError(message: "generated \(property.type).\(property.name) mutation received the wrong receiver", fatal: true)
                }
                copy.\(property.name) = try convertGeneratedPropertyValue(newValue, as: \(property.returnType).self)
                return copy
            })
    """
    }
    return """
            registerProperty(&t, "var \(property.type).\(property.name): \(property.returnType) { get }", get: { base in
                (base as? \(memberReceiverCast(for: property.type))).map { \(memberResultCall(property.returnType))($0.\(property.name)) }
            })
    """
}

func memberMethodCode(_ variant: MemberVariant) -> String {
    let parameters = variant.params.enumerated().map { index, param in
            "\(param.label ?? "_") p\(index): \(param.contractType!)"
        }
        .joined(separator: ", ")
    let receiver = foundationalGenericStructCarrierKeys.contains(variant.type) ? variant.type : memberReceiverCast(for: variant.type)
    let declaration = "func \(receiver).\(variant.name)(\(parameters)) -> \(variant.returnType)"
    let specs = variant.params
        .map { "ParamSpec(\($0.label.map { "\"\($0)\"" } ?? "nil"), .\($0.tag))" }
        .joined(separator: ", ")
    let argList = variant.params.enumerated()
        .map { index, param in
            (param.label.map { "\($0): " } ?? "") + param.cast.replacingOccurrences(of: "%@", with: "v[\(index)]")
        }
        .joined(separator: ", ")
    if variant.type == "Measurement", variant.name == "formatted", variant.params.isEmpty {
        return """
            registerMethod(&t, "\(declaration)", []) { base, v in
                generatedMemberResult(GeneratedMembers.measurementFormatted(base as! Measurement<Dimension>))
            }
    """
    }
    return """
            registerMethod(&t, "\(declaration)", [\(specs)]) { base, v in
                \(memberResultCall(variant.returnType))((base as! \(memberReceiverCast(for: variant.type))).\(variant.name)(\(argList)))
            }
    """
}

let sortedProperties = memberProperties.sorted { ($0.type, $0.name) < ($1.type, $1.name) }
let sortedMembers = memberMethodVariants.sorted { ($0.type, $0.name, $0.params.count) < ($1.type, $1.name, $1.params.count) }
let concreteViewMethodKeysLiteral = Set(
    sortedMembers.lazy
        .filter { concreteViewMemberTypes.contains($0.type) }
        .map { $0.type + "." + $0.name }
).sorted()
    .map(String.init(reflecting:))
    .joined(separator: ", ")
var knownImportedNestedTypePaths: Set<String> = []
let importedNestedTypeSeeds = memberTypes
    .union(foundationMaterializableSequenceTypes)
    .union(nativeValueInits.map(\.type))
    .union(foundationRuntimeAliasMap.keys)
    .union(foundationRuntimeAliasMap.values.flatMap { $0 })
    .union(foundationAttributedStringKeySurface.keyTypeNames)
    .union(foundationAttributedStringKeySurface.receiverTypeNames)
for typeName in importedNestedTypeSeeds {
    let components = typeName.split(separator: ".").map(String.init)
    guard components.count > 1 else { continue }
    for count in 2...components.count {
        knownImportedNestedTypePaths.insert(
            components.prefix(count).joined(separator: "."))
    }
}
let knownImportedNestedTypePathsLiteral = knownImportedNestedTypePaths
    .sorted()
    .map(String.init(reflecting:))
    .joined(separator: ", ")
var nestedRuntimeNameGroups: [String: [String]] = [:]
let nestedRuntimeTypes = memberTypes.union(
    foundationMaterializableSequenceTypes)
for typeName in nestedRuntimeTypes where typeName.contains(".") {
    let leaf = typeName.split(separator: ".").last.map(String.init)
        ?? typeName
    nestedRuntimeNameGroups[leaf, default: []].append(typeName)
}
var nestedRuntimeNames: [String: String] = [:]
for (leaf, names) in nestedRuntimeNameGroups where names.count == 1 {
    nestedRuntimeNames[leaf] = names[0]
}
let nestedRuntimeNamesLiteral = nestedRuntimeNames.sorted(by: {
    $0.key < $1.key
}).map {
    "\(String(reflecting: $0.key)): \(String(reflecting: $0.value))"
}.joined(separator: ", ")
let runtimeTypeAliasesLiteral = foundationRuntimeAliasMap.sorted(by: {
    $0.key < $1.key
}).map { canonical, aliases in
    let values = aliases.map { String(reflecting: $0) }
        .joined(separator: ", ")
    return "\(String(reflecting: canonical)): [\(values)]"
}.joined(separator: ", ")
let propertyChunks = stride(from: 0, to: sortedProperties.count, by: chunkSize).map {
    Array(sortedProperties[$0..<min($0 + chunkSize, sortedProperties.count)])
}
let methodChunks = stride(from: 0, to: sortedMembers.count, by: chunkSize).map {
    Array(sortedMembers[$0..<min($0 + chunkSize, sortedMembers.count)])
}

var membersOutput = """
// GENERATED by BridgeGen from SDK swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sortedProperties.count) properties + \(sortedMembers.count) method variants across \(memberTypes.sorted().joined(separator: ", ")).
import Charts
import Foundation
import SwiftUI
import SwiftInterpreter

extension GeneratedMembers {
    static let concreteViewMethodKeys: Set<String> = [
        \(concreteViewMethodKeysLiteral)
    ]
    static let knownImportedNestedTypePaths: Set<String> = [
        \(knownImportedNestedTypePathsLiteral)
    ]
    static let runtimeNestedTypeNames: [String: String] = [\(nestedRuntimeNamesLiteral)]
    static let runtimeTypeAliasesByCanonicalName: [String: [String]] = [\(runtimeTypeAliasesLiteral)]

    static func buildProperties() -> [String: GeneratedMemberProperty] {
        var t: [String: GeneratedMemberProperty] = [:]

"""
for index in propertyChunks.indices {
    membersOutput += "        buildP\(index)(&t)\n"
}
membersOutput += "        return t\n    }\n"
membersOutput += "\n    static func buildMethods() -> [String: [GeneratedMemberOverload]] {\n"
membersOutput += "        var t: [String: [GeneratedMemberOverload]] = [:]\n\n"
for index in methodChunks.indices {
    membersOutput += "        buildM\(index)(&t)\n"
}
membersOutput += "        return t\n    }\n"

for (index, chunk) in propertyChunks.enumerated() {
    membersOutput += "\n    private static func buildP\(index)(_ t: inout [String: GeneratedMemberProperty]) {\n"
    for property in chunk {
        membersOutput += memberPropertyCode(property) + "\n"
    }
    membersOutput += "    }\n"
}
for (index, chunk) in methodChunks.enumerated() {
    membersOutput += "\n    private static func buildM\(index)(_ t: inout [String: [GeneratedMemberOverload]]) {\n"
    for variant in chunk {
        membersOutput += memberMethodCode(variant) + "\n"
    }
    membersOutput += "    }\n"
}
membersOutput += "}\n"

// Units table + generic-carrier constructors (swept above) join the same
// generated file: the Dimension statics serve Coerce.dimension, and the
// carrier constructors register by member-table key.
membersOutput += "\nextension GeneratedMembers {\n"
if unitStatics.isEmpty {
    membersOutput += "    static let dimensionStatics: [String: Dimension] = [:]\n\n"
} else {
    membersOutput += "    static let dimensionStatics: [String: Dimension] = [\n"
    for entry in unitStatics.sorted(by: { ($0.container, $0.name) < ($1.container, $1.name) }) {
        membersOutput += "        \"\(entry.container).\(entry.name)\": \(entry.container).\(entry.name),\n"
    }
    membersOutput += "    ]\n\n"
}
var bareNames: [String: [String]] = [:]
for entry in unitStatics {
    bareNames[entry.name, default: []].append(entry.container)
}
if bareNames.isEmpty {
    membersOutput += "    static let dimensionContainersByBareName: [String: [String]] = [:]\n\n"
} else {
    membersOutput += "    static let dimensionContainersByBareName: [String: [String]] = [\n"
    for (name, containers) in bareNames.sorted(by: { $0.key < $1.key }) {
        let list = containers.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        membersOutput += "        \"\(name)\": [\(list)],\n"
    }
    membersOutput += "    ]\n\n"
}
let unitClasses = Set(unitStatics.map(\.container)).sorted()
if !unitClasses.isEmpty {
    membersOutput += "    /// formatted() localizes THROUGH the concrete unit type (mph for\n"
    membersOutput += "    /// a US locale's km/h) — the erased carrier re-specializes over\n"
    membersOutput += "    /// every swept Dimension class before formatting.\n"
    membersOutput += "    static func measurementFormatted(_ m: Measurement<Dimension>) -> String {\n"
    membersOutput += "        switch m.unit {\n"
    for unitClass in unitClasses {
        membersOutput += "        case let unit as \(unitClass): return Measurement<\(unitClass)>(value: m.value, unit: unit).formatted()\n"
    }
    membersOutput += "        default: return m.formatted()\n"
    membersOutput += "        }\n"
    membersOutput += "    }\n\n"
}

if throwingConstructorContracts.isEmpty {
    membersOutput += "    static let throwingConstructorContracts: [String: [HostSignature]] = [:]\n\n"
} else {
    membersOutput += "    static let throwingConstructorContracts: [String: [HostSignature]] = [\n"
    for (typeName, declarations) in throwingConstructorContracts.sorted(
        by: { $0.key < $1.key }
    ) {
        membersOutput += "        \(String(reflecting: typeName)): [\n"
        for declaration in declarations.sorted() {
            membersOutput += "            parseConstructorContract(\(String(reflecting: declaration))),\n"
        }
        membersOutput += "        ],\n"
    }
    membersOutput += "    ]\n\n"
}

if nativeValueInits.isEmpty {
    membersOutput += "    static let nativeValueConstructors: [String: GeneratedConstructorSet] = [:]\n\n"
} else {
    membersOutput += "    /// Concrete value constructors selected transitively from throwing\n"
    membersOutput += "    /// initializer parameter types in Foundation.swiftinterface.\n"
    membersOutput += "    static let nativeValueConstructors: [String: GeneratedConstructorSet] = [\n"
    for (type, entries) in Dictionary(
        grouping: nativeValueInits, by: \.type
    ).sorted(by: { $0.key < $1.key }) {
        membersOutput += "        \(String(reflecting: type)): GeneratedConstructorSet([\n"
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            let specs = entry.params.map { parameter in
                let label = parameter.label.map(String.init(reflecting:))
                    ?? "nil"
                return "ParamSpec(\(label), .\(parameter.mapping!.tag))"
            }.joined(separator: ", ")
            let arguments = entry.params.enumerated().map {
                index, parameter -> String in
                let value = "("
                    + parameter.mapping!.cast.replacingOccurrences(
                        of: "%@", with: "values[\(index)]")
                    + ")"
                return (parameter.label.map { "\($0): " } ?? "") + value
            }.joined(separator: ", ")
            membersOutput += "            GeneratedConstructor(params: [\(specs)]) { values in\n"
            membersOutput += "                \(type)(\(arguments))\n"
            membersOutput += "            },\n"
        }
        membersOutput += "        ]),\n"
    }
    membersOutput += "    ]\n\n"
}

membersOutput += carrierInits.isEmpty
    ? "    @MainActor static let carrierConstructors: [String: HostFunction] = [:]\n"
    : "    @MainActor static let carrierConstructors: [String: HostFunction] = [\n"
for (type, inits) in Dictionary(grouping: carrierInits, by: \.type).sorted(by: { $0.key < $1.key }) {
    guard let carrier = genericStructCarriers[type]?.carrier else { continue }
    membersOutput += "        \"\(type)\": HostFunction(name: \"\(type)\") { args, ctx in\n"
    for (index, entry) in inits.enumerated() {
        let condition = entry.params
            .map { "args.labeled(\"\($0.label ?? "")\") != nil" }
            .joined(separator: " && ")
        let argList = entry.params
            .map { param -> String in
                let coerced = "try GeneratedDispatch.coerce(.\(param.mapping!.tag), args.labeled(\"\(param.label ?? "")\")!, ctx)"
                return "\(param.label!): " + param.mapping!.cast.replacingOccurrences(of: "%@", with: coerced)
            }
            .joined(separator: ", ")
        membersOutput += "            \(index == 0 ? "if" : "} else if") \(condition) {\n"
        membersOutput += "                return .native(\(carrier)(\(argList)))\n"
    }
    membersOutput += "            }\n"
    membersOutput += "            throw RuntimeError(message: \"\(type) argument shape not bridged\")\n"
    membersOutput += "        },\n"
}
if !carrierInits.isEmpty { membersOutput += "    ]\n" }
membersOutput += "}\n"

let attributedStringKeyRows = foundationAttributedStringKeySurface
    .keyTypeNames.map { typeName in
        "        \(String(reflecting: typeName)): \(typeName).self,"
    }.joined(separator: "\n")
membersOutput += """

// The key types and receiver conformances are derived from Foundation's
// AttributedStringKey constraints and generic metatype subscripts.
extension GeneratedMembers {
    static let attributedStringKeyTypes:
        [String: any AttributedStringKey.Type] = [
\(attributedStringKeyRows)
    ]

    static let attributedStringKeyTypeNames: [String] =
        attributedStringKeyTypes.keys.sorted()

    static let attributedStringKeySubscriptReceiverTypeNames: [String] =
        \(String(reflecting:
            foundationAttributedStringKeySurface.receiverTypeNames))
}
"""
for receiverType in foundationAttributedStringKeySurface.receiverTypeNames {
    membersOutput += """

extension \(receiverType): GeneratedMetatypeSubscriptCarrier {
    func generatedMetatypeSubscript(
        typeNamed typeName: String
    ) -> RuntimeValue? {
        guard let key = GeneratedMembers.attributedStringKeyTypes[typeName]
        else { return nil }
        return generatedMetatypeSubscript(key)
    }

    private func generatedMetatypeSubscript<Key: AttributedStringKey>(
        _ key: Key.Type
    ) -> RuntimeValue {
        .native(self[key])
    }
}
"""
}

let membersPath = "Sources/SwiftUIBridge/Generated/GeneratedMembers.swift"
try membersOutput.write(toFile: membersPath, atomically: true, encoding: .utf8)
print("wrote \(membersPath) (\(sortedProperties.count) properties, \(sortedMembers.count) method variants)")

let bufferRebindingEntries = generatedUnsafeMemorySurface
    .bufferRebindingMembers.map {
        "        \(String(reflecting: $0.name)): "
            + "\(String(reflecting: $0.metatypeLabel))"
    }.joined(separator: ",\n")
let bufferRebindingLiteral = bufferRebindingEntries.isEmpty
    ? "[:]"
    : "[\n\(bufferRebindingEntries),\n    ]"
let mutableBufferCallbackEntries = generatedUnsafeMemorySurface
    .mutableBufferCallbackMembers.map {
        "        \(String(reflecting: $0.name)): "
            + "\(String(reflecting: $0.argumentLabel))"
    }.joined(separator: ",\n")
let mutableBufferCallbackLiteral = mutableBufferCallbackEntries.isEmpty
    ? "[:]"
    : "[\n\(mutableBufferCallbackEntries),\n    ]"
let pointerBulkCopyEntries = generatedUnsafeMemorySurface
    .pointerBulkCopyMembers.map {
        "        \(String(reflecting: $0.name)): "
            + "(source: \(String(reflecting: $0.sourceLabel)), "
            + "count: \(String(reflecting: $0.countLabel)))"
    }.joined(separator: ",\n")
let pointerBulkCopyLiteral = pointerBulkCopyEntries.isEmpty
    ? "[:]"
    : "[\n\(pointerBulkCopyEntries),\n    ]"
let unsafeMemoryOutput = """
// GENERATED by BridgeGen from the active Swift standard-library swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
enum GeneratedUnsafeMemorySurface {
    static let pointerTypeNames: Set<String> = Set(\(String(reflecting:
        generatedUnsafeMemorySurface.pointerTypes)))
    static let rawPointerTypeNames: Set<String> = Set(\(String(reflecting:
        generatedUnsafeMemorySurface.rawPointerTypes)))
    static let bufferTypeNames: Set<String> = Set(\(String(reflecting:
        generatedUnsafeMemorySurface.bufferTypes)))
    static let bufferRebindingMetatypeLabels: [String: String] = \(bufferRebindingLiteral)
    static let mutableBufferCallbackArgumentLabels: [String: String] = \(mutableBufferCallbackLiteral)
    static let pointerBulkCopyArgumentLabels: [String: (source: String, count: String)] = \(pointerBulkCopyLiteral)

    static func isPointerType(_ name: String) -> Bool {
        pointerTypeNames.contains(canonicalTypeName(name))
    }

    static func isRawPointerType(_ name: String) -> Bool {
        rawPointerTypeNames.contains(canonicalTypeName(name))
    }

    static func isBufferType(_ name: String) -> Bool {
        bufferTypeNames.contains(canonicalTypeName(name))
    }

    static func bufferRebindingMetatypeLabel(for name: String) -> String? {
        bufferRebindingMetatypeLabels[name]
    }

    static func mutableBufferCallbackArgumentLabel(
        for name: String
    ) -> String? {
        mutableBufferCallbackArgumentLabels[name]
    }

    static func pointerBulkCopyLabels(
        for name: String
    ) -> (source: String, count: String)? {
        pointerBulkCopyArgumentLabels[name]
    }

    private static func canonicalTypeName(_ rawName: String) -> String {
        var name = rawName
        for prefix in ["Swift."] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name
    }
}
""" + "\n"
let unsafeMemoryPath =
    "Sources/SwiftInterpreter/Generated/GeneratedUnsafeMemorySurface.swift"
try unsafeMemoryOutput.write(
    toFile: unsafeMemoryPath, atomically: true, encoding: .utf8)
print("wrote \(unsafeMemoryPath) (\(generatedUnsafeMemorySurface.pointerTypes.count) pointer, \(generatedUnsafeMemorySurface.bufferTypes.count) buffer types, \(generatedUnsafeMemorySurface.mutableBufferCallbackMembers.count) mutable-buffer callbacks, \(generatedUnsafeMemorySurface.pointerBulkCopyMembers.count) pointer bulk copies)")

var unicodeDecodingOutput = """
// GENERATED by BridgeGen from the active Swift standard-library swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
enum GeneratedUnicodeDecodingSurface {
    struct Initializer {
        let codeUnitsLabel: String
        let encodingLabel: String
    }

    static func initializers(named rawName: String) -> [Initializer] {
        switch canonicalTypeName(rawName) {
""" + "\n"
for (typeName, initializers) in Dictionary(
    grouping: generatedUnicodeDecodingSurface.initializers,
    by: \.typeName
).sorted(by: { $0.key < $1.key }) {
    let values = initializers.sorted {
        ($0.codeUnitsLabel, $0.encodingLabel)
            < ($1.codeUnitsLabel, $1.encodingLabel)
    }.map {
        "Initializer(codeUnitsLabel: \(String(reflecting: $0.codeUnitsLabel)), "
            + "encodingLabel: \(String(reflecting: $0.encodingLabel)))"
    }.joined(separator: ", ")
    unicodeDecodingOutput += """
        case \(String(reflecting: typeName)):
            return [\(values)]
""" + "\n"
}
unicodeDecodingOutput += """
        default:
            return []
        }
    }

    static func decode(
        _ codeUnits: [UInt64],
        as rawEncodingTypeName: String
    ) -> String? {
        switch canonicalTypeName(rawEncodingTypeName) {
""" + "\n"
for encoding in generatedUnicodeDecodingSurface.encodings {
    let cases = encoding.sourceSpellings
        .map(String.init(reflecting:))
        .joined(separator: ", ")
    unicodeDecodingOutput += """
        case \(cases):
            return decode(codeUnits, as: \(encoding.typeName).self)
""" + "\n"
}
unicodeDecodingOutput += """
        default:
            return nil
        }
    }

    private static func decode<Encoding: _UnicodeEncoding>(
        _ codeUnits: [UInt64],
        as encoding: Encoding.Type
    ) -> String {
        String(
            decoding: codeUnits.map {
                Encoding.CodeUnit(truncatingIfNeeded: $0)
            },
            as: encoding)
    }

    private static func canonicalTypeName(_ rawName: String) -> String {
        var name = rawName
        if name.hasPrefix("Swift.") {
            name.removeFirst("Swift.".count)
        }
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name
    }
}
""" + "\n"
unicodeDecodingOutput += """

enum GeneratedUnicodeScalarSurface {
    enum InputKind {
        case integer
        case string
        case scalar
    }

    struct Initializer {
        let resultTypeName: String
        let parameterTypeName: String
        let label: String?
        let inputKind: InputKind
        let isFailable: Bool
    }

    static func initializers(named rawName: String) -> [Initializer] {
        switch canonicalTypeName(rawName) {
""" + "\n"
for scalar in generatedUnicodeDecodingSurface.scalars {
    let cases = scalar.sourceSpellings
        .map(String.init(reflecting:))
        .joined(separator: ", ")
    let initializers = scalar.initializers.map { initializer in
        let label = initializer.label.map(String.init(reflecting:)) ?? "nil"
        return """
                Initializer(
                    resultTypeName: \(String(reflecting: scalar.typeName)),
                    parameterTypeName: \(String(reflecting: initializer.parameterTypeName)),
                    label: \(label),
                    inputKind: .\(initializer.inputKind.rawValue),
                    isFailable: \(initializer.isFailable))
        """
    }.joined(separator: ",\n")
    unicodeDecodingOutput += """
        case \(cases):
            return [
\(initializers)
            ]
""" + "\n"
}
unicodeDecodingOutput += """
        default:
            return []
        }
    }

    static func representsScalarType(named rawName: String) -> Bool {
        !initializers(named: rawName).isEmpty
    }

    private static func canonicalTypeName(_ rawName: String) -> String {
        var name = rawName
        if name.hasPrefix("Swift.") {
            name.removeFirst("Swift.".count)
        }
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name
    }
}
""" + "\n"
let unicodeDecodingPath =
    "Sources/SwiftInterpreter/Generated/GeneratedUnicodeDecodingSurface.swift"
try unicodeDecodingOutput.write(
    toFile: unicodeDecodingPath, atomically: true, encoding: .utf8)
print(
    "wrote \(unicodeDecodingPath) "
        + "(\(generatedUnicodeDecodingSurface.initializers.count) initializers, "
        + "\(generatedUnicodeDecodingSurface.encodings.count) encodings, "
        + "\(generatedUnicodeDecodingSurface.scalars.count) scalar types)")

var generatedCollectionPropertyProtocols: [String: Set<String>] = [:]
for property in generatedBooleanIndexEndpointEqualityCollectionDefaults {
    generatedCollectionPropertyProtocols[property.memberName, default: []]
        .formUnion(property.eligibleProtocolNames)
}
for property in generatedOptionalElementCollectionDefaults {
    generatedCollectionPropertyProtocols[property.memberName, default: []]
        .formUnion(property.eligibleProtocolNames)
}
let generatedCollectionPropertyProtocolRows =
    generatedCollectionPropertyProtocols.sorted { $0.key < $1.key }.map {
        memberName, protocolNames in
        "        \(String(reflecting: memberName)): Set(["
            + protocolNames.sorted().map(String.init(reflecting:))
                .joined(separator: ", ")
            + "]),"
    }.joined(separator: "\n")

var collectionDefaultsOutput = """
// GENERATED by BridgeGen from the active Swift standard-library swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
enum GeneratedCollectionDefaultSurface {
    private static let elementGenericCollectionNominalNames: Set<String> = Set([
        \(generatedElementGenericCollectionNominals
            .map(String.init(reflecting:)).joined(separator: ", "))
    ])

    static func usesElementGenericParameter(
        nominalName: String
    ) -> Bool {
        elementGenericCollectionNominalNames.contains(nominalName)
    }

    private static let materializableSequenceProtocolNames: Set<String> = Set([
        \(generatedMaterializableSequenceProtocolNames
            .map(String.init(reflecting:)).joined(separator: ", "))
    ])

    static func isMaterializableSequenceProtocol(
        named rawName: String
    ) -> Bool {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["any ", "some "] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            name = name.trimmingCharacters(in: .whitespaces)
        }
        if name.hasPrefix("Swift.") {
            name.removeFirst("Swift.".count)
        }
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return materializableSequenceProtocolNames.contains(name)
    }
""" + "\n"
collectionDefaultsOutput += """

    static let repeatedElementSequenceFactoryNames: Set<String> = Set([
        \(generatedRepeatedElementSequenceFactories
            .map(\.functionName).map(String.init(reflecting:))
            .joined(separator: ", "))
    ])

    @MainActor
    static func repeatedElementSequenceFactory(
        named name: String
    ) -> HostFunction? {
        switch name {
""" + "\n"
for factory in generatedRepeatedElementSequenceFactories {
    let elementArgument = factory.elementArgumentLabel.map {
        "args.labeled(\(String(reflecting: $0)))"
    } ?? "args.positional(0)"
    let countArgument = factory.countArgumentLabel.map {
        "args.labeled(\(String(reflecting: $0)))"
    } ?? "args.positional(1)"
    collectionDefaultsOutput += """
        case \(String(reflecting: factory.functionName)):
            return HostFunction(name: name) { args, _ in
                guard args.arguments.count == 2,
                      let element = \(elementArgument),
                      let count = \(countArgument)?.intValue,
                      count >= 0 else {
                    throw RuntimeError(
                        message: "generated repeated-element sequence argument mismatch")
                }
                return .native(
                    [RuntimeValue](repeating: element, count: count))
            }
""" + "\n"
}
collectionDefaultsOutput += """
        default:
            return nil
        }
    }
""" + "\n"
collectionDefaultsOutput += """

    @MainActor
    static func nativeWritableStringCollectionView(
        named name: String,
        on owner: String
    ) -> RuntimeValue? {
        switch name {
""" + "\n"
for view in generatedNativeWritableStringCollectionViews {
    collectionDefaultsOutput += """
        case \(String(reflecting: view.propertyName)):
            return .native(owner.\(view.propertyName).map {
                RuntimeValue.native(String($0))
            })
""" + "\n"
}
collectionDefaultsOutput += """
        default:
            return nil
        }
    }

    private static let nativeWritableStringCollectionViewNames: Set<String> =
        Set([\(generatedNativeWritableStringCollectionViews
            .map(\.propertyName).map(String.init(reflecting:))
            .joined(separator: ", "))])

    static func isNativeWritableStringCollectionView(
        named name: String
    ) -> Bool {
        nativeWritableStringCollectionViewNames.contains(name)
    }

    @MainActor
    static func replacingNativeWritableStringCollectionView(
        named name: String,
        in owner: String,
        with replacement: RuntimeValue
    ) throws -> String? {
        switch name {
""" + "\n"
for view in generatedNativeWritableStringCollectionViews {
    collectionDefaultsOutput += """
        case \(String(reflecting: view.propertyName)):
            guard let elements = replacement.arrayValue else {
                throw RuntimeError(
                    message: "generated writable String collection view needs an array")
            }
            var projected = ""
            for element in elements {
                guard let fragment = element.stringValue,
                      fragment.\(view.propertyName).count == 1 else {
                    throw RuntimeError(
                        message: "generated writable String collection view element mismatch")
                }
                projected += fragment
            }
            var result = owner
            result.\(view.propertyName) = projected.\(view.propertyName)
            return result
""" + "\n"
}
collectionDefaultsOutput += """
        default:
            return nil
        }
    }

    private static let propertyProtocols: [String: Set<String>] = [
\(generatedCollectionPropertyProtocolRows)
    ]

    static func suppliesProperty(
        named name: String,
        conformances: Set<String>
    ) -> Bool {
        guard let eligible = propertyProtocols[name] else { return false }
        return !conformances.isDisjoint(with: eligible)
    }

    @MainActor
    static func member(
        named name: String,
        conformances: Set<String>
    ) -> HostFunction? {
""" + "\n"
for (memberName, defaults) in Dictionary(
    grouping: generatedIntegerIndexCollectionDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    let protocols = Set(defaults.flatMap(\.eligibleProtocolNames)).sorted()
        .map(String.init(reflecting:))
        .joined(separator: ", ")
    collectionDefaultsOutput += """
        if name == \(String(reflecting: memberName)),
           !conformances.isDisjoint(with: Set([\(protocols)])) {
            return HostFunction(name: name) { args, _ in
""" + "\n"
    for rule in defaults {
        let argument = rule.argumentLabel.map {
            "args.labeled(\(String(reflecting: $0)))"
        } ?? "args.positional(0)"
        let operationArgument = rule.indexOperationLabel.map {
            "\($0): \(rule.distance)"
        } ?? String(rule.distance)
        collectionDefaultsOutput += """
                if !conformances.isDisjoint(with: Set([\(
                    rule.eligibleProtocolNames.sorted()
                        .map(String.init(reflecting:))
                        .joined(separator: ", "))])),
                   args.arguments.count == 1,
                   let index = \(argument)?.intValue {
                    return .native(index.\(rule.indexOperationName)(
                        \(operationArgument)))
                }
""" + "\n"
    }
    for rule in generatedNativeIndexMotionDefaults
    where rule.memberName == memberName {
        var eligibleProtocols = Set(defaults.flatMap(
            \.eligibleProtocolNames
        )).intersection(rule.eligibleProtocolNames)
        for direct in defaults
        where rule.argumentLabels == [direct.argumentLabel] {
            eligibleProtocols.subtract(direct.eligibleProtocolNames)
        }
        guard !eligibleProtocols.isEmpty else { continue }
        let eligibility = eligibleProtocols.sorted()
            .map(String.init(reflecting:))
            .joined(separator: ", ")
        let arguments = rule.argumentLabels.enumerated().map {
            index, label in
            label.map {
                "args.labeled(\(String(reflecting: $0)))"
            } ?? "args.positional(\(index))"
        }
        switch rule.kind {
        case .successor, .predecessor:
            let distance = rule.kind == .successor ? 1 : -1
            collectionDefaultsOutput += """
                if !conformances.isDisjoint(with: Set([\(eligibility)])),
                   args.arguments.count == 1,
                   let index = \(arguments[0])?.intValue {
                    return .native(index + \(distance))
                }
""" + "\n"
        case .offset:
            collectionDefaultsOutput += """
                if !conformances.isDisjoint(with: Set([\(eligibility)])),
                   args.arguments.count == 2,
                   let index = \(arguments[0])?.intValue,
                   let distance = \(arguments[1])?.intValue {
                    return .native(index + distance)
                }
""" + "\n"
        case .limitedOffset:
            collectionDefaultsOutput += """
                if !conformances.isDisjoint(with: Set([\(eligibility)])),
                   args.arguments.count == 3,
                   let index = \(arguments[0])?.intValue,
                   let distance = \(arguments[1])?.intValue,
                   let limit = \(arguments[2])?.intValue {
                    return limitedIntegerIndex(
                        from: index, by: distance, limitedBy: limit)
                }
""" + "\n"
        }
    }
    collectionDefaultsOutput += """
                throw RuntimeError(
                    message: "generated collection default argument mismatch")
            }
        }
""" + "\n"
}
collectionDefaultsOutput += """
        return nil
    }

    @MainActor
    private static func limitedIntegerIndex(
        from index: Int,
        by distance: Int,
        limitedBy limit: Int
    ) -> RuntimeValue {
        let delta = limit - index
        let crossesLimit = distance > 0
            ? delta >= 0 && delta < distance
            : delta <= 0 && distance < delta
        guard !crossesLimit else {
            return .none(wrappedTypeName: "Int")
        }
        return .some(
            .native(index + distance), wrappedTypeName: "Int")
    }

    @MainActor
    static func nativeIndexMotionMember(
        named name: String,
        receiver: RuntimeValue
    ) -> HostFunction? {
""" + "\n"
for (memberName, defaults) in Dictionary(
    grouping: generatedNativeIndexMotionDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    collectionDefaultsOutput += """
        if name == \(String(reflecting: memberName)) {
            return HostFunction(name: name) { args, _ in
""" + "\n"
    for rule in defaults {
        let arguments = rule.argumentLabels.enumerated().map {
            index, label in
            label.map {
                "args.labeled(\(String(reflecting: $0)))"
            } ?? "args.positional(\(index))"
        }
        switch rule.kind {
        case .successor, .predecessor:
            let distance = rule.kind == .successor ? 1 : -1
            collectionDefaultsOutput += """
                if args.arguments.count == 1,
                   let index = \(arguments[0]) {
                    return try moveNativeIndex(
                        in: receiver, from: index, by: \(distance))
                }
""" + "\n"
        case .offset:
            collectionDefaultsOutput += """
                if args.arguments.count == 2,
                   let index = \(arguments[0]),
                   let distance = \(arguments[1])?.intValue {
                    return try moveNativeIndex(
                        in: receiver, from: index, by: distance)
                }
""" + "\n"
        case .limitedOffset:
            collectionDefaultsOutput += """
                if args.arguments.count == 3,
                   let index = \(arguments[0]),
                   let distance = \(arguments[1])?.intValue,
                   let limit = \(arguments[2]) {
                    return try limitedNativeIndex(
                        in: receiver, from: index,
                        by: distance, limitedBy: limit)
                }
""" + "\n"
        }
    }
    collectionDefaultsOutput += """
                throw RuntimeError(
                    message: "generated native index motion argument mismatch")
            }
        }
""" + "\n"
}
collectionDefaultsOutput += """
        return nil
    }

    @MainActor
    private static func moveNativeIndex(
        in receiver: RuntimeValue,
        from indexValue: RuntimeValue,
        by distance: Int
    ) throws -> RuntimeValue {
        // `substringValue`, not `stringValue`: a member whose RESULT is an
        // index has to speak the receiver's own index space, and a slice
        // shares its base's. Reading the text as a fresh String re-bases it.
        if let string = receiver.substringValue {
            guard case .host(let payload) = indexValue,
                  let index = payload as? String.Index else {
                throw RuntimeError(
                    message: "generated string index motion needs String.Index")
            }
            let limit = distance >= 0 ? string.endIndex : string.startIndex
            guard let moved = string.index(
                index, offsetBy: distance, limitedBy: limit) else {
                throw RuntimeError(
                    message: "generated string index motion is out of bounds")
            }
            return .native(moved)
        }
        if receiver.arraySliceValue != nil,
           let index = indexValue.intValue {
            return .native(index + distance)
        }
        throw RuntimeError(
            message: "generated native index motion needs an indexed carrier")
    }

    @MainActor
    private static func limitedNativeIndex(
        in receiver: RuntimeValue,
        from indexValue: RuntimeValue,
        by distance: Int,
        limitedBy limitValue: RuntimeValue
    ) throws -> RuntimeValue {
        if let string = receiver.substringValue {
            guard case .host(let indexPayload) = indexValue,
                  let index = indexPayload as? String.Index,
                  case .host(let limitPayload) = limitValue,
                  let limit = limitPayload as? String.Index else {
                throw RuntimeError(
                    message: "generated limited string motion needs String.Index")
            }
            guard let moved = string.index(
                index, offsetBy: distance, limitedBy: limit) else {
                return .none(wrappedTypeName: "String.Index")
            }
            return .some(
                .native(moved), wrappedTypeName: "String.Index")
        }
        if receiver.arraySliceValue != nil,
           let index = indexValue.intValue,
           let limit = limitValue.intValue {
            let delta = limit - index
            let crossesLimit = distance > 0
                ? delta >= 0 && delta < distance
                : delta <= 0 && distance < delta
            guard !crossesLimit else {
                return .none(wrappedTypeName: "Int")
            }
            return .some(
                .native(index + distance), wrappedTypeName: "Int")
        }
        throw RuntimeError(
            message: "generated limited index motion needs an indexed carrier")
    }

    private enum NativeIndexSearchDirection {
        case forward
        case backward
    }

    @MainActor
    static func nativeIndexSearchMember(
        named name: String,
        receiver: RuntimeValue
    ) -> HostFunction? {
""" + "\n"

for (memberName, defaults) in Dictionary(
    grouping: generatedIndexSearchDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    collectionDefaultsOutput += """
        if name == \(String(reflecting: memberName)) {
            return HostFunction(name: name) { args, context in
""" + "\n"
    for rule in defaults {
        switch rule.argumentKind {
        case .element:
            let argument = rule.argumentLabel.map {
                "args.labeled(\(String(reflecting: $0)))"
            } ?? "args.positional(0)"
            collectionDefaultsOutput += """
                if args.arguments.count == 1,
                   let target = \(argument) {
                    return try firstNativeIndex(
                        in: receiver,
                        direction: .\(rule.direction.rawValue),
                        where: { try Builtins.areEqual($0, target) })
                }
""" + "\n"
        case .predicate:
            let labeledClosure = rule.argumentLabel.map {
                "args.closure(labeled: \(String(reflecting: $0)))"
            } ?? "nil"
            collectionDefaultsOutput += """
                if args.arguments.count == 1,
                   let predicate = \(labeledClosure)
                    ?? args.firstUnlabeledClosure
                    ?? args.positional(0)?.closureValue {
                    return try firstNativeIndex(
                        in: receiver,
                        direction: .\(rule.direction.rawValue),
                        where: {
                            try context.callClosure(
                                predicate, arguments: [$0]).boolValue == true
                        })
                }
""" + "\n"
        }
    }
    collectionDefaultsOutput += """
                throw RuntimeError(
                    message: "generated index search argument mismatch")
            }
        }
""" + "\n"
}
collectionDefaultsOutput += """
        return nil
    }

    @MainActor
    private static func firstNativeIndex(
        in receiver: RuntimeValue,
        direction: NativeIndexSearchDirection,
        where matches: (RuntimeValue) throws -> Bool
    ) throws -> RuntimeValue {
        if let string = receiver.substringValue {
            switch direction {
            case .forward:
                var index = string.startIndex
                while index != string.endIndex {
                    if try matches(.native(String(string[index]))) {
                        return .some(
                            .native(index), wrappedTypeName: "String.Index")
                    }
                    string.formIndex(after: &index)
                }
            case .backward:
                var index = string.endIndex
                while index != string.startIndex {
                    string.formIndex(before: &index)
                    if try matches(.native(String(string[index]))) {
                        return .some(
                            .native(index), wrappedTypeName: "String.Index")
                    }
                }
            }
            return .none(wrappedTypeName: "String.Index")
        }
        if let array = receiver.arraySliceValue {
            // `arraySliceValue`: a search RETURNS an index, so it has to be
            // an index into the base the receiver came from.
            let indices: AnySequence<Int> = switch direction {
            case .forward: AnySequence(array.indices)
            case .backward: AnySequence(array.indices.reversed())
            }
            for index in indices where try matches(array[index]) {
                return .some(
                    .native(index), wrappedTypeName: "Int")
            }
            return .none(wrappedTypeName: "Int")
        }
        throw RuntimeError(
            message: "generated index search needs an indexed carrier")
    }

    @MainActor
    static func property(
        named name: String,
        conformances: Set<String>,
        receiver: RuntimeValue,
        interpreter: Interpreter
    ) throws -> RuntimeValue? {
""" + "\n"
for (memberName, defaults) in Dictionary(
    grouping: generatedBooleanIndexEndpointEqualityCollectionDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    collectionDefaultsOutput += """
        if name == \(String(reflecting: memberName)) {
""" + "\n"
    for rule in defaults {
        let protocols = rule.eligibleProtocolNames.sorted()
            .map(String.init(reflecting:))
            .joined(separator: ", ")
        collectionDefaultsOutput += """
            if !conformances.isDisjoint(with: Set([\(protocols)])),
               let endpointsEqual = try interpreter
                .interpretedIntegerIndexedCollectionEndpointsAreEqual(
                    receiver,
                    leftMemberName: \(String(reflecting: rule.leftEndpointName)),
                    rightMemberName: \(String(reflecting: rule.rightEndpointName))) {
                return .native(endpointsEqual)
            }
""" + "\n"
    }
    collectionDefaultsOutput += """
        }
""" + "\n"
}
for (memberName, defaults) in Dictionary(
    grouping: generatedOptionalElementCollectionDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    let projections = Set(defaults.map(\.projection))
    precondition(
        projections.count == 1,
        "one collection member cannot project both endpoints")
    let projection = projections.first!.rawValue
    let protocols = Set(defaults.flatMap(\.eligibleProtocolNames)).sorted()
        .map(String.init(reflecting:))
        .joined(separator: ", ")
    collectionDefaultsOutput += """
        if name == \(String(reflecting: memberName)),
           !conformances.isDisjoint(with: Set([\(protocols)])),
           let elements = try interpreter
            .interpretedIntegerIndexedCollectionElements(receiver) {
            guard let element = elements.\(projection) else { return .none() }
            return element.liftedToOptional()
        }
""" + "\n"
}
collectionDefaultsOutput += """
        return nil
    }

    static let optionalLastRemovalProtocols: [String: Set<String>] = [
""" + "\n"
for (memberName, defaults) in Dictionary(
    grouping: generatedOptionalLastRemovalCollectionDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    let protocols = Set(defaults.flatMap(\.eligibleProtocolNames)).sorted()
        .map(String.init(reflecting:))
        .joined(separator: ", ")
    collectionDefaultsOutput += """
        \(String(reflecting: memberName)): Set([\(protocols)]),
""" + "\n"
}
collectionDefaultsOutput += """
    ]

    static func optionallyRemovesLast(named memberName: String) -> Bool {
        optionalLastRemovalProtocols[memberName] != nil
    }

    enum NativeCollectionEndpoint {
        case first
        case last
    }

    private static let requiredEndpointRemovals:
        [String: NativeCollectionEndpoint] = [
""" + "\n"
for (memberName, defaults) in Dictionary(
    grouping: generatedRequiredEndpointRemovalCollectionDefaults,
    by: \.memberName
).sorted(by: { $0.key < $1.key }) {
    let endpoints = Set(defaults.map(\.endpoint))
    precondition(
        endpoints.count == 1,
        "one required collection removal cannot target both endpoints")
    collectionDefaultsOutput += """
        \(String(reflecting: memberName)): .\(endpoints.first!.rawValue),
""" + "\n"
}
collectionDefaultsOutput += """
    ]

    static func requiredEndpointRemoval(
        named memberName: String
    ) -> NativeCollectionEndpoint? {
        requiredEndpointRemovals[memberName]
    }

    enum NativeCarrierKind {
        case array
        case dictionary
        case set
    }

    private static let nativeCarrierScalarVoidMutationNames:
        [NativeCarrierKind: Set<String>] = [
""" + "\n"
for carrierKind in NativeCollectionCarrierKind.allCases {
    let names = Set(generatedNativeCollectionCarrierScalarVoidMutations
        .filter { $0.carrierKind == carrierKind }
        .map(\.memberName))
        .sorted()
        .map(String.init(reflecting:))
        .joined(separator: ", ")
    collectionDefaultsOutput += """
        .\(carrierKind.rawValue): Set([\(names)]),
""" + "\n"
}
collectionDefaultsOutput += """
    ]

    static func isNativeCarrierScalarVoidMutation(
        named memberName: String,
        carrierKind: NativeCarrierKind
    ) -> Bool {
        nativeCarrierScalarVoidMutationNames[carrierKind]?
            .contains(memberName) == true
    }
""" + "\n"
let nativeDictionaryKeyOptionalValueMutationNames =
    generatedNativeDictionaryKeyOptionalValueMutations
        .map(\.memberName).sorted()
        .map(String.init(reflecting:))
        .joined(separator: ", ")
collectionDefaultsOutput += """

    private static let nativeDictionaryKeyOptionalValueMutationNames:
        Set<String> = Set([\(nativeDictionaryKeyOptionalValueMutationNames)])

    static func isNativeDictionaryKeyOptionalValueMutation(
        named memberName: String
    ) -> Bool {
        nativeDictionaryKeyOptionalValueMutationNames.contains(memberName)
    }

    @MainActor
    static func invokeNativeDictionaryKeyOptionalValueMutation(
        named name: String,
        arguments: CallArguments,
        carrier: inout DictValue,
        interpreter: Interpreter
    ) throws -> RuntimeValue {
""" + "\n"
for mutation in generatedNativeDictionaryKeyOptionalValueMutations {
    let argument = mutation.argumentLabel.map {
        "arguments.labeled(\(String(reflecting: $0)))"
    } ?? "arguments.positional(0)"
    collectionDefaultsOutput += """
        if name == \(String(reflecting: mutation.memberName)),
           arguments.arguments.count == 1,
           let key = \(argument) {
            return .optional(try carrier.removeEntry(
                forKey: key,
                by: interpreter.collectionStorageValuesAreEqual))
        }
""" + "\n"
}
collectionDefaultsOutput += """
        throw RuntimeError(
            message: "generated native dictionary key mutation argument mismatch")
    }
""" + "\n"
for carrierKind in NativeCollectionCarrierKind.allCases {
    let carrierType: String
    switch carrierKind {
    case .array: carrierType = "[RuntimeValue]"
    case .dictionary: carrierType = "DictValue"
    case .set: carrierType = "RuntimeSetValue"
    }
    collectionDefaultsOutput += """

    @MainActor
    static func invokeNativeCarrierScalarVoidMutation(
        named name: String,
        arguments: CallArguments,
        carrier: inout \(carrierType)
    ) throws -> Bool {
""" + "\n"
    for mutation in generatedNativeCollectionCarrierScalarVoidMutations
    where mutation.carrierKind == carrierKind {
        let argument = mutation.argumentLabel.map {
            "arguments.labeled(\(String(reflecting: $0)))"
        } ?? "arguments.positional(0)"
        let valueProjection = switch mutation.argumentKind {
        case .integer: "intValue"
        case .boolean: "boolValue"
        }
        let invocationArgument = mutation.argumentLabel.map {
            "\($0): value"
        } ?? "value"
        func appendInvocation(
            condition: String,
            defaultLiteral: String? = nil
        ) {
            collectionDefaultsOutput += "        if \(condition) {\n"
            if let defaultLiteral {
                collectionDefaultsOutput +=
                    "            let value = \(defaultLiteral)\n"
            }
            switch carrierKind {
            case .array:
                collectionDefaultsOutput += """
            carrier.\(mutation.memberName)(\(invocationArgument))
""" + "\n"
            case .dictionary:
                collectionDefaultsOutput += """
            carrier.withMutableStorage { keys, values in
                keys.\(mutation.memberName)(\(invocationArgument))
                values.\(mutation.memberName)(\(invocationArgument))
            }
""" + "\n"
            case .set:
                collectionDefaultsOutput += """
            carrier.withMutableElements { elements in
                elements.\(mutation.memberName)(\(invocationArgument))
            }
""" + "\n"
            }
            collectionDefaultsOutput += """
            return true
        }
""" + "\n"
        }

        appendInvocation(condition:
            "name == \(String(reflecting: mutation.memberName)), "
                + "arguments.arguments.count == 1, "
                + "let value = \(argument)?.\(valueProjection)")
        let defaultLiteral: String? = switch mutation.defaultValue {
        case .integer(let value): String(value)
        case .boolean(let value): String(value)
        case nil: nil
        }
        if let defaultLiteral {
            appendInvocation(
                condition:
                    "name == \(String(reflecting: mutation.memberName)), "
                        + "arguments.arguments.isEmpty",
                defaultLiteral: defaultLiteral)
        }
    }
    collectionDefaultsOutput += """
        if nativeCarrierScalarVoidMutationNames[.\(carrierKind.rawValue)]?
            .contains(name) == true {
            throw RuntimeError(
                message: "generated native \(carrierKind.rawValue) mutation argument mismatch")
        }
        return false
    }
""" + "\n"
}
collectionDefaultsOutput += """
}
""" + "\n"
let collectionDefaultsPath =
    "Sources/SwiftInterpreter/Generated/GeneratedCollectionDefaultSurface.swift"
try collectionDefaultsOutput.write(
    toFile: collectionDefaultsPath, atomically: true, encoding: .utf8)
print(
    "wrote \(collectionDefaultsPath) "
        + "(\(generatedIntegerIndexCollectionDefaults.count) methods, "
        + "\(generatedNativeIndexMotionDefaults.count) native index motions, "
        + "\(generatedIndexSearchDefaults.count) index searches, "
        + "\(generatedBooleanIndexEndpointEqualityCollectionDefaults.count) Boolean endpoint properties, "
        + "\(generatedOptionalElementCollectionDefaults.count) properties, "
        + "\(generatedOptionalLastRemovalCollectionDefaults.count) optional removals, "
        + "\(generatedRequiredEndpointRemovalCollectionDefaults.count) required endpoint removals, "
        + "\(generatedElementGenericCollectionNominals.count) element-generic collections, "
        + "\(generatedMaterializableSequenceProtocolNames.count) Sequence protocols, "
        + "\(generatedRepeatedElementSequenceFactories.count) repeated-element factories, "
        + "\(generatedNativeWritableStringCollectionViews.count) writable String collection views, "
        + "\(generatedNativeCollectionCarrierScalarVoidMutations.count) native carrier scalar mutations, "
        + "\(generatedNativeDictionaryKeyOptionalValueMutations.count) dictionary key mutations)")

let generatedCaseTransformCases = Dictionary(
    grouping: generatedCaseTransformOperations,
    by: \.nominalName
).mapValues { operations in
    Set(operations.map(\.selectedCaseName)).sorted()
}
let caseTransformOutput = """
// GENERATED by BridgeGen from the active Swift standard-library swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
enum GeneratedCaseTransformApplication: Sendable {
    case payload
    case carrier
}

struct GeneratedCaseTransformOperation: Sendable {
    let selectedCaseName: String
    let argumentLabel: String?
    let application: GeneratedCaseTransformApplication
}

enum GeneratedCaseTransformSurface {
    static func operation(
        nominalName rawNominalName: String,
        memberName: String
    ) -> GeneratedCaseTransformOperation? {
        let nominalName = canonicalNominalName(rawNominalName)
        switch (nominalName, memberName) {
\(generatedCaseTransformOperations.map { operation in
    let label = operation.argumentLabel.map(String.init(reflecting:))
        ?? "nil"
    return """
        case (\(String(reflecting: operation.nominalName)), \
\(String(reflecting: operation.memberName))):
            return GeneratedCaseTransformOperation(
                selectedCaseName: \
\(String(reflecting: operation.selectedCaseName)),
                argumentLabel: \(label),
                application: .\(operation.application.rawValue))
"""
}.joined(separator: "\n"))
        default:
            return nil
        }
    }

    static func containsCase(
        _ caseName: String,
        nominalName rawNominalName: String
    ) -> Bool {
        let nominalName = canonicalNominalName(rawNominalName)
        switch nominalName {
\(generatedCaseTransformCases.sorted(by: { $0.key < $1.key }).map {
    nominalName, caseNames in
    """
        case \(String(reflecting: nominalName)):
            return Set([\(caseNames.map(String.init(reflecting:))
                .joined(separator: ", "))]).contains(caseName)
"""
}.joined(separator: "\n"))
        default:
            return false
        }
    }

    private static func canonicalNominalName(_ rawName: String) -> String {
        var name = rawName.filter { !$0.isWhitespace }
        if let generic = name.firstIndex(of: "<") {
            name = String(name[..<generic])
        }
        return name.split(separator: ".").last.map(String.init) ?? name
    }
}
""" + "\n"
let caseTransformPath =
    "Sources/SwiftInterpreter/Generated/GeneratedCaseTransformSurface.swift"
try caseTransformOutput.write(
    toFile: caseTransformPath, atomically: true, encoding: .utf8)
print(
    "wrote \(caseTransformPath) "
        + "(\(generatedCaseTransformOperations.count) case transforms)")

let rangeRemovalMembers = Dictionary(
    grouping: generatedRangeRemovalMutations,
    by: \.memberName
).mapValues { mutations in
    mutations.map(\.protocolName).sorted()
}
let rangeRemovalEntries = rangeRemovalMembers.sorted(by: {
    $0.key < $1.key
}).map { memberName, protocols in
    "\(String(reflecting: memberName)): Set(\(String(reflecting: protocols)))"
}.joined(separator: ", ")
let rangeMutationOutput = """
// GENERATED by BridgeGen from the active Swift standard-library swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
enum GeneratedRangeMutationSurface {
    static let rangeRemovalProtocols: [String: Set<String>] = [
        \(rangeRemovalEntries)
    ]

    static func removesRange(named memberName: String) -> Bool {
        rangeRemovalProtocols[memberName] != nil
    }
}
""" + "\n"
let rangeMutationPath =
    "Sources/SwiftInterpreter/Generated/GeneratedRangeMutationSurface.swift"
try rangeMutationOutput.write(
    toFile: rangeMutationPath, atomically: true, encoding: .utf8)
print(
    "wrote \(rangeMutationPath) "
        + "(\(generatedRangeRemovalMutations.count) range removals)")

let cMemoryPath =
    "Sources/SwiftUIBridge/Generated/GeneratedCMemoryBridge.swift"
try cMemoryGeneration.output.write(
    toFile: cMemoryPath, atomically: true, encoding: .utf8)
print(
    "wrote \(cMemoryPath) (\(cMemoryGeneration.functionNames.count) C functions, "
        + "\(cMemoryGeneration.recordNames.count) writable records)")

let platformPath = "Sources/SwiftUIBridge/Generated/GeneratedPlatformBridge.swift"
try platformGeneration.output.write(
    toFile: platformPath, atomically: true, encoding: .utf8)
print("wrote \(platformPath)")

let propertyWrappersOutput = """
// GENERATED by BridgeGen from the SDK's SwiftUICore/SwiftUI swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(frameworkSuppliedWrappers.count) framework-supplied property wrappers.
import SwiftUI
import SwiftInterpreter

extension GeneratedPropertyWrappers {
    /// A wrapper the declaration passes nothing to: the interface gives it a
    /// no-argument init and a get-only `wrappedValue`, so constructing it IS
    /// the whole story and its value is whatever the framework hands back.
    static func build() -> [String: @MainActor () -> Any] {
        [
\(frameworkSuppliedWrappers.map {
    "            // \($0.name).wrappedValue: \($0.valueType)\n"
        + "            \(String(reflecting: $0.name)): "
        + "{ \($0.name)().wrappedValue },"
}.joined(separator: "\n"))
        ]
    }
}

"""
// One carrier pair per wrapper whose projection the interface leaves
// uninitializable. The body is the same in every case because the gap is the
// same in every case: declare the real wrapper, hand the modifier the
// projection SwiftUI made, and keep the interpreted binding and the wrapper's
// value in step both ways. Nothing here is written per wrapper by hand, so a
// wrapper the SDK adds later is carried the moment the scan sees it.
func wrapperProjectionCarrierSource(
    wrapper: String, isOptionalValue: Bool
) -> String {
    let carrier = generatedWrapperProjectionCarrierName(
        wrapper: wrapper, isOptionalValue: isOptionalValue)
    let generics = isOptionalValue
        ? "<Value: Hashable, Content: View>" : "<Content: View>"
    let stored = isOptionalValue ? "Value?" : "Bool"
    return """
    /// Bridges an ordinary interpreted binding to `\(wrapper)`'s projection,
    /// which the interface declares with no initializer any caller can reach.
    struct \(carrier)\(generics): View {
        @\(wrapper) private var focus: \(stored)
        let binding: Binding<\(stored)>
        let content: (\(wrapper)<\(stored)>.Binding) -> Content

        var body: some View {
            content($focus)
                .onAppear { focus = binding.wrappedValue }
                .onChange(of: binding.wrappedValue) { _, new in
                    guard focus != new else { return }
                    focus = new
                }
                .onChange(of: focus) { _, new in
                    guard binding.wrappedValue != new else { return }
                    binding.wrappedValue = new
                }
        }
    }
    """
}

let wrapperProjectionCarrierSources = wrapperProjectionWrappers
    .sorted { $0.key < $1.key }
    .flatMap { _, projection -> [String] in
        var sources: [String] = []
        if projection.hasBoolValue {
            sources.append(wrapperProjectionCarrierSource(
                wrapper: projection.wrapper, isOptionalValue: false))
        }
        if projection.hasOptionalHashableValue {
            sources.append(wrapperProjectionCarrierSource(
                wrapper: projection.wrapper, isOptionalValue: true))
        }
        return sources
    }

let wrapperProjectionsOutput = """
// Generated by BridgeGen. Do not edit.
//
// A property wrapper whose PROJECTION the interface publishes as a parameter
// type but gives no way to build: `FocusState<Value>.Binding` stores a
// `private var _binding` and declares `wrappedValue`/`projectedValue` and no
// initializer at all. Such a parameter cannot be satisfied by converting an
// argument, only by DECLARING the enclosing wrapper somewhere real — which is
// what these carriers do.

import SwiftUI

\(wrapperProjectionCarrierSources.joined(separator: "\n\n"))

"""
let wrapperProjectionsPath =
    "Sources/SwiftUIBridge/Generated/GeneratedWrapperProjections.swift"
try wrapperProjectionsOutput.write(
    toFile: wrapperProjectionsPath, atomically: true, encoding: .utf8)
print(
    "wrote \(wrapperProjectionsPath) "
        + "(\(wrapperProjectionCarrierSources.count) projection carriers for "
        + "\(wrapperProjectionWrappers.count) wrappers)")

// One line per value type some interface declares a `Binding` over. The body
// is identical in every case because the gap is identical in every case: the
// concrete `Value` has to be spelled in real Swift before a `Binding<Value>`
// can exist, and nothing else about the type is needed — its coercion travels
// in the tag. So a value type the SDK gains is carried the moment the scan
// maps it, with no edit here.
let bindingValuesOutput = """
// Generated by BridgeGen. Do not edit.
//
// `Binding<Value>` is the one parameter shape no argument conversion can
// satisfy. Every other parameter asks whether the argument already IS, or can
// become, the value the interface declares; for a binding the answer is always
// no, because an interpreted `$model.tint` is a projection onto INTERPRETED
// storage and so is never a `Binding` SwiftUI itself built. The parameter is
// satisfied by DRIVING one instead, which needs `Value` spelled concretely —
// generic code cannot conjure `Binding<Value>` from a type name.
//
// Each adapter is therefore the same one line over a different `Value`, and
// what makes it a bridge rather than a table of special cases is that the
// coercion in both directions is the value type's own, handed in by the tag.

import Foundation
import SwiftUI

enum GeneratedBindingValues {
    /// Keyed by the binding's VALUE type as the interfaces normalize it.
    static let adapters:
        [String: (Any, InterpretedBindingStorage) -> Any?] = [
\(bindingValueTypes.sorted().map {
    "        \(String(reflecting: $0)): "
        + "{ GeneratedBindingValueSupport.binding($0, $1, as: \($0).self) },"
}.joined(separator: "\n"))
    ]
}

"""
let bindingValuesPath =
    "Sources/SwiftUIBridge/Generated/GeneratedBindingValues.swift"
try bindingValuesOutput.write(
    toFile: bindingValuesPath, atomically: true, encoding: .utf8)
print(
    "wrote \(bindingValuesPath) "
        + "(\(bindingValueTypes.count) binding value adapters)")

let propertyWrappersPath =
    "Sources/SwiftUIBridge/Generated/GeneratedPropertyWrappers.swift"
try propertyWrappersOutput.write(
    toFile: propertyWrappersPath, atomically: true, encoding: .utf8)
print(
    "wrote \(propertyWrappersPath) "
        + "(\(frameworkSuppliedWrappers.count) framework-supplied wrappers)")

let foundationReferencePropertyPath =
    "Sources/SwiftUIBridge/Generated/GeneratedFoundationReferenceProperties.swift"
try foundationReferencePropertyGeneration.output.write(
    toFile: foundationReferencePropertyPath,
    atomically: true, encoding: .utf8)
print(
    "wrote \(foundationReferencePropertyPath) "
        + "(\(foundationReferencePropertyGeneration.propertyCount) properties)")

// MARK: - Emit compiler-preflight host module

// Real SDK declarations are already the source of every generated gateway.
// Re-exporting those modules lets swiftc consume their complete serialized
// effects and isolation instead of maintaining a lossy declaration copy.
// Only interpreter-synthetic APIs need declarations appended here later.
let requiredPreflightModules = ["_Concurrency", "Foundation", "SwiftUI"]
let conditionalPreflightModules = Array(Set([
    "Combine", "CoreGraphics", "Darwin", "ObjectiveC",
] + platformGeneration.coverage.keys)
    .subtracting(requiredPreflightModules)).sorted()
let preflightModuleSource = (
    requiredPreflightModules.map { "@_exported import \($0)" }
        + conditionalPreflightModules.flatMap {
            ["#if canImport(\($0))", "@_exported import \($0)", "#endif"]
        }
).joined(separator: "\n") + "\n"
let preflightModules = (requiredPreflightModules
    + conditionalPreflightModules).sorted()
let preflightModuleOutput = """
// GENERATED by BridgeGen from the SDK modules backing generated gateways.
// Do not edit. Regenerate: swift run BridgeGen --emit
import SwiftInterpreter

enum GeneratedCompilerPreflightSurface {
    static let exportedModules = \(String(reflecting: preflightModules))
    static let module = CompilerPreflightHostModule(
        moduleName: "DynamicSwiftUIHostSurface",
        source: \(String(reflecting: preflightModuleSource)))
}
""" + "\n"
let preflightModulePath =
    "Sources/SwiftUIBridge/Generated/GeneratedCompilerPreflightSurface.swift"
try preflightModuleOutput.write(
    toFile: preflightModulePath, atomically: true, encoding: .utf8)
print("wrote \(preflightModulePath) (\(preflightModules.count) modules)")


// MARK: - Emit parity probes (--probes)

// The native-baseline doctrine extended to APIs: every generated member
// gets an expression probe evaluated by a COMPILED twin and by the
// interpreter; ParityCheck diffs the outputs. Seeds are deterministic and
// textually IDENTICAL on both sides.
let parityPrelude = """
let seedURL = URL(string: "https://example.com/a/b/file.txt?x=1&y=2")!
let seedURL2 = URL(string: "https://example.org/other/path")!
let seedDate = Date(timeIntervalSince1970: 1234567890)
let seedDate2 = Date(timeIntervalSince1970: 1300000000)
let seedData = "hello world".data(using: .utf8)!
let seedData2 = "abc".data(using: .utf8)!
let seedUUID = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
let seedCalendar = Calendar.current
let seedTimeZone = TimeZone.current
let seedLocale = Locale(identifier: "en_US")
let seedComponents = DateComponents(year: 2020, month: 5, day: 17)
let seedInterval = DateInterval(start: seedDate, duration: 3600)
let seedURLComponents = URLComponents(string: "https://example.com/a?x=1")!
let seedQueryItem = URLQueryItem(name: "k", value: "v")
let seedRequest = URLRequest(url: seedURL)
let seedCharset = CharacterSet(charactersIn: "abcxyz")
let seedIndexSet = IndexSet([1, 2, 3, 9])
let seedDecimal = Decimal(string: "3.14159")!
let seedIndexPath = IndexPath(indexes: [1, 3])
let seedPersonName = PersonNameComponents(givenName: "Ada", familyName: "Lovelace")
let seedInt = 42
let seedDouble = 3.5
"""

let seedReceivers: [String: String] = [
    "URL": "seedURL", "Data": "seedData", "Date": "seedDate", "UUID": "seedUUID",
    "Calendar": "seedCalendar", "TimeZone": "seedTimeZone", "Locale": "seedLocale",
    "DateComponents": "seedComponents", "DateInterval": "seedInterval",
    "URLComponents": "seedURLComponents", "URLQueryItem": "seedQueryItem",
    "URLRequest": "seedRequest", "CharacterSet": "seedCharset", "IndexSet": "seedIndexSet",
    "Decimal": "seedDecimal", "IndexPath": "seedIndexPath",
    "PersonNameComponents": "seedPersonName",
    // Protocol-receiver carriers (the stdlib sweep's Int/Double surface).
    "Int": "seedInt", "Double": "seedDouble",
]

func probeArgument(for tag: String) -> String? {
    switch tag {
    case "string", "localizationKey": return "\"sample\""
    case "int": return "3"
    case "double", "cgFloat": return "2.5"
    case "bool": return "true"
    case "date": return "seedDate2"
    case "url": return "seedURL2"
    case "data": return "seedData2"
    case "stringArray": return "[\"a\", \"b\"]"
    case "decimal": return "seedDecimal"
    case "characterSet": return "seedCharset"
    case "indexSet": return "seedIndexSet"
    case "dateComponents": return "seedComponents"
    case "dateInterval": return "seedInterval"
    case "indexPath": return "seedIndexPath"
    case "intArray": return "[1, 2]"
    case "intRange": return "2..<5"
    case "doubleRange": return "0.0...10.0"
    case "calendarComponent": return ".month"
    case "calendarComponentSet": return "[.year, .month]"
    default: return nil
    }
}

/// Probes that can never be deterministic or that hang (network etc.) —
/// grow this list from ParityCheck's unstable report if the auto-filter
/// misses any.
let denyProbes: Set<String> = []

struct ParityProbe {
    let id: String
    let expression: String
}

var parityProbes: [ParityProbe] = []
var probeSeen = Set<String>()

for property in memberProperties {
    guard let receiver = seedReceivers[property.type] else { continue }
    let id = "\(property.type).\(property.name)"
    guard !denyProbes.contains(id), probeSeen.insert(id).inserted else { continue }
    parityProbes.append(ParityProbe(id: id, expression: "\(receiver).\(property.name)"))
}
for variant in memberMethodVariants {
    guard let receiver = seedReceivers[variant.type] else { continue }
    var argParts: [String] = []
    var ok = true
    for param in variant.params {
        guard let value = probeArgument(for: param.tag) else { ok = false; break }
        argParts.append((param.label.map { "\($0): " } ?? "") + value)
    }
    guard ok else { continue }
    let id = "\(variant.type).\(variant.name)|\(variant.params.map { "\($0.label ?? "_"):\($0.tag)" }.joined(separator: ","))"
    guard !denyProbes.contains(id), probeSeen.insert(id).inserted else { continue }
    parityProbes.append(ParityProbe(
        id: id, expression: "\(receiver).\(variant.name)(\(argParts.joined(separator: ", ")))"))
}

if CommandLine.arguments.contains("--probes") {
    var twin = "// GENERATED by BridgeGen --probes. Do not edit.\nimport Foundation\n\n"
    twin += parityPrelude + "\n\n"
    twin += "@inline(never) func emit(_ id: String, _ value: Any) {\n"
    twin += "    print(\"\\(id)\\u{9}\\(String(describing: value))\")\n}\n\n"
    for (index, probe) in parityProbes.enumerated() {
        if index % 40 == 0 { twin += "func probes\(index / 40)() {\n" }
        twin += "    emit(\"\(probe.id)\", \(probe.expression))\n"
        if index % 40 == 39 || index == parityProbes.count - 1 { twin += "}\n" }
    }
    for index in stride(from: 0, to: parityProbes.count, by: 40) {
        twin += "probes\(index / 40)()\n"
    }
    try twin.write(toFile: "Sources/ParityTwin/main.swift", atomically: true, encoding: .utf8)

    var table = "// GENERATED by BridgeGen --probes. Do not edit.\n\n"
    table += "let parityPrelude = \"\"\"\n" + parityPrelude + "\n\"\"\"\n\n"
    table += "let parityProbes: [(id: String, expression: String)] = [\n"
    for probe in parityProbes {
        let escaped = probe.expression.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        table += "    (\"\(probe.id)\", \"\(escaped)\"),\n"
    }
    table += "]\n"
    try table.write(toFile: "Sources/ParityCheck/GeneratedProbes.swift", atomically: true, encoding: .utf8)
    print("wrote \(parityProbes.count) parity probes (ParityTwin/main.swift + ParityCheck/GeneratedProbes.swift)")
}