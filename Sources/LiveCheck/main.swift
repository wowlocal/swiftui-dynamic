import Foundation
import CheckSupport
import SwiftInterpreter
import SwiftUIBridge

// LiveCheck: the third fitness function — live-data fidelity. Scenarios run
// with the network in REPLAY mode (recorded real API responses; see
// Fixtures/), so the metric stays deterministic. Assertions check that
// fixture-derived content actually reaches decoded models and rendered
// trees. The failure histogram is the priority queue on the road to
// "a real networked app shows real data".
//
// Usage: swift run LiveCheck [--scenario substring] [--jobs N]


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
let rawArguments = Array(CommandLine.arguments.dropFirst())
let parallelOptions: ParallelCheckOptions
do {
    parallelOptions = try ParallelCheckOptions.parse(rawArguments)
} catch {
    FileHandle.standardError.write(Data("LiveCheck: \(error)\n".utf8))
    exit(2)
}
var iterator = ParallelCheckOptions.strippingParallelOptions(
    from: rawArguments).makeIterator()
while let argument = iterator.next() {
    if argument == "--scenario" { filter = iterator.next() }
}
// LIVECHECK_TRACE=1 prints each fired lifecycle closure + outcome —
// diagnostics only, never part of the metric.
LiveCheckSupport.traceLifecycle = ProcessInfo.processInfo.environment["LIVECHECK_TRACE"] != nil

struct Scenario {
    let name: String
    let fixturesDirectory: String
    let run: () async throws -> [String]  // returns assertion failures (empty = pass)
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
        // Launch parity: the iOS home opens on NOW PLAYING
        // (MoviesMenu.allCases.first) — expected titles come from the
        // fixture the app actually requests at launch.
        guard let json = fixtureJSON(fixtures + "/tmdb-popular/3_movie_now_playing.json") as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return ["fixture unreadable"]
        }
        let expectedTitles = results.compactMap { $0["title"] as? String }.prefix(10)
        // MovieSwiftUI imports SwiftUIFlux as an SPM dependency — the live
        // probe compiles WITH dependencies like SPM does, so the real
        // upstream store/provider/connector sources join the merge (pinned
        // clone under External/deps).
        let flux = ProjectMaterial.mergedSource(at: depsRoot + "/SwiftUIFlux/Sources")
        // The iOS TARGET only: xcodebuild never compiles MovieSwiftTV into
        // the iPhone app — merged sibling targets collide (@UIApplicationMain
        // vs @main, two HomeViews) and the TV home was winning the root.
        let source = flux + "\n" + ProjectMaterial.mergedSource(
            at: ossRoot + "/MovieSwiftUI", excludingTargets: ["MovieSwiftTV"])
        let render = try await LiveCheckSupport.render(source: source)
        let strings = render.strings
        let joined = strings.joined(separator: "\n")
        let found = expectedTitles.filter { joined.contains($0) }
        if found.count >= 3 {
            return []
        }
        var message = "only \(found.count)/10 fixture titles reached the tree (\(strings.count) strings, root \(render.rootSymbol), \(render.lifecycleFired) lifecycle closures fired)"
        for error in render.lifecycleErrors.prefix(3) {
            message += "\n     lifecycle error: \(error.prefix(160))"
        }
        message += "\n     network: \(render.networkRequests.isEmpty ? "NO REQUESTS" : render.networkRequests.prefix(6).joined(separator: ", "))"
        let absorbed = render.absorbedHostMembers
            .sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)×\($0.value)" }
        if !absorbed.isEmpty {
            message += "\n     absorbed: \(absorbed.joined(separator: ", "))"
        }
        return [message]
    },
    Scenario(name: "achnbrowser-items-ui", fixturesDirectory: "/Users/mike/src/tries/2026-07-08-swiftui-dynamic/External/oss/ACHNBrowserUI/ACHNBrowserUI/Packages/Backend/Sources/Backend/Resources/json") {
        // A THIRD async genre: bundled RESOURCE data rides a Combine
        // pipeline (Result.publisher → decode(type:decoder:) →
        // subscribe(on:) → sink into @Published). The repo's committed
        // JSON IS the fixture — real bytes the compiled app ships in
        // Bundle.module.
        BundleResources.roots = [ossRoot + "/ACHNBrowserUI"]
        defer { BundleResources.roots = [] }
        let resource = ossRoot + "/ACHNBrowserUI/ACHNBrowserUI/Packages/Backend/Sources/Backend/Resources/json/fish"
        guard let json = fixtureJSON(resource) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return ["bundled resource unreadable"]
        }
        let expectedNames = results.compactMap { $0["name"] as? String }.prefix(20)
        let source = ProjectMaterial.mergedSource(at: ossRoot + "/ACHNBrowserUI")
        let render = try await LiveCheckSupport.render(source: source)
        let strings = render.strings
        let joined = strings.joined(separator: "\n")
        let found = expectedNames.filter { joined.contains($0) }
        if found.count >= 3 {
            return []
        }
        var message = "only \(found.count)/\(expectedNames.count) bundled item names reached the tree (\(strings.count) strings, root \(render.rootSymbol), \(render.lifecycleFired) lifecycle closures fired)"
        for error in render.lifecycleErrors.prefix(3) {
            message += "\n     lifecycle error: \(error.prefix(160))"
        }
        let absorbed = render.absorbedHostMembers
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
        let render = try await LiveCheckSupport.render(source: source)
        let strings = render.strings
        let joined = strings.joined(separator: "\n")
        let found = expectedAuthors.filter { joined.contains($0) }
        if found.count >= 3 {
            return []
        }
        var message = "only \(found.count)/\(expectedAuthors.count) fixture authors reached the tree (\(strings.count) strings, root \(render.rootSymbol), \(render.lifecycleFired) lifecycle closures fired)"
        for error in render.lifecycleErrors.prefix(3) {
            message += "\n     lifecycle error: \(error.prefix(160))"
        }
        message += "\n     network: \(render.networkRequests.isEmpty ? "NO REQUESTS" : render.networkRequests.prefix(6).joined(separator: ", "))"
        let absorbed = render.absorbedHostMembers
            .sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)×\($0.value)" }
        if !absorbed.isEmpty {
            message += "\n     absorbed: \(absorbed.joined(separator: ", "))"
        }
        return [message]
    },
]

