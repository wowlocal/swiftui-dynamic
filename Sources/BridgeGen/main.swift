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
    case "ButtonRole": return .init(tag: "buttonRole", cast: "%@ as! ButtonRole")
    case "Axis": return .init(tag: "axis", cast: "%@ as! Axis")
    case "[Color]": return .init(tag: "colorArray", cast: "%@ as! [Color]")
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
}

func analyzeParameter(_ param: FunctionParameterSyntax, generics: Generics) -> AnalyzedParam {
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
    if let facts = generics[normalized] {
        switch facts {
        case .concrete(let concrete):
            if let mapping = directMapping(for: concrete) {
                return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault, blocker: "== \(concrete)", usesGeneric: normalized)
        case .constraints(let set):
            if set.count == 1, let mapping = constraintMapping(for: set.first!) {
                return .init(label: label, mapping: mapping, hasDefault: hasDefault, blocker: nil, usesGeneric: normalized)
            }
            return .init(label: label, mapping: nil, hasDefault: hasDefault,
                         blocker: "<\(set.sorted().joined(separator: "&"))>", usesGeneric: normalized)
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

// MARK: - View-struct init sweep

var initVariants: [Variant] = []
var initSeenKeys = Set<String>()
var initTotal = 0
var initGeneratable = 0
var initGuarded = 0
var viewStructs = Set<String>()
var generatableStructs = Set<String>()

/// Struct names never emitted (compile problems or hand-only semantics).
let denyStructs: Set<String> = []

func structGenerics(_ structDecl: StructDeclSyntax) -> Generics {
    var generics: Generics = [:]
    collectGenericClause(structDecl.genericParameterClause, into: &generics)
    collectWhereClause(structDecl.genericWhereClause, into: &generics)
    return generics
}

func processInit(_ structName: String, _ initDecl: InitializerDeclSyntax, generics baseGenerics: Generics, guarded: Bool) {
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
        blockers["variadic", default: 0] += 1
        return
    }
    let analyzed = parameters.map { analyzeParameter($0, generics: generics) }
    let genericUses = analyzed.compactMap(\.usesGeneric)
    if Set(genericUses).count != genericUses.count {
        blockers["<shared generic>", default: 0] += 1
        return
    }
    if let firstBlocked = analyzed.first(where: { $0.mapping == nil && !$0.hasDefault }) {
        blockers[firstBlocked.blocker ?? "?", default: 0] += 1
        return
    }
    if guarded || needsAvailabilityGuard(initDecl.attributes) {
        initGuarded += 1
        return
    }
    initGeneratable += 1
    generatableStructs.insert(structName)
    guard !denyStructs.contains(structName) else { return }

    let maxLen = analyzed.prefix(while: { $0.mapping != nil }).count
    var cut = maxLen
    while true {
        if analyzed[cut...].allSatisfy(\.hasDefault) {
            let slice = analyzed[..<cut]
            let variant = Variant(
                name: structName,
                params: slice.map { .init(label: $0.label, tag: $0.mapping!.tag, cast: $0.mapping!.cast) }
            )
            if initSeenKeys.insert(variant.key).inserted {
                initVariants.append(variant)
            }
        }
        guard cut > 0, analyzed[cut - 1].hasDefault else { break }
        cut -= 1
    }
}

// Pass A: View-extension modifiers + View structs (recording their generics
// so pass B can process extension-declared inits, where most of them live).
var viewStructInfo: [String: (generics: Generics, guarded: Bool)] = [:]

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
                processModifier(function, guarded: extGuarded)
            }
        }

        if let structDecl = decl.as(StructDeclSyntax.self),
           isUsable(structDecl.attributes),
           !structDecl.name.text.hasPrefix("_"),
           structDecl.inheritanceClause?.inheritedTypes.contains(where: {
               normalize($0.type.trimmedDescription) == "View"
           }) == true {
            let name = structDecl.name.text
            viewStructs.insert(name)
            let guarded = needsAvailabilityGuard(structDecl.attributes)
            let generics = structGenerics(structDecl)
            viewStructInfo[name] = (generics, guarded)
            for member in structDecl.memberBlock.members {
                guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                      isUsable(initDecl.attributes) else { continue }
                processInit(name, initDecl, generics: generics, guarded: guarded)
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
        for member in ext.memberBlock.members {
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                  isUsable(initDecl.attributes) else { continue }
            processInit(extendedName, initDecl, generics: generics, guarded: guarded)
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

═══ View-struct initializers ═══
View structs:           \(viewStructs.count)
total inits:            \(initTotal)
generatable inits:      \(initGeneratable)  (across \(generatableStructs.count) structs)
newer-OS (skipped):     \(initGuarded)
emitted variants:       \(initVariants.count)

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

// MARK: - Emit constructors

func initEntryCode(_ variant: Variant) -> String {
    let specs = variant.params
        .map { "ParamSpec(\($0.label.map { "\"\($0)\"" } ?? "nil"), .\($0.tag))" }
        .joined(separator: ", ")
    let argList = variant.params.enumerated()
        .map { index, param in
            (param.label.map { "\($0): " } ?? "") + param.cast.replacingOccurrences(of: "%@", with: "v[\(index)]")
        }
        .joined(separator: ", ")
    return """
        register(&t, "\(variant.name)", [\(specs)]) { v in
            AnyView(\(variant.name)(\(argList)))
        }
    """
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
