import Foundation
import SwiftParser
import SwiftSyntax

struct PlatformCoverageSection: Encodable {
    let scannedSymbols: Int
    let selectedTypes: Int
    let emittedConstructors: Int
    let emittedProperties: Int
    let emittedMethods: Int
    let emittedStaticProperties: Int
    let emittedStaticMethods: Int
    let emittedEnumValues: Int
    let emittedSignatures: [String]
    let blockers: [String: Int]
}

struct PlatformGenerationResult {
    let output: String
    let coverage: [String: PlatformCoverageSection]
    let summaries: [String]
}

private struct PlatformFrameworkSpec {
    let name: String
    let sdkName: String
    let target: String
    let availabilityDomain: String
    let deploymentMajor: Int
    let deploymentMinor: Int
    let roots: Set<String>
}

/// Type-level policy, not a member allowlist: once a type is selected, every
/// mechanically bridgeable public constructor/member is emitted from SDK
/// metadata. These are the platform primitives that interpreted SwiftUI apps
/// most often use directly; adding another type grows its whole surface.
private let platformFrameworkSpecs: [PlatformFrameworkSpec] = [
    .init(
        name: "AppKit", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        availabilityDomain: "macOS", deploymentMajor: 15, deploymentMinor: 0,
        roots: [
            "NSApplication", "NSResponder", "NSWindow", "NSScreen",
            "NSView", "NSControl", "NSViewController", "NSAppearance",
            "NSColor", "NSFont", "NSImage", "NSBezierPath",
            "NSDirectionalEdgeInsets", "NSButton", "NSImageView",
            "NSScrollView", "NSTableView", "NSCollectionView",
            "NSTextField", "NSTextView",
        ]),
    .init(
        name: "UIKit", sdkName: "iphoneos",
        target: "arm64-apple-ios18.0",
        availabilityDomain: "iOS", deploymentMajor: 18, deploymentMinor: 0,
        roots: [
            "UIApplication", "UIResponder", "UIWindow", "UIWindowScene",
            "UIScreen", "UIView", "UIControl", "UIViewController",
            "UIColor", "UIFont", "UIImage", "UIBezierPath",
            "UIEdgeInsets", "UIOffset", "NSDirectionalEdgeInsets",
            "UIButton", "UIImageView", "UILabel", "UIScrollView",
            "UITableView", "UICollectionView", "UITextField", "UITextView",
        ]),
]

private struct SymbolGraph: Decodable {
    let symbols: [Symbol]
    let relationships: [Relationship]

    struct Symbol: Decodable {
        struct Identifier: Decodable { let precise: String }
        struct Kind: Decodable { let identifier: String }
        struct Fragment: Decodable {
            let kind: String
            let spelling: String
            let preciseIdentifier: String?
        }
        struct Availability: Decodable {
            struct Version: Decodable {
                let major: Int
                let minor: Int?
            }
            let domain: String
            let introduced: Version?
            let deprecated: Version?
            let obsoleted: Version?
            let isUnconditionallyUnavailable: Bool?
        }

        let identifier: Identifier
        let kind: Kind
        let pathComponents: [String]
        let declarationFragments: [Fragment]?
        let availability: [Availability]?

        var declaration: String {
            declarationFragments?.map(\.spelling).joined() ?? ""
        }
    }

    struct Relationship: Decodable {
        let source: String
        let target: String
        let kind: String
    }
}

private enum PlatformNominalKind: String {
    case `class`, `struct`, `enum`

    var isValueType: Bool { self != .class }
}

private struct PlatformNominal {
    let framework: String
    let precise: String
    let type: String
    let root: String
    let kind: PlatformNominalKind
}

private struct PlatformParameter {
    let label: String?
    let type: String
    let hasDefault: Bool
    let isAction: Bool
}

private struct PlatformCallable {
    enum Kind { case constructor, method, staticMethod }

    let framework: String
    let kind: Kind
    let receiverType: String
    let receiverIsValueType: Bool
    let name: String
    let resultType: String
    let params: [PlatformParameter]
    let isThrowing: Bool
    let isFailable: Bool

    var declaration: String {
        let parameters = params.enumerated().map { index, param in
            "\(param.label ?? "_") p\(index): \(param.type)"
        }.joined(separator: ", ")
        let effects = isThrowing ? " throws" : ""
        switch kind {
        case .constructor:
            return "init\(isFailable ? "?" : "") \(receiverType)(\(parameters))\(effects)"
        case .method:
            return "func \(receiverType).\(name)(\(parameters))\(effects) -> \(resultType)"
        case .staticMethod:
            return "static func \(receiverType).\(name)(\(parameters))\(effects) -> \(resultType)"
        }
    }

