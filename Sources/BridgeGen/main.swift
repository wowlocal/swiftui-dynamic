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

let interfaceFiles = ["SwiftUICore", "SwiftUI", "Charts"].compactMap { framework -> SourceFileSyntax? in
    guard let path = interfacePath(framework: framework),
          let source = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("warning: no swiftinterface for \(framework)")
        return nil
    }
    print("parsing \(framework) (\(source.count) chars)…")
    return Parser.parse(source: source)
}

// MARK: - Type normalization & mapping

// Longest first: "CoreFoundation." must strip before "Foundation." matches
// inside it (ditto SwiftUICore/SwiftUI).
let modulePrefixes = [
    "UniformTypeIdentifiers.", "DeveloperToolsSupport.",
    "CoreFoundation.", "CoreGraphics.", "Charts.",
    "Observation.", "SwiftUICore.", "Foundation.", "CoreData.", "SwiftUI.",
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

    init(
        tag: String, cast: String, requiredFramework: String? = nil
    ) {
        self.tag = tag
        self.cast = cast
        self.requiredFramework = requiredFramework
    }
}

/// Filled from the same platform symbol graphs that generate SDK gateways.
/// SwiftUI initializers/modifiers can then accept any selected AppKit/UIKit
/// nominal without maintaining a second type-name allowlist.
var platformTypeFrameworks: [String: Set<String>] = [:]

/// Public, deployment-compatible SDK enums and their payload-free cases.
/// Populated from the same interfaces before the modifier/init sweep.
var sdkEnumCases: [String: [String]] = [:]
var sdkEnumFrameworkRequirements: [String: Set<String>] = [:]

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
    case "ClosedRange<Double>": return .init(tag: "doubleRange", cast: "%@ as! ClosedRange<Double>")
    case "Color": return .init(tag: "color", cast: "%@ as! Color")
    case "Font": return .init(tag: "font", cast: "%@ as! Font")
    case "Font.Weight": return .init(tag: "fontWeight", cast: "%@ as! Font.Weight")
    case "Angle": return .init(tag: "angle", cast: "%@ as! Angle")
    case "Animation": return .init(tag: "animation", cast: "%@ as! Animation")
    case "Alignment": return .init(tag: "alignment", cast: "%@ as! Alignment")
    case "HorizontalAlignment": return .init(tag: "horizontalAlignment", cast: "%@ as! HorizontalAlignment")
    case "VerticalAlignment": return .init(tag: "verticalAlignment", cast: "%@ as! VerticalAlignment")
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
        guard sdkEnumCases[normalized] != nil else { return nil }
        let requirements = sdkEnumFrameworkRequirements[normalized] ?? []
        return .init(
            tag: "sdkEnum(\"\(normalized)\")", cast: "%@ as! \(normalized)",
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

/// Every Swift call shape obtainable by omitting mapped or unmapped defaulted
/// parameters. Defaults are not restricted to a trailing suffix: declarations
/// such as `VStack(alignment:spacing:content:)` allow `alignment` to be omitted
/// while `spacing` and the required builder remain present.
func parameterSelections(_ analyzed: [AnalyzedParam]) -> [[AnalyzedParam]] {
    var selections: [[AnalyzedParam]] = []

    func visit(
        _ index: Int,
        _ selected: [AnalyzedParam],
        omittedUnlabeledDefault: Bool
    ) {
        guard index < analyzed.count else {
            selections.append(selected)
            return
        }

        let parameter = analyzed[index]
        if parameter.hasDefault {
            visit(
                index + 1,
                selected,
                omittedUnlabeledDefault: omittedUnlabeledDefault || parameter.label == nil)
        }
        // Swift cannot skip an unlabeled default and then bind a later
        // unlabeled argument positionally. (A source trailing closure can
        // sometimes do so, but generated calls deliberately use explicit
        // argument lists.) Labeled parameters after the omission are safe.
        if parameter.mapping != nil,
           !(omittedUnlabeledDefault && parameter.label == nil) {
            visit(
                index + 1,
                selected + [parameter],
                omittedUnlabeledDefault: omittedUnlabeledDefault)
        }
    }

    visit(0, [], omittedUnlabeledDefault: false)
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
    if let attributed = type.as(AttributedTypeSyntax.self) {
        inspectAttributes(attributed.attributes)
        type = attributed.baseType
    }
    var normalized = normalize(type.trimmedDescription)
    if normalized.hasSuffix("?") { normalized = String(normalized.dropLast()) }

    if isAutoclosure {
        return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "@autoclosure", usesGeneric: nil)
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
    // A generic parameter can legally shadow a concrete SDK type (`Data` is
    // common in collection initializers). Resolve declared generics first so
    // it is never mistaken for Foundation.Data or another direct mapping.
    if let facts = generics[normalized] {
        switch facts {
        case .concrete(let concrete):
            if let mapping = directMapping(for: concrete) {
                return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized, genericConcrete: concrete)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "== \(concrete)", usesGeneric: normalized)
        case .constraints(let set):
            if set.count == 1, let mapping = constraintMapping(for: set.first!) {
                return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized, genericConcrete: constraintConcreteType(for: set.first!))
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault,
                         blocker: "<\(set.sorted().joined(separator: "&"))>", usesGeneric: normalized)
        }
    }
    if let mapping = directMapping(for: normalized) {
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
        if let concrete,
           let mapping = directMapping(
            for: normalized.replacingOccurrences(of: "<\(name)>", with: "<\(concrete)>")) {
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

// MARK: - Availability

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
               text.contains("unavailable") || text.contains("deprecated")
                || text.contains("obsoleted") {
                return false
            }
        }
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") { return false }
    }
    return true
}