let filteredScenarios = scenarios.filter { scenario in
    guard let filter else { return true }
    return scenario.name.localizedCaseInsensitiveContains(filter)
}
if parallelOptions.shouldCoordinate, filteredScenarios.count > 1 {
    let jobs = min(parallelOptions.jobs, filteredScenarios.count)
    print("running \(filteredScenarios.count) live-data scenarios with \(jobs) process shards\n")
    do {
        let outputs = try ParallelCheckRunner.runSelf(jobs: jobs)
        let summary = try ParallelCheckRunner.aggregate(outputs)
        ParallelCheckRunner.replay(outputs)
        let passed = try summary.required("passed")
        let ran = try summary.required("total")
        guard ran == filteredScenarios.count else {
            throw ParallelCheckError.invalidOption(
                "live shards covered \(ran)/\(filteredScenarios.count) scenarios")
        }
        print("\n═══ \(passed)/\(ran) live-data scenarios pass (\(jobs) parallel shards) ═══")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("LiveCheck: \(error)\n".utf8))
        exit(1)
    }
}

let scenariosToRun = parallelOptions.selected(from: filteredScenarios)

// A shard is killed by the closing gate when it outlives
// DYNAMIC_SWIFT_CHECK_TIMEOUT_SECONDS, so the board has to say WHICH
// scenario spent the budget. Without it a shard timeout reports only
// that the slowest of the five ran long, and the live stage is the
// longest stage in the gate.
func elapsedDescription(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18
    return String(format: "%.1fs", seconds)
}

var passed = 0
var failureClasses: [(scenario: String, message: String)] = []
var ran = 0
let shardStarted = ContinuousClock.now
for scenario in scenariosToRun {
    ran += 1
    NetworkBridge.policy = .replay(fixturesDirectory: scenario.fixturesDirectory)
    NetworkBridge.requestLog = []
    defer { NetworkBridge.policy = .absorbed }
    let started = ContinuousClock.now
    do {
        let failures = try await scenario.run()
        let elapsed = elapsedDescription(started.duration(to: ContinuousClock.now))
        if failures.isEmpty {
            passed += 1
            print("✅ \(scenario.name)  \(elapsed)")
        } else {
            print("🟡 \(scenario.name)  \(elapsed)")
            for failure in failures {
                print("   ✗ \(failure)")
                failureClasses.append((scenario.name, failure))
            }
        }
    } catch {
        print("❌ \(scenario.name)  \(elapsedDescription(started.duration(to: ContinuousClock.now)))  \(error)")
        failureClasses.append((scenario.name, "\(error)"))
    }
}
print("shard \(parallelOptions.shardIndex + 1)/\(parallelOptions.shardCount) ran \(ran) scenarios in \(elapsedDescription(shardStarted.duration(to: ContinuousClock.now)))")

print("\n═══ \(passed)/\(ran) live-data scenarios pass ═══")
if !failureClasses.isEmpty {
    print("\nfailure classes (fix the biggest first):")
    for entry in failureClasses {
        print("   \(entry.scenario): \(entry.message.prefix(110))")
    }
}
if parallelOptions.shardCount > 1 {
    ParallelCheckRunner.emit(ParallelCheckSummary([
        "passed": passed,
        "total": ran,
    ]))
}
