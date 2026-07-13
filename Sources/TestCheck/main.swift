import Foundation
import CheckSupport
import SwiftInterpreter
import SwiftUIBridge

// TestCheck: the semantic fitness function. Runs each project's OWN unit
// tests over the interpreted code (both halves interpreted). Every failing
// assertion is an author-written oracle catching a divergence the render
// pipeline can't see — the histogram is a priority queue sharper than
// ProjectCheck's.
//
// Usage: swift run TestCheck [root] [--limit N | --all]
//        [--project substring] [--jobs N]


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

let rawArguments = Array(CommandLine.arguments.dropFirst())
let parallelOptions: ParallelCheckOptions
do {
    parallelOptions = try ParallelCheckOptions.parse(rawArguments)
} catch {
    FileHandle.standardError.write(Data("TestCheck: \(error)\n".utf8))
    exit(2)
}
let arguments = ParallelCheckOptions.strippingParallelOptions(from: rawArguments)
var root = "External/oss"
var limit = 10
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

// The bridge's gated diagnostics (⚠/⇢/⚡) follow the same env switch here.
LiveCheckSupport.traceLifecycle = ProcessInfo.processInfo.environment["LIVECHECK_TRACE"] == "1"

// The TestCheck Ledger (LOOP.md): upstream-broken suites, never counted.
TestHarness.upstreamBrokenClasses = [
    "PromptTemplateTests": "references Llama2Template/Vicuna/ChatML/Alpaca "
        + "types that exist NOWHERE in the FreeChat checkout or its four "
        + "package dependencies — the test target cannot compile natively "
        + "(verified 2026-07-11)",
]

let fm = FileManager.default

struct Unit {
    let name: String
    let directory: String
    let bytes: Int
}

var units: [Unit] = []
for entry in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() {
    let directory = root + "/" + entry
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else { continue }
    if let filter, !entry.localizedCaseInsensitiveContains(filter) { continue }
    let bytes = ProjectMaterial.swiftFiles(under: directory)
        .compactMap { try? fm.attributesOfItem(atPath: $0)[.size] as? Int }
        .reduce(0, +)
    units.append(Unit(name: entry, directory: directory, bytes: bytes))
}
units.sort { $0.bytes < $1.bytes }

// Select before sharding so a parallel run covers exactly the same first N
// test-bearing projects as the original sequential traversal.
var testUnits: [Unit] = []
for unit in units {
    guard testUnits.count < limit else { break }
    let containsTests = ProjectMaterial.swiftFiles(under: unit.directory).contains { path in
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return source.contains("XCTestCase") || source.contains("@Test")
    }
    if containsTests { testUnits.append(unit) }
}
units = testUnits

if parallelOptions.shouldCoordinate, units.count > 1 {
    let jobs = min(parallelOptions.jobs, units.count)
    print("checking \(units.count) interpreted test suites with \(jobs) process shards\n")
    do {
        let outputs = try ParallelCheckRunner.runSelf(jobs: jobs)
        let summary = try ParallelCheckRunner.aggregate(outputs)
        ParallelCheckRunner.replay(outputs)
        let selected = try summary.required("selected")
        let projects = try summary.required("projects")
        let passed = try summary.required("passed")
        let failed = try summary.required("failed")
        let errored = try summary.required("errored")
        let skipped = try summary.required("skipped")
        guard selected == units.count else {
            throw ParallelCheckError.invalidOption(
                "test shards covered \(selected)/\(units.count) projects")
        }
        print("\n═══ \(projects) suites: \(passed) passed, \(failed) failed, \(errored) errored, \(skipped) skipped (\(jobs) parallel shards) ═══")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("TestCheck: \(error)\n".utf8))
        exit(1)
    }
}

units = parallelOptions.selected(from: units, weightedBy: \.bytes)
var totals = (projects: 0, passed: 0, failed: 0, errored: 0, skipped: 0)
var failureClasses: [String: (count: Int, example: String)] = [:]

for unit in units {
    let source = ProjectMaterial.testMergedSource(at: unit.directory)
    if let dumpDir = ProcessInfo.processInfo.environment["TESTCHECK_DUMP"] {
        // Located errors point into the MERGE — the dump is what they index.
        try? source.write(
            toFile: "\(dumpDir)/\(unit.name).merged.swift", atomically: true, encoding: .utf8)
    }
    do {
        let report = try TestHarness.run(source: source)
        guard !report.results.isEmpty else {
            print("⚪️ \(unit.name)  (XCTestCase present, 0 runnable tests discovered)")
            continue
        }
        totals.projects += 1
        totals.passed += report.passed
        totals.failed += report.failed
        totals.errored += report.errored
        totals.skipped += report.skipped
        let mark = report.failed == 0 && report.errored == 0 ? "✅" : "🟡"
        var line = "\(mark) \(unit.name)  \(report.passed) passed, \(report.failed) failed, \(report.errored) errored"
        if report.skipped > 0 {
            line += ", \(report.skipped) skipped"
        }
        print(line + " (\(report.results.count) tests)")
        for result in report.results {
            switch result.outcome {
            case .passed:
                break
            case .failed(let reasons):
                let key = String(reasons.first?.prefix(60) ?? "assertion failed")
                failureClasses[key, default: (0, "")] = (
                    (failureClasses[key]?.count ?? 0) + 1,
                    "\(unit.name).\(result.className).\(result.testName)")
                print("   ✗ \(result.className).\(result.testName): \(reasons.first ?? "")")
            case .skipped:
                break
            case .errored(let message):
                let key = message
                    .replacingOccurrences(of: "[0-9]+", with: "…", options: .regularExpression)
                    .prefix(70)
                failureClasses[String(key), default: (0, "")] = (
                    (failureClasses[String(key)]?.count ?? 0) + 1,
                    "\(unit.name).\(result.className).\(result.testName)")
                print("   ⚠ \(result.className).\(result.testName): \(message.prefix(100))")
            }
        }
    } catch {
        print("❌ \(unit.name)  \(error)")
        let key = "\(error)".replacingOccurrences(of: "[0-9]+", with: "…", options: .regularExpression)
        failureClasses[String(key.prefix(70)), default: (0, "")] = (
            (failureClasses[String(key.prefix(70))]?.count ?? 0) + 1, unit.name)
    }
}

print("\n═══ \(totals.projects) suites: \(totals.passed) passed, \(totals.failed) failed, \(totals.errored) errored, \(totals.skipped) skipped ═══")
if !failureClasses.isEmpty {
    print("\nfailure classes (fix the biggest first):")
    for (key, value) in failureClasses.sorted(by: { $0.value.count > $1.value.count }).prefix(12) {
        print(String(format: "%4d  %@", value.count, key))
        print("      e.g. \(value.example)")
    }
}
if parallelOptions.shardCount > 1 {
    ParallelCheckRunner.emit(ParallelCheckSummary([
        "selected": units.count,
        "projects": totals.projects,
        "passed": totals.passed,
        "failed": totals.failed,
        "errored": totals.errored,
        "skipped": totals.skipped,
    ]))
}