/// GeneratedSDKEnumCoercions is shared without a platform payload wrapper, so
/// keep that table restricted to declarations present on every target.
func isUniversallyUsable(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        if text.contains("unavailable") || text.contains("deprecated")
            || text.contains("obsoleted") {
            return false
        }
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") { return false }
    }
    return true
}

let deploymentTarget = 15

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

// MARK: - Automatically coercible SDK enums

func isPublicSDKDecl(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.text == "public" }
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
            if !cases.isEmpty {
                let type = path.joined(separator: ".")
                sdkEnumCases[type] = Array(Set(cases)).sorted()
                sdkEnumFrameworkRequirements[type] = requirements
            }
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
        collectSDKEnums(
            in: structDecl.memberBlock.members,
            path: path + [structDecl.name.text],
            guarded: inheritedGuarded || needsAvailabilityGuard(structDecl.attributes),
            frameworkRequirements: inheritedRequirements.union(
                platformFrameworkRequirements(structDecl.attributes)))
        return
    }

    if let classDecl = decl.as(ClassDeclSyntax.self) {
        guard isPublicSDKDecl(classDecl.modifiers),
              isUniversallyUsable(classDecl.attributes),
              !classDecl.name.text.hasPrefix("_") else { return }
        collectSDKEnums(
            in: classDecl.memberBlock.members,
            path: path + [classDecl.name.text],
            guarded: inheritedGuarded || needsAvailabilityGuard(classDecl.attributes),
            frameworkRequirements: inheritedRequirements.union(
                platformFrameworkRequirements(classDecl.attributes)))
        return
    }

    if let actorDecl = decl.as(ActorDeclSyntax.self) {
        guard isPublicSDKDecl(actorDecl.modifiers),
              isUniversallyUsable(actorDecl.attributes),
              !actorDecl.name.text.hasPrefix("_") else { return }
        collectSDKEnums(
            in: actorDecl.memberBlock.members,
            path: path + [actorDecl.name.text],
            guarded: inheritedGuarded || needsAvailabilityGuard(actorDecl.attributes),
            frameworkRequirements: inheritedRequirements.union(
                platformFrameworkRequirements(actorDecl.attributes)))
        return
    }

    if let protocolDecl = decl.as(ProtocolDeclSyntax.self) {
        guard isPublicSDKDecl(protocolDecl.modifiers),
              isUniversallyUsable(protocolDecl.attributes),
              !protocolDecl.name.text.hasPrefix("_") else { return }
        collectSDKEnums(
            in: protocolDecl.memberBlock.members,
            path: path + [protocolDecl.name.text],
            guarded: inheritedGuarded || needsAvailabilityGuard(protocolDecl.attributes),
            frameworkRequirements: inheritedRequirements.union(
                platformFrameworkRequirements(protocolDecl.attributes)))
        return
    }

    if let extensionDecl = decl.as(ExtensionDeclSyntax.self),
       isUniversallyUsable(extensionDecl.attributes) {
        let extendedPath = normalize(extensionDecl.extendedType.trimmedDescription)
            .split(separator: ".").map(String.init)
        collectSDKEnums(
            in: extensionDecl.memberBlock.members,
            path: extendedPath,
            guarded: inheritedGuarded || needsAvailabilityGuard(extensionDecl.attributes),
            frameworkRequirements: inheritedRequirements.union(
                platformFrameworkRequirements(extensionDecl.attributes)))
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

// AppKit/UIKit are predominantly Clang-imported Objective-C APIs, so their
// textual Swift overlays do not contain the declarations Swift source sees.
// Build that metadata model before sweeping SwiftUI so platform-valued
// SwiftUI parameters reuse the exact same selected nominal set.
let platformGeneration = try generatePlatformBridge()
platformTypeFrameworks = platformGeneration.typeFrameworks

// MARK: - Sweep

struct EmittableParam {
    let label: String?
    let tag: String
    let cast: String
    /// The concrete type accepted by a generated Foundation gateway. View
    /// modifiers and constructors still use their ParamTag-only boundary.
    let contractType: String?
    let requiredFramework: String?

    init(
        label: String?, tag: String, cast: String,
        contractType: String? = nil, requiredFramework: String? = nil
    ) {
        self.label = label
        self.tag = tag
        self.cast = cast
        self.contractType = contractType
        self.requiredFramework = requiredFramework
    }
}

struct Variant {
    let name: String
    let params: [EmittableParam]
    let inheritedFrameworkRequirements: Set<String>

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
    frameworkRequirements: Set<String>
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
            params: selection.map {
                .init(
                    label: $0.label, tag: $0.mapping!.tag,
                    cast: $0.mapping!.cast,
                    requiredFramework: $0.mapping!.requiredFramework)
            },
            inheritedFrameworkRequirements: frameworkRequirements.union(
                platformFrameworkRequirements(function.attributes))
        )
        if seenKeys.insert(variant.key).inserted {
            variants.append(variant)
        }
    }
}