    var signatureKey: String { "\(framework)|\(declaration)" }
}

private struct PlatformProperty {
    let framework: String
    let receiverType: String
    let receiverIsValueType: Bool
    let name: String
    let resultType: String
    let isSettable: Bool
    let isStatic: Bool

    var declaration: String {
        let prefix = isStatic ? "static var" : "var"
        let accessors = isSettable ? " { get set }" : " { get }"
        return "\(prefix) \(receiverType).\(name): \(resultType)\(accessors)"
    }

    var signatureKey: String { "\(framework)|\(declaration)" }
}

private struct PlatformEnumValue {
    let framework: String
    let type: String
    let name: String
}

private struct PlatformKnownMember {
    let framework: String
    let type: String
    let name: String
    let isCallable: Bool
}

private struct ParsedPlatformFramework {
    let spec: PlatformFrameworkSpec
    let graph: SymbolGraph
    let nominals: [String: PlatformNominal]
    let supertypeByType: [String: String]
    let constructors: [PlatformCallable]
    let methods: [PlatformCallable]
    let staticMethods: [PlatformCallable]
    let properties: [PlatformProperty]
    let staticProperties: [PlatformProperty]
    let enumValues: [PlatformEnumValue]
    let knownMembers: [PlatformKnownMember]
    let blockers: [String: Int]
}

func generatePlatformBridge() throws -> PlatformGenerationResult {
    let parsed = try platformFrameworkSpecs.map(parsePlatformFramework)
    let output = emitPlatformBridge(parsed)
    var coverage: [String: PlatformCoverageSection] = [:]
    var summaries: [String] = []
    for framework in parsed {
        let signatures = (
            framework.constructors.map(\.signatureKey)
                + framework.methods.map(\.signatureKey)
                + framework.staticMethods.map(\.signatureKey)
                + framework.properties.map(\.signatureKey)
                + framework.staticProperties.map(\.signatureKey)
        ).sorted()
        coverage[framework.spec.name] = PlatformCoverageSection(
            scannedSymbols: framework.graph.symbols.count,
            selectedTypes: framework.nominals.count,
            emittedConstructors: framework.constructors.count,
            emittedProperties: framework.properties.count,
            emittedMethods: framework.methods.count,
            emittedStaticProperties: framework.staticProperties.count,
            emittedStaticMethods: framework.staticMethods.count,
            emittedEnumValues: framework.enumValues.count,
            emittedSignatures: signatures,
            blockers: framework.blockers)
        summaries.append(
            "\(framework.spec.name): \(framework.nominals.count) types, "
                + "\(framework.constructors.count) constructors, "
                + "\(framework.properties.count + framework.staticProperties.count) properties, "
                + "\(framework.methods.count + framework.staticMethods.count) methods, "
                + "\(framework.enumValues.count) contextual values")
    }
    return PlatformGenerationResult(
        output: output, coverage: coverage, summaries: summaries)
}

