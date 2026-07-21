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
    let emittedGlobalFunctions: Int
    let emittedGlobalProperties: Int
    let emittedEnumValues: Int
    let emittedSignatures: [String]
    let blockers: [String: Int]
}

struct PlatformGenerationResult {
    let output: String
    let coverage: [String: PlatformCoverageSection]
    let summaries: [String]
    let typeFrameworks: [String: Set<String>]
}

struct FoundationReferencePropertyGenerationResult {
    let output: String
    let propertyCount: Int
}

private struct PlatformFrameworkSpec {
    let name: String
    let sdkName: String
    let target: String
    /// Every deployment on which the checked-in bridge must compile. A
    /// cross-platform framework such as Metal is filtered against both SDK
    /// availability domains from one metadata sweep.
    let deployments: [String: (major: Int, minor: Int)]
    let roots: Set<String>
    /// The module the symbol graph is extracted from, when the public
    /// framework re-exports an underlying module (CoreLocation's CLLocation
    /// lives in _LocationEssentials). Emitted code still imports `name`.
    var extractionModule: String?
    /// Compilation condition for callable code when a cross-platform module's
    /// symbol graph comes from one SDK family. Its nominal hierarchy remains
    /// available as string metadata on every host.
    var nativeImportCondition: String?
}

/// Type-level policy, not a member allowlist: once a type is selected, every
/// mechanically bridgeable public constructor/member is emitted from SDK
/// metadata. These are the platform primitives that interpreted SwiftUI apps
/// most often use directly; adding another type grows its whole surface.
private let platformFrameworkSpecs: [PlatformFrameworkSpec] = [
    .init(
        // Foundation's Objective-C classes have no nominal bodies in the
        // swiftinterface. Select the complete ProcessInfo surface from its
        // SDK symbol graph so read-only values keep their native scalar
        // payloads instead of falling through to an absorbing host box.
        name: "Foundation", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        deployments: ["macOS": (15, 0)],
        roots: ["Operation", "OperationQueue", "ProcessInfo"]),
    .init(
        name: "AppKit", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        deployments: ["macOS": (15, 0)],
        roots: [
            "NSApplication", "NSResponder", "NSWindow", "NSScreen",
            "NSMenu", "NSMenuItem",
            "NSView", "NSControl", "NSViewController", "NSAppearance",
            "NSColor", "NSColorSpace", "NSColorSpaceName", "NSFont",
            "NSImage", "NSImageRep", "NSBitmapImageRep", "NSBezierPath",
            "NSDirectionalEdgeInsets", "NSButton", "NSImageView",
            "NSScrollView", "NSTableView", "NSCollectionView",
            "NSTextField", "NSTextView",
        ]),
    .init(
        name: "UIKit", sdkName: "iphoneos",
        target: "arm64-apple-ios18.0",
        deployments: ["iOS": (18, 0)],
        roots: [
            "UIApplication", "UIResponder", "UIWindow", "UIWindowScene",
            "UIScreen", "UITraitCollection", "UIView", "UIControl", "UIViewController",
            "UIColor", "UIFont", "UIFontMetrics", "UIImage", "UIBezierPath",
            "UIEdgeInsets", "UIOffset", "NSDirectionalEdgeInsets",
            "UIButton", "UIImageView", "UILabel", "UIScrollView",
            "UITableView", "UICollectionView", "UITextField", "UITextView",
        ]),
    .init(
        // WebKit source subclasses cross both representable families. Sweep
        // the iOS hierarchy so opposite-platform checking retains the
        // WKWebView -> UIView edge, while availability filtering keeps the
        // generated callable surface valid on macOS too.
        name: "WebKit", sdkName: "iphoneos",
        target: "arm64-apple-ios18.0",
        deployments: ["macOS": (15, 0), "iOS": (18, 0)],
        roots: ["WKWebView"],
        nativeImportCondition: "canImport(UIKit) && canImport(WebKit)"),
    .init(
        // The FoodTruck city screen's DetailedMapView builds a real
        // MKMapView inside its representable controller — the map surface
        // interpreted apps configure directly.
        name: "MapKit", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        deployments: ["macOS": (15, 0)],
        roots: [
            "MKMapView", "MKMapCamera", "MKMapConfiguration",
            "MKStandardMapConfiguration", "MKPointOfInterestFilter",
        ]),
    .init(
        name: "CoreLocation", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        deployments: ["macOS": (15, 0)],
        roots: [
            "CLLocation", "CLLocationCoordinate2D",
        ],
        extractionModule: "_LocationEssentials"),
    .init(
        // Generate the common Metal surface from the more restrictive iOS
        // SDK; the same emitted calls then compile for both package targets.
        name: "Metal", sdkName: "iphoneos",
        target: "arm64-apple-ios18.0",
        deployments: ["macOS": (15, 0), "iOS": (18, 0)],
        roots: [
            "MTLSize", "MTLResourceOptions", "MTLCommandBufferStatus",
            "MTLCompileOptions", "MTLDevice", "MTLCommandQueue",
            "MTLLibrary", "MTLFunction", "MTLComputePipelineState",
            "MTLResource", "MTLBuffer", "MTLCommandBuffer",
            "MTLCommandEncoder", "MTLComputeCommandEncoder",
        ]),
]

/// Classes whose synthesized no-argument constructor does not compile
/// (unavailable/abstract plain initializers) — grown from build failures.
private let platformNoArgInitDeny: Set<String> = [
    "MKMapConfiguration", // abstract base: init() unavailable
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
        let targetFallback: String?
    }
}

private enum PlatformNominalKind: String {
    case `class`, `struct`, `enum`, `protocol`

    var isValueType: Bool { self == .struct || self == .enum }

    var nativePrefix: String { self == .protocol ? "any " : "" }
}

private struct PlatformNominal {
    let framework: String
    let precise: String
    let type: String
    let root: String
    let kind: PlatformNominalKind
    let isEquatable: Bool
}

private struct PlatformParameter {
    let label: String?
    let type: String
    /// Statically compiled SDK spelling. Protocol values retain `any`; the
    /// host contract deliberately uses the nominal protocol name.
    let nativeType: String
    /// Runtime overload contract. Usually identical to `type`; nil-only
    /// unsafe pointers use `Never?` so only a nil source value can match.
    let contractType: String
    let hasDefault: Bool
    let isAction: Bool
    let pointerKind: PlatformPointerKind?
}

/// A native scheduler can accept a source-defined subclass whose lifecycle
/// entry point must run back inside the interpreter. Symbol graphs describe
/// the scheduler conformance and the lifecycle method, but cannot encode that
/// cross-runtime override handoff.
private struct PlatformInterpretedLifecycleAdapter {
    let parameterIndex: Int
    let entryPoint: String
}