// MARK: - View-struct init sweep

var initVariants: [Variant] = []
var initSeenKeys = Set<String>()
var initTotal = 0
var initGeneratable = 0
var initGuarded = 0
var viewStructs = Set<String>()
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
    frameworkRequirements: Set<String>
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
            params: selection.map {
                .init(
                    label: $0.label, tag: $0.mapping!.tag,
                    cast: $0.mapping!.cast,
                    requiredFramework: $0.mapping!.requiredFramework)
            },
            inheritedFrameworkRequirements: frameworkRequirements.union(
                platformFrameworkRequirements(initDecl.attributes))
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
for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item,
              let ext = decl.as(ExtensionDeclSyntax.self),
              isUsable(ext.attributes),
              ext.inheritanceClause?.inheritedTypes.contains(where: {
                  normalize($0.type.trimmedDescription) == "View"
              }) == true else { continue }
        var generics: Generics = [:]
        collectWhereClause(ext.genericWhereClause, into: &generics)
        extensionViewConformances[
            normalize(ext.extendedType.trimmedDescription)
        ] = ViewConformanceInfo(
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
    frameworkRequirements: Set<String>
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
            let directlyConforms = structDecl.inheritanceClause?.inheritedTypes
                .contains(where: {
                    normalize($0.type.trimmedDescription) == "View"
                }) == true
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
            viewStructInfo[name] = (
                generics, guarded, frameworkRequirements)
            for member in structDecl.memberBlock.members {
                guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                      isUsable(initDecl.attributes) else { continue }
                processInit(
                    name, initDecl, generics: generics, guarded: guarded,
                    frameworkRequirements: frameworkRequirements)
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
                frameworkRequirements: frameworkRequirements)
        }
    }
}

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

/// Members tolerate Apple's soft-deprecation sentinel (`deprecated:
/// 100000.0`): `url.path`, `appendingPathComponent(_:)` and friends carry it
/// yet remain the idioms real projects compile against — and skipping the
/// classic property lets its `host(percentEncoded:)` sibling shadow property
/// reads with a function value. Hard deprecations stay excluded.
func memberIsUsable(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        if text.contains("unavailable") || text.contains("obsoleted") { return false }
        if text.contains("deprecated"), !text.contains("deprecated: 100000.0") { return false }
        if attr.attributeName.trimmedDescription.hasSuffix("_spi") { return false }
    }
    return true
}

struct CarrierInit {
    let type: String            // member-table key ("Measurement")
    let params: [AnalyzedParam]
}