private func parsePlatformFramework(
    _ spec: PlatformFrameworkSpec
) throws -> ParsedPlatformFramework {
    let graphURL = try platformSymbolGraphURL(for: spec)
    let graph = try JSONDecoder().decode(
        SymbolGraph.self, from: Data(contentsOf: graphURL))

    let nominalKindBySymbolKind: [String: PlatformNominalKind] = [
        "swift.class": .class,
        "swift.struct": .struct,
        "swift.enum": .enum,
    ]
    var allNominals: [String: PlatformNominal] = [:]
    for symbol in graph.symbols {
        guard let kind = nominalKindBySymbolKind[symbol.kind.identifier],
              !symbol.pathComponents.isEmpty,
              platformSymbolIsAvailable(symbol, for: spec),
              !symbol.declaration.contains("<") else { continue }
        let type = symbol.pathComponents.joined(separator: ".")
        allNominals[symbol.identifier.precise] = PlatformNominal(
            framework: spec.name,
            precise: symbol.identifier.precise,
            type: type,
            root: symbol.pathComponents[0],
            kind: kind)
    }

    let selected = allNominals.filter { spec.roots.contains($0.value.root) }
    let selectedTypes = Set(selected.values.map(\.type))
    var parentByMember: [String: String] = [:]
    for relationship in graph.relationships where relationship.kind == "memberOf" {
        parentByMember[relationship.source] = relationship.target
    }
    var supertypeByType: [String: String] = [:]
    for relationship in graph.relationships where relationship.kind == "inheritsFrom" {
        guard let child = selected[relationship.source],
              let parent = allNominals[relationship.target] else { continue }
        supertypeByType[child.type] = parent.type
    }

    var blockers: [String: Int] = [:]
    var constructors: [PlatformCallable] = []
    var methods: [PlatformCallable] = []
    var staticMethods: [PlatformCallable] = []
    var properties: [PlatformProperty] = []
    var staticProperties: [PlatformProperty] = []
    var enumValues: [PlatformEnumValue] = []
    var knownMembersByKey: [String: PlatformKnownMember] = [:]
    var callableSeen = Set<String>()
    var propertySeen = Set<String>()
    var enumSeen = Set<String>()

    for symbol in graph.symbols {
        guard platformSymbolIsAvailable(symbol, for: spec),
              let parentID = parentByMember[symbol.identifier.precise],
              let nominal = selected[parentID] else { continue }

        if ["swift.method", "swift.property"].contains(symbol.kind.identifier),
           let name = platformSymbolBaseName(symbol) {
            let key = "\(spec.name)|\(nominal.type)|\(name)"
            let callable = symbol.kind.identifier == "swift.method"
                || knownMembersByKey[key]?.isCallable == true
            knownMembersByKey[key] = PlatformKnownMember(
                framework: spec.name, type: nominal.type,
                name: name, isCallable: callable)
        }

        switch symbol.kind.identifier {
        case "swift.init":
            guard let initDecl = parsePlatformDecl(symbol.declaration)?
                .as(InitializerDeclSyntax.self) else {
                blockers["unparsed initializer", default: 0] += 1
                continue
            }
            guard initDecl.genericParameterClause == nil,
                  initDecl.genericWhereClause == nil,
                  initDecl.optionalMark == nil else {
                blockers["generic/failable initializer", default: 0] += 1
                continue
            }
            let effects = initDecl.signature.effectSpecifiers?.trimmedDescription ?? ""
            guard !effects.contains("async") else {
                blockers["async", default: 0] += 1
                continue
            }
            guard !initDecl.signature.parameterClause.parameters.contains(where: {
                $0.ellipsis != nil
            }) else {
                blockers["variadic", default: 0] += 1
                continue
            }
            guard let analyzed = analyzePlatformParameters(
                initDecl.signature.parameterClause.parameters,
                framework: spec.name,
                selectedTypes: selectedTypes,
                blockers: &blockers) else { continue }
            for selection in platformParameterSelections(analyzed) {
                let callable = PlatformCallable(
                    framework: spec.name, kind: .constructor,
                    receiverType: nominal.type,
                    receiverIsValueType: nominal.kind.isValueType,
                    name: nominal.type,
                    resultType: nominal.type,
                    params: selection,
                    isThrowing: effects.contains("throws") || effects.contains("rethrows"),
                    isFailable: false)
                if callableSeen.insert(callable.signatureKey).inserted {
                    constructors.append(callable)
                }
            }

        case "swift.method", "swift.type.method":
            guard let function = parsePlatformDecl(symbol.declaration)?
                .as(FunctionDeclSyntax.self) else {
                blockers["unparsed method", default: 0] += 1
                continue
            }
            let name = platformIdentifier(function.name.text)
            guard name.first?.isLetter == true, !name.hasPrefix("_") else { continue }
            guard function.genericParameterClause == nil,
                  function.genericWhereClause == nil else {
                blockers["generic", default: 0] += 1
                continue
            }
            let effects = function.signature.effectSpecifiers?.trimmedDescription ?? ""
            guard !effects.contains("async") else {
                blockers["async", default: 0] += 1
                continue
            }
            guard !function.modifiers.contains(where: {
                ["mutating", "consuming"].contains($0.name.text)
            }) else {
                blockers["mutating method", default: 0] += 1
                continue
            }
            guard !function.signature.parameterClause.parameters.contains(where: {
                $0.ellipsis != nil
            }) else {
                blockers["variadic", default: 0] += 1
                continue
            }
            let resultType = function.signature.returnClause.map {
                platformContractType(normalize($0.type.trimmedDescription))
            } ?? "Void"
            guard platformTypeIsSupported(
                resultType, framework: spec.name,
                selectedTypes: selectedTypes) else {
                blockers["return \(resultType)", default: 0] += 1
                continue
            }
            guard let analyzed = analyzePlatformParameters(
                function.signature.parameterClause.parameters,
                framework: spec.name,
                selectedTypes: selectedTypes,
                blockers: &blockers) else { continue }
            let kind: PlatformCallable.Kind = symbol.kind.identifier == "swift.type.method"
                ? .staticMethod : .method
            for selection in platformParameterSelections(analyzed) {
                let callable = PlatformCallable(
                    framework: spec.name, kind: kind,
                    receiverType: nominal.type,
                    receiverIsValueType: nominal.kind.isValueType,
                    name: name, resultType: resultType,
                    params: selection,
                    isThrowing: effects.contains("throws") || effects.contains("rethrows"),
                    isFailable: false)
                if callableSeen.insert(callable.signatureKey).inserted {
                    if kind == .staticMethod {
                        staticMethods.append(callable)
                    } else {
                        methods.append(callable)
                    }
                }
            }

        case "swift.property", "swift.type.property":
            guard let variable = parsePlatformDecl(symbol.declaration)?
                .as(VariableDeclSyntax.self),
                  let binding = variable.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let rawType = binding.typeAnnotation?.type.trimmedDescription else {
                blockers["unparsed property", default: 0] += 1
                continue
            }
            let name = platformIdentifier(pattern.identifier.text)
            guard !name.hasPrefix("_") else { continue }
            let resultType = platformContractType(normalize(rawType))
            guard platformTypeIsSupported(
                resultType, framework: spec.name,
                selectedTypes: selectedTypes) else {
                blockers["property \(resultType)", default: 0] += 1
                continue
            }
            let isStatic = symbol.kind.identifier == "swift.type.property"
            let isSettable = !isStatic && platformPropertyIsSettable(variable)
            let property = PlatformProperty(
                framework: spec.name,
                receiverType: nominal.type,
                receiverIsValueType: nominal.kind.isValueType,
                name: name, resultType: resultType,
                isSettable: isSettable, isStatic: isStatic)
            if propertySeen.insert(property.signatureKey).inserted {
                if isStatic { staticProperties.append(property) }
                else { properties.append(property) }
            }
            if isStatic, resultType == nominal.type {
                let key = "\(spec.name)|\(nominal.type)|\(name)"
                if enumSeen.insert(key).inserted {
                    enumValues.append(.init(
                        framework: spec.name, type: nominal.type, name: name))
                }
            }

        case "swift.enum.case":
            guard nominal.kind == .enum,
                  let rawName = symbol.pathComponents.last,
                  case let name = platformIdentifier(rawName),
                  !name.contains("("), name.first?.isLetter == true else { continue }
            let key = "\(spec.name)|\(nominal.type)|\(name)"
            if enumSeen.insert(key).inserted {
                enumValues.append(.init(
                    framework: spec.name, type: nominal.type, name: name))
            }

        default:
            continue
        }
    }

    return ParsedPlatformFramework(
        spec: spec, graph: graph, nominals: selected,
        supertypeByType: supertypeByType,
        constructors: constructors,
        methods: methods,
        staticMethods: staticMethods,
        properties: properties,
        staticProperties: staticProperties,
        enumValues: enumValues,
        knownMembers: knownMembersByKey.values.sorted {
            ($0.type, $0.name) < ($1.type, $1.name)
        },
        blockers: blockers)
}

