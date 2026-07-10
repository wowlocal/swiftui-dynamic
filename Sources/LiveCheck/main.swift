import Foundation
import SwiftInterpreter
import SwiftUIBridge

// LiveCheck: the third fitness function — live-data fidelity. Scenarios run
// with the network in REPLAY mode (recorded real API responses; see
// Fixtures/), so the metric stays deterministic. Assertions check that
// fixture-derived content actually reaches decoded models and rendered
// trees. The failure histogram is the priority queue on the road to
// "a real networked app shows real data".
//
// Usage: swift run LiveCheck [--scenario substring]


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

let repoRoot = FileManager.default.currentDirectoryPath
let fixtures = repoRoot + "/Fixtures"
let ossRoot = "/Users/mike/src/tries/2026-07-08-swiftui-dynamic/External/oss"
let depsRoot = "/Users/mike/src/tries/2026-07-08-swiftui-dynamic/External/deps"

var filter: String?
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    if argument == "--scenario" { filter = iterator.next() }
}
// LIVECHECK_TRACE=1 prints each fired lifecycle closure + outcome —
// diagnostics only, never part of the metric.
LiveCheckSupport.traceLifecycle = ProcessInfo.processInfo.environment["LIVECHECK_TRACE"] != nil

struct Scenario {
    let name: String
    let fixturesDirectory: String
    let run: () throws -> [String]  // returns assertion failures (empty = pass)
}

func fixtureJSON(_ path: String) -> Any? {
    FileManager.default.contents(atPath: path).flatMap {
        try? JSONSerialization.jsonObject(with: $0)
    }
}

let mastodonModels = """
struct Account: Codable {
    let username: String
    let displayName: String?
}

struct Status: Codable {
    let id: String
    let content: String
    let createdAt: Date
    let account: Account
}
"""