var carrierInits: [CarrierInit] = []

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
            params: selection.map {
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
                } else if let initDecl = member.decl.as(InitializerDeclSyntax.self),
                          memberIsUsable(initDecl.attributes),
                          genericStructCarriers[typeName] != nil {
                    processCarrierInitializer(typeName, initDecl, guarded: guarded)
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
}

func unsafeMemorySurface(in file: SourceFileSyntax?) -> UnsafeMemorySurface {
    guard let file else {
        return UnsafeMemorySurface(
            pointerTypes: [], rawPointerTypes: [], bufferTypes: [])
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

    let bufferTypes = Set(nominals.compactMap { name, nominal -> String? in
        let hasBufferInitializer = nominal.memberBlock.members.contains {
            member in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self)
            else { return false }
            let parameters = initializer.signature.parameterClause.parameters
            guard parameters.count == 2 else { return false }
            let first = parameters[parameters.startIndex]
            let second = parameters[parameters.index(after: parameters.startIndex)]
            let pointerType = nominalName(first.type.trimmedDescription)
            return first.firstName.text == "start"
                && pointerTypes.contains(pointerType)
                && second.firstName.text == "count"
                && nominalName(second.type.trimmedDescription) == "Int"
        }
        return hasBufferInitializer ? name : nil
    })

    return UnsafeMemorySurface(
        pointerTypes: pointerTypes.sorted(),
        rawPointerTypes: rawPointerTypes.sorted(),
        bufferTypes: bufferTypes.sorted())
}

let generatedUnsafeMemorySurface = unsafeMemorySurface(in: stdlibFile)
let generatedUnicodeDecodingSurface = unicodeDecodingSurface(in: stdlibFile)
let generatedIntegerIndexCollectionDefaults =
    integerIndexCollectionDefaults(in: stdlibFile)
let generatedOptionalElementCollectionDefaults =
    optionalElementCollectionDefaults(in: stdlibFile)
let generatedOptionalLastRemovalCollectionDefaults =
    optionalLastRemovalCollectionDefaults(in: stdlibFile)
let generatedNativeArrayCarrierIntegerVoidMutations =
    nativeArrayCarrierIntegerVoidMutations(in: stdlibFile)
let generatedRangeRemovalMutations =
    rangeRemovalMutations(in: stdlibFile)

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

═══ View-struct initializers ═══
View structs:           \(viewStructs.count)
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

let emittedSDKEnumTypes = Set(
    (variants + initVariants)
        .flatMap(\.params)
        .compactMap { sdkEnumType(from: $0.tag) })

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

func entryCode(_ variant: Variant) -> String {
    let specs = variant.params
        .map { "ParamSpec(\($0.label.map { "\"\($0)\"" } ?? "nil"), .\($0.tag))" }
        .joined(separator: ", ")
    let argList = variant.params.enumerated()
        .map { index, param in
            let value = param.tag == "builder"
                ? "{ b\(index) }"
                : param.cast.replacingOccurrences(of: "%@", with: "v[\(index)]")
            return (param.label.map { "\($0): " } ?? "") + value
        }
        .joined(separator: ", ")
    var lines = ["    register(&t, \"\(variant.name)\", [\(specs)]) { view, v in"]
    for (index, param) in variant.params.enumerated() where param.tag == "builder" {
        lines.append("        let b\(index) = try generatedBuilder(v[\(index)])")
    }
    lines.append("        return AnyView(view.\(variant.name)(\(argList)))")
    lines.append("    }")
    return compileGuarded(lines.joined(separator: "\n"), for: variant)
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
import SwiftInterpreter
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

func initEntryCode(_ variant: Variant) -> String {
    let specs = variant.params
        .map { "ParamSpec(\($0.label.map { "\"\($0)\"" } ?? "nil"), .\($0.tag))" }
        .joined(separator: ", ")
    let argList = variant.params.enumerated()
        .map { index, param in
            let value = param.tag == "builder"
                ? "{ b\(index) }"
                : param.cast.replacingOccurrences(of: "%@", with: "v[\(index)]")
            return (param.label.map { "\($0): " } ?? "") + value
        }
        .joined(separator: ", ")
    var lines = ["    register(&t, \"\(variant.name)\", [\(specs)]) { v in"]
    for (index, param) in variant.params.enumerated() where param.tag == "builder" {
        lines.append("        let b\(index) = try generatedBuilder(v[\(index)])")
    }
    lines.append("        return AnyView(\(variant.name)(\(argList)))")
    lines.append("    }")
    return compileGuarded(lines.joined(separator: "\n"), for: variant)
}

