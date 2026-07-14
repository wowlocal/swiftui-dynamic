import Foundation
import SwiftParser
import SwiftSyntax

private enum GenerationError: Error, CustomStringConvertible {
    case missingArgument(String)
    case commandFailed(String)
    case interfaceNotFound(String)
    case unreadableInterface(String)
    case missingIntrinsics([String])
    case missingGeneratedOutput(String)
    case staleGeneratedOutput(String)

    var description: String {
        switch self {
        case .missingArgument(let flag):
            "missing value after \(flag)"
        case .commandFailed(let command):
            "command failed: \(command)"
        case .interfaceNotFound(let root):
            "could not locate _Concurrency.swiftinterface below \(root)"
        case .unreadableInterface(let path):
            "could not read _Concurrency.swiftinterface at \(path)"
        case .missingIntrinsics(let names):
            "active _Concurrency.swiftinterface is missing required task-group "
                + "members: \(names.joined(separator: ", "))"
        case .missingGeneratedOutput(let path):
            "generated output is missing at \(path)"
        case .staleGeneratedOutput(let path):
            "generated output is stale at \(path); run swift run "
                + "ConcurrencySurfaceGen"
        }
    }
}

private let checkFlag = "--check"
private let outputFlag = "--output"
private let interfaceFlag = "--interface"
private let defaultOutput =
    "Sources/SwiftInterpreter/Generated/GeneratedConcurrencySurface.swift"
private let taskGroupTypes: Set<String> = ["TaskGroup", "ThrowingTaskGroup"]
private let supportedIntrinsics: Set<String> = [
    "addTask", "addTaskUnlessCancelled", "waitForAll", "next",
    "cancelAll", "isCancelled", "isEmpty",
]

private func argument(after flag: String) throws -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else {
        return nil
    }
    guard CommandLine.arguments.indices.contains(index + 1) else {
        throw GenerationError.missingArgument(flag)
    }
    return CommandLine.arguments[index + 1]
}

private func command(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GenerationError.commandFailed(
            ([executable] + arguments).joined(separator: " "))
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func activeInterfacePath() throws -> String {
    let sdk = try command(
        "/usr/bin/xcrun", ["--show-sdk-path", "--sdk", "macosx"])
    let architecture = try command("/usr/bin/uname", ["-m"])
    let directory = sdk + "/usr/lib/swift/_Concurrency.swiftmodule"
    let candidates = try FileManager.default.contentsOfDirectory(
        atPath: directory
    ).filter {
        $0.hasSuffix("-apple-macos.swiftinterface")
    }.sorted()
    let prefix = architecture == "arm64" ? "arm64" : architecture
    guard let file = candidates.first(where: { $0.hasPrefix(prefix) })
            ?? candidates.first else {
        throw GenerationError.interfaceNotFound(directory)
    }
    return directory + "/" + file
}

private func normalizedTypeName(_ text: String) -> String {
    let withoutModule = text.replacingOccurrences(of: "_Concurrency.", with: "")
    return withoutModule.split(separator: "<", maxSplits: 1).first.map(String.init)
        ?? withoutModule
}

private func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.public) }
}

private func aliasedIntrinsic(in function: FunctionDeclSyntax) -> String? {
    let body = function.body?.trimmedDescription ?? ""
    for intrinsic in ["addTaskUnlessCancelled", "addTask"] {
        if body.range(
            of: #"\b"# + intrinsic + #"\s*\("#,
            options: .regularExpression
        ) != nil {
            return intrinsic
        }
    }
    return nil
}

private func inspect(
    _ members: MemberBlockItemListSyntax,
    knownNames: inout Set<String>,
    dispatch: inout [String: String]
) {
    for item in members {
        if let function = item.decl.as(FunctionDeclSyntax.self),
           isPublic(function.modifiers) {
            let name = function.name.text
            knownNames.insert(name)
            if supportedIntrinsics.contains(name) {
                dispatch[name] = name
            } else if let intrinsic = aliasedIntrinsic(in: function) {
                dispatch[name] = intrinsic
            }
            continue
        }
        guard let variable = item.decl.as(VariableDeclSyntax.self),
              isPublic(variable.modifiers) else { continue }
        for binding in variable.bindings {
            guard let identifier = binding.pattern.as(
                IdentifierPatternSyntax.self
            ) else { continue }
            let name = identifier.identifier.text
            knownNames.insert(name)
            if supportedIntrinsics.contains(name) {
                dispatch[name] = name
            }
        }
    }
}

