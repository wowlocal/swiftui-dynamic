#!/usr/bin/env swift

import Foundation

private struct Manifest: Decodable {
    struct Case: Decodable {
        let id: String
        let fixture: String
        let upstreamPath: String
    }

    struct SupportFile: Decodable {
        let fixture: String
        let upstreamPath: String
    }

    let repository: String
    let revision: String
    let commit: String
    let supportFiles: [SupportFile]
    let cases: [Case]
}

private struct Inventory: Encodable {
    struct Summary: Encodable {
        let total: Int
        let direct: Int
        let diagnostic: Int
        let needsAdapter: Int
        let unsupported: Int
    }

    struct Entry: Encodable {
        let upstreamPath: String
        let classification: String
        let reason: String
        let selectedCaseID: String?
    }

    let repository: String
    let revision: String
    let commit: String
    let scope: String
    let classificationVersion: Int
    let summary: Summary
    let tests: [Entry]
}

private enum InventoryError: Error, CustomStringConvertible {
    case usage
    case unsafeRelativePath(String)
    case missingSelectedFixture(String)
    case selectedFixtureOutsideInventory(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: SwiftUpstreamInventory.swift CHECKOUT DESTINATION"
        case .unsafeRelativePath(let path):
            return "unsafe relative path in upstream manifest: \(path)"
        case .missingSelectedFixture(let path):
            return "selected upstream fixture does not exist: \(path)"
        case .selectedFixtureOutsideInventory(let path):
            return "selected concurrency fixture is outside inventory: \(path)"
        }
    }
}

private let concurrencyScope = "test/Concurrency/Runtime"

private func child(_ relativePath: String, of root: URL) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.hasPrefix("/"),
          !components.contains(where: { $0.isEmpty || $0 == ".." }) else {
        throw InventoryError.unsafeRelativePath(relativePath)
    }
    let normalizedRoot = root.standardizedFileURL
    let result = normalizedRoot.appendingPathComponent(relativePath)
        .standardizedFileURL
    guard result.path.hasPrefix(normalizedRoot.path + "/") else {
        throw InventoryError.unsafeRelativePath(relativePath)
    }
    return result
}

private func writeBytes(from source: URL, to destination: URL) throws {
    let bytes = try Data(contentsOf: source)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try bytes.write(to: destination, options: .atomic)
}

private func relativePath(of file: URL, under root: URL) -> String {
    String(file.standardizedFileURL.path.dropFirst(
        root.standardizedFileURL.path.count + 1))
}

private func activeCheckLines(in source: String) -> [String] {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .compactMap { rawLine in
            let line = String(rawLine)
            guard let marker = line.range(of: "// CHECK") else { return nil }
            let directive = String(line[marker.upperBound...])
            guard directive.hasPrefix(":")
                    || directive.hasPrefix("-NEXT:")
                    || directive.hasPrefix("-SAME:")
                    || directive.hasPrefix("-DAG:")
                    || directive.hasPrefix("-NOT:")
                    || directive.hasPrefix("-LABEL:") else {
                return nil
            }
            return directive
        }
}

private func importedModules(in source: String) -> [String] {
    source.split(separator: "\n", omittingEmptySubsequences: false)
        .compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("import ") else { return nil }
            return line.dropFirst("import ".count).split(separator: ".").first
                .map(String.init)
        }
        .filter { $0 != "_Concurrency" }
        .reduce(into: [String]()) { modules, module in
            if !modules.contains(module) { modules.append(module) }
        }
}

