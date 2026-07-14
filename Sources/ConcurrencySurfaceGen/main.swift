import Foundation
import SwiftParser
import SwiftSyntax

private enum GenerationError: Error, CustomStringConvertible {
    case missingArgument(String)
    case commandFailed(String)
    case interfaceNotFound(String)
    case unreadableInterface(String)
    case missingIntrinsics([String])
    case missingFunctions([String])
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
        case .missingFunctions(let names):
            "active _Concurrency.swiftinterface is missing required task-group "
                + "functions: \(names.joined(separator: ", "))"
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
private let taskGroupTypes = [
    "DiscardingTaskGroup", "TaskGroup", "ThrowingDiscardingTaskGroup",
    "ThrowingTaskGroup",
]
private let supportedIntrinsics: Set<String> = [
    "addTask", "addTaskUnlessCancelled", "waitForAll", "next",
    "cancelAll", "isCancelled", "isEmpty",
]
private let requiredIntrinsicsByType: [String: Set<String>] = [
    "DiscardingTaskGroup": [
        "addTask", "addTaskUnlessCancelled", "cancelAll", "isCancelled",
        "isEmpty",
    ],
    "TaskGroup": supportedIntrinsics,
    "ThrowingDiscardingTaskGroup": [
        "addTask", "addTaskUnlessCancelled", "cancelAll", "isCancelled",
        "isEmpty",
    ],
    "ThrowingTaskGroup": supportedIntrinsics,
]
private let requiredTaskGroupFunctions: Set<String> = [
    "withDiscardingTaskGroup", "withTaskGroup",
    "withThrowingDiscardingTaskGroup", "withThrowingTaskGroup",
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
    let taskGroupTypeSet = Set(taskGroupTypes)
    var knownNames = Dictionary(uniqueKeysWithValues:
        taskGroupTypes.map { ($0, Set<String>()) })
    var dispatch = Dictionary(uniqueKeysWithValues:
        taskGroupTypes.map { ($0, [String: String]()) })
    var knownFunctions: Set<String> = []

    for statement in syntax.statements {
        guard case .decl(let declaration) = statement.item else { continue }
        if let function = declaration.as(FunctionDeclSyntax.self),
           isPublic(function.modifiers) {
            knownFunctions.insert(function.name.text)
            continue
        }
        let typeName: String?
        let members: MemberBlockItemListSyntax?
        if let structure = declaration.as(StructDeclSyntax.self),
           taskGroupTypeSet.contains(structure.name.text) {
            typeName = structure.name.text
            members = structure.memberBlock.members
        } else if let extensionDeclaration = declaration.as(
            ExtensionDeclSyntax.self
        ) {
            let extendedType = normalizedTypeName(
                extensionDeclaration.extendedType.trimmedDescription)
            typeName = taskGroupTypeSet.contains(extendedType)
                ? extendedType : nil
            members = typeName == nil
                ? nil : extensionDeclaration.memberBlock.members
        } else {
            typeName = nil
            members = nil
        }
        guard let typeName, let members else { continue }
        var typeKnownNames = knownNames[typeName, default: []]
        var typeDispatch = dispatch[typeName, default: [:]]
        inspect(
            members,
            knownNames: &typeKnownNames,
            dispatch: &typeDispatch)
        knownNames[typeName] = typeKnownNames
        dispatch[typeName] = typeDispatch
    }

    var missingMembers: [String] = []
    for typeName in taskGroupTypes {
        let implemented = Set(dispatch[typeName, default: [:]].values)
        let required = requiredIntrinsicsByType[typeName, default: []]
        missingMembers.append(contentsOf: required.subtracting(implemented)
            .sorted().map { "\(typeName).\($0)" })
    }
    guard missingMembers.isEmpty else {
        throw GenerationError.missingIntrinsics(missingMembers)
    }
    let missingFunctions = requiredTaskGroupFunctions
        .subtracting(knownFunctions).sorted()
    guard missingFunctions.isEmpty else {
        throw GenerationError.missingFunctions(missingFunctions)
    }

    let dispatchBlocks = taskGroupTypes.map { typeName in
        let entries = dispatch[typeName, default: [:]]
        let lines = entries.keys.sorted().map { sourceName in
            "            \"\(escaped(sourceName))\": .\(entries[sourceName]!),"
        }.joined(separator: "\n")
        return "        \"\(typeName)\": [\n\(lines)\n        ],"
    }.joined(separator: "\n")
    let knownBlocks = taskGroupTypes.map { typeName in
        let lines = knownNames[typeName, default: []].sorted().map {
            "            \"\(escaped($0))\","
        }.joined(separator: "\n")
        return "        \"\(typeName)\": [\n\(lines)\n        ],"
    }.joined(separator: "\n")
    let functionLines = requiredTaskGroupFunctions.sorted().map {
        "        \"\(escaped($0))\","
    }.joined(separator: "\n")
    let compilerVersion = interfaceSource.split(separator: "\n").first {
        $0.hasPrefix("// swift-compiler-version:")
    }.map(String.init) ?? "// swift-compiler-version: unknown"

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
        static let taskGroupDispatch: [
            String: [String: RuntimeTaskGroupIntrinsic]
        ] = [
    \(dispatchBlocks)
        ]

        static let knownTaskGroupMembers: [String: Set<String>] = [
    \(knownBlocks)
        ]

        static let taskGroupFunctions: Set<String> = [
    \(functionLines)
        ]

        static func intrinsic(
            typeName: String, memberName: String
        ) -> RuntimeTaskGroupIntrinsic? {
            taskGroupDispatch[typeName]?[memberName]
        }

        static func knowsMember(typeName: String, memberName: String) -> Bool {
            knownTaskGroupMembers[typeName]?.contains(memberName) == true
        }
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
