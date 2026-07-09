import Foundation
import SwiftInterpreter
import SwiftUIBridge

// TestCheck: the semantic fitness function. Runs each project's OWN unit
// tests over the interpreted code (both halves interpreted). Every failing
// assertion is an author-written oracle catching a divergence the render
// pipeline can't see — the histogram is a priority queue sharper than
// ProjectCheck's.
//
// Usage: swift run TestCheck [root] [--limit N | --all] [--project substring]

let arguments = CommandLine.arguments.dropFirst()
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

var checked = 0
var totals = (projects: 0, passed: 0, failed: 0, errored: 0)
var failureClasses: [String: (count: Int, example: String)] = [:]

for unit in units {
    guard checked < limit else { break }
    let source = ProjectMaterial.testMergedSource(at: unit.directory)
    guard source.contains("XCTestCase") else { continue }
    checked += 1

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
        let mark = report.failed == 0 && report.errored == 0 ? "✅" : "🟡"
        print("\(mark) \(unit.name)  \(report.passed) passed, \(report.failed) failed, \(report.errored) errored (\(report.results.count) tests)")
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

print("\n═══ \(totals.projects) suites: \(totals.passed) passed, \(totals.failed) failed, \(totals.errored) errored ═══")
if !failureClasses.isEmpty {
    print("\nfailure classes (fix the biggest first):")
    for (key, value) in failureClasses.sorted(by: { $0.value.count > $1.value.count }).prefix(12) {
        print(String(format: "%4d  %@", value.count, key))
        print("      e.g. \(value.example)")
    }
}
