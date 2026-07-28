import Foundation
import SwiftParser
import SwiftSyntax

// BridgeGen: parse the SDK's SwiftUICore + SwiftUI interfaces, classify every
// `extension View` modifier against the bridge's coercible-type whitelist,
// report coverage, and (with --emit) generate statically-compiled gateway
// tables. Generated calls compile against the real SDK, so a wrong signature
// fails at build time, never in a user session.

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

/// SwiftUI's Catalyst-only overlays live under the SDK's iOSSupport tree,
/// separate from the macOS interface. They contain target constructors such
/// as platform-value conversions that a macOS-hosted interpreter must still
/// recognize without compiling UIKit into the host binary.
func catalystOverlayInterfacePath(framework: String) -> String? {
    let moduleDir = "\(sdk)/System/iOSSupport/System/Library/Frameworks/\(framework).framework/Modules/\(framework).swiftmodule"
    let candidates = ((try? FileManager.default.contentsOfDirectory(
        atPath: moduleDir)) ?? [])
        .filter { $0.hasSuffix("-apple-ios-macabi.swiftinterface") }
        .sorted()
    let architecturePrefix = hostArchitecture == "arm64"
        ? "arm64" : hostArchitecture
    guard let name = candidates.first(where: {
        $0.hasPrefix(architecturePrefix)
    }) ?? candidates.first else { return nil }
    return "\(moduleDir)/\(name)"
}

let interfaceFiles = ["SwiftUICore", "SwiftUI", "Charts"].compactMap { framework -> SourceFileSyntax? in
    guard let path = interfacePath(framework: framework),
          let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("warning: no swiftinterface for \(framework)")
        return nil
    }
    print("parsing \(framework) (\(source.count) chars)…")
    return Parser.parse(source: source)
}