let sortedInits = initVariants.sorted { ($0.name, $0.params.count) < ($1.name, $1.params.count) }
let initChunks = stride(from: 0, to: sortedInits.count, by: chunkSize).map {
    Array(sortedInits[$0..<min($0 + chunkSize, sortedInits.count)])
}

var viewsOutput = """
// GENERATED by BridgeGen from the SDK's SwiftUICore/SwiftUI swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sortedInits.count) initializer variants across \(Set(sortedInits.map(\.name)).count) View structs.
import SwiftUI
import SwiftInterpreter
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
viewsOutput += "        return t\n    }\n"

for (index, chunk) in initChunks.enumerated() {
    viewsOutput += "\n    private static func build\(index)(_ t: inout [String: [GeneratedConstructor]]) {\n"
    for variant in chunk {
        viewsOutput += initEntryCode(variant) + "\n"
    }
    viewsOutput += "    }\n"
}
viewsOutput += "}\n"

let viewsPath = "Sources/SwiftUIBridge/Generated/GeneratedViews.swift"
try viewsOutput.write(toFile: viewsPath, atomically: true, encoding: .utf8)
print("wrote \(viewsPath) (\(sortedInits.count) variants)")

// MARK: - Emit SDK enum coercions

var enumsOutput = """
// GENERATED by BridgeGen from public, payload-free SwiftUI SDK enum cases.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(emittedSDKEnumTypes.count) enum types.
import SwiftUI
import SwiftInterpreter

