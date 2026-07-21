import Foundation

struct CMemoryGenerationResult {
    let output: String
    let functionNames: [String]
    let recordNames: [String]
}

private struct ClangASTNode: Decodable {
    struct TypeInfo: Decodable {
        let qualType: String?
        let desugaredQualType: String?
    }

    let kind: String
    let name: String?
    let isImplicit: Bool?
    let type: TypeInfo?
    let inner: [ClangASTNode]?
}

private struct DarwinCInteropSymbolGraph: Decodable {
    struct Symbol: Decodable {
        struct Identifier: Decodable { let precise: String }
        struct Kind: Decodable { let identifier: String }
        struct Fragment: Decodable {
            let kind: String
            let spelling: String
            let preciseIdentifier: String?
        }
        struct FunctionSignature: Decodable {
            struct Parameter: Decodable {
                let declarationFragments: [Fragment]?
            }

            let parameters: [Parameter]?
            let returns: [Fragment]?
        }

        let identifier: Identifier
        let kind: Kind
        let pathComponents: [String]
        let declarationFragments: [Fragment]?
        let functionSignature: FunctionSignature?

        var declaration: String {
            declarationFragments?.map(\.spelling).joined() ?? ""
        }
    }

    let symbols: [Symbol]
}

private struct DarwinCharacterRecordFunction: Hashable {
    let name: String
    let recordName: String
    let fields: [String]
}

/// Darwin's imported C records are not present in a Swift interface, but the
/// SDK symbol graph does preserve their synthesized zero-argument initializer,
/// stored fields, and pointer use at global C functions. Select the complete
/// one-out-parameter family whose record consists only of fixed CChar buffers.
/// This property yields `uname(utsname *)` today without naming either API in
/// the generator or runtime, and gives the emitted adapter enough metadata to
/// copy every native field back into the interpreted record.
private func discoverDarwinCharacterRecordFunctions(
    sdkPath: String
) throws -> [DarwinCharacterRecordFunction] {
    let sdkKey = URL(fileURLWithPath: sdkPath).lastPathComponent
        .replacingOccurrences(of: ".", with: "-")
    let output = URL(fileURLWithPath: ".build/bridgegen-symbolgraphs")
        .appendingPathComponent(sdkKey)
        .appendingPathComponent("DarwinCInterop")
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true)
    let graphURL = output.appendingPathComponent("Darwin.symbols.json")
    if !FileManager.default.fileExists(atPath: graphURL.path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift-symbolgraph-extract",
            "-module-name", "Darwin",
            "-minimum-access-level", "public",
            "-sdk", sdkPath,
            "-target", "arm64-apple-macosx15.0",
            "-output-dir", output.path,
        ]
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? ""
            throw NSError(
                domain: "BridgeGen.CMemory", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "Darwin symbol-graph sweep failed:\n\(message)"])
        }
    }

    let graph = try JSONDecoder().decode(
        DarwinCInteropSymbolGraph.self,
        from: Data(contentsOf: graphURL))
    let records = Set(graph.symbols.compactMap { symbol -> String? in
        guard symbol.kind.identifier == "swift.struct",
              symbol.identifier.precise.hasPrefix("c:@S@"),
              symbol.pathComponents.count == 1 else { return nil }
        return symbol.pathComponents[0]
    })
    let zeroArgumentRecords = Set(graph.symbols.compactMap { symbol -> String? in
        guard symbol.kind.identifier == "swift.init",
              symbol.pathComponents.count == 2,
              symbol.pathComponents[1] == "init()",
              let record = symbol.pathComponents.first,
              records.contains(record) else { return nil }
        return record
    })

    var characterFieldsByRecord: [String: [String]] = [:]
    for record in zeroArgumentRecords {
        let properties = graph.symbols.filter {
            $0.kind.identifier == "swift.property"
                && $0.pathComponents.count == 2
                && $0.pathComponents[0] == record
        }
        guard !properties.isEmpty else { continue }
        var fields: [String] = []
        for property in properties {
            let types = (property.declarationFragments ?? []).filter {
                $0.kind == "typeIdentifier"
            }
            guard types.count > 1,
                  types.allSatisfy({ $0.spelling == "CChar" }),
                  property.declaration.contains(": (") else {
                fields = []
                break
            }
            fields.append(property.pathComponents[1])
        }
        if !fields.isEmpty {
            characterFieldsByRecord[record] = fields.sorted()
        }
    }

    var candidatesByName: [String: Set<DarwinCharacterRecordFunction>] = [:]
    for symbol in graph.symbols {
        guard symbol.kind.identifier == "swift.func",
              symbol.pathComponents.count == 1,
              let signature = symbol.functionSignature,
              let parameters = signature.parameters,
              parameters.count == 1,
              signature.returns?.map(\.spelling).joined() == "Int32",
              let fragments = parameters[0].declarationFragments,
              fragments.map(\.spelling).joined().contains("UnsafeMutablePointer<"),
              let recordFragment = fragments.first(where: {
                  $0.kind == "typeIdentifier"
                      && $0.preciseIdentifier?.hasPrefix("c:@S@") == true
                      && characterFieldsByRecord[$0.spelling] != nil
              }),
              let fields = characterFieldsByRecord[recordFragment.spelling],
              let name = symbol.declarationFragments?.first(where: {
                  $0.kind == "identifier"
              })?.spelling else { continue }
        candidatesByName[name, default: []].insert(
            DarwinCharacterRecordFunction(
                name: name,
                recordName: recordFragment.spelling,
                fields: fields))
    }

    return candidatesByName.values.compactMap { candidates in
        candidates.count == 1 ? candidates.first : nil
    }.sorted { ($0.name, $0.recordName) < ($1.name, $1.recordName) }
}