private func platformSymbolGraphURL(
    for spec: PlatformFrameworkSpec
) throws -> URL {
    let sdkPath = try runPlatformTool(
        "/usr/bin/xcrun", ["--show-sdk-path", "--sdk", spec.sdkName])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sdkPath.isEmpty else {
        throw NSError(
            domain: "BridgeGen", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate \(spec.sdkName) SDK"])
    }
    let sdkKey = URL(fileURLWithPath: sdkPath).lastPathComponent
        .replacingOccurrences(of: ".", with: "-")
    let output = URL(fileURLWithPath: ".build/bridgegen-symbolgraphs")
        .appendingPathComponent(sdkKey)
        .appendingPathComponent(spec.name)
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true)
    let graph = output.appendingPathComponent("\(spec.name).symbols.json")
    if FileManager.default.fileExists(atPath: graph.path) { return graph }
    _ = try runPlatformTool("/usr/bin/xcrun", [
        "swift-symbolgraph-extract",
        "-module-name", spec.name,
        "-minimum-access-level", "public",
        "-sdk", sdkPath,
        "-target", spec.target,
        "-output-dir", output.path,
        "-skip-synthesized-members",
    ])
    guard FileManager.default.fileExists(atPath: graph.path) else {
        throw NSError(
            domain: "BridgeGen", code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "symbol graph extractor did not emit \(graph.path)"])
    }
    return graph
}

private func runPlatformTool(
    _ executable: String, _ arguments: [String]
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    let stderr = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "BridgeGen", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey:
                "\(([executable] + arguments).joined(separator: " ")) failed:\n\(stderr)"])
    }
    return stdout
}