let targetOverlayFiles = ["SwiftUI"].compactMap {
    framework -> SourceFileSyntax? in
    guard let path = catalystOverlayInterfacePath(framework: framework),
          let source = try? String(contentsOfFile: path, encoding: .utf8)
    else {
        print("warning: no Catalyst overlay swiftinterface for \(framework)")
        return nil
    }
    print("parsing \(framework) Catalyst overlay (\(source.count) chars)…")
    return Parser.parse(source: source)
}

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
]

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

    init(
        tag: String, cast: String, requiredFramework: String? = nil,
        contextualType: String? = nil
    ) {
        self.tag = tag
        self.cast = cast
        self.requiredFramework = requiredFramework
        self.contextualType = contextualType
    }

    func contextualized(as type: String) -> TypeMapping {
        .init(
            tag: tag, cast: cast, requiredFramework: requiredFramework,
            contextualType: type)
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

var sdkProtocols: Set<String> = []
var sdkProtocolRefinements: [String: Set<String>] = [:]
var sdkNominalConformances: [String: Set<String>] = [:]
var sdkProtocolContextualValues: Set<SDKProtocolContextualValue> = []

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
    let conformances = sdkNominalConformances[type] ?? []
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
    guard !constraints.isEmpty,
          constraints.allSatisfy({ sdkProtocols.contains($0) }) else {
        return nil
    }
    let visibleProtocols = constraints.reduce(into: Set<String>()) {
        $0.formUnion(protocolClosure(of: $1))
    }
    let candidates = sdkProtocolContextualValues.filter {
        visibleProtocols.contains($0.declaringProtocol)
            && nominal($0.concreteType, satisfies: constraints)
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
    guard !unambiguous.isEmpty else { return nil }

    let ordered = constraints.sorted()
    let key = ordered.joined(separator: "&")
    sdkProtocolCompositionValues[key] = unambiguous
    return .init(
        tag: "sdkProtocolValue(\"\(key)\")",
        cast: "%@ as! any \(ordered.joined(separator: " & "))")
}

/// Supporting SDK interfaces are collected under their module-qualified
/// paths, while a consuming declaration may spell the same contextual type
/// without that module. Resolve only a unique suffix match: ambiguity remains
/// blocked exactly as it would at a native import boundary.
func contextualSDKTypeName(matching normalized: String) -> String? {
    if sdkEnumCases[normalized] != nil { return normalized }
    let matches = sdkEnumCases.keys.filter {
        $0.hasSuffix("." + normalized)
    }
    return matches.count == 1 ? matches[0] : nil
}

func directMapping(for normalized: String) -> TypeMapping? {
    switch normalized {
    case "String", "StringProtocol": return .init(tag: "string", cast: "%@ as! String")
    case "LocalizedStringKey": return .init(tag: "string", cast: "LocalizedStringKey(%@ as! String)")
    case "LocalizedStringResource":
        return .init(tag: "string", cast: "LocalizedStringResource(stringLiteral: %@ as! String)")
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
    case "[Color]": return .init(tag: "colorArray", cast: "%@ as! [Color]")
    case "Binding<Bool>": return .init(tag: "bindingBool", cast: "%@ as! Binding<Bool>")
    case "Binding<String>": return .init(tag: "bindingString", cast: "%@ as! Binding<String>")
    case "Binding<Double>": return .init(tag: "bindingDouble", cast: "%@ as! Binding<Double>")
    case "AnyShapeStyle": return .init(tag: "shapeStyle", cast: "%@ as! AnyShapeStyle")
    case "URL": return .init(tag: "url", cast: "%@ as! URL")
    case "Date": return .init(tag: "date", cast: "%@ as! Date")
    case "Data": return .init(tag: "data", cast: "%@ as! Data")
    default:
        if let frameworks = platformTypeFrameworks[normalized],
           frameworks.count == 1, let framework = frameworks.first {
            return .init(
                tag: "platformValue(\"\(framework)\", \"\(normalized)\")",
                cast: "%@ as! \(normalized)",
                requiredFramework: framework)
        }
        guard let contextualType =
                contextualSDKTypeName(matching: normalized) else {
            return nil
        }
        let requirements =
            sdkEnumFrameworkRequirements[contextualType] ?? []
        return .init(
            tag: "sdkEnum(\"\(contextualType)\")",
            cast: "%@ as! \(contextualType)",
            requiredFramework: requirements.count == 1
                ? requirements.first : nil)
    }
}

/// The canonical concrete type a lone conformance constraint specializes
/// to when it appears INSIDE a compound type (`ClosedRange<V>` with
/// V: BinaryFloatingPoint → ClosedRange<Double>).
func constraintConcreteType(for constraint: String) -> String? {
    switch constraint {
    case "BinaryFloatingPoint", "FloatingPoint": return "Double"
    case "StringProtocol": return "String"
    case "BinaryInteger": return "Int"
    case "Transferable": return "URL"
    default: return nil
    }
}

func constraintMapping(for constraint: String) -> TypeMapping? {
    switch constraint {
    case "ShapeStyle": return .init(tag: "shapeStyle", cast: "%@ as! AnyShapeStyle")
    case "View": return .init(tag: "anyView", cast: "%@ as! AnyView")
    case "StringProtocol": return .init(tag: "string", cast: "%@ as! String")
    case "BinaryFloatingPoint": return .init(tag: "double", cast: "%@ as! Double")
    case "Equatable": return .init(tag: "equatable", cast: "%@ as! String")
    case "Shape": return .init(tag: "shape", cast: "%@ as! AnyShape")
    case "Transferable": return .init(tag: "url", cast: "%@ as! URL")
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
        let isFinalClosure = index == analyzed.count - 1
            && [
                "builder", "action", "asyncAction",
                "syncVoidClosure", "syncCGFloatClosure",
            ].contains(
                parameter.mapping?.tag ?? "")
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
    var isBuilder = false
    var isAutoclosure = false

    // Result-builder and closure attributes are represented on the parameter
    // by current SwiftSyntax, while older interfaces/parsers may attach them
    // to AttributedTypeSyntax. Read both locations so generation follows the
    // SDK declaration rather than a parser-layout accident.
    func inspectAttributes(_ attributes: AttributeListSyntax) {
        for attribute in attributes {
            let name = attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription ?? ""
            let normalizedName = normalize(name)
            if normalizedName.hasSuffix("ViewBuilder") { isBuilder = true }
            if normalizedName == "autoclosure" { isAutoclosure = true }
        }
    }
    inspectAttributes(param.attributes)
    while let attributed = type.as(AttributedTypeSyntax.self) {
        inspectAttributes(attributed.attributes)
        type = attributed.baseType
    }
    var normalized = normalize(type.trimmedDescription)
    if normalized.hasSuffix("?") { normalized = String(normalized.dropLast()) }

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
        }
    }
    if isBuilder {
        // Builders with framework-supplied inputs (GeometryProxy,
        // AsyncImagePhase, collection elements, accessibility content, …)
        // need a semantic adapter that can manufacture the input value.
        // A generated zero-argument closure would compile incorrectly or
        // silently discard data, so only the ordinary `() -> View` shape is
        // mechanical.
        guard normalized.hasPrefix("() ->") else {
            return .init(
                label: label, mapping: nil, hasDefault: hasDefault,
                blocker: "@ViewBuilder input closure", usesGeneric: nil)
        }
        return .init(
            label: label,
            mapping: .init(tag: "builder", cast: "{ %@ as! AnyView }"),
            hasDefault: hasDefault, blocker: nil, usesGeneric: generics[normalized] != nil ? normalized : nil
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
    // Framework-owned synchronous callbacks with one concrete input share one
    // argument adapter. The SDK supplies the input value; the declared result
    // shape selects whether the interpreter result is discarded or coerced.
    // This is driven by closure structure, not modifier or input identity.
    if let closure = type.as(FunctionTypeSyntax.self),
       closure.parameters.count == 1,
       let inputParameter = closure.parameters.first,
       inputParameter.type.as(AttributedTypeSyntax.self)?
           .specifiers.isEmpty != false,
       let input = Optional({
           normalize($0.type.trimmedDescription)
       }(inputParameter)),
       !referencesGenericIdentifier(input, generics: generics) {
        let result = normalize(
            closure.returnClause.type.trimmedDescription)
        let mapping: TypeMapping? = switch result {
        case "Void":
            .init(
                tag: "syncVoidClosure",
                cast: "generatedSyncVoidClosure(%@)")
        case "CGFloat":
            .init(
                tag: "syncCGFloatClosure",
                cast: "generatedSyncCGFloatClosure(%@)")
        default:
            nil
        }
        if let mapping {
            return .init(
                label: label, mapping: mapping,
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
                return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized, genericConcrete: concrete)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "== \(concrete)", usesGeneric: normalized)
        case .constraints(let set):
            if set.count == 1, let mapping = constraintMapping(for: set.first!) {
                return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized, genericConcrete: constraintConcreteType(for: set.first!))
            }
            if let mapping = sdkProtocolMapping(for: set) {
                return .init(
                    label: label, mapping: mapping,
                    hasDefault: hasDefault, blocker: nil,
                    usesGeneric: normalized)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault,
                         blocker: "<\(set.sorted().joined(separator: "&"))>", usesGeneric: normalized)
        }
    }
    if let mapping = directMapping(for: normalized)?
        .contextualized(as: normalized) {
        return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
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
            return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: name, genericConcrete: concrete)
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

let primaryInterfaceFrameworks: Set<String> = [
    "SwiftUICore", "SwiftUI", "Charts",
]
var qualifiedConstraintModules: Set<String> = []
for file in interfaceFiles {
    collectQualifiedConstraintModules(
        in: Syntax(file), into: &qualifiedConstraintModules)
}
let supportingInterfaceFiles:
    [(module: String, file: SourceFileSyntax)] =
        qualifiedConstraintModules.sorted().compactMap { module in
            guard !primaryInterfaceFrameworks.contains(module),
                  let path = interfacePath(framework: module),
                  let source = try? String(
                    contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            print("parsing contextual support \(module) (\(source.count) chars)…")
            return (module, Parser.parse(source: source))
        }

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
/// deployment, independently of the macOS host. Future-version deprecations
/// remain legal API; only actual unavailability/obsoletion or newer
/// introduction prevents emission.
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
        if text.contains("iOS, unavailable")
            || text.contains("iOS unavailable")
            || text.contains("iOS, obsoleted") {
            return false
        }
        if let introduced = introducedVersion(in: text, platform: "iOS"),
           introduced > (deploymentTarget, 0) {
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
    if let protocolDecl = decl.as(ProtocolDeclSyntax.self) {
        guard isPublicSDKDecl(protocolDecl.modifiers),
              isUniversallyUsable(protocolDecl.attributes) else { return }
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(protocolDecl.attributes)
        guard !guarded else { return }
        let childPath = path + [protocolDecl.name.text]
        let type = "\(module).\(childPath.joined(separator: "."))"
        sdkProtocols.insert(type)
        let refinements = protocolDecl.inheritanceClause?.inheritedTypes.map {
            canonicalSDKType(
                $0.type.trimmedDescription, module: module,
                localTopLevelNames: localTopLevelNames)
        } ?? []
        sdkProtocolRefinements[type, default: []].formUnion(refinements)
        collectSDKProtocolDeclarations(
            in: protocolDecl.memberBlock.members,
            module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: guarded)
        return
    }

    if let structDecl = decl.as(StructDeclSyntax.self) {
        guard isPublicSDKDecl(structDecl.modifiers),
              isUniversallyUsable(structDecl.attributes) else { return }
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(structDecl.attributes)
        collectSDKProtocolDeclarations(
            in: structDecl.memberBlock.members,
            module: module, path: path + [structDecl.name.text],
            localTopLevelNames: localTopLevelNames, guarded: guarded)
        return
    }
    if let enumDecl = decl.as(EnumDeclSyntax.self) {
        guard isPublicSDKDecl(enumDecl.modifiers),
              isUniversallyUsable(enumDecl.attributes) else { return }
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(enumDecl.attributes)
        collectSDKProtocolDeclarations(
            in: enumDecl.memberBlock.members,
            module: module, path: path + [enumDecl.name.text],
            localTopLevelNames: localTopLevelNames, guarded: guarded)
        return
    }
    if let classDecl = decl.as(ClassDeclSyntax.self) {
        guard isPublicSDKDecl(classDecl.modifiers),
              isUniversallyUsable(classDecl.attributes) else { return }
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(classDecl.attributes)
        collectSDKProtocolDeclarations(
            in: classDecl.memberBlock.members,
            module: module, path: path + [classDecl.name.text],
            localTopLevelNames: localTopLevelNames, guarded: guarded)
        return
    }
    if let actorDecl = decl.as(ActorDeclSyntax.self) {
        guard isPublicSDKDecl(actorDecl.modifiers),
              isUniversallyUsable(actorDecl.attributes) else { return }
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(actorDecl.attributes)
        collectSDKProtocolDeclarations(
            in: actorDecl.memberBlock.members,
            module: module, path: path + [actorDecl.name.text],
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

    if let protocolDecl = decl.as(ProtocolDeclSyntax.self) {
        guard usable(protocolDecl.modifiers, protocolDecl.attributes) else {
            return
        }
        collectSDKProtocolMetadata(
            in: protocolDecl.memberBlock.members,
            module: module, path: path + [protocolDecl.name.text],
            localTopLevelNames: localTopLevelNames, guarded: false)
        return
    }

    if let structDecl = decl.as(StructDeclSyntax.self) {
        guard usable(structDecl.modifiers, structDecl.attributes) else {
            return
        }
        let childPath = path + [structDecl.name.text]
        recordSDKNominalConformances(
            type: "\(module).\(childPath.joined(separator: "."))",
            inheritanceClause: structDecl.inheritanceClause,
            module: module, localTopLevelNames: localTopLevelNames)
        collectSDKProtocolMetadata(
            in: structDecl.memberBlock.members,
            module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: false)
        return
    }
    if let enumDecl = decl.as(EnumDeclSyntax.self) {
        guard usable(enumDecl.modifiers, enumDecl.attributes) else { return }
        let childPath = path + [enumDecl.name.text]
        recordSDKNominalConformances(
            type: "\(module).\(childPath.joined(separator: "."))",
            inheritanceClause: enumDecl.inheritanceClause,
            module: module, localTopLevelNames: localTopLevelNames)
        collectSDKProtocolMetadata(
            in: enumDecl.memberBlock.members,
            module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: false)
        return
    }
    if let classDecl = decl.as(ClassDeclSyntax.self) {
        guard usable(classDecl.modifiers, classDecl.attributes) else { return }
        let childPath = path + [classDecl.name.text]
        recordSDKNominalConformances(
            type: "\(module).\(childPath.joined(separator: "."))",
            inheritanceClause: classDecl.inheritanceClause,
            module: module, localTopLevelNames: localTopLevelNames)
        collectSDKProtocolMetadata(
            in: classDecl.memberBlock.members,
            module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: false)
        return
    }
    if let actorDecl = decl.as(ActorDeclSyntax.self) {
        guard usable(actorDecl.modifiers, actorDecl.attributes) else { return }
        let childPath = path + [actorDecl.name.text]
        recordSDKNominalConformances(
            type: "\(module).\(childPath.joined(separator: "."))",
            inheritanceClause: actorDecl.inheritanceClause,
            module: module, localTopLevelNames: localTopLevelNames)
        collectSDKProtocolMetadata(
            in: actorDecl.memberBlock.members,
            module: module, path: childPath,
            localTopLevelNames: localTopLevelNames, guarded: false)
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
    }

    collectSDKProtocolMetadata(
        in: extensionDecl.memberBlock.members,
        module: module,
        path: nestedSDKPath(for: extended, module: module),
        localTopLevelNames: localTopLevelNames, guarded: false)
}

for support in supportingInterfaceFiles {
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
}

// MARK: - Automatically coercible contextual SDK values

func isPublicSDKDecl(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.text == "public" }
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
    frameworkRequirements: Set<String>
) {
    guard !guarded else { return }
    var names: [String] = []
    for member in members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
              isPublicSDKDecl(variable.modifiers),
              variable.modifiers.contains(where: { $0.name.text == "static" }),
              isUniversallyUsable(variable.attributes),
              !needsAvailabilityGuard(variable.attributes) else { continue }
        for binding in variable.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  let annotation = binding.typeAnnotation,
                  normalize(annotation.type.trimmedDescription) == type else {
                continue
            }
            names.append(identifier.identifier.text.trimmingCharacters(
                in: CharacterSet(charactersIn: "`")))
        }
    }
    recordSDKContextualValues(
        type: type, members: names,
        frameworkRequirements: frameworkRequirements)
}

func collectSDKEnums(
    in members: MemberBlockItemListSyntax, path: [String], guarded: Bool,
    frameworkRequirements: Set<String>
) {
    for member in members {
        collectSDKEnums(
            in: member.decl, path: path, guarded: guarded,
            frameworkRequirements: frameworkRequirements)
    }
}

func collectSDKEnums(
    in decl: DeclSyntax, path: [String], guarded inheritedGuarded: Bool,
    frameworkRequirements inheritedRequirements: Set<String>
) {
    if let enumDecl = decl.as(EnumDeclSyntax.self) {
        guard isPublicSDKDecl(enumDecl.modifiers),
              isUniversallyUsable(enumDecl.attributes),
              !enumDecl.name.text.hasPrefix("_") else { return }
        let path = path + [enumDecl.name.text]
        let guarded = inheritedGuarded || needsAvailabilityGuard(enumDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(enumDecl.attributes))
        let type = path.joined(separator: ".")
        recordSDKSetAlgebraConformance(
            type: type, inheritanceClause: enumDecl.inheritanceClause,
            guarded: guarded)
        collectSameTypeSDKStatics(
            in: enumDecl.memberBlock.members, type: type, guarded: guarded,
            frameworkRequirements: requirements)
        if !guarded {
            var cases: [String] = []
            for member in enumDecl.memberBlock.members {
                guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self),
                      isUniversallyUsable(caseDecl.attributes),
                      !needsAvailabilityGuard(caseDecl.attributes) else { continue }
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
            frameworkRequirements: requirements)
        return
    }

    if let structDecl = decl.as(StructDeclSyntax.self) {
        guard isPublicSDKDecl(structDecl.modifiers),
              isUniversallyUsable(structDecl.attributes),
              !structDecl.name.text.hasPrefix("_") else { return }
        let childPath = path + [structDecl.name.text]
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(structDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(structDecl.attributes))
        recordSDKSetAlgebraConformance(
            type: childPath.joined(separator: "."),
            inheritanceClause: structDecl.inheritanceClause, guarded: guarded)
        collectSameTypeSDKStatics(
            in: structDecl.memberBlock.members,
            type: childPath.joined(separator: "."), guarded: guarded,
            frameworkRequirements: requirements)
        collectSDKEnums(
            in: structDecl.memberBlock.members,
            path: childPath, guarded: guarded,
            frameworkRequirements: requirements)
        return
    }

    if let classDecl = decl.as(ClassDeclSyntax.self) {
        guard isPublicSDKDecl(classDecl.modifiers),
              isUniversallyUsable(classDecl.attributes),
              !classDecl.name.text.hasPrefix("_") else { return }
        let childPath = path + [classDecl.name.text]
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(classDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(classDecl.attributes))
        recordSDKSetAlgebraConformance(
            type: childPath.joined(separator: "."),
            inheritanceClause: classDecl.inheritanceClause, guarded: guarded)
        collectSameTypeSDKStatics(
            in: classDecl.memberBlock.members,
            type: childPath.joined(separator: "."), guarded: guarded,
            frameworkRequirements: requirements)
        collectSDKEnums(
            in: classDecl.memberBlock.members,
            path: childPath, guarded: guarded,
            frameworkRequirements: requirements)
        return
    }

    if let actorDecl = decl.as(ActorDeclSyntax.self) {
        guard isPublicSDKDecl(actorDecl.modifiers),
              isUniversallyUsable(actorDecl.attributes),
              !actorDecl.name.text.hasPrefix("_") else { return }
        let childPath = path + [actorDecl.name.text]
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(actorDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(actorDecl.attributes))
        recordSDKSetAlgebraConformance(
            type: childPath.joined(separator: "."),
            inheritanceClause: actorDecl.inheritanceClause, guarded: guarded)
        collectSameTypeSDKStatics(
            in: actorDecl.memberBlock.members,
            type: childPath.joined(separator: "."), guarded: guarded,
            frameworkRequirements: requirements)
        collectSDKEnums(
            in: actorDecl.memberBlock.members,
            path: childPath, guarded: guarded,
            frameworkRequirements: requirements)
        return
    }

    if let protocolDecl = decl.as(ProtocolDeclSyntax.self) {
        guard isPublicSDKDecl(protocolDecl.modifiers),
              isUniversallyUsable(protocolDecl.attributes),
              !protocolDecl.name.text.hasPrefix("_") else { return }
        let childPath = path + [protocolDecl.name.text]
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(protocolDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(protocolDecl.attributes))
        collectSameTypeSDKStatics(
            in: protocolDecl.memberBlock.members,
            type: childPath.joined(separator: "."), guarded: guarded,
            frameworkRequirements: requirements)
        collectSDKEnums(
            in: protocolDecl.memberBlock.members,
            path: childPath, guarded: guarded,
            frameworkRequirements: requirements)
        return
    }

    if let extensionDecl = decl.as(ExtensionDeclSyntax.self),
       isUniversallyUsable(extensionDecl.attributes) {
        let extendedPath = normalize(extensionDecl.extendedType.trimmedDescription)
            .split(separator: ".").map(String.init)
        let guarded = inheritedGuarded
            || needsAvailabilityGuard(extensionDecl.attributes)
        let requirements = inheritedRequirements.union(
            platformFrameworkRequirements(extensionDecl.attributes))
        recordSDKSetAlgebraConformance(
            type: extendedPath.joined(separator: "."),
            inheritanceClause: extensionDecl.inheritanceClause,
            guarded: guarded)
        collectSameTypeSDKStatics(
            in: extensionDecl.memberBlock.members,
            type: extendedPath.joined(separator: "."), guarded: guarded,
            frameworkRequirements: requirements)
        collectSDKEnums(
            in: extensionDecl.memberBlock.members,
            path: extendedPath,
            guarded: guarded, frameworkRequirements: requirements)
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

// AppKit/UIKit are predominantly Clang-imported Objective-C APIs, so their
// textual Swift overlays do not contain the declarations Swift source sees.
// Build that metadata model before sweeping SwiftUI so platform-valued
// SwiftUI parameters reuse the exact same selected nominal set.
let platformGeneration = try generatePlatformBridge()
platformTypeFrameworks = platformGeneration.typeFrameworks
let foundationReferencePropertyGeneration =
    try generateFoundationReferenceProperties()

// MARK: - Sweep

struct EmittableParam {
    let label: String?
    let tag: String
    let cast: String
    /// The concrete type accepted by a generated Foundation gateway. View
    /// modifiers and constructors still use their ParamTag-only boundary.
    let contractType: String?
    let requiredFramework: String?
    let contextualType: String?

    init(
        label: String?, tag: String, cast: String,
        contractType: String? = nil, requiredFramework: String? = nil,
        contextualType: String? = nil
    ) {
        self.label = label
        self.tag = tag
        self.cast = cast
        self.contractType = contractType
        self.requiredFramework = requiredFramework
        self.contextualType = contextualType
    }
}

struct Variant {
    let name: String
    let params: [EmittableParam]
    let trailingClosureIndex: Int?
    let inheritedFrameworkRequirements: Set<String>
    /// Imports required by the interpreted source target. Unlike compile-time
    /// framework guards, these survive into generated dispatch so a
    /// macOS-hosted interpreter can distinguish iOS source from macOS source.
    let targetImportRequirements: Set<String>
    /// Values that are structurally both View and ShapeStyle must remain their
    /// concrete semantic value; erasing them to AnyView loses later style use.
    let preservesSemanticValue: Bool

    var key: String {
        name + "|" + params.map { "\($0.label ?? "_"):\($0.tag)" }.joined(separator: ",")
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
    targetImportRequirements: Set<String> = []
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
    for (_, uses) in byGeneric where uses.count > 1 {
        let concretes = Set(uses.map(\.genericConcrete))
        if concretes.count != 1 || concretes.first == nil {
            modifierBlockers["<shared generic>", default: 0] += 1
            return
        }
    }

    if let firstBlocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        modifierBlockers[firstBlocked.blocker ?? "?", default: 0] += 1
        return
    }
    if guarded || needsAvailabilityGuard(function.attributes) {
        modifierGuarded += 1
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
                    contextualType: $0.mapping!.contextualType)
            },
            trailingClosureIndex: selection.trailingClosureIndex,
            inheritedFrameworkRequirements: frameworkRequirements.union(
                platformFrameworkRequirements(function.attributes)),
            targetImportRequirements: targetImportRequirements,
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
var viewStructs = Set<String>()
var valueStructs = Set<String>()
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
    preservesSemanticValue: Bool
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
    if parameters.contains(where: { $0.ellipsis != nil }) {
        initBlockers["variadic", default: 0] += 1
        return
    }
    let analyzed = parameters.map { analyzeParameter($0, generics: generics) }
    let byGenericInit = Dictionary(grouping: analyzed.filter { $0.usesGeneric != nil }, by: { $0.usesGeneric! })
    for (_, uses) in byGenericInit where uses.count > 1 {
        let concretes = Set(uses.map(\.genericConcrete))
        if concretes.count != 1 || concretes.first == nil {
            initBlockers["<shared generic>", default: 0] += 1
            return
        }
    }
    if let firstBlocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        initBlockers[firstBlocked.blocker ?? "?", default: 0] += 1
        return
    }
    if guarded || needsAvailabilityGuard(initDecl.attributes) {
        initGuarded += 1
        return
    }
    initGeneratable += 1
    generatableStructs.insert(structName)
    guard !denyStructs.contains(structName) else { return }

    for selection in parameterSelections(analyzed) {
        let variant = Variant(
            name: structName,
            params: selection.params.map {
                .init(
                    label: $0.label, tag: $0.mapping!.tag,
                    cast: $0.mapping!.cast,
                    requiredFramework: $0.mapping!.requiredFramework,
                    contextualType: $0.mapping!.contextualType)
            },
            trailingClosureIndex: selection.trailingClosureIndex,
            inheritedFrameworkRequirements: frameworkRequirements.union(
                platformFrameworkRequirements(initDecl.attributes)),
            targetImportRequirements: [],
            preservesSemanticValue: preservesSemanticValue
        )
        if initSeenKeys.insert(variant.key).inserted {
            initVariants.append(variant)
        }
    }
}

struct ViewConformanceInfo {
    let generics: Generics
    let guarded: Bool
    let frameworkRequirements: Set<String>
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
        guard conformances.contains("View") else { continue }
        var generics: Generics = [:]
        collectWhereClause(ext.genericWhereClause, into: &generics)
        extensionViewConformances[extendedType] = ViewConformanceInfo(
            generics: generics,
            guarded: needsAvailabilityGuard(ext.attributes),
            frameworkRequirements: platformFrameworkRequirements(
                ext.attributes))
    }
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
                        ext.attributes))
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
            let directlyConforms = directConformances.contains("View")
            let extensionConformance = extensionViewConformances[name]
            guard directlyConforms || extensionConformance != nil else {
                continue
            }
            viewStructs.insert(name)
            let guarded = needsAvailabilityGuard(structDecl.attributes)
                || (extensionConformance?.guarded ?? false)
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
                targetImportRequirements: ["UIKit"])
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
              isUsableIOSOverlay(ext.attributes) else { continue }
        let extendedName = normalize(ext.extendedType.trimmedDescription)
        guard let info = viewStructInfo[extendedName] else { continue }
        var generics = info.generics
        collectWhereClause(ext.genericWhereClause, into: &generics)
        for member in ext.memberBlock.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                  isUsableIOSOverlay(initDecl.attributes) else { continue }
            processInit(
                extendedName, initDecl, generics: generics, guarded: false,
                frameworkRequirements: info.frameworkRequirements.union(
                    ["UIKit"]),
                preservesSemanticValue: info.preservesSemanticValue)
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
        guard generatedParameterValueTypes.contains(name) else {
            continue
        }
        let guarded = needsAvailabilityGuard(structure.attributes)
        let frameworkRequirements = platformFrameworkRequirements(
            structure.attributes)
        let generics = structGenerics(structure)
        valueStructs.insert(name)
        valueStructInfo[name] = (
            generics, guarded, frameworkRequirements)
        for member in structure.memberBlock.members {
            guard let initializer = member.decl.as(
                InitializerDeclSyntax.self),
                  isUsable(initializer.attributes) else {
                continue
            }
            processInit(
                name, initializer, generics: generics, guarded: guarded,
                frameworkRequirements: frameworkRequirements,
                preservesSemanticValue: true)
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
        for member in extensionDeclaration.memberBlock.members {
            guard let initializer = member.decl.as(
                InitializerDeclSyntax.self),
                  isUsable(initializer.attributes) else {
                continue
            }
            processInit(
                extendedName, initializer, generics: generics,
                guarded: guarded,
                frameworkRequirements: frameworkRequirements,
                preservesSemanticValue: true)
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
            contextualType: parameter.contextualType)
        let adapter = Variant(
            name: variant.name, params: [semanticParameter],
            trailingClosureIndex: nil,
            inheritedFrameworkRequirements: [],
            targetImportRequirements: [],
            preservesSemanticValue: true)
        let key = "\(framework)|\(adapter.key)"
        guard seen.insert(key).inserted else { return nil }
        return PlatformSemanticAdapterVariant(
            variant: adapter,
            unavailableFramework: framework,
            resultKind: variant.preservesSemanticValue ? .shapeStyle : .view)
    }
}()

