import Foundation
import SwiftInterpreter
import SwiftUIBridge

// ProjectCheck: the fitness function for "runs real projects".
//
// Points at a directory of SwiftUI projects (zips or folders), extracts as
// needed, merges each project's .swift sources (imports stripped), and runs
// the HeadlessVerifier (interpret → deep-render every body → click every
// action). Prints per-project results and a failure-class histogram — the
// histogram is the loop's priority queue.
//
// Usage: swift run ProjectCheck [root] [--limit N | --all] [--project substring]


// The metric must be REPRODUCIBLE: Swift's per-process seeded hashing
// makes Set/Dictionary iteration order vary per launch, and interpreter
// behavior downstream of any ordered walk varies with it (nextcloud-ios
// flipped failure classes across identical runs). Re-exec once with
// deterministic hashing so every run of this tool sees the same order.
if ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == nil {
    var environment = ProcessInfo.processInfo.environment
    environment["SWIFT_DETERMINISTIC_HASHING"] = "1"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = Array(CommandLine.arguments.dropFirst())
    process.environment = environment
    try? process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}

let arguments = CommandLine.arguments.dropFirst()
var root = "/Users/mike/Documents/sample-projects"
var limit = 25
var filter: String?
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--limit": limit = Int(iterator.next() ?? "") ?? limit
    case "--all": limit = .max
    case "--project": filter = iterator.next()
    default: root = argument
    }
}

let fm = FileManager.default
let extractionRoot = "External"
try? fm.createDirectory(atPath: extractionRoot, withIntermediateDirectories: true)

// MARK: - Collect project units

struct Unit {
    let name: String
    let sources: [String] // file paths
    let totalBytes: Int
}

func swiftFiles(under directory: String) -> [String] {
    ProjectMaterial.swiftFiles(under: directory)
}

func extractedDir(forZip zipPath: String) -> String {
    let stem = URL(fileURLWithPath: zipPath).deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: " ", with: "_")
    return extractionRoot + "/" + stem
}

var units: [Unit] = []
let rootEntries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
for entry in rootEntries.sorted() {
    let full = root + "/" + entry
    var directory: String?
    if entry.hasSuffix(".zip") {
        let destination = extractedDir(forZip: full)
        if !fm.fileExists(atPath: destination) {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", full, "-d", destination]
            unzip.standardOutput = Pipe()
            unzip.standardError = Pipe()
            try? unzip.run()
            unzip.waitUntilExit()
        }
        directory = destination
    } else {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
            directory = full
        }
    }
    guard let directory else { continue }
    let files = swiftFiles(under: directory)
    guard !files.isEmpty else { continue }
    let bytes = files.compactMap { try? fm.attributesOfItem(atPath: $0)[.size] as? Int }.reduce(0, +)
    let name = URL(fileURLWithPath: directory).lastPathComponent
    if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
    units.append(Unit(name: name, sources: files, totalBytes: bytes))
}

// Real open-source apps cloned into External/oss/<name> (LOOP.md step 9:
// harder material once the zip ladder saturates). Named oss:<repo> so the
// two corpora stay distinguishable in the histogram.
let ossRoot = extractionRoot + "/oss"
for entry in ((try? fm.contentsOfDirectory(atPath: ossRoot)) ?? []).sorted() {
    let directory = ossRoot + "/" + entry
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else { continue }
    let files = swiftFiles(under: directory)
    guard !files.isEmpty else { continue }
    let bytes = files.compactMap { try? fm.attributesOfItem(atPath: $0)[.size] as? Int }.reduce(0, +)
    let name = "oss:" + entry
    if let filter, !name.localizedCaseInsensitiveContains(filter) { continue }
    units.append(Unit(name: name, sources: files, totalBytes: bytes))
}

// Smallest first: the ladder climbs from simple to challenging.
units.sort { $0.totalBytes < $1.totalBytes }
if units.count > limit { units = Array(units.prefix(limit)) }

print("checking \(units.count) projects (smallest first) from \(root)\n")

// MARK: - Run

func mergedSource(of unit: Unit) -> String {
    ProjectMaterial.mergedSource(files: unit.sources)
}

/// Collapse an error message into a class: strip positions and quoted names
/// so identical root causes tally together.
func failureClass(_ message: String) -> String {
    var out = message
    if let range = out.range(of: #"^\d+:\d+: "#, options: .regularExpression) {
        out.removeSubrange(range)
    }
    out = out.replacingOccurrences(of: #"'[^']*'"#, with: "'…'", options: .regularExpression)
    return String(out.prefix(90))
}

var passed = 0
var histogram: [String: [String]] = [:]

/// Excluded from the metric with reasons — mirrors LOOP.md's Quarantine
/// section. Last resort, never used to inflate the pass rate: these lean on
/// third-party library INTERNALS (not SwiftUI surface) that an interpreter
/// stub can't honestly satisfy.
let quarantined: [String: String] = [:]

for unit in units {
    if let reason = quarantined[unit.name] {
        print("🚧 \(unit.name)  quarantined: \(reason)")
        continue
    }
    let source = mergedSource(of: unit)
    do {
        // Merged multi-file units have no main.swift: library globals are
        // lazy, exactly as compiled Swift initializes them.
        let report = try HeadlessVerifier.verify(source: source, lazyTopLevelGlobals: true)
        passed += 1
        print("✅ \(unit.name)  (\(report.nodeCount) nodes, \(report.actionsInvoked) actions)")
    } catch let error as RuntimeError {
        if error.message.hasPrefix("no View-conforming struct found") {
            // Pure-AppKit repos aren't SwiftUI material — counted out,
            // like quarantine but automatic and self-describing.
            print("⚪ \(unit.name)  not SwiftUI material (no View structs)")
            continue
        }
        print("❌ \(unit.name)  \(error.description)")
        histogram[failureClass(error.message), default: []].append(unit.name)
    } catch {
        print("❌ \(unit.name)  \(error)")
        histogram[failureClass(String(describing: error)), default: []].append(unit.name)
    }
}

print("\n═══ \(passed)/\(units.count) projects pass ═══")
if !histogram.isEmpty {
    print("\nfailure classes (fix the biggest first):")
    for (message, projects) in histogram.sorted(by: { $0.value.count > $1.value.count }) {
        print(String(format: "%4d  %@", projects.count, message))
        print("      e.g. \(projects.prefix(3).joined(separator: ", "))")
    }
}