private func platformSymbolIsAvailable(
    _ symbol: SymbolGraph.Symbol, for spec: PlatformFrameworkSpec
) -> Bool {
    for availability in symbol.availability ?? [] {
        // Symbol graphs retain pre-Swift-3 spellings solely to describe their
        // rename. They are not callable in the current language mode.
        if availability.domain == "Swift", availability.obsoleted != nil {
            return false
        }
        if availability.isUnconditionallyUnavailable == true,
           availability.domain == spec.availabilityDomain || availability.domain == "*" {
            return false
        }
        guard availability.domain == spec.availabilityDomain else { continue }
        if let introduced = availability.introduced {
            let version = (introduced.major, introduced.minor ?? 0)
            if version > (spec.deploymentMajor, spec.deploymentMinor) {
                return false
            }
        }
        // Match the existing swiftinterface sweep: retired API remains in SDK
        // metadata for source compatibility, but should not grow a new bridge.
        if let deprecated = availability.deprecated {
            let version = (deprecated.major, deprecated.minor ?? 0)
            if version <= (spec.deploymentMajor, spec.deploymentMinor) {
                return false
            }
        }
        if let obsoleted = availability.obsoleted {
            let version = (obsoleted.major, obsoleted.minor ?? 0)
            if version <= (spec.deploymentMajor, spec.deploymentMinor) {
                return false
            }
        }
    }
    return true
}

private func parsePlatformDecl(_ source: String) -> DeclSyntax? {
    guard !source.isEmpty else { return nil }
    let file = Parser.parse(source: source + "\n")
    guard let first = file.statements.first,
          case .decl(let declaration) = first.item else { return nil }
    return declaration
}

private func analyzePlatformParameters(
    _ parameters: FunctionParameterListSyntax,
    framework: String,
    selectedTypes: Set<String>,
    blockers: inout [String: Int]
) -> [PlatformParameter]? {
    var result: [PlatformParameter] = []
    for parameter in parameters {
        let labelText = parameter.firstName.text
        let label = labelText == "_" ? nil : labelText
        var type = parameter.type
        var isAction = false
        if let attributed = type.as(AttributedTypeSyntax.self) {
            guard attributed.specifiers.isEmpty else {
                blockers["inout/ownership parameter", default: 0] += 1
                return nil
            }
            type = attributed.baseType
        }
        var normalized = platformContractType(normalize(type.trimmedDescription))
        if normalized == "@escaping () -> Void" { normalized = "() -> Void" }
        if normalized == "() -> Void" { isAction = true }
        guard isAction || platformTypeIsSupported(
            normalized, framework: framework,
            selectedTypes: selectedTypes) else {
            blockers["parameter \(normalized)", default: 0] += 1
            return nil
        }
        result.append(PlatformParameter(
            label: label, type: normalized,
            hasDefault: parameter.defaultValue != nil,
            isAction: isAction))
    }
    return result
}

private func platformParameterSelections(
    _ parameters: [PlatformParameter]
) -> [[PlatformParameter]] {
    var result: [[PlatformParameter]] = []
    func visit(
        _ index: Int,
        _ selected: [PlatformParameter],
        omittedUnlabeledDefault: Bool
    ) {
        guard index < parameters.count else {
            result.append(selected)
            return
        }
        let parameter = parameters[index]
        if parameter.hasDefault {
            visit(
                index + 1, selected,
                omittedUnlabeledDefault:
                    omittedUnlabeledDefault || parameter.label == nil)
        }
        if !(omittedUnlabeledDefault && parameter.label == nil) {
            visit(
                index + 1, selected + [parameter],
                omittedUnlabeledDefault: omittedUnlabeledDefault)
        }
    }
    visit(0, [], omittedUnlabeledDefault: false)
    return result
}

private let platformDirectTypes: Set<String> = [
    "Void", "()", "Bool", "String", "Substring", "Character",
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float", "CGFloat", "TimeInterval",
    "CGPoint", "CGSize", "CGRect", "CGVector", "CGAffineTransform",
    "CGColor", "CGImage", "URL", "Data", "Date", "IndexPath", "NSRange",
    "ComparisonResult", "Bundle", "Notification.Name", "NSAttributedString",
]

private func platformContractType(_ type: String) -> String {
    var result = type.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.hasPrefix("@escaping ") {
        result = String(result.dropFirst("@escaping ".count))
    }
    // Clang overlays still expose a handful of Objective-C compatibility
    // spellings. Canonicalize only true Swift typealiases; emitted calls keep
    // compiling because each pair has the same SDK type identity.
    if result.hasSuffix("!") {
        return platformContractType(String(result.dropLast())) + "?"
    }
    if result.hasSuffix("?") {
        return platformContractType(String(result.dropLast())) + "?"
    }
    if result.hasPrefix("Optional<"), result.hasSuffix(">") {
        return platformContractType(
            String(result.dropFirst("Optional<".count).dropLast())) + "?"
    }
    if result.hasPrefix("["), result.hasSuffix("]"), !result.contains(":") {
        return "[" + platformContractType(String(result.dropFirst().dropLast())) + "]"
    }
    if result.hasPrefix("Array<"), result.hasSuffix(">") {
        return "[" + platformContractType(
            String(result.dropFirst("Array<".count).dropLast())) + "]"
    }
    let aliases = [
        "NSRect": "CGRect",
        "NSPoint": "CGPoint",
        "NSSize": "CGSize",
        "NSNotification.Name": "Notification.Name",
    ]
    return aliases[result] ?? memberContractType(for: result)
}