private func classify(
    path: String,
    source: String,
    selectedCaseID: String?
) -> Inventory.Entry {
    if let selectedCaseID {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "direct",
            reason: "Selected unchanged for native/interpreter differential execution.",
            selectedCaseID: selectedCaseID)
    }

    if path.contains("/Inputs/") {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "unsupported",
            reason: "Auxiliary input, not a standalone executable test.",
            selectedCaseID: nil)
    }

    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let runLines = lines.filter {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix("// RUN:")
    }
    let hasExecutableRun = runLines.contains { $0.contains("%target-run") }
    if !hasExecutableRun {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "diagnostic",
            reason: "No executable %target-run command; this is a compiler, ABI, or diagnostic test.",
            selectedCaseID: nil)
    }

    let lowercasedName = URL(fileURLWithPath: path)
        .deletingPathExtension().lastPathComponent.lowercased()
    if runLines.contains(where: {
        $0.contains("%target-crash") || $0.contains("not --crash")
            || $0.contains("%target-run-fail")
    }) || (lowercasedName.contains("_crash")
            && !lowercasedName.contains("nocrash")) {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "unsupported",
            reason: "Expected crash or nonzero-exit test requires an isolated crash oracle.",
            selectedCaseID: nil)
    }

    if source.contains("import StdlibUnittest") {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "needs-adapter",
            reason: "Depends on the Swift repository's StdlibUnittest support module.",
            selectedCaseID: nil)
    }

    if runLines.contains(where: {
        $0.contains("%S/Inputs") || $0.contains("%t/")
            || $0.contains("-I %t") || $0.contains("-L %t")
    }) {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "needs-adapter",
            reason: "RUN command builds auxiliary inputs or modules before executing the test.",
            selectedCaseID: nil)
    }

    let checks = activeCheckLines(in: source)
    if checks.contains(where: { $0.contains("{{") || $0.contains("[[") }) {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "needs-adapter",
            reason: "Uses FileCheck regular expressions or variables not accepted by the literal matcher.",
            selectedCaseID: nil)
    }

    let modules = importedModules(in: source)
    if !modules.isEmpty {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "needs-adapter",
            reason: "Requires imported runtime API review: \(modules.joined(separator: ", ")).",
            selectedCaseID: nil)
    }

    if checks.isEmpty {
        return Inventory.Entry(
            upstreamPath: path,
            classification: "needs-adapter",
            reason: "Has no active CHECK oracle; deterministic exact output has not been established.",
            selectedCaseID: nil)
    }

    return Inventory.Entry(
        upstreamPath: path,
        classification: "needs-adapter",
        reason: "Executable candidate not yet admitted; requires Swift 6 compilation and deterministic interpreter review.",
        selectedCaseID: nil)
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw InventoryError.usage
    }
    let checkout = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let destination = URL(
        fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let manifestURL = destination.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: manifestURL))

    for selected in manifest.cases {
        let source = try child(selected.upstreamPath, of: checkout)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InventoryError.missingSelectedFixture(selected.upstreamPath)
        }
        let target = try child(selected.fixture, of: destination)
        try writeBytes(from: source, to: target)
    }
    for support in manifest.supportFiles {
        let source = try child(support.upstreamPath, of: checkout)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw InventoryError.missingSelectedFixture(support.upstreamPath)
        }
        let target = try child(support.fixture, of: destination)
        try writeBytes(from: source, to: target)
    }
    try writeBytes(
        from: checkout.appendingPathComponent("LICENSE.txt"),
        to: destination.appendingPathComponent("LICENSE.txt"))

    let scopeRoot = checkout.appendingPathComponent(
        concurrencyScope, isDirectory: true)
    let selectedConcurrencyCases = Dictionary(uniqueKeysWithValues:
        manifest.cases.compactMap { selected -> (String, String)? in
            guard selected.upstreamPath.hasPrefix(concurrencyScope + "/") else {
                return nil
            }
            return (selected.upstreamPath, selected.id)
        })

    guard let enumerator = FileManager.default.enumerator(
        at: scopeRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]) else {
        throw InventoryError.missingSelectedFixture(concurrencyScope)
    }
    let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    let entries = try files.map { file -> Inventory.Entry in
        let path = concurrencyScope + "/" + relativePath(of: file, under: scopeRoot)
        let source = try String(contentsOf: file, encoding: .utf8)
        return classify(
            path: path,
            source: source,
            selectedCaseID: selectedConcurrencyCases[path])
    }

    let inventoriedPaths = Set(entries.map(\.upstreamPath))
    for path in selectedConcurrencyCases.keys where !inventoriedPaths.contains(path) {
        throw InventoryError.selectedFixtureOutsideInventory(path)
    }

    let summary = Inventory.Summary(
        total: entries.count,
        direct: entries.count { $0.classification == "direct" },
        diagnostic: entries.count { $0.classification == "diagnostic" },
        needsAdapter: entries.count { $0.classification == "needs-adapter" },
        unsupported: entries.count { $0.classification == "unsupported" })
    let inventory = Inventory(
        repository: manifest.repository,
        revision: manifest.revision,
        commit: manifest.commit,
        scope: concurrencyScope,
        classificationVersion: 1,
        summary: summary,
        tests: entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(inventory)
    data.append(0x0A)
    try data.write(
        to: destination.appendingPathComponent("inventory.json"),
        options: .atomic)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("SwiftUpstreamInventory: \(error)\n".utf8))
    exit(1)
}