private func escaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func portableInterfaceLabel(_ path: String) -> String {
    guard let range = path.range(of: "/usr/lib/swift/") else {
        return URL(fileURLWithPath: path).lastPathComponent
    }
    return "<macOS SDK>" + path[range.lowerBound...]
}

private func generatedSource(
    interfacePath: String,
    interfaceSource: String
) throws -> String {
    let syntax = Parser.parse(source: interfaceSource)
    var knownNames: Set<String> = []
    var dispatch: [String: String] = [:]

    for statement in syntax.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        if let structure = declaration.as(StructDeclSyntax.self),
           taskGroupTypes.contains(structure.name.text) {
            inspect(
                structure.memberBlock.members,
                knownNames: &knownNames,
                dispatch: &dispatch)
        } else if let extensionDeclaration = declaration.as(
            ExtensionDeclSyntax.self
        ), taskGroupTypes.contains(normalizedTypeName(
            extensionDeclaration.extendedType.trimmedDescription
        )) {
            inspect(
                extensionDeclaration.memberBlock.members,
                knownNames: &knownNames,
                dispatch: &dispatch)
        }
    }

    let missing = supportedIntrinsics.subtracting(dispatch.values).sorted()
    guard missing.isEmpty else {
        throw GenerationError.missingIntrinsics(missing)
    }
    let compilerVersion = interfaceSource.split(separator: "\n").first {
        $0.hasPrefix("// swift-compiler-version:")
    }.map(String.init) ?? "// swift-compiler-version: unknown"
    let dispatchLines = dispatch.keys.sorted().map { sourceName in
        "        \"\(escaped(sourceName))\": .\(dispatch[sourceName]!),"
    }.joined(separator: "\n")
    let knownLines = knownNames.sorted().map {
        "        \"\(escaped($0))\","
    }.joined(separator: "\n")

    return """
    // GENERATED by ConcurrencySurfaceGen from the active _Concurrency.swiftinterface.
    // Do not edit. Regenerate: swift run ConcurrencySurfaceGen
    // Source: \(portableInterfaceLabel(interfacePath))
    \(compilerVersion)

    enum RuntimeTaskGroupIntrinsic: String, Sendable {
        case addTask
        case addTaskUnlessCancelled
        case waitForAll
        case next
        case cancelAll
        case isCancelled
        case isEmpty
    }

    enum GeneratedConcurrencySurface {
        static let taskGroupDispatch: [String: RuntimeTaskGroupIntrinsic] = [
    \(dispatchLines)
        ]

        static let knownTaskGroupMembers: Set<String> = [
    \(knownLines)
        ]
    }
    """ + "\n"
}

private func run() throws {
    let interfacePath = try argument(after: interfaceFlag)
        ?? activeInterfacePath()
    let outputPath = try argument(after: outputFlag) ?? defaultOutput
    guard let source = try? String(
        contentsOfFile: interfacePath, encoding: .utf8
    ) else {
        throw GenerationError.unreadableInterface(interfacePath)
    }
    let output = try generatedSource(
        interfacePath: interfacePath, interfaceSource: source)
    if CommandLine.arguments.contains(checkFlag) {
        guard let existing = try? String(
            contentsOfFile: outputPath, encoding: .utf8
        ) else {
            throw GenerationError.missingGeneratedOutput(outputPath)
        }
        guard existing == output else {
            throw GenerationError.staleGeneratedOutput(outputPath)
        }
        print("verified \(outputPath)")
        return
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try output.write(to: outputURL, atomically: true, encoding: .utf8)
    print("wrote \(outputPath)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(
        Data("ConcurrencySurfaceGen: \(error)\n".utf8))
    exit(1)
}