private func platformTypeIsSupported(
    _ rawType: String,
    framework: String,
    selectedTypes: Set<String>
) -> Bool {
    let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    if type.hasPrefix("any ") || type.hasPrefix("some ")
        || type == "Self" || type.contains("->") {
        return false
    }
    if type.hasSuffix("?") {
        return platformTypeIsSupported(
            String(type.dropLast()), framework: framework,
            selectedTypes: selectedTypes)
    }
    if type.hasPrefix("Optional<"), type.hasSuffix(">") {
        return platformTypeIsSupported(
            String(type.dropFirst("Optional<".count).dropLast()),
            framework: framework, selectedTypes: selectedTypes)
    }
    if type.hasPrefix("["), type.hasSuffix("]"), !type.contains(":") {
        return platformTypeIsSupported(
            String(type.dropFirst().dropLast()), framework: framework,
            selectedTypes: selectedTypes)
    }
    if type.hasPrefix("Array<"), type.hasSuffix(">") {
        return platformTypeIsSupported(
            String(type.dropFirst("Array<".count).dropLast()),
            framework: framework, selectedTypes: selectedTypes)
    }
    return platformDirectTypes.contains(type) || selectedTypes.contains(type)
}

private func platformPropertyIsSettable(_ variable: VariableDeclSyntax) -> Bool {
    guard variable.bindingSpecifier.text == "var",
          let binding = variable.bindings.first else { return false }
    guard let accessors = binding.accessorBlock else { return true }
    switch accessors.accessors {
    case .getter:
        return false
    case .accessors(let list):
        return list.contains {
            ["set", "_modify", "modify"].contains($0.accessorSpecifier.text)
        }
    }
}

// MARK: - Emission

private func emitPlatformBridge(
    _ frameworks: [ParsedPlatformFramework]
) -> String {
    var output = """
    // GENERATED by BridgeGen from AppKit/UIKit SDK symbol graphs.
    // Do not edit. Regenerate: swift run BridgeGen --emit
    import Foundation
    import SwiftInterpreter
    #if canImport(AppKit)
    import AppKit
    #elseif canImport(UIKit)
    import UIKit
    #endif

    extension GeneratedPlatformBridge {

    """
    let constructorGroups = frameworks.map { ($0.spec.name, $0.constructors) }
    let methodGroups = frameworks.map { ($0.spec.name, $0.methods) }
    let staticMethodGroups = frameworks.map { ($0.spec.name, $0.staticMethods) }
    let propertyGroups = frameworks.map { ($0.spec.name, $0.properties) }
    let staticPropertyGroups = frameworks.map { ($0.spec.name, $0.staticProperties) }
    let enumGroups = frameworks.map { ($0.spec.name, $0.enumValues) }
    let knownMemberGroups = frameworks.map { ($0.spec.name, $0.knownMembers) }

    output += emitBuilder(
        name: "Constructors",
        tableType: "[String: [GeneratedPlatformConstructorEntry]]",
        groups: constructorGroups,
        entry: emitPlatformConstructor)
    output += emitBuilder(
        name: "Methods",
        tableType: "[GeneratedPlatformMemberKey: [GeneratedPlatformMethodEntry]]",
        groups: methodGroups,
        entry: emitPlatformMethod)
    output += emitBuilder(
        name: "StaticMethods",
        tableType: "[GeneratedPlatformMemberKey: [GeneratedPlatformStaticMethodEntry]]",
        groups: staticMethodGroups,
        entry: emitPlatformStaticMethod)
    output += emitBuilder(
        name: "Properties",
        tableType: "[GeneratedPlatformMemberKey: GeneratedPlatformPropertyEntry]",
        groups: propertyGroups,
        entry: emitPlatformProperty)
    output += emitBuilder(
        name: "StaticProperties",
        tableType: "[GeneratedPlatformMemberKey: GeneratedPlatformStaticPropertyEntry]",
        groups: staticPropertyGroups,
        entry: emitPlatformStaticProperty)
    output += emitBuilder(
        name: "EnumValues",
        tableType: "[GeneratedPlatformMemberKey: [GeneratedPlatformEnumEntry]]",
        groups: enumGroups,
        entry: emitPlatformEnumValue)
    output += emitBuilder(
        name: "KnownMembers",
        tableType: "[GeneratedPlatformMemberKey: Bool]",
        groups: knownMemberGroups,
        entry: emitPlatformKnownMember)

    output += "\n    static func buildNominalKinds() -> [GeneratedPlatformTypeKey: Bool] {\n"
    output += "        var t: [GeneratedPlatformTypeKey: Bool] = [:]\n"
    for framework in frameworks {
        for nominal in framework.nominals.values.sorted(by: { $0.type < $1.type }) {
            output += "        t[GeneratedPlatformTypeKey(framework: \(swiftLiteral(framework.spec.name)), type: \(swiftLiteral(nominal.type)))] = \(nominal.kind.isValueType)\n"
        }
    }
    output += "        return t\n    }\n"

    output += "\n    static func buildSupertypes() -> [GeneratedPlatformTypeKey: String] {\n"
    output += "        var t: [GeneratedPlatformTypeKey: String] = [:]\n"
    for framework in frameworks {
        for (type, parent) in framework.supertypeByType.sorted(by: { $0.key < $1.key }) {
            output += "        t[GeneratedPlatformTypeKey(framework: \(swiftLiteral(framework.spec.name)), type: \(swiftLiteral(type)))] = \(swiftLiteral(parent))\n"
        }
    }
    output += "        return t\n    }\n"
    output += "}\n"
    return output
}