// MARK: - Foundation member sweep

/// Value types whose instance surface the generated-members tier serves.
/// Receiver downcasts run against the host's dynamic type, so only types a
/// `.host` value actually carries belong here (boxes like URLComponentsBox
/// keep their own dynamic type and never reach this table).
let memberTypes: Set<String> = [
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

/// Protocol extensions serve their CONCRETE runtime carriers: the
/// interpreter's numeric payloads are Int and Double, so members Foundation
/// publishes on the numeric protocols (`formatted()` and the FormatStyle
/// family) register once per carrier the dispatch can actually receive.
/// While sweeping a protocol extension for a concrete carrier, `Self`
/// params/returns mean the carrier (`isMultiple(of other: Self)`).
var currentSelfCarrier: String?

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

let genericStructCarriers: [String: GenericStructCarrier] = [
    "Measurement": .init(
        generic: "UnitType", substitute: "Dimension",
        carrier: "Measurement<Dimension>"),
]

var currentGenericSubstitution: (from: String, to: String)?

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
    default: return nil
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
    guard let returnType = function.signature.returnClause?.type.trimmedDescription,
          !returnType.contains("some "), normalize(returnType) != "Self" else {
        memberBlockers[function.signature.returnClause == nil ? "void return" : "opaque/Self return",
                       default: 0] += 1
        if ProcessInfo.processInfo.environment["BRIDGEGEN_DUMP_BLOCKED"] != nil {
            print("   blocked[void/opaque] \(typeName).\(name)\(function.signature.parameterClause.trimmedDescription)")
        }
        return
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
            returnType: memberContractType(for: normalize(returnType)),
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

let foundationFile: SourceFileSyntax? = {
    guard let path = interfacePath(framework: "Foundation"),
          let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("warning: no swiftinterface for Foundation")
        return nil
    }
    print("parsing Foundation (\(source.count) chars)…")
    return Parser.parse(source: source)
}()

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
    canonicalTypes: memberTypes.union(
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
            if let entry = genericStructCarriers[typeName] {
                currentGenericSubstitution = (entry.generic, entry.substitute)
            }
            for member in members {
                if let function = member.decl.as(FunctionDeclSyntax.self), memberIsUsable(function.attributes) {
                    processMemberFunction(typeName, function, guarded: guarded)
                } else if let variable = member.decl.as(VariableDeclSyntax.self), memberIsUsable(variable.attributes) {
                    processMemberProperty(typeName, variable, guarded: guarded)
                } else if let initDecl = member.decl.as(
                    InitializerDeclSyntax.self
                ), memberIsUsable(initDecl.attributes) {
                    processThrowingConstructorContract(
                        typeName, initDecl, guarded: guarded)
                    if genericStructCarriers[typeName] != nil {
                        processCarrierInitializer(
                            typeName, initDecl, guarded: guarded)
                    }
                }
            }
            currentSelfCarrier = nil
            currentGenericSubstitution = nil
        }
    }
}