enum GeneratedSDKEnumCoercions {
    static func coerce(_ typeName: String, _ value: RuntimeValue) throws -> Any {
        switch typeName {

"""

for type in emittedSDKEnumTypes.sorted() {
    guard let cases = sdkEnumCases[type], !cases.isEmpty else { continue }
    enumsOutput += "        case \"\(type)\":\n"
    enumsOutput += "            if case .host(let any) = value, let typed = any as? \(type) { return typed }\n"
    enumsOutput += "            guard case .implicitMember(let member) = value else {\n"
    enumsOutput += "                throw RuntimeError(message: \"expected a \(type) implicit member\")\n"
    enumsOutput += "            }\n"
    enumsOutput += "            switch member {\n"
    for caseName in cases {
        // Backticks are valid around every identifier and cover SDK cases
        // whose spelling is also a Swift keyword.
        enumsOutput += "            case \"\(caseName)\": return \(type).`\(caseName)`\n"
    }
    enumsOutput += "            default:\n"
    enumsOutput += "                throw RuntimeError(message: \"unknown \(type) member '.\\(member)'\")\n"
    enumsOutput += "            }\n"
}
enumsOutput += """
        default:
            throw RuntimeError(message: "unknown generated SDK enum '\\(typeName)'")
        }
    }
}
"""

let enumsPath = "Sources/SwiftUIBridge/Generated/GeneratedSDKEnums.swift"
try enumsOutput.write(toFile: enumsPath, atomically: true, encoding: .utf8)
print("wrote \(enumsPath) (\(emittedSDKEnumTypes.count) enum types)")

// MARK: - Emit members

/// Array-typed contracts box element-wise into the interpreter's array
/// plane (`DateBins.thresholds`); every other return keeps its host
/// typing. The choice is made HERE at emit time — a type-directed
/// overload would re-rank member resolution inside the emitted closures
/// (Sequence.dropLast beating IndexPath.dropLast).
func memberResultCall(_ returnType: String) -> String {
    returnType.hasPrefix("[") && returnType.hasSuffix("]") && !returnType.contains(":")
        ? "generatedMemberArrayResult" : "generatedMemberResult"
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

let membersPath = "Sources/SwiftUIBridge/Generated/GeneratedMembers.swift"
try membersOutput.write(toFile: membersPath, atomically: true, encoding: .utf8)
print("wrote \(membersPath) (\(sortedProperties.count) properties, \(sortedMembers.count) method variants)")

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

    static func isPointerType(_ name: String) -> Bool {
        pointerTypeNames.contains(canonicalTypeName(name))
    }

    static func isRawPointerType(_ name: String) -> Bool {
        rawPointerTypeNames.contains(canonicalTypeName(name))
    }

    static func isBufferType(_ name: String) -> Bool {
        bufferTypeNames.contains(canonicalTypeName(name))
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
print("wrote \(unsafeMemoryPath) (\(generatedUnsafeMemorySurface.pointerTypes.count) pointer, \(generatedUnsafeMemorySurface.bufferTypes.count) buffer types)")

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
let unicodeDecodingPath =
    "Sources/SwiftInterpreter/Generated/GeneratedUnicodeDecodingSurface.swift"
try unicodeDecodingOutput.write(
    toFile: unicodeDecodingPath, atomically: true, encoding: .utf8)
print(
    "wrote \(unicodeDecodingPath) "
        + "(\(generatedUnicodeDecodingSurface.initializers.count) initializers, "
        + "\(generatedUnicodeDecodingSurface.encodings.count) encodings)")

var collectionDefaultsOutput = """
// GENERATED by BridgeGen from the active Swift standard-library swiftinterface.
// Do not edit. Regenerate: swift run BridgeGen --emit
enum GeneratedCollectionDefaultSurface {
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
    static func property(
        named name: String,
        conformances: Set<String>,
        receiver: RuntimeValue,
        interpreter: Interpreter
    ) throws -> RuntimeValue? {
""" + "\n"
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

    static let nativeArrayCarrierIntegerVoidMutationNames: Set<String> = Set([
        \(Set(generatedNativeArrayCarrierIntegerVoidMutations.map(\.memberName))
            .sorted().map(String.init(reflecting:)).joined(separator: ", "))
    ])

    static func isNativeArrayCarrierIntegerVoidMutation(
        named memberName: String
    ) -> Bool {
        nativeArrayCarrierIntegerVoidMutationNames.contains(memberName)
    }

    @MainActor
    static func invokeNativeArrayCarrierIntegerVoidMutation(
        named name: String,
        arguments: CallArguments,
        array: inout [RuntimeValue]
    ) throws -> Bool {
""" + "\n"
for mutation in generatedNativeArrayCarrierIntegerVoidMutations {
    let argument = mutation.argumentLabel.map {
        "arguments.labeled(\(String(reflecting: $0)))"
    } ?? "arguments.positional(0)"
    let invocationArgument = mutation.argumentLabel.map {
        "\($0): value"
    } ?? "value"
    collectionDefaultsOutput += """
        if name == \(String(reflecting: mutation.memberName)),
           arguments.arguments.count == 1,
           let value = \(argument)?.intValue {
            array.\(mutation.memberName)(\(invocationArgument))
            return true
        }
""" + "\n"
}
collectionDefaultsOutput += """
        if nativeArrayCarrierIntegerVoidMutationNames.contains(name) {
            throw RuntimeError(
                message: "generated native array mutation argument mismatch")
        }
        return false
    }
}
""" + "\n"
let collectionDefaultsPath =
    "Sources/SwiftInterpreter/Generated/GeneratedCollectionDefaultSurface.swift"
try collectionDefaultsOutput.write(
    toFile: collectionDefaultsPath, atomically: true, encoding: .utf8)
print(
    "wrote \(collectionDefaultsPath) "
        + "(\(generatedIntegerIndexCollectionDefaults.count) methods, "
        + "\(generatedOptionalElementCollectionDefaults.count) properties, "
        + "\(generatedOptionalLastRemovalCollectionDefaults.count) optional removals, "
        + "\(generatedNativeArrayCarrierIntegerVoidMutations.count) native array mutations)")

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
print("wrote \(cMemoryPath) (\(cMemoryGeneration.functionNames.count) relative-pointer functions)")

let platformPath = "Sources/SwiftUIBridge/Generated/GeneratedPlatformBridge.swift"
try platformGeneration.output.write(
    toFile: platformPath, atomically: true, encoding: .utf8)
print("wrote \(platformPath)")

// MARK: - Emit compiler-preflight host module

// Real SDK declarations are already the source of every generated gateway.
// Re-exporting those modules lets swiftc consume their complete serialized
// effects and isolation instead of maintaining a lossy declaration copy.
// Only interpreter-synthetic APIs need declarations appended here later.
let requiredPreflightModules = ["_Concurrency", "Foundation", "SwiftUI"]
let conditionalPreflightModules = Array(Set([
    "Combine", "CoreGraphics", "Darwin", "ObjectiveC",
] + platformGeneration.coverage.keys)).sorted()
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