let scenarios: [Scenario] = [
    Scenario(name: "mastodon-fixture-decode", fixturesDirectory: fixtures + "/mastodon-public-timeline") {
        let source = mastodonModels + """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let statuses = try decoder.decode([Status].self, from: __fixtureData("api_v1_timelines_public"))
        var usernames = ""
        for status in statuses {
            usernames += status.account.username + " "
        }
        (statuses.count, usernames)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        guard let tuple = result.tupleValue else { return ["decode returned \(result.stringified)"] }
        var failures: [String] = []
        if tuple.values[0].intValue != 20 {
            failures.append("expected 20 statuses, got \(tuple.values[0].stringified)")
        }
        if (tuple.values[1].stringValue ?? "").split(separator: " ").count < 15 {
            failures.append("usernames look empty: \(tuple.values[1].stringified.prefix(80))")
        }
        return failures
    },
    Scenario(name: "tmdb-fixture-decode", fixturesDirectory: fixtures + "/tmdb-popular") {
        let source = """
        struct Movie: Codable {
            let id: Int
            let title: String
            let overview: String
            let posterPath: String?
            let voteAverage: Double
        }

        struct MovieResponse: Codable {
            let page: Int
            let results: [Movie]
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(MovieResponse.self, from: __fixtureData("3_movie_popular"))
        var titles = ""
        for movie in response.results {
            titles += movie.title + "|"
        }
        (response.results.count, titles)
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        guard let tuple = result.tupleValue else { return ["decode returned \(result.stringified)"] }
        var failures: [String] = []
        if (tuple.values[0].intValue ?? 0) < 10 {
            failures.append("expected ≥10 movies, got \(tuple.values[0].stringified)")
        }
        if (tuple.values[1].stringValue ?? "").split(separator: "|").count < 10 {
            failures.append("titles look empty")
        }
        return failures
    },
    Scenario(name: "movieswiftui-popular-ui", fixturesDirectory: fixtures + "/tmdb-popular") {
        guard let json = fixtureJSON(fixtures + "/tmdb-popular/3_movie_popular.json") as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return ["fixture unreadable"]
        }
        let expectedTitles = results.compactMap { $0["title"] as? String }.prefix(10)
        // MovieSwiftUI imports SwiftUIFlux as an SPM dependency — the live
        // probe compiles WITH dependencies like SPM does, so the real
        // upstream store/provider/connector sources join the merge (pinned
        // clone under External/deps).
        let flux = ProjectMaterial.mergedSource(at: depsRoot + "/SwiftUIFlux/Sources")
        let source = flux + "\n" + ProjectMaterial.mergedSource(at: ossRoot + "/MovieSwiftUI")
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        let joined = strings.joined(separator: "\n")
        let found = expectedTitles.filter { joined.contains($0) }
        if found.count >= 3 {
            return []
        }
        var message = "only \(found.count)/10 fixture titles reached the tree (\(strings.count) strings, root \(LiveCheckSupport.lastRootSymbol), \(LiveCheckSupport.lastLifecycleFired) lifecycle closures fired)"
        for error in LiveCheckSupport.lastLifecycleErrors.prefix(3) {
            message += "\n     lifecycle error: \(error.prefix(160))"
        }
        message += "\n     network: \(NetworkBridge.requestLog.isEmpty ? "NO REQUESTS" : NetworkBridge.requestLog.prefix(6).joined(separator: ", "))"
        let absorbed = LiveCheckSupport.lastAbsorbedHostMembers
            .sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)×\($0.value)" }
        if !absorbed.isEmpty {
            message += "\n     absorbed: \(absorbed.joined(separator: ", "))"
        }
        return [message]
    },
    Scenario(name: "icecubes-timeline-ui", fixturesDirectory: fixtures + "/mastodon-public-timeline") {
        // Launch parity: an UNAUTHENTICATED IceCubes shows TRENDING —
        // expected authors come from whichever fixture the app requests.
        var authorPool: [String] = []
        for fixture in ["api_v1_trends_statuses", "api_v1_timelines_public"] {
            if let json = fixtureJSON(fixtures + "/mastodon-public-timeline/\(fixture).json") as? [[String: Any]] {
                authorPool += json.compactMap { ($0["account"] as? [String: Any])?["username"] as? String }
            }
        }
        guard !authorPool.isEmpty else { return ["fixtures unreadable"] }
        let expectedAuthors = authorPool.prefix(20)
        let source = ProjectMaterial.mergedSource(at: ossRoot + "/IceCubesApp")
        let strings = try LiveCheckSupport.renderedStrings(source: source)
        let joined = strings.joined(separator: "\n")
        let found = expectedAuthors.filter { joined.contains($0) }
        if found.count >= 3 {
            return []
        }
        var message = "only \(found.count)/\(expectedAuthors.count) fixture authors reached the tree (\(strings.count) strings, root \(LiveCheckSupport.lastRootSymbol), \(LiveCheckSupport.lastLifecycleFired) lifecycle closures fired)"
        for error in LiveCheckSupport.lastLifecycleErrors.prefix(3) {
            message += "\n     lifecycle error: \(error.prefix(160))"
        }
        message += "\n     network: \(NetworkBridge.requestLog.isEmpty ? "NO REQUESTS" : NetworkBridge.requestLog.prefix(6).joined(separator: ", "))"
        let absorbed = LiveCheckSupport.lastAbsorbedHostMembers
            .sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)×\($0.value)" }
        if !absorbed.isEmpty {
            message += "\n     absorbed: \(absorbed.joined(separator: ", "))"
        }
        return [message]
    },
]

var passed = 0
var failureClasses: [(scenario: String, message: String)] = []
var ran = 0
for scenario in scenarios {
    if let filter, !scenario.name.localizedCaseInsensitiveContains(filter) { continue }
    ran += 1
    NetworkBridge.policy = .replay(fixturesDirectory: scenario.fixturesDirectory)
    NetworkBridge.requestLog = []
    defer { NetworkBridge.policy = .absorbed }
    do {
        let failures = try scenario.run()
        if failures.isEmpty {
            passed += 1
            print("✅ \(scenario.name)")
        } else {
            print("🟡 \(scenario.name)")
            for failure in failures {
                print("   ✗ \(failure)")
                failureClasses.append((scenario.name, failure))
            }
        }
    } catch {
        print("❌ \(scenario.name)  \(error)")
        failureClasses.append((scenario.name, "\(error)"))
    }
}

print("\n═══ \(passed)/\(ran) live-data scenarios pass ═══")
if !failureClasses.isEmpty {
    print("\nfailure classes (fix the biggest first):")
    for entry in failureClasses {
        print("   \(entry.scenario): \(entry.message.prefix(110))")
    }
}