private enum PlatformPointerKind {
    case raw
    case mutableRaw
    case mutableBytes
}

private struct PlatformCallable {
    enum Kind { case constructor, method, staticMethod, globalFunction }

    let framework: String
    let kind: Kind
    let receiverType: String
    let nativeReceiverType: String
    let receiverIsValueType: Bool
    let name: String
    let resultType: String
    let nativeResultType: String
    let resultPointerKind: PlatformPointerKind?
    let params: [PlatformParameter]
    let isThrowing: Bool
    let isFailable: Bool
    var interpretedLifecycleAdapter: PlatformInterpretedLifecycleAdapter? = nil

    private func formattedDeclaration(useContractTypes: Bool) -> String {
        let parameters = params.enumerated().map { index, param in
            let type = useContractTypes ? param.contractType : param.type
            return "\(param.label ?? "_") p\(index): \(type)"
        }.joined(separator: ", ")
        let effects = isThrowing ? " throws" : ""
        switch kind {
        case .constructor:
            return "init\(isFailable ? "?" : "") \(receiverType)(\(parameters))\(effects)"
        case .method:
            return "func \(receiverType).\(name)(\(parameters))\(effects) -> \(resultType)"
        case .staticMethod:
            return "static func \(receiverType).\(name)(\(parameters))\(effects) -> \(resultType)"
        case .globalFunction:
            return "func \(name)(\(parameters))\(effects) -> \(resultType)"
        }
    }

    /// SDK-facing declaration used by coverage and stable identity.
    var declaration: String { formattedDeclaration(useContractTypes: false) }

    /// Executable host contract. `Never?` precisely models parameters for
    /// which the bridge can construct a typed nil but no non-nil pointer.
    var hostDeclaration: String {
        formattedDeclaration(useContractTypes: true)
    }

    var signatureKey: String { "\(framework)|\(declaration)" }
}

private struct PlatformProperty {
    let framework: String
    let receiverType: String
    let nativeReceiverType: String
    let receiverIsValueType: Bool
    let name: String
    let resultType: String
    let nativeResultType: String
    let pointerKind: PlatformPointerKind?
    let isImplicitlyUnwrapped: Bool
    let isSettable: Bool
    let isStatic: Bool

    var declaration: String {
        let prefix = isStatic ? "static var" : "var"
        let accessors = isSettable ? " { get set }" : " { get }"
        return "\(prefix) \(receiverType).\(name): \(resultType)\(accessors)"
    }

    var signatureKey: String { "\(framework)|\(declaration)" }
}

private struct PlatformGlobalProperty {
    let framework: String
    let name: String
    let resultType: String
    let nativeResultType: String
    let pointerKind: PlatformPointerKind?
    let isImplicitlyUnwrapped: Bool

    var signatureKey: String {
        "\(framework)|global var \(name): \(resultType)"
    }
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
    let supertypesByType: [String: [String]]
    let constructors: [PlatformCallable]
    let methods: [PlatformCallable]
    let staticMethods: [PlatformCallable]
    let globalFunctions: [PlatformCallable]
    let globalProperties: [PlatformGlobalProperty]
    let properties: [PlatformProperty]
    let staticProperties: [PlatformProperty]
    let enumValues: [PlatformEnumValue]
    let knownMembers: [PlatformKnownMember]
    let blockers: [String: Int]
}

/// Union of every sweep's root-selected nominal names, computed by a light
/// pre-pass so each framework's parameter acceptance can reference the
/// others' types (graphs are disk-cached; the decode is cheap).
private var platformCrossFrameworkSelectedTypes: Set<String> = []

func generatePlatformBridge() throws -> PlatformGenerationResult {
    platformCrossFrameworkSelectedTypes = Set(
        try platformFrameworkSpecs.flatMap { spec -> [String] in
            let graph = try JSONDecoder().decode(
                SymbolGraph.self,
                from: Data(contentsOf: platformSymbolGraphURL(for: spec)))
            return graph.symbols.compactMap { symbol in
                guard symbol.kind.identifier.hasPrefix("swift."),
                      ["swift.class", "swift.struct", "swift.enum"]
                          .contains(symbol.kind.identifier),
                      let first = symbol.pathComponents.first,
                      spec.roots.contains(first),
                      platformSymbolIsAvailable(symbol, for: spec) else { return nil }
                return symbol.pathComponents.joined(separator: ".")
            }
        })
    let parsed = try platformFrameworkSpecs.map(parsePlatformFramework)
    let output = emitPlatformBridge(parsed)
    var coverage: [String: PlatformCoverageSection] = [:]
    var summaries: [String] = []
    var typeFrameworks: [String: Set<String>] = [:]
    for framework in parsed {
        for nominal in framework.nominals.values {
            typeFrameworks[nominal.type, default: []].insert(framework.spec.name)
        }
        let signatures = (
            framework.constructors.map(\.signatureKey)
                + framework.methods.map(\.signatureKey)
                + framework.staticMethods.map(\.signatureKey)
                + framework.globalFunctions.map(\.signatureKey)
                + framework.globalProperties.map(\.signatureKey)
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
            emittedGlobalFunctions: framework.globalFunctions.count,
            emittedGlobalProperties: framework.globalProperties.count,
            emittedEnumValues: framework.enumValues.count,
            emittedSignatures: signatures,
            blockers: framework.blockers)
        summaries.append(
            "\(framework.spec.name): \(framework.nominals.count) types, "
                + "\(framework.constructors.count) constructors, "
                + "\(framework.properties.count + framework.staticProperties.count) properties, "
                + "\(framework.methods.count + framework.staticMethods.count) methods, "
                + "\(framework.globalFunctions.count) global functions, "
                + "\(framework.globalProperties.count) global properties, "
                + "\(framework.enumValues.count) contextual values")
    }
    return PlatformGenerationResult(
        output: output, coverage: coverage, summaries: summaries,
        typeFrameworks: typeFrameworks)
}