private func emitBuilder<T>(
    name: String,
    tableType: String,
    groups: [(String, [T])],
    entry: (T) -> String
) -> String {
    let chunkSize = 35
    var output = "\n    static func build\(name)() -> \(tableType) {\n"
    output += "        var t: \(tableType) = [:]\n"
    for (framework, values) in groups {
        let chunks = stride(from: 0, to: values.count, by: chunkSize).map {
            Array(values[$0..<min($0 + chunkSize, values.count)])
        }
        for index in chunks.indices {
            output += "        build\(name)\(framework)\(index)(&t)\n"
        }
    }
    output += "        return t\n    }\n"
    for (framework, values) in groups {
        let chunks = stride(from: 0, to: values.count, by: chunkSize).map {
            Array(values[$0..<min($0 + chunkSize, values.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            output += "\n    private static func build\(name)\(framework)\(index)(_ t: inout \(tableType)) {\n"
            for value in chunk { output += entry(value) + "\n" }
            output += "    }\n"
        }
    }
    return output
}

private func emitPlatformConstructor(_ value: PlatformCallable) -> String {
    let arguments = platformCallArguments(value.params)
    let call = "\(value.receiverType)(\(arguments))"
    var body = platformInvocationBody(
        call: call, resultType: value.resultType,
        framework: value.framework,
        isThrowing: value.isThrowing)
    body = indent(body, by: 12)
    return """
            registerConstructor(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.declaration)),
                resultType: \(swiftLiteral(value.resultType))) { v, ctx in
    #if canImport(\(value.framework))
    \(body)
    #else
                preconditionFailure("\(value.framework) gateway invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformMethod(_ value: PlatformCallable) -> String {
    let arguments = platformCallArguments(value.params)
    let call = "receiver.`\(value.name)`(\(arguments))"
    var invocation = platformInvocationBody(
        call: call, resultType: value.resultType,
        framework: value.framework,
        isThrowing: value.isThrowing)
    invocation = indent(invocation, by: 12)
    return """
            registerMethod(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.declaration)),
                resultType: \(swiftLiteral(value.resultType))) { base, v, ctx in
    #if canImport(\(value.framework))
                guard let receiver = base.payload as? \(value.receiverType) else {
                    throw RuntimeError(message: "generated \(value.framework) receiver mismatch", fatal: true)
                }
    \(invocation)
    #else
                preconditionFailure("\(value.framework) gateway invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformStaticMethod(_ value: PlatformCallable) -> String {
    let arguments = platformCallArguments(value.params)
    let call = "\(value.receiverType).`\(value.name)`(\(arguments))"
    var body = platformInvocationBody(
        call: call, resultType: value.resultType,
        framework: value.framework,
        isThrowing: value.isThrowing)
    body = indent(body, by: 12)
    return """
            registerStaticMethod(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.declaration)),
                resultType: \(swiftLiteral(value.resultType))) { v, ctx in
    #if canImport(\(value.framework))
    \(body)
    #else
                preconditionFailure("\(value.framework) gateway invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformProperty(_ value: PlatformProperty) -> String {
    let setter: String
    if value.isSettable {
        let binding = value.receiverIsValueType ? "var" : "let"
        setter = """
                }, set: { base, newValue, ctx in
    #if canImport(\(value.framework))
                    guard \(binding) receiver = base as? \(value.receiverType) else {
                        throw RuntimeError(message: "generated \(value.framework) property receiver mismatch", fatal: true)
                    }
                    receiver.`\(value.name)` = try generatedPlatformArgument(
                        newValue, as: \(value.resultType).self,
                        framework: \(swiftLiteral(value.framework)),
                        typeName: \(swiftLiteral(value.resultType)), context: ctx)
                    base = receiver
    #else
                    preconditionFailure("\(value.framework) setter invoked off-platform")
    #endif
                })
    """
    } else {
        setter = "\n                }, set: nil)"
    }
    return """
            registerProperty(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.declaration)),
                resultType: \(swiftLiteral(value.resultType)), get: { base in
    #if canImport(\(value.framework))
                    guard let receiver = base as? \(value.receiverType) else {
                        throw RuntimeError(message: "generated \(value.framework) property receiver mismatch", fatal: true)
                    }
                    return generatedPlatformResult(
                        receiver.`\(value.name)`,
                        framework: \(swiftLiteral(value.framework)),
                        declaredType: \(swiftLiteral(value.resultType)))
    #else
                    preconditionFailure("\(value.framework) getter invoked off-platform")
    #endif
    \(setter)
    """
}

private func emitPlatformStaticProperty(_ value: PlatformProperty) -> String {
    """
            registerStaticProperty(
                &t, framework: \(swiftLiteral(value.framework)),
                type: \(swiftLiteral(value.receiverType)),
                name: \(swiftLiteral(value.name)),
                resultType: \(swiftLiteral(value.resultType))) {
    #if canImport(\(value.framework))
                generatedPlatformResult(
                    \(value.receiverType).`\(value.name)`,
                    framework: \(swiftLiteral(value.framework)),
                    declaredType: \(swiftLiteral(value.resultType)))
    #else
                preconditionFailure("\(value.framework) getter invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformEnumValue(_ value: PlatformEnumValue) -> String {
    """
            registerEnumValue(
                &t, framework: \(swiftLiteral(value.framework)),
                type: \(swiftLiteral(value.type)), name: \(swiftLiteral(value.name))) {
    #if canImport(\(value.framework))
                \(value.type).`\(value.name)`
    #else
                preconditionFailure("\(value.framework) enum value invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformKnownMember(_ value: PlatformKnownMember) -> String {
    """
            t[GeneratedPlatformMemberKey(
                framework: \(swiftLiteral(value.framework)),
                type: \(swiftLiteral(value.type)),
                member: \(swiftLiteral(value.name)))] = \(value.isCallable)
    """
}

private func platformCallArguments(_ params: [PlatformParameter]) -> String {
    params.enumerated().map { index, parameter in
        let expression: String
        if parameter.isAction {
            expression = "generatedAction(try GeneratedDispatch.coerce(.action, v[\(index)], ctx))"
        } else {
            expression = "try generatedPlatformArgument(v[\(index)], as: \(parameter.type).self, framework: \(swiftLiteral("__FRAMEWORK__")), typeName: \(swiftLiteral(parameter.type)), context: ctx)"
        }
        return (parameter.label.map { "\($0): " } ?? "") + expression
    }.joined(separator: ", ")
}

private func platformInvocationBody(
    call: String,
    resultType: String,
    framework: String,
    isThrowing: Bool
) -> String {
    let fixedCall = call.replacingOccurrences(
        of: swiftLiteral("__FRAMEWORK__"), with: swiftLiteral(framework))
    let prefix = isThrowing ? "try " : ""
    if resultType == "Void" || resultType == "()" {
        return "\(prefix)\(fixedCall)\nreturn .void"
    }
    return "return generatedPlatformResult(\(prefix)\(fixedCall), framework: \(swiftLiteral(framework)), declaredType: \(swiftLiteral(resultType)))"
}

private func swiftLiteral(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}

private func indent(_ value: String, by count: Int) -> String {
    let prefix = String(repeating: " ", count: count)
    return value.split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + $0 }
        .joined(separator: "\n")
}

private func platformIdentifier(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
}

private func platformSymbolBaseName(
    _ symbol: SymbolGraph.Symbol
) -> String? {
    guard let component = symbol.pathComponents.last else { return nil }
    let raw = component.split(separator: "(", maxSplits: 1)
        .first.map(String.init) ?? component
    let name = platformIdentifier(raw)
    guard name.first?.isLetter == true, !name.hasPrefix("_") else { return nil }
    return name
}
