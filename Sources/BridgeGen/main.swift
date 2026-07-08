import Foundation
import SwiftParser
import SwiftSyntax

// BridgeGen phase 1: feasibility report.
//
// Parses the SDK's SwiftUI.swiftinterface (the same trick Bitrig describes)
// and classifies every `extension View` modifier and every View-struct init
// against the interpreter's coercible-type whitelist. The output tells us
// exactly how many gateways generation would yield today, and which types to
// teach the coercion layer next.

// MARK: - Locate the interface

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

/// Modern SDKs split the API surface: core views/modifiers live in
/// SwiftUICore, the rest in SwiftUI. Sweep both interfaces.
func interfacePath(framework: String) -> String? {
    let moduleDir = "\(sdk)/System/Library/Frameworks/\(framework).framework/Modules/\(framework).swiftmodule"
    let candidates = (try? FileManager.default.contentsOfDirectory(atPath: moduleDir)) ?? []
    guard let name = candidates.first(where: { $0.hasSuffix("-apple-macos.swiftinterface") }) else {
        return nil
    }
    return "\(moduleDir)/\(name)"
}

let interfaceFiles = ["SwiftUICore", "SwiftUI"].compactMap { framework -> SourceFileSyntax? in
    guard let path = interfacePath(framework: framework) else {
        print("warning: no swiftinterface for \(framework)")
        return nil
    }
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    print("parsing \(framework) (\(source.count) chars)…")
    return Parser.parse(source: source)
}

// MARK: - Type classification

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

/// Types the bridge can already coerce from RuntimeValue.
let coercibleTypes: Set<String> = [
    "String", "LocalizedStringKey", "Bool", "Int", "Double", "CGFloat",
    "Color", "Font", "Font.Weight", "Angle", "Animation", "Animation?",
    "Alignment", "HorizontalAlignment", "VerticalAlignment", "TextAlignment",
    "Edge.Set", "UnitPoint", "ContentMode", "Image.Scale", "ButtonRole?",
    "Binding<Bool>", "Binding<String>", "Binding<Double>",
    "GridItem", "[GridItem]", "[Color]", "AnyShapeStyle", "ButtonRole",
]

/// Generic constraints we can instantiate at a concrete type.
let coercibleConstraints: Set<String> = [
    "ShapeStyle", "View", "StringProtocol", "BinaryFloatingPoint", "Shape",
    "InsettableShape", "Equatable",
]

struct ParamVerdict {
    let ok: Bool
    let blocker: String?
}

func classifyParameter(
    _ param: FunctionParameterSyntax,
    generics: [String: String]
) -> ParamVerdict {
    if param.defaultValue != nil {
        return ParamVerdict(ok: true, blocker: nil) // omittable
    }
    var type = param.type
    var isBuilder = false
    if let attributed = type.as(AttributedTypeSyntax.self) {
        isBuilder = attributed.attributes.contains {
            let name = $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription ?? ""
            return name.hasSuffix("ViewBuilder")
        }
        type = attributed.baseType
    }
    let normalized = normalize(type.trimmedDescription)
    if isBuilder {
        return ParamVerdict(ok: true, blocker: nil)
    }
    if normalized == "() -> Void" || normalized == "@escaping () -> Void" {
        return ParamVerdict(ok: true, blocker: nil) // action closure
    }
    if coercibleTypes.contains(normalized) {
        return ParamVerdict(ok: true, blocker: nil)
    }
    // Optional of a coercible type
    if normalized.hasSuffix("?"), coercibleTypes.contains(String(normalized.dropLast())) {
        return ParamVerdict(ok: true, blocker: nil)
    }
    // A bare generic parameter with a whitelisted constraint
    if let constraint = generics[normalized] {
        if coercibleConstraints.contains(constraint) {
            return ParamVerdict(ok: true, blocker: nil)
        }
        return ParamVerdict(ok: false, blocker: "<\(constraint)>")
    }
    return ParamVerdict(ok: false, blocker: normalized)
}

