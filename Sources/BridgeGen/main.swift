import Foundation
import SwiftParser
import SwiftSyntax

// BridgeGen: parse the SDK's SwiftUICore + SwiftUI interfaces, classify every
// `extension View` modifier against the bridge's coercible-type whitelist,
// report coverage, and (with --emit) generate statically-compiled gateway
// tables. Generated calls compile against the real SDK, so a wrong signature
// fails at build time, never in a user session.

let emitMode = CommandLine.arguments.contains("--emit")

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

func interfacePath(framework: String) -> String? {
    let moduleDir = "\(sdk)/System/Library/Frameworks/\(framework).framework/Modules/\(framework).swiftmodule"
    let candidates = (try? FileManager.default.contentsOfDirectory(atPath: moduleDir)) ?? []
    guard let name = candidates.first(where: { $0.hasSuffix("-apple-macos.swiftinterface") }) else {
        return nil
    }
    return "\(moduleDir)/\(name)"
}

let interfaceFiles = ["SwiftUICore", "SwiftUI"].compactMap { framework -> SourceFileSyntax? in
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
    "UniformTypeIdentifiers.", "CoreFoundation.", "CoreGraphics.",
    "Observation.", "SwiftUICore.", "Foundation.", "CoreData.", "SwiftUI.",
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
}

func directMapping(for normalized: String) -> TypeMapping? {
    switch normalized {
    case "String", "StringProtocol": return .init(tag: "string", cast: "%@ as! String")
    case "LocalizedStringKey": return .init(tag: "string", cast: "LocalizedStringKey(%@ as! String)")
    case "Text": return .init(tag: "string", cast: "Text(%@ as! String)")
    case "Bool": return .init(tag: "bool", cast: "%@ as! Bool")
    case "Int": return .init(tag: "int", cast: "%@ as! Int")
    case "Double": return .init(tag: "double", cast: "%@ as! Double")
    case "CGFloat": return .init(tag: "cgFloat", cast: "%@ as! CGFloat")
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
    case "Visibility": return .init(tag: "visibility", cast: "%@ as! Visibility")
    case "Axis.Set": return .init(tag: "axisSet", cast: "%@ as! Axis.Set")
    case "EdgeInsets": return .init(tag: "edgeInsets", cast: "%@ as! EdgeInsets")
    case "Gradient": return .init(tag: "gradient", cast: "%@ as! Gradient")
    case "[GridItem]": return .init(tag: "gridItems", cast: "%@ as! [GridItem]")
    case "Binding<Bool>": return .init(tag: "bindingBool", cast: "%@ as! Binding<Bool>")
    case "Binding<String>": return .init(tag: "bindingString", cast: "%@ as! Binding<String>")
    case "Binding<Double>": return .init(tag: "bindingDouble", cast: "%@ as! Binding<Double>")
    case "AnyShapeStyle": return .init(tag: "shapeStyle", cast: "%@ as! AnyShapeStyle")
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

// MARK: - Parameter analysis

struct AnalyzedParam {
    let label: String?
    let mapping: TypeMapping?
    let hasDefault: Bool
    let blocker: String?
    let usesGeneric: String?
}

func analyzeParameter(_ param: FunctionParameterSyntax, generics: [String: String]) -> AnalyzedParam {
    let labelText = param.firstName.text
    let label: String? = labelText == "_" ? nil : labelText
    let hasDefault = param.defaultValue != nil

    var type = param.type
    var isBuilder = false
    var isAutoclosure = false
    if let attributed = type.as(AttributedTypeSyntax.self) {
        for attribute in attributed.attributes {
            let name = attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription ?? ""
            if name.hasSuffix("ViewBuilder") { isBuilder = true }
            if name == "autoclosure" { isAutoclosure = true }
        }
        type = attributed.baseType
    }
    var normalized = normalize(type.trimmedDescription)
    if normalized.hasSuffix("?") { normalized = String(normalized.dropLast()) }

    if isAutoclosure {
        return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "@autoclosure", usesGeneric: nil)
    }
    if isBuilder {
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
    if let mapping = directMapping(for: normalized) {
        return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: nil)
    }
    if let constraint = generics[normalized] {
        if let mapping = constraintMapping(for: constraint) {
            return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized)
        }
        return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "<\(constraint)>", usesGeneric: normalized)
    }
    return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: normalized, usesGeneric: nil)
}

func genericConstraints(of function: FunctionDeclSyntax) -> [String: String] {
    var constraints: [String: String] = [:]
    if let clause = function.genericParameterClause {
        for parameter in clause.parameters {
            constraints[parameter.name.text] = normalize(parameter.inheritedType?.trimmedDescription ?? "")
        }
    }
    if let whereClause = function.genericWhereClause {
        for requirement in whereClause.requirements {
            if let conformance = requirement.requirement.as(ConformanceRequirementSyntax.self) {
                constraints[normalize(conformance.leftType.trimmedDescription)] =
                    normalize(conformance.rightType.trimmedDescription)
            }
        }
    }
    return constraints
}

// MARK: - Availability