/// Clang's implicit libc builtins are callable from Swift but omitted from
/// Darwin's symbol graph. Sweep the SDK header AST and select the read-only
/// relative-pointer family by declaration properties: builtin function,
/// pointer result, and `(const void *, int, size_t)` parameters. The emitted
/// call uses the metadata-provided spelling, so runtime code contains no C API
/// name allowlist.
func generateCMemoryBridge(sdkPath: String) throws -> CMemoryGenerationResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "clang", "-isysroot", sdkPath,
        "-x", "c", "-std=c17",
        "-Xclang", "-ast-dump=json",
        "-fsyntax-only", "-include", "string.h", "/dev/null",
    ]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    // AST JSON is larger than a pipe's kernel buffer. Drain it while clang
    // runs; waiting first would deadlock once that buffer fills.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "BridgeGen.CMemory", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey:
                "clang string.h AST sweep failed:\n\(errorText)"])
    }

    let root = try JSONDecoder().decode(ClangASTNode.self, from: data)
    var selected = Set<String>()
    func visit(_ node: ClangASTNode) {
        defer { node.inner?.forEach(visit) }
        guard node.kind == "FunctionDecl",
              node.isImplicit != true,
              let name = node.name,
              name.first?.isLetter == true,
              let functionType = node.type?.qualType,
              functionType.hasPrefix("void *("),
              node.inner?.contains(where: { $0.kind == "BuiltinAttr" }) == true
        else { return }
        let parameters = (node.inner ?? []).filter { $0.kind == "ParmVarDecl" }
        guard parameters.count == 3 else { return }
        func canonicalType(_ parameter: ClangASTNode) -> String {
            parameter.type?.desugaredQualType
                ?? parameter.type?.qualType ?? ""
        }
        guard canonicalType(parameters[0]) == "const void *",
              canonicalType(parameters[1]) == "int",
              canonicalType(parameters[2]) == "unsigned long"
        else { return }
        selected.insert(name)
    }
    visit(root)
    let names = selected.sorted()
    let recordFunctions = try discoverDarwinCharacterRecordFunctions(
        sdkPath: sdkPath)
    let recordNames = Array(Set(recordFunctions.map(\.recordName))).sorted()

    var source = """
    // GENERATED by BridgeGen from the Darwin SDK's Clang AST and symbol graph.
    // Do not edit. Regenerate: swift run BridgeGen --emit
    import Darwin
    import SwiftInterpreter

    enum GeneratedCMemoryBridge {
        static func record(named name: String) -> GeneratedCRecordValue? {
            switch name {

    """
    for name in recordNames {
        source += """
            case \(String(reflecting: name)):
                return GeneratedCRecordValue(typeName: name)

        """
    }
    source += """
            default:
                return nil
            }
        }

        static func function(named name: String) -> HostFunction? {
            switch name {

    """
    for name in names {
        source += """
            case \(String(reflecting: name)):
                return HostFunction(name: name) { args, _ in
                    try generatedCRelativePointerFunction(
                        memory: args.positional(0),
                        scalar: args.positional(1),
                        count: args.positional(2)
                    ) { pointer, scalar, count in
                        Darwin.`\(name)`(pointer, scalar, count)
                    }
                }

        """
    }
    for function in recordFunctions {
        source += """
            case \(String(reflecting: function.name)):
                return HostFunction(name: name) { args, _ in
                    guard case .host(let any)? = args.positional(0),
                          let record = any as? GeneratedCRecordValue,
                          record.typeName == \(String(reflecting: function.recordName)) else {
                        throw RuntimeError(message:
                            "\\(name) needs an inout \(function.recordName)")
                    }
                    var native = Darwin.`\(function.recordName)`()
                    let result = Darwin.`\(function.name)`(&native)

        """
        for field in function.fields {
            source += """
                    record.members[\(String(reflecting: field))] = .native(
                        generatedCCharacterBuffer(native.`\(field)`))

            """
        }
        source += """
                    return .native(Int(result))
                }

        """
    }
    source += """
            default:
                return nil
            }
        }
    }
    """
    return CMemoryGenerationResult(
        output: source + "\n",
        functionNames: (names + recordFunctions.map(\.name)).sorted(),
        recordNames: recordNames)
}