if let foundationFile {
    sweepMemberFile(foundationFile)
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
let stdlibFile: SourceFileSyntax? = {
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
    return Parser.parse(source: source)
}()

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

// MARK: - Report

let parameterBlockers = modifierBlockers.merging(initBlockers, uniquingKeysWith: +)

print("""

═══ View-extension modifiers ═══
total overloads:        \(modifierTotal)  (\(modifierNames.count) distinct names)
generatable overloads:  \(modifierGeneratable)  (\(generatableNames.count) distinct names)
newer-OS (skipped):     \(modifierGuarded)
emitted variants:       \(variants.count)

═══ SwiftUI constructors ═══
View structs:           \(viewStructs.count)
parameter value structs: \(valueStructs.count)
total inits:            \(initTotal)
generatable inits:      \(initGeneratable)  (across \(generatableStructs.count) structs)
newer-OS (skipped):     \(initGuarded)
emitted variants:       \(initVariants.count)

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

func sdkProtocolComposition(from tag: String) -> String? {
    let prefix = "sdkProtocolValue(\""
    let suffix = "\")"
    guard tag.hasPrefix(prefix), tag.hasSuffix(suffix) else { return nil }
    return String(tag.dropFirst(prefix.count).dropLast(suffix.count))
}

let emittedSDKEnumTypes = Set(
    (variants + initVariants)
        .flatMap(\.params)
        .compactMap { sdkEnumType(from: $0.tag) }
        + nativeValueInits.flatMap(\.params)
            .compactMap { parameter in
                parameter.mapping.flatMap {
                    sdkEnumType(from: $0.tag)
                }
            })
let emittedSDKProtocolCompositions = Set(
    (variants + initVariants)
        .flatMap(\.params)
        .compactMap { sdkProtocolComposition(from: $0.tag) })
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
            emittedVariants: variants.count,
            emittedSignatures: variants.map(\.key).sorted(),
            blockers: modifierBlockers),
        constructors: CoverageSection(
            scannedOverloads: initTotal,
            generatableOverloads: initGeneratable,
            emittedVariants: initVariants.count,
            emittedSignatures: initVariants.map(\.key).sorted(),
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
    let context = parameter.contextualType.map {
        ", contextualType: \"\($0)\""
    } ?? ""
    return "ParamSpec(\(label), .\(parameter.tag)\(context))"
}

func generatedCallPreamble(_ variant: Variant) -> [String] {
    var lines = variant.params.enumerated().compactMap { index, param in
        if param.tag == "builder" {
            return "        let b\(index) = try generatedBuilder(v[\(index)])"
        }
        if sdkProtocolComposition(from: param.tag) != nil {
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
            if param.tag == "builder" {
                value = "{ b\(index) }"
            } else if sdkProtocolComposition(from: param.tag) != nil {
                // A named existential is opened by Swift when passed to the
                // native generic call; an inline cast fixes the generic
                // argument to the existential type itself.
                value = "p\(index)"
            } else {
                value = param.cast.replacingOccurrences(
                    of: "%@", with: "v[\(index)]")
            }
            return (param.label.map { "\($0): " } ?? "") + value
        }
        .joined(separator: ", ")
    guard let trailingIndex = variant.trailingClosureIndex else {
        return "\(callee)(\(argList))"
    }
    let head = argList.isEmpty ? callee : "\(callee)(\(argList))"
    let closure = switch variant.params[trailingIndex].tag {
    case "builder": "{ b\(trailingIndex) }"
    case "action": "{ a\(trailingIndex)() }"
    case "asyncAction": "{ await a\(trailingIndex)() }"
    case "syncVoidClosure":
        "{ value in generatedSyncVoidClosure(v[\(trailingIndex)])(value) }"
    case "syncCGFloatClosure":
        "{ value in generatedSyncCGFloatClosure(v[\(trailingIndex)])(value) }"
    default: fatalError("trailing call argument is not a generated closure")
    }
    return "\(head) \(closure)"
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
    var lines = ["    register(&t, \"\(variant.name)\", [\(specs)]\(importArgument)) { view, v in"]
    lines.append(contentsOf: generatedCallPreamble(variant))
    lines.append("        return AnyView(\(generatedCall("view.\(variant.name)", variant)))")
    lines.append("    }")
    let exact = lines.joined(separator: "\n")
    guard !variant.targetImportRequirements.isEmpty else {
        return compileGuarded(exact, for: variant)
    }
    let condition = variant.requiredFrameworks
        .map { "canImport(\($0))" }
        .joined(separator: " && ")
    let fallback = """
    register(&t, "\(variant.name)", [\(specs)]\(importArgument), executesBuilderArguments: false) { view, _ in
        return AnyView(view)
    }
    """
    return "#if \(condition)\n\(exact)\n#else\n\(fallback)\n#endif"
}

func compileGuarded(_ source: String, for variant: Variant) -> String {
    guard !variant.requiredFrameworks.isEmpty else { return source }
    let condition = variant.requiredFrameworks
        .map { "canImport(\($0))" }
        .joined(separator: " && ")
    return "#if \(condition)\n\(source)\n#endif"
}

let sorted = variants.sorted { ($0.name, $0.params.count) < ($1.name, $1.params.count) }
let chunkSize = 40
let chunks = stride(from: 0, to: sorted.count, by: chunkSize).map {
    Array(sorted[$0..<min($0 + chunkSize, sorted.count)])
}

var output = """
// GENERATED by BridgeGen from the SDK's SwiftUICore/SwiftUI/Charts swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sorted.count) modifier overload variants across \(Set(sorted.map(\.name)).count) names.
import Charts
import SwiftUI
\(emittedSupportingImportBlock)import SwiftInterpreter
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
    var lines = ["    register(&t, \"\(variant.name)\", [\(specs)]) { v in"]
    lines.append(contentsOf: generatedCallPreamble(variant))
    let constructed = generatedCall(variant.name, variant)
    if let adapted = swiftUIMagicConstructorAdapterCall(
        variant, constructed: constructed
    ) {
        lines.append(
            "        return " + adapted.replacingOccurrences(
                of: "\n", with: "\n        "))
    } else {
        lines.append(variant.preservesSemanticValue
            ? "        return \(constructed)"
            : "        return AnyView(\(constructed))")
    }
    lines.append("    }")
    return compileGuarded(lines.joined(separator: "\n"), for: variant)
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

let sortedInits = initVariants.sorted { ($0.name, $0.params.count) < ($1.name, $1.params.count) }
let initChunks = stride(from: 0, to: sortedInits.count, by: chunkSize).map {
    Array(sortedInits[$0..<min($0 + chunkSize, sortedInits.count)])
}

var viewsOutput = """
// GENERATED by BridgeGen from the SDK's SwiftUICore/SwiftUI swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sortedInits.count) initializer variants across \(Set(sortedInits.map(\.name)).count) SwiftUI structs.
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

let viewsPath = "Sources/SwiftUIBridge/Generated/GeneratedViews.swift"
try viewsOutput.write(toFile: viewsPath, atomically: true, encoding: .utf8)
print("wrote \(viewsPath) (\(sortedInits.count) variants)")

// MARK: - Emit contextual SDK value coercions

var enumsOutput = """
// GENERATED by BridgeGen from public SwiftUI SDK enum cases and same-type statics.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(emittedSDKEnumTypes.count) contextual value types.
import Charts
import SwiftUI
\(emittedSupportingImportBlock)import SwiftInterpreter

enum GeneratedSDKEnumCoercions {
    static func coerce(_ typeName: String, _ value: RuntimeValue) throws -> Any {
        switch typeName {

"""

for type in emittedSDKEnumTypes.sorted() {
    guard let cases = sdkEnumCases[type], !cases.isEmpty else { continue }
    enumsOutput += "        case \"\(type)\":\n"
    enumsOutput += "            if case .host(let any) = value, let typed = any as? \(type) { return typed }\n"
    if sdkSetAlgebraTypes.contains(type) {
        enumsOutput += "            if case .array(let elements) = value {\n"
        enumsOutput += "                var result = \(type)()\n"
        enumsOutput += "                for element in elements {\n"
        enumsOutput += "                    result.formUnion(try coerce(typeName, element) as! \(type))\n"
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
        enumsOutput += "            case \"\(caseName)\": return \(type).`\(caseName)` as \(type)\n"
    }
    enumsOutput += "            default:\n"
    enumsOutput += "                throw RuntimeError(message: \"unknown \(type) member '.\\(member)'\")\n"
    enumsOutput += "            }\n"
}
enumsOutput += """
        default:
            throw RuntimeError(message: "unknown generated SDK contextual type '\\(typeName)'")
        }
    }
}
"""

let enumsPath = "Sources/SwiftUIBridge/Generated/GeneratedSDKEnums.swift"
try enumsOutput.write(toFile: enumsPath, atomically: true, encoding: .utf8)
print("wrote \(enumsPath) (\(emittedSDKEnumTypes.count) enum types)")

var protocolValuesOutput = """
// GENERATED by BridgeGen from public protocol-extension `Self == Concrete`
// contextual values and interface-declared conformances.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(emittedSDKProtocolCompositions.count) protocol compositions.
import SwiftUI
\(emittedSupportingImportBlock)import SwiftInterpreter

enum GeneratedSDKProtocolValueCoercions {
    static func coerce(
        _ composition: String, _ value: RuntimeValue
    ) throws -> Any {
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
    let parameters = variant.params.enumerated()
        .map { index, param in
            "\(param.label ?? "_") p\(index): \(param.contractType!)"
        }
        .joined(separator: ", ")
    let declaration = "func \(variant.type).\(variant.name)(\(parameters)) -> \(variant.returnType)"
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
// GENERATED by BridgeGen from the SDK's Foundation swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sortedProperties.count) properties + \(sortedMembers.count) method variants across \(memberTypes.sorted().joined(separator: ", ")).
import Charts
import Foundation
import SwiftInterpreter

extension GeneratedMembers {
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
        if let string = receiver.stringValue {
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
        if receiver.arrayValue != nil,
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
        if let string = receiver.stringValue {
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
        if receiver.arrayValue != nil,
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
        if let string = receiver.stringValue {
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
        if let array = receiver.arrayValue {
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
    case "string": return "\"sample\""
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