func isUsable(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let text = attr.trimmedDescription
        if text.contains("unavailable") || text.contains("deprecated") || text.contains("obsoleted") {
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

// MARK: - Sweep

struct EmittableParam {
    let label: String?
    let tag: String
    let cast: String
}

struct Variant {
    let name: String
    let params: [EmittableParam]

    var key: String {
        name + "|" + params.map { "\($0.label ?? "_"):\($0.tag)" }.joined(separator: ",")
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
var blockers: [String: Int] = [:]

func acceptableModifierReturn(_ type: String) -> Bool {
    let normalized = normalize(type)
    return normalized.contains("some View") || normalized.hasPrefix("ModifiedContent<")
}

func processModifier(_ function: FunctionDeclSyntax, guarded: Bool) {
    let name = function.name.text
    guard !name.hasPrefix("_") else { return } // SPI-adjacent underscore APIs
    modifierTotal += 1
    modifierNames.insert(name)

    let generics = genericConstraints(of: function)
    let parameters = function.signature.parameterClause.parameters
    if parameters.contains(where: { $0.ellipsis != nil }) {
        blockers["variadic", default: 0] += 1
        return
    }
    let analyzed = parameters.map { analyzeParameter($0, generics: generics) }

    // A generic used by more than one parameter can't be instantiated
    // independently per-argument — skip those signatures.
    let genericUses = analyzed.compactMap(\.usesGeneric)
    if Set(genericUses).count != genericUses.count {
        blockers["<shared generic>", default: 0] += 1
        return
    }

    if let firstBlocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        blockers[firstBlocked.blocker ?? "?", default: 0] += 1
        return
    }
    if guarded || needsAvailabilityGuard(function.attributes) {
        modifierGuarded += 1
        return
    }
    modifierGeneratable += 1
    generatableNames.insert(name)
    guard !denyNames.contains(name) else { return }

    // Emit suffix-default variants: the full mappable prefix, then shorter
    // prefixes as trailing defaulted params drop off (Swift call shapes).
    let maxLen = analyzed.prefix(while: { $0.mapping != nil }).count
    var cut = maxLen
    while true {
        if cut == maxLen || analyzed[cut...].allSatisfy(\.hasDefault) {
            if analyzed[cut...].allSatisfy(\.hasDefault) {
                let slice = analyzed[..<cut]
                let variant = Variant(
                    name: name,
                    params: slice.map { .init(label: $0.label, tag: $0.mapping!.tag, cast: $0.mapping!.cast) }
                )
                if seenKeys.insert(variant.key).inserted {
                    variants.append(variant)
                }
            }
        }
        guard cut > 0, analyzed[cut - 1].hasDefault else { break }
        cut -= 1
    }
}

for file in interfaceFiles {
    for statement in file.statements {
        guard case .decl(let decl) = statement.item else { continue }
        guard let ext = decl.as(ExtensionDeclSyntax.self),
              normalize(ext.extendedType.trimmedDescription) == "View",
              isUsable(ext.attributes) else { continue }
        let extGuarded = needsAvailabilityGuard(ext.attributes)
        for member in ext.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                  isUsable(function.attributes),
                  let returnType = function.signature.returnClause?.type.trimmedDescription,
                  acceptableModifierReturn(returnType) else { continue }
            processModifier(function, guarded: extGuarded)
        }
    }
}

// MARK: - Report

print("""

═══ View-extension modifiers ═══
total overloads:        \(modifierTotal)  (\(modifierNames.count) distinct names)
generatable overloads:  \(modifierGeneratable)  (\(generatableNames.count) distinct names)
newer-OS (skipped):     \(modifierGuarded)
emitted variants:       \(variants.count)

═══ Top blocking types ═══
""")
for (type, count) in blockers.sorted(by: { $0.value > $1.value }).prefix(25) {
    print(String(format: "%5d  %@", count, type))
}

// MARK: - Emit

guard emitMode else { exit(0) }

func entryCode(_ variant: Variant) -> String {
    let specs = variant.params
        .map { "ParamSpec(\($0.label.map { "\"\($0)\"" } ?? "nil"), .\($0.tag))" }
        .joined(separator: ", ")
    let argList = variant.params.enumerated()
        .map { index, param in
            (param.label.map { "\($0): " } ?? "") + param.cast.replacingOccurrences(of: "%@", with: "v[\(index)]")
        }
        .joined(separator: ", ")
    return """
        register(&t, "\(variant.name)", [\(specs)]) { view, v in
            AnyView(view.\(variant.name)(\(argList)))
        }
    """
}

let sorted = variants.sorted { ($0.name, $0.params.count) < ($1.name, $1.params.count) }
let chunkSize = 40
let chunks = stride(from: 0, to: sorted.count, by: chunkSize).map {
    Array(sorted[$0..<min($0 + chunkSize, sorted.count)])
}

var output = """
// GENERATED by BridgeGen from the SDK's SwiftUICore/SwiftUI swiftinterfaces.
// Do not edit. Regenerate: swift run BridgeGen --emit
// \(sorted.count) modifier overload variants across \(Set(sorted.map(\.name)).count) names.
import SwiftUI
import SwiftInterpreter

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