/// Foundation's Objective-C reference declarations are imported from Clang
/// and therefore do not appear as nominal bodies in Foundation.swiftinterface.
/// Sweep the SDK symbol graph for every mechanically contractible writable
/// class property. Runtime reference boxes opt into this generated contract
/// by capability, so coverage grows by interface property rather than by
/// handwritten member-name branches.
func generateFoundationReferenceProperties()
    throws -> FoundationReferencePropertyGenerationResult
{
    let spec = PlatformFrameworkSpec(
        name: "Foundation", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        deployments: ["macOS": (15, 0)], roots: [])
    let graph = try JSONDecoder().decode(
        SymbolGraph.self,
        from: Data(contentsOf: platformSymbolGraphURL(for: spec)))
    let classesByPrecise = Dictionary(uniqueKeysWithValues:
        graph.symbols.compactMap { symbol -> (String, String)? in
            guard symbol.kind.identifier == "swift.class",
                  platformSymbolIsAvailable(symbol, for: spec),
                  !symbol.pathComponents.isEmpty else { return nil }
            let type = symbol.pathComponents.joined(separator: ".")
            guard !type.contains("<") else { return nil }
            return (symbol.identifier.precise, type)
        })
    let selectedTypes = Set(classesByPrecise.values)
    var parentByMember: [String: String] = [:]
    for relationship in graph.relationships
    where relationship.kind == "memberOf" {
        parentByMember[relationship.source] = relationship.target
    }

    var declarationsByKey: [String: String] = [:]
    for symbol in graph.symbols
    where symbol.kind.identifier == "swift.property"
        && platformSymbolIsAvailable(symbol, for: spec)
    {
        guard let parent = parentByMember[symbol.identifier.precise],
              let receiverType = classesByPrecise[parent],
              let variable = parsePlatformDecl(symbol.declaration)?
                .as(VariableDeclSyntax.self),
              platformPropertyIsSettable(variable),
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let rawType = binding.typeAnnotation?.type.trimmedDescription
        else { continue }
        let name = platformIdentifier(pattern.identifier.text)
        guard !name.hasPrefix("_") else { continue }
        let nativeType = platformNativeType(rawType)
        guard platformPointerKind(nativeType) == nil else { continue }
        let resultType = platformContractType(nativeType)
        guard platformTypeIsSupported(
            resultType, framework: spec.name,
            selectedTypes: selectedTypes) else { continue }
        let key = "\(receiverType).\(name)"
        declarationsByKey[key] =
            "var \(receiverType).\(name): \(resultType) { get set }"
    }

    let entries = declarationsByKey.sorted { $0.key < $1.key }.map {
        "        \(swiftLiteral($0.key)): \(swiftLiteral($0.value))"
    }.joined(separator: ",\n")
    let output = """
    // GENERATED by BridgeGen from Foundation's SDK symbol graph.
    // Do not edit. Regenerate: swift run BridgeGen --emit
    // \(declarationsByKey.count) writable reference-type property contracts.
    enum GeneratedFoundationReferenceProperties {
        static let declarationsByKey: [String: String] = [
    \(entries)
        ]
    }
    """ + "\n"
    return FoundationReferencePropertyGenerationResult(
        output: output, propertyCount: declarationsByKey.count)
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
        "swift.protocol": .protocol,
    ]
    let equatableNominals = Set(graph.relationships.lazy.filter {
        $0.kind == "conformsTo"
            && ($0.target == "s:SQ" || $0.targetFallback == "Swift.Equatable")
    }.map(\.source))
    var allNominals: [String: PlatformNominal] = [:]
    for symbol in graph.symbols {
        guard let kind = nominalKindBySymbolKind[symbol.kind.identifier],
              !symbol.pathComponents.isEmpty,
              platformSymbolIsAvailable(symbol, for: spec),
              (!symbol.declaration.contains("<") || kind == .protocol) else { continue }
        let type = symbol.pathComponents.joined(separator: ".")
        allNominals[symbol.identifier.precise] = PlatformNominal(
            framework: spec.name,
            precise: symbol.identifier.precise,
            type: type,
            root: symbol.pathComponents[0],
            kind: kind,
            isEquatable: equatableNominals.contains(symbol.identifier.precise))
    }

    let selected = allNominals.filter { spec.roots.contains($0.value.root) }
    // Cross-framework references bridge when the referenced type is selected
    // by ANY sweep (MKMapCamera's initializer takes CoreLocation's
    // CLLocationCoordinate2D); the runtime unwraps platform values by
    // dynamic cast, so acceptance is framework-agnostic.
    let selectedTypes = Set(selected.values.map(\.type))
        .union(platformCrossFrameworkSelectedTypes)
    var parentByMember: [String: String] = [:]
    for relationship in graph.relationships
        where relationship.kind == "memberOf" || relationship.kind == "requirementOf"
    {
        parentByMember[relationship.source] = relationship.target
    }
    let schedulerTypes: Set<String> = Set(
        graph.relationships.compactMap { relationship -> String? in
            guard relationship.kind == "conformsTo",
                  relationship.targetFallback?.split(separator: ".").last
                    == "Scheduler",
                  let nominal = selected[relationship.source]
            else { return nil }
            return nominal.type
        })
    // A scheduler submission that accepts a source subclass cannot hand that
    // interpreter-owned object to native code. Derive the lifecycle entry
    // point from the submitted parameter type's public zero-argument `start`
    // contract; no scheduler or submission API identity is named here.
    var lifecycleEntryPointByType: [String: String] = [:]
    for symbol in graph.symbols where symbol.kind.identifier == "swift.method" {
        guard let parent = parentByMember[symbol.identifier.precise],
              let nominal = selected[parent],
              let function = parsePlatformDecl(symbol.declaration)?
                .as(FunctionDeclSyntax.self),
              platformIdentifier(function.name.text) == "start",
              function.signature.parameterClause.parameters.isEmpty,
              function.signature.returnClause == nil
        else { continue }
        lifecycleEntryPointByType[nominal.type] =
            platformIdentifier(function.name.text)
    }
    var supertypesByType: [String: [String]] = [:]
    for relationship in graph.relationships
        where relationship.kind == "inheritsFrom" || relationship.kind == "conformsTo"
    {
        guard let child = selected[relationship.source] else { continue }
        let parentType = allNominals[relationship.target]?.type
            ?? (relationship.kind == "inheritsFrom"
                ? relationship.targetFallback.flatMap { fallback in
                let components = fallback.split(separator: ".")
                guard components.count > 1 else { return nil }
                return components.dropFirst().joined(separator: ".")
            } : nil)
        guard let parentType else { continue }
        if !supertypesByType[child.type, default: []].contains(parentType) {
            supertypesByType[child.type, default: []].append(parentType)
        }
    }

    var blockers: [String: Int] = [:]
    var constructors: [PlatformCallable] = []
    var methods: [PlatformCallable] = []
    var staticMethods: [PlatformCallable] = []
    var globalFunctions: [PlatformCallable] = []
    var globalProperties: [PlatformGlobalProperty] = []
    var properties: [PlatformProperty] = []
    var staticProperties: [PlatformProperty] = []
    var enumValues: [PlatformEnumValue] = []
    var knownMembersByKey: [String: PlatformKnownMember] = [:]
    var callableSeen = Set<String>()
    var propertySeen = Set<String>()
    var enumSeen = Set<String>()

    // Clang-imported framework globals are values, not unknown uppercase
    // nominal names (`NSApp` is the canonical example). A global joins the
    // selected type tier when its result references one of that tier's
    // nominals. Primitive macro constants remain with the C-import absorber;
    // this also avoids pretending symbol graphs carry their macro payloads.
    for symbol in graph.symbols where symbol.kind.identifier == "swift.var" {
        guard symbol.pathComponents.count == 1,
              platformSymbolIsAvailable(symbol, for: spec),
              let variable = parsePlatformDecl(symbol.declaration)?
                .as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let rawType = binding.typeAnnotation?.type.trimmedDescription
        else { continue }
        let name = platformIdentifier(pattern.identifier.text)
        guard name.first?.isLetter == true, !name.hasPrefix("_") else { continue }
        let nativeResultType = platformNativeType(rawType)
        let pointerKind = platformPointerKind(nativeResultType)
        let resultType = pointerKind == nil
            ? platformContractType(nativeResultType)
            : platformPointerContractType(nativeResultType)
        guard platformTypeIsSupported(
            resultType, framework: spec.name, selectedTypes: selectedTypes)
                || pointerKind != nil,
              platformTypeReferencesSelected(
                resultType, selectedTypes: selectedTypes)
        else {
            blockers["global property \(resultType)", default: 0] += 1
            continue
        }
        globalProperties.append(PlatformGlobalProperty(
            framework: spec.name,
            name: name,
            resultType: resultType,
            nativeResultType: nativeResultType,
            pointerKind: pointerKind,
            isImplicitlyUnwrapped: rawType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("!")))
    }

    // Clang-imported frameworks expose module functions alongside, rather
    // than beneath, their nominals. Emit every mechanically bridgeable public
    // global: availability and the shared type/coercion rules are the policy,
    // so primitive-only Begin/End functions are not lost merely because their
    // declarations do not mention a selected framework nominal.
    for symbol in graph.symbols where symbol.kind.identifier == "swift.func" {
        guard platformSymbolIsAvailable(symbol, for: spec),
              let function = parsePlatformDecl(symbol.declaration)?
                .as(FunctionDeclSyntax.self),
              function.genericParameterClause == nil,
              function.genericWhereClause == nil,
              !function.signature.parameterClause.parameters.contains(where: {
                  $0.ellipsis != nil
              }) else { continue }
        let effects = function.signature.effectSpecifiers?.trimmedDescription ?? ""
        guard !effects.contains("async") else { continue }
        let name = platformIdentifier(function.name.text)
        guard name.first?.isLetter == true, !name.hasPrefix("_") else { continue }
        let nativeResultType = function.signature.returnClause.map {
            platformNativeType($0.type.trimmedDescription)
        } ?? "Void"
        let resultPointerKind = platformPointerKind(nativeResultType)
        let resultType = resultPointerKind == nil
            ? platformContractType(nativeResultType)
            : platformPointerContractType(nativeResultType)
        guard platformTypeIsSupported(
            resultType, framework: spec.name, selectedTypes: selectedTypes)
                || resultPointerKind != nil,
              let analyzed = analyzePlatformParameters(
                function.signature.parameterClause.parameters,
                framework: spec.name, selectedTypes: selectedTypes,
                allowNilOnlyPointers: false, blockers: &blockers)
        else { continue }
        for selection in platformParameterSelections(analyzed) {
            let callable = PlatformCallable(
                framework: spec.name, kind: .globalFunction,
                receiverType: "", nativeReceiverType: "",
                receiverIsValueType: false,
                name: name, resultType: resultType,
                nativeResultType: nativeResultType,
                resultPointerKind: resultPointerKind,
                params: selection,
                isThrowing: effects.contains("throws") || effects.contains("rethrows"),
                isFailable: false)
            if callableSeen.insert(callable.signatureKey).inserted {
                globalFunctions.append(callable)
            }
        }
    }

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
                  initDecl.genericWhereClause == nil else {
                blockers["generic initializer", default: 0] += 1
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
                allowNilOnlyPointers: true,
                blockers: &blockers) else { continue }
            for selection in platformParameterSelections(analyzed) {
                let callable = PlatformCallable(
                    framework: spec.name, kind: .constructor,
                    receiverType: nominal.type,
                    nativeReceiverType: nominal.type,
                    receiverIsValueType: nominal.kind.isValueType,
                    name: nominal.type,
                    resultType: nominal.type,
                    nativeResultType: nominal.type,
                    resultPointerKind: nil,
                    params: selection,
                    isThrowing: effects.contains("throws") || effects.contains("rethrows"),
                    isFailable: initDecl.optionalMark != nil)
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
            let nativeResultType = function.signature.returnClause.map {
                platformNativeType($0.type.trimmedDescription)
            } ?? "Void"
            let resultPointerKind = platformPointerKind(nativeResultType)
            let resultType = function.signature.returnClause.map {
                let native = platformNativeType($0.type.trimmedDescription)
                return platformPointerKind(native) == nil
                    ? platformContractType(native)
                    : platformPointerContractType(native)
            } ?? "Void"
            guard platformTypeIsSupported(
                resultType, framework: spec.name,
                selectedTypes: selectedTypes) || resultPointerKind != nil else {
                blockers["return \(resultType)", default: 0] += 1
                continue
            }
            guard let analyzed = analyzePlatformParameters(
                function.signature.parameterClause.parameters,
                framework: spec.name,
                selectedTypes: selectedTypes,
                allowNilOnlyPointers: false,
                blockers: &blockers) else { continue }
            let kind: PlatformCallable.Kind = symbol.kind.identifier == "swift.type.method"
                ? .staticMethod : .method
            for selection in platformParameterSelections(analyzed) {
                let callable = PlatformCallable(
                    framework: spec.name, kind: kind,
                    receiverType: nominal.type,
                    nativeReceiverType: nominal.kind.nativePrefix + nominal.type,
                    receiverIsValueType: nominal.kind.isValueType,
                    name: name, resultType: resultType,
                    nativeResultType: nativeResultType,
                    resultPointerKind: resultPointerKind,
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
            let nativeResultType = platformNativeType(rawType)
            let pointerKind = platformPointerKind(nativeResultType)
            let resultType = pointerKind == nil
                ? platformContractType(nativeResultType)
                : platformPointerContractType(nativeResultType)
            guard platformTypeIsSupported(
                resultType, framework: spec.name,
                selectedTypes: selectedTypes) || pointerKind != nil else {
                blockers["property \(resultType)", default: 0] += 1
                continue
            }
            let isStatic = symbol.kind.identifier == "swift.type.property"
            let isSettable = !isStatic && platformPropertyIsSettable(variable)
            let property = PlatformProperty(
                framework: spec.name,
                receiverType: nominal.type,
                nativeReceiverType: nominal.kind.nativePrefix + nominal.type,
                receiverIsValueType: nominal.kind.isValueType,
                name: name, resultType: resultType,
                nativeResultType: nativeResultType, pointerKind: pointerKind,
                isImplicitlyUnwrapped: rawType
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasSuffix("!"),
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

    // ObjC classes inherit NSObject's plain initializer, which symbol
    // graphs omit (-skip-synthesized-members). A selected class that swept
    // NO initializer still constructs natively via `Type()` — synthesize
    // that variant so inherited-init-only subclasses (MKMapView) are
    // constructible. A synthesis that does not compile joins the deny set.
    let constructedTypes = Set(constructors.map(\.receiverType))
    for nominal in selected.values.sorted(by: { $0.type < $1.type })
    where nominal.kind == .class
        && !constructedTypes.contains(nominal.type)
        && !platformNoArgInitDeny.contains(nominal.type)
    {
        constructors.append(PlatformCallable(
            framework: spec.name, kind: .constructor,
            receiverType: nominal.type,
            nativeReceiverType: nominal.type,
            receiverIsValueType: false,
            name: nominal.type,
            resultType: nominal.type,
            nativeResultType: nominal.type,
            resultPointerKind: nil,
            params: [],
            isThrowing: false,
            isFailable: false))
    }

    for index in methods.indices {
        let method = methods[index]
        guard schedulerTypes.contains(method.receiverType),
              method.params.count == 1,
              let entryPoint = lifecycleEntryPointByType[method.params[0].type]
        else { continue }
        methods[index].interpretedLifecycleAdapter = .init(
            parameterIndex: 0, entryPoint: entryPoint)
    }

    return ParsedPlatformFramework(
        spec: spec, graph: graph, nominals: selected,
        supertypesByType: supertypesByType.mapValues { $0.sorted() },
        // `swift-symbolgraph-extract` does not promise array order. Stable
        // signature ordering keeps checked-in generation reproducible after a
        // clean cache or a different machine extracts the same SDK surface.
        constructors: constructors.sorted { $0.signatureKey < $1.signatureKey },
        methods: methods.sorted { $0.signatureKey < $1.signatureKey },
        staticMethods: staticMethods.sorted { $0.signatureKey < $1.signatureKey },
        globalFunctions: globalFunctions.sorted { $0.signatureKey < $1.signatureKey },
        globalProperties: globalProperties.sorted { $0.signatureKey < $1.signatureKey },
        properties: properties.sorted { $0.signatureKey < $1.signatureKey },
        staticProperties: staticProperties.sorted { $0.signatureKey < $1.signatureKey },
        enumValues: enumValues.sorted {
            ($0.framework, $0.type, $0.name) < ($1.framework, $1.type, $1.name)
        },
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
    let module = spec.extractionModule ?? spec.name
    let graph = output.appendingPathComponent("\(module).symbols.json")
    if FileManager.default.fileExists(atPath: graph.path) { return graph }
    _ = try runPlatformTool("/usr/bin/xcrun", [
        "swift-symbolgraph-extract",
        "-module-name", module,
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
           spec.deployments[availability.domain] != nil || availability.domain == "*" {
            return false
        }
        guard let deployment = spec.deployments[availability.domain] else { continue }
        if let introduced = availability.introduced {
            let version = (introduced.major, introduced.minor ?? 0)
            if version > (deployment.major, deployment.minor) {
                return false
            }
        }
        // Match the existing swiftinterface sweep: retired API remains in SDK
        // metadata for source compatibility, but should not grow a new bridge.
        if let deprecated = availability.deprecated {
            let version = (deprecated.major, deprecated.minor ?? 0)
            if version <= (deployment.major, deployment.minor) {
                return false
            }
        }
        if let obsoleted = availability.obsoleted {
            let version = (obsoleted.major, obsoleted.minor ?? 0)
            if version <= (deployment.major, deployment.minor) {
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
    allowNilOnlyPointers: Bool,
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
        let nativeType = platformNativeType(type.trimmedDescription)
        var normalized = platformContractType(nativeType)
        if normalized == "@escaping () -> Void" { normalized = "() -> Void" }
        if normalized == "() -> Void" { isAction = true }
        let nilOnly = platformTypeSupportsNilOnly(normalized)
        let pointerKind = platformPointerKind(nativeType)
        let readablePointer = pointerKind == .raw && !nilOnly
        guard isAction || platformTypeIsSupported(
            normalized, framework: framework,
            selectedTypes: selectedTypes)
            || readablePointer || (allowNilOnlyPointers && nilOnly) else {
            blockers["parameter \(normalized)", default: 0] += 1
            return nil
        }
        result.append(PlatformParameter(
            label: label, type: normalized, nativeType: nativeType,
            contractType: nilOnly ? "Never?"
                : (pointerKind != nil ? platformPointerContractType(nativeType) : normalized),
            hasDefault: parameter.defaultValue != nil,
            isAction: isAction, pointerKind: pointerKind))
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
    "Void", "()", "Any", "Error", "Bool", "String", "Substring", "Character",
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float", "CGFloat", "TimeInterval",
    "CGPoint", "CGSize", "CGRect", "CGVector", "CGAffineTransform",
    "CGColor", "CGImage", "URL", "Data", "Date", "IndexPath", "NSRange",
    "ComparisonResult", "Bundle", "Notification.Name", "NSAttributedString",
]

/// Clang overlays expose compatibility spellings that are true aliases of a
/// Swift/CoreGraphics type. Keep the canonicalization table shared by emitted
/// member contracts and runtime constructor lookup so an alias has exactly
/// the same behavior as its canonical type at every bridge boundary.
private let platformContractAliases: [String: String] = [
    "NSRect": "CGRect",
    "NSPoint": "CGPoint",
    "NSSize": "CGSize",
    "NSNotification.Name": "Notification.Name",
    // CoreLocation's scalar measures are true Double typealiases.
    "CLLocationDistance": "Double",
    "CLLocationDirection": "Double",
    "CLLocationDegrees": "Double",
    "CLLocationAccuracy": "Double",
    "CLLocationSpeed": "Double",
]

private func platformContractType(_ type: String) -> String {
    var result = type.trimmingCharacters(in: .whitespacesAndNewlines)
    if result == "()" { return "Void" }
    while result.hasPrefix("@escaping ") {
        result = String(result.dropFirst("@escaping ".count))
    }
    while result.hasPrefix("@Sendable ") {
        result = String(result.dropFirst("@Sendable ".count))
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
    if result.hasPrefix("("), result.hasSuffix(")") {
        return platformContractType(String(result.dropFirst().dropLast()))
    }
    if result.hasPrefix("any ") {
        return platformContractType(String(result.dropFirst("any ".count)))
    }
    if let (key, value) = platformDictionaryComponents(result) {
        return "[\(platformContractType(key)): \(platformContractType(value))]"
    }
    if result.hasPrefix("["), result.hasSuffix("]"), !result.contains(":") {
        return "[" + platformContractType(String(result.dropFirst().dropLast())) + "]"
    }
    if result.hasPrefix("Array<"), result.hasSuffix(">") {
        return "[" + platformContractType(
            String(result.dropFirst("Array<".count).dropLast())) + "]"
    }
    return platformContractAliases[result] ?? memberContractType(for: result)
}

/// Preserve the compiler-facing existential and pointer spelling while still
/// applying true imported typealiases. Host signatures use
/// `platformContractType`; emitted SDK calls use this form.
private func platformNativeType(_ type: String) -> String {
    var result = normalize(type).trimmingCharacters(in: .whitespacesAndNewlines)
    if result == "()" { return "Void" }
    if result.hasSuffix("!") {
        return platformNativeType(String(result.dropLast())) + "?"
    }
    for (alias, canonical) in platformContractAliases {
        result = result.replacingOccurrences(of: alias, with: canonical)
    }
    return result
}

private func platformPointerKind(_ rawType: String) -> PlatformPointerKind? {
    var type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    if type.hasSuffix("?") { type.removeLast() }
    if type.hasPrefix("Optional<"), type.hasSuffix(">") {
        type = String(type.dropFirst("Optional<".count).dropLast())
    }
    switch type {
    case "UnsafeRawPointer": return .raw
    case "UnsafeMutableRawPointer": return .mutableRaw
    case "UnsafeMutablePointer<UInt8>": return .mutableBytes
    default: return nil
    }
}

private func platformPointerContractType(_ rawType: String) -> String {
    let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    return (type.hasSuffix("?")
        || (type.hasPrefix("Optional<") && type.hasSuffix(">"))) ? "Any?" : "Any"
}

private func platformTypeIsSupported(
    _ rawType: String,
    framework: String,
    selectedTypes: Set<String>
) -> Bool {
    let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    if type.hasPrefix("some ")
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
    if let (key, value) = platformDictionaryComponents(type) {
        return platformTypeIsSupported(
            key, framework: framework, selectedTypes: selectedTypes)
            && platformTypeIsSupported(
                value, framework: framework, selectedTypes: selectedTypes)
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

private func platformTypeReferencesSelected(
    _ rawType: String, selectedTypes: Set<String>
) -> Bool {
    var type = platformContractType(rawType)
    if type.hasSuffix("?") { type.removeLast() }
    if let (key, value) = platformDictionaryComponents(type) {
        return platformTypeReferencesSelected(key, selectedTypes: selectedTypes)
            || platformTypeReferencesSelected(value, selectedTypes: selectedTypes)
    }
    if type.hasPrefix("["), type.hasSuffix("]") {
        return platformTypeReferencesSelected(
            String(type.dropFirst().dropLast()), selectedTypes: selectedTypes)
    }
    return selectedTypes.contains(type)
}

/// Unsafe pointer constructor parameters are mechanically bridgeable when
/// source passes `nil`: Optional's shared runtime adapter can construct the
/// statically typed nil without manufacturing or dereferencing a pointer.
/// Methods with pointer parameters stay on the typed inert fallback until the
/// runtime has real inout storage; emitting a nil-only overload there would
/// incorrectly shadow valid `&value` calls.
private func platformTypeSupportsNilOnly(_ rawType: String) -> Bool {
    let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    let wrapped: String
    if type.hasSuffix("?") {
        wrapped = String(type.dropLast())
    } else if type.hasPrefix("Optional<"), type.hasSuffix(">") {
        wrapped = String(type.dropFirst("Optional<".count).dropLast())
    } else {
        return false
    }
    let name = wrapped.prefix { $0 != "<" }
    return [
        "UnsafePointer", "UnsafeMutablePointer",
        "UnsafeRawPointer", "UnsafeMutableRawPointer",
        "AutoreleasingUnsafeMutablePointer",
    ].contains(String(name))
}

private func platformDictionaryComponents(
    _ rawType: String
) -> (key: String, value: String)? {
    let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
    guard type.hasPrefix("["), type.hasSuffix("]") else { return nil }
    let inner = type.dropFirst().dropLast()
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
            let key = inner[..<index].trimmingCharacters(in: .whitespaces)
            let value = inner[inner.index(after: index)...]
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return (key, value)
        default: break
        }
    }
    return nil
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
    // GENERATED by BridgeGen from Foundation/AppKit/UIKit/WebKit/Metal/MapKit/CoreLocation SDK symbol graphs.
    // Do not edit. Regenerate: swift run BridgeGen --emit
    import Foundation
    import SwiftInterpreter
    #if canImport(AppKit)
    import AppKit
    #elseif canImport(UIKit)
    import UIKit
    #endif
    #if canImport(Metal)
    import Metal
    #endif
    #if canImport(MapKit)
    import MapKit
    #endif
    #if canImport(CoreLocation)
    import CoreLocation
    #endif
    #if canImport(UIKit) && canImport(WebKit)
    import WebKit
    #endif

    extension GeneratedPlatformBridge {

    """
    let constructorGroups = frameworks.map { ($0.spec.name, $0.constructors) }
    let methodGroups = frameworks.map { ($0.spec.name, $0.methods) }
    let staticMethodGroups = frameworks.map { ($0.spec.name, $0.staticMethods) }
    let globalFunctionGroups = frameworks.map { ($0.spec.name, $0.globalFunctions) }
    let globalPropertyGroups = frameworks.map { ($0.spec.name, $0.globalProperties) }
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
        name: "GlobalFunctions",
        tableType: "[String: [GeneratedPlatformGlobalFunctionEntry]]",
        groups: globalFunctionGroups,
        entry: emitPlatformGlobalFunction)
    output += emitBuilder(
        name: "GlobalProperties",
        tableType: "[String: [GeneratedPlatformGlobalPropertyEntry]]",
        groups: globalPropertyGroups,
        entry: emitPlatformGlobalProperty)
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

    output += "\n    static func buildEqualityAdapters() -> [GeneratedPlatformTypeKey: GeneratedPlatformEqualityAdapter] {\n"
    output += "        var t: [GeneratedPlatformTypeKey: GeneratedPlatformEqualityAdapter] = [:]\n"
    for framework in frameworks {
        let equatable = framework.nominals.values
            .filter(\.isEquatable)
            .sorted(by: { $0.type < $1.type })
        guard !equatable.isEmpty else { continue }
        output += "#if \(platformNativeImportCondition(for: framework.spec.name))\n"
        for nominal in equatable {
            output += "        registerEqualityAdapter(&t, framework: \(swiftLiteral(framework.spec.name)), type: \(swiftLiteral(nominal.type)), \(nominal.type).self)\n"
        }
        output += "#endif\n"
    }
    output += "        return t\n    }\n"

    output += "\n    static func buildNominalKinds() -> [GeneratedPlatformTypeKey: Bool] {\n"
    output += "        var t: [GeneratedPlatformTypeKey: Bool] = [:]\n"
    for framework in frameworks {
        for nominal in framework.nominals.values.sorted(by: { $0.type < $1.type }) {
            output += "        t[GeneratedPlatformTypeKey(framework: \(swiftLiteral(framework.spec.name)), type: \(swiftLiteral(nominal.type)))] = \(nominal.kind.isValueType)\n"
        }
    }
    output += "        return t\n    }\n"

    output += "\n    static func buildSupertypes() -> [GeneratedPlatformTypeKey: [String]] {\n"
    output += "        var t: [GeneratedPlatformTypeKey: [String]] = [:]\n"
    for framework in frameworks {
        for (type, parents) in framework.supertypesByType.sorted(by: { $0.key < $1.key }) {
            let list = parents.map(swiftLiteral).joined(separator: ", ")
            output += "        t[GeneratedPlatformTypeKey(framework: \(swiftLiteral(framework.spec.name)), type: \(swiftLiteral(type)))] = [\(list)]\n"
        }
    }
    output += "        return t\n    }\n"

    output += "\n    static func buildTypeAliases() -> [String: String] {\n"
    output += "        [\n"
    for (alias, canonical) in platformContractAliases.sorted(by: {
        $0.key < $1.key
    }) {
        output += "            \(swiftLiteral(alias)): \(swiftLiteral(canonical)),\n"
    }
    output += "        ]\n    }\n"
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
        isThrowing: value.isThrowing,
        resultPointerKind: value.resultPointerKind,
        pointerOwner: nil)
    body = wrapPlatformPointerArguments(
        body, params: value.params, framework: value.framework)
    body = indent(body, by: 12)
    return """
            registerConstructor(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.hostDeclaration)),
                resultType: \(swiftLiteral(value.resultType))) { v, ctx in
    #if \(platformNativeImportCondition(for: value.framework))
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
        isThrowing: value.isThrowing,
        resultPointerKind: value.resultPointerKind,
        pointerOwner: "base")
    invocation = wrapPlatformPointerArguments(
        invocation, params: value.params, framework: value.framework)
    invocation = indent(invocation, by: 12)
    let interpretedLifecycle = value.interpretedLifecycleAdapter.map { adapter in
        """
                    if generatedPlatformScheduleInterpretedLifecycle(
                        v[\(adapter.parameterIndex)],
                        entryPoint: \(swiftLiteral(adapter.entryPoint)), context: ctx
                    ) {
                        return .void
                    }
        """ + "\n"
    } ?? ""
    return """
            registerMethod(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.hostDeclaration)),
                resultType: \(swiftLiteral(value.resultType))) { base, v, ctx in
    #if \(platformNativeImportCondition(for: value.framework))
    \(interpretedLifecycle)            guard let receiver = base.payload as? \(value.nativeReceiverType) else {
                    throw RuntimeError(message: "generated \(value.framework) receiver mismatch", fatal: true)
                }
    \(invocation)
    #else
                preconditionFailure("\(value.framework) gateway invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformGlobalFunction(_ value: PlatformCallable) -> String {
    let arguments = platformCallArguments(value.params)
    let call = "`\(value.name)`(\(arguments))"
    var body = platformInvocationBody(
        call: call, resultType: value.resultType,
        framework: value.framework,
        isThrowing: value.isThrowing,
        resultPointerKind: value.resultPointerKind,
        pointerOwner: nil)
    body = wrapPlatformPointerArguments(
        body, params: value.params, framework: value.framework)
    body = indent(body, by: 12)
    return """
            registerGlobalFunction(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.hostDeclaration)),
                resultType: \(swiftLiteral(value.resultType))) { v, ctx in
    #if \(platformNativeImportCondition(for: value.framework))
    \(body)
    #else
                preconditionFailure("\(value.framework) gateway invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformGlobalProperty(_ value: PlatformGlobalProperty) -> String {
    let result: String
    if value.pointerKind != nil {
        result = "generatedPlatformPointerResult(`\(value.name)`, owner: nil, declaredType: \(swiftLiteral(value.resultType)))"
    } else {
        result = "generatedPlatformResult(`\(value.name)`, framework: \(swiftLiteral(value.framework)), declaredType: \(swiftLiteral(value.resultType)))"
    }
    return """
            registerGlobalProperty(
                &t, framework: \(swiftLiteral(value.framework)),
                name: \(swiftLiteral(value.name)),
                resultType: \(swiftLiteral(value.resultType)),
                isImplicitlyUnwrapped: \(value.isImplicitlyUnwrapped)) {
    #if \(platformNativeImportCondition(for: value.framework))
                return \(result)
    #else
                preconditionFailure("\(value.framework) global getter invoked off-platform")
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
        isThrowing: value.isThrowing,
        resultPointerKind: value.resultPointerKind,
        pointerOwner: nil)
    body = wrapPlatformPointerArguments(
        body, params: value.params, framework: value.framework)
    body = indent(body, by: 12)
    return """
            registerStaticMethod(
                &t, framework: \(swiftLiteral(value.framework)),
                declaration: \(swiftLiteral(value.hostDeclaration)),
                resultType: \(swiftLiteral(value.resultType))) { v, ctx in
    #if \(platformNativeImportCondition(for: value.framework))
    \(body)
    #else
                preconditionFailure("\(value.framework) gateway invoked off-platform")
    #endif
            }
    """
}

private func emitPlatformProperty(_ value: PlatformProperty) -> String {
    let iuoArgument = value.isImplicitlyUnwrapped
        ? "\n            isImplicitlyUnwrapped: true,"
        : ""
    let setter: String
    if value.isSettable {
        let binding = value.receiverIsValueType ? "var" : "let"
        setter = """
                }, set: { base, newValue, ctx in
    #if \(platformNativeImportCondition(for: value.framework))
                    guard \(binding) receiver = base as? \(value.nativeReceiverType) else {
                        throw RuntimeError(message: "generated \(value.framework) property receiver mismatch", fatal: true)
                    }
                    receiver.`\(value.name)` = try generatedPlatformArgument(
                        newValue, as: \(platformNativeMetatype(value.nativeResultType)),
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
                resultType: \(swiftLiteral(value.resultType)),\(iuoArgument)
                get: { base in
    #if \(platformNativeImportCondition(for: value.framework))
                    guard let receiver = base as? \(value.nativeReceiverType) else {
                        throw RuntimeError(message: "generated \(value.framework) property receiver mismatch", fatal: true)
                    }
                    return \(platformPropertyResultExpression(value))
    #else
                    preconditionFailure("\(value.framework) getter invoked off-platform")
    #endif
    \(setter)
    """
}

private func emitPlatformStaticProperty(_ value: PlatformProperty) -> String {
    let iuoArgument = value.isImplicitlyUnwrapped
        ? "\n            isImplicitlyUnwrapped: true,"
        : ""
    return """
            registerStaticProperty(
                &t, framework: \(swiftLiteral(value.framework)),
                type: \(swiftLiteral(value.receiverType)),
                name: \(swiftLiteral(value.name)),
                resultType: \(swiftLiteral(value.resultType)),\(iuoArgument)
                get: {
    #if \(platformNativeImportCondition(for: value.framework))
                generatedPlatformResult(
                    \(value.receiverType).`\(value.name)`,
                    framework: \(swiftLiteral(value.framework)),
                    declaredType: \(swiftLiteral(value.resultType)))
    #else
                preconditionFailure("\(value.framework) getter invoked off-platform")
    #endif
            })
    """
}

private func emitPlatformEnumValue(_ value: PlatformEnumValue) -> String {
    """
            registerEnumValue(
                &t, framework: \(swiftLiteral(value.framework)),
                type: \(swiftLiteral(value.type)), name: \(swiftLiteral(value.name))) {
    #if \(platformNativeImportCondition(for: value.framework))
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

private func platformNativeImportCondition(for framework: String) -> String {
    platformFrameworkSpecs.first(where: { $0.name == framework })?
        .nativeImportCondition ?? "canImport(\(framework))"
}

private func platformCallArguments(_ params: [PlatformParameter]) -> String {
    params.enumerated().map { index, parameter in
        let expression: String
        if parameter.pointerKind == .raw && parameter.contractType == "Any" {
            expression = "p\(index)"
        } else if parameter.isAction {
            expression = "generatedAction(try GeneratedDispatch.coerce(.action, v[\(index)], ctx))"
        } else {
            expression = "try generatedPlatformArgument(v[\(index)], as: \(platformNativeMetatype(parameter.nativeType)), framework: \(swiftLiteral("__FRAMEWORK__")), typeName: \(swiftLiteral(parameter.type)), context: ctx)"
        }
        return (parameter.label.map { "\($0): " } ?? "") + expression
    }.joined(separator: ", ")
}

private func platformInvocationBody(
    call: String,
    resultType: String,
    framework: String,
    isThrowing: Bool,
    resultPointerKind: PlatformPointerKind?,
    pointerOwner: String?
) -> String {
    let fixedCall = call.replacingOccurrences(
        of: swiftLiteral("__FRAMEWORK__"), with: swiftLiteral(framework))
    let prefix = isThrowing ? "try " : ""
    if resultType == "Void" || resultType == "()" {
        return "\(prefix)\(fixedCall)\nreturn .void"
    }
    if resultPointerKind != nil {
        return "return generatedPlatformPointerResult(\(prefix)\(fixedCall), owner: \(pointerOwner ?? "nil"), declaredType: \(swiftLiteral(resultType)))"
    }
    return "return generatedPlatformResult(\(prefix)\(fixedCall), framework: \(swiftLiteral(framework)), declaredType: \(swiftLiteral(resultType)))"
}

private func wrapPlatformPointerArguments(
    _ body: String, params: [PlatformParameter], framework: String
) -> String {
    var result = body
    for (index, parameter) in params.enumerated().reversed()
        where parameter.pointerKind == .raw && parameter.contractType == "Any"
    {
        result = """
        return try generatedPlatformWithUnsafeRawPointer(
            v[\(index)], context: ctx
        ) { p\(index) in
        \(indent(result, by: 4))
        }
        """
    }
    return result
}

private func platformPropertyResultExpression(_ value: PlatformProperty) -> String {
    if value.pointerKind != nil {
        return "generatedPlatformPointerResult(receiver.`\(value.name)`, owner: base, declaredType: \(swiftLiteral(value.resultType)))"
    }
    return "generatedPlatformResult(receiver.`\(value.name)`, framework: \(swiftLiteral(value.framework)), declaredType: \(swiftLiteral(value.resultType)))"
}

private func platformNativeMetatype(_ type: String) -> String {
    type.hasPrefix("any ") ? "(\(type)).self" : "\(type).self"
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

/// Foundation's unit-system statics from the Foundation SYMBOL GRAPH — the
/// NSUnit family is Clang-imported and absent from the textual
/// swiftinterface. Returns (container, name) pairs for every `class var`
/// on a Dimension subclass whose type is the class itself.
func sweptFoundationDimensionStatics() -> [(container: String, name: String)] {
    let spec = PlatformFrameworkSpec(
        name: "Foundation", sdkName: "macosx",
        target: "arm64-apple-macosx15.0",
        deployments: ["macOS": (15, 0)],
        roots: [])
    guard let graphURL = try? platformSymbolGraphURL(for: spec),
          let graph = try? JSONDecoder().decode(
              SymbolGraph.self, from: Data(contentsOf: graphURL)) else {
        print("warning: no Foundation symbol graph for the unit sweep")
        return []
    }
    var classByID: [String: String] = [:]
    for symbol in graph.symbols where symbol.kind.identifier == "swift.class" {
        guard symbol.pathComponents.count == 1 else { continue }
        classByID[symbol.identifier.precise] = symbol.pathComponents[0]
    }
    // Dimension subclasses: walk inheritsFrom up to "Dimension".
    var parentOf: [String: String] = [:]
    for relationship in graph.relationships where relationship.kind == "inheritsFrom" {
        guard let child = classByID[relationship.source],
              let parent = classByID[relationship.target] else { continue }
        parentOf[child] = parent
    }
    func descendsFromDimension(_ name: String) -> Bool {
        var current: String? = name
        var hops = 0
        while let value = current, hops < 8 {
            if value == "Dimension" { return true }
            current = parentOf[value]
            hops += 1
        }
        return false
    }
    var result: [(container: String, name: String)] = []
    for symbol in graph.symbols where symbol.kind.identifier == "swift.type.property" {
        guard symbol.pathComponents.count == 2 else { continue }
        let container = symbol.pathComponents[0]
        let name = symbol.pathComponents[1]
        guard descendsFromDimension(container),
              platformSymbolIsAvailable(symbol, for: spec),
              symbol.declaration.contains(": \(container)")
                || symbol.declaration.contains("-> \(container)") else { continue }
        result.append((container: container, name: name))
    }
    return result
}