func genericConstraints(of function: FunctionDeclSyntax) -> [String: String] {
    var constraints: [String: String] = [:]
    if let clause = function.genericParameterClause {
        for parameter in clause.parameters {
            if let inherited = parameter.inheritedType {
                constraints[parameter.name.text] = normalize(inherited.trimmedDescription)
            } else {
                constraints[parameter.name.text] = ""
            }
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

/// The package's deployment target; newer APIs would need availability guards.
let deploymentTarget = 15

func needsAvailabilityGuard(_ attributes: AttributeListSyntax) -> Bool {
    for attribute in attributes {
        guard let attr = attribute.as(AttributeSyntax.self),
              attr.attributeName.trimmedDescription == "available" else { continue }
        let text = attr.trimmedDescription
        guard let range = text.range(of: "macOS ") else { continue }
        let version = text[range.upperBound...].prefix { $0.isNumber }
        if let major = Int(version), major > deploymentTarget { return true }
    }
    return false
}

// MARK: - Sweep

var modifierTotal = 0
var modifierGeneratable = 0
var modifierGuarded = 0
var modifierNames = Set<String>()
var generatableNames = Set<String>()
var blockers: [String: Int] = [:]

var initTotal = 0
var initGeneratable = 0
var viewStructs = Set<String>()
var generatableStructs = Set<String>()

func acceptableModifierReturn(_ type: String) -> Bool {
    let normalized = normalize(type)
    return normalized.contains("some View") || normalized.hasPrefix("ModifiedContent<")
}

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
                modifierTotal += 1
                modifierNames.insert(function.name.text)
                let generics = genericConstraints(of: function)
                var firstBlocker: String?
                for parameter in function.signature.parameterClause.parameters {
                    let verdict = classifyParameter(parameter, generics: generics)
                    if !verdict.ok {
                        firstBlocker = verdict.blocker
                        break
                    }
                }
                if let firstBlocker {
                    blockers[firstBlocker, default: 0] += 1
                } else if extGuarded || needsAvailabilityGuard(function.attributes) {
                    modifierGuarded += 1
                } else {
                    modifierGeneratable += 1
                    generatableNames.insert(function.name.text)
                }
            }
        }

        if let structDecl = decl.as(StructDeclSyntax.self),
           isUsable(structDecl.attributes),
           !needsAvailabilityGuard(structDecl.attributes),
           structDecl.inheritanceClause?.inheritedTypes.contains(where: {
               normalize($0.type.trimmedDescription) == "View"
           }) == true {
            viewStructs.insert(structDecl.name.text)
            for member in structDecl.memberBlock.members {
                guard let initDecl = member.decl.as(InitializerDeclSyntax.self),
                      isUsable(initDecl.attributes) else { continue }
                initTotal += 1
                var generics: [String: String] = [:]
                if let clause = initDecl.genericParameterClause {
                    for parameter in clause.parameters {
                        generics[parameter.name.text] = normalize(parameter.inheritedType?.trimmedDescription ?? "")
                    }
                }
                var blocked = false
                for parameter in initDecl.signature.parameterClause.parameters {
                    let verdict = classifyParameter(parameter, generics: generics)
                    if !verdict.ok {
                        blockers[verdict.blocker ?? "?", default: 0] += 1
                        blocked = true
                        break
                    }
                }
                if !blocked {
                    initGeneratable += 1
                    generatableStructs.insert(structDecl.name.text)
                }
            }
        }
    }
}

// MARK: - Report

print("""

═══ View-extension modifiers (returning some View / ModifiedContent) ═══
total overloads:        \(modifierTotal)  (\(modifierNames.count) distinct names)
generatable overloads:  \(modifierGeneratable)  (\(generatableNames.count) distinct names)
newer-OS (need guard):  \(modifierGuarded)

═══ View-struct initializers ═══
View structs:           \(viewStructs.count)
total inits:            \(initTotal)
generatable inits:      \(initGeneratable)  (across \(generatableStructs.count) structs)

═══ Top blocking types (add coercions here for the biggest wins) ═══
""")
for (type, count) in blockers.sorted(by: { $0.value > $1.value }).prefix(30) {
    print(String(format: "%5d  %@", count, type))
}
