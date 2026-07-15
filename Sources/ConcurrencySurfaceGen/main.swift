import ConcurrencySurfaceGenCore
import Foundation

private enum CommandError: Error, CustomStringConvertible {
    case missingArgument(String)
    case unreadableInterface(String)
    case missingGeneratedOutput(String)
    case staleGeneratedOutput(String)

    var description: String {
        switch self {
        case .missingArgument(let flag):
            "missing value after \(flag)"
        case .unreadableInterface(let path):
            "could not read _Concurrency.swiftinterface at \(path)"
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
private let inventoryOutputFlag = "--inventory-output"
private let interfaceFlag = "--interface"
private let defaultOutput =
    "Sources/SwiftInterpreter/Generated/GeneratedConcurrencySurface.swift"
private let defaultInventoryOutput =
    "Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json"

private func argument(after flag: String) throws -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else {
        return nil
    }
    guard CommandLine.arguments.indices.contains(index + 1) else {
        throw CommandError.missingArgument(flag)
    }
    return CommandLine.arguments[index + 1]
}

private func run() throws {
    let interfacePath = try argument(after: interfaceFlag)
        ?? ConcurrencySurfaceGenerator.activeInterfacePath()
    let outputPath = try argument(after: outputFlag) ?? defaultOutput
    let inventoryOutputPath = try argument(after: inventoryOutputFlag)
        ?? defaultInventoryOutput
    guard let source = try? String(
        contentsOfFile: interfacePath, encoding: .utf8,
    ) else {
        throw CommandError.unreadableInterface(interfacePath)
    }
    let output = try ConcurrencySurfaceGenerator.generatedSource(
        interfacePath: interfacePath, interfaceSource: source,
    )
    let inventoryOutput = try ConcurrencySurfaceGenerator
        .generatedCapabilityInventory(
            interfacePath: interfacePath, interfaceSource: source,
        )
    if CommandLine.arguments.contains(checkFlag) {
        for (path, expected) in [
            (outputPath, output),
            (inventoryOutputPath, inventoryOutput),
        ] {
            guard let existing = try? String(
                contentsOfFile: path, encoding: .utf8,
            ) else {
                throw CommandError.missingGeneratedOutput(path)
            }
            guard existing == expected else {
                throw CommandError.staleGeneratedOutput(path)
            }
            print("verified \(path)")
        }
        return
    }
    for (path, contents) in [
        (outputPath, output),
        (inventoryOutputPath, inventoryOutput),
    ] {
        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try contents.write(to: outputURL, atomically: true, encoding: .utf8)
        print("wrote \(path)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(
        Data("ConcurrencySurfaceGen: \(error)\n".utf8))
    exit(1)
}
