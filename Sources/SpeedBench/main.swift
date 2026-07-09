// Interpreter-vs-native microbenchmark.
//
// Defines the same pure-Swift workloads twice: once as SOURCE fed to the
// tree-walking interpreter (functions collected once, then invoked through
// `callClosure`, which resets the step budget per call), and once compiled
// natively in this release binary. Sizes auto-shrink until a workload fits
// the interpreter's 100k-step budget; the native twin then runs the SAME n.

import Foundation
import SwiftInterpreter

// MARK: - Interpreted program

let program = """
func fib(_ n: Int) -> Int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}

func sumSquares(_ n: Int) -> Int {
    var total = 0
    for i in 0..<n {
        total += i * i
    }
    return total
}

func sortAndSum(_ n: Int) -> Int {
    var arr: [Int] = []
    for i in 0..<n {
        arr.append((i * 7919) % 1000)
    }
    let s = arr.sorted()
    return s[0] + s[n - 1]
}

func buildString(_ n: Int) -> Int {
    var s = ""
    for i in 0..<n {
        s += "\\(i),"
    }
    return s.count
}

func mapFilterReduce(_ n: Int) -> Int {
    var arr: [Int] = []
    for i in 0..<n {
        arr.append(i)
    }
    return arr.map { $0 * 2 }.filter { $0 % 3 == 0 }.reduce(0) { $0 + $1 }
}
"""

// MARK: - Native twins
// `opaque` launders constants through a runtime value so the optimizer can't
// fold results at compile time; results also accumulate into `sink`.

let opaque = CommandLine.arguments.count // 1 at runtime, unknowable statically
var sink = 0

@inline(never) func nativeFib(_ n: Int) -> Int {
    if n < 2 { return n }
    return nativeFib(n - 1) + nativeFib(n - 2)
}

@inline(never) func nativeSumSquares(_ n: Int) -> Int {
    var total = 0
    for i in 0..<n {
        total += i * i
    }
    return total
}

@inline(never) func nativeSortAndSum(_ n: Int) -> Int {
    var arr: [Int] = []
    for i in 0..<n {
        arr.append((i * 7919) % 1000)
    }
    let s = arr.sorted()
    return s[0] + s[n - 1]
}

@inline(never) func nativeBuildString(_ n: Int) -> Int {
    var s = ""
    for i in 0..<n {
        s += "\(i),"
    }
    return s.count
}

@inline(never) func nativeMapFilterReduce(_ n: Int) -> Int {
    var arr: [Int] = []
    for i in 0..<n {
        arr.append(i)
    }
    return arr.map { $0 * 2 }.filter { $0 % 3 == 0 }.reduce(0) { $0 + $1 }
}

// MARK: - Timing

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Runs `body` in growing batches until at least `minTime` has elapsed;
/// returns seconds per call (best batch average).
func measure(minTime: Double = 0.4, _ body: () throws -> Int) rethrows -> (perOp: Double, result: Int) {
    var result = try body() // warmup
    var iters = 1
    var best = Double.infinity
    while true {
        let start = now()
        for _ in 0..<iters { result = try body() }
        let elapsed = Double(now() - start) / 1e9
        best = min(best, elapsed / Double(iters))
        if elapsed >= minTime { break }
        let scale = max(2.0, minTime / max(elapsed, 1e-9) * 1.3)
        iters = max(iters + 1, Int(Double(iters) * scale))
    }
    return (best, result)
}

func fmt(_ seconds: Double) -> String {
    if seconds >= 1.0 { return String(format: "%.2f s", seconds) }
    if seconds >= 1e-3 { return String(format: "%.2f ms", seconds * 1e3) }
    if seconds >= 1e-6 { return String(format: "%.2f µs", seconds * 1e6) }
    return String(format: "%.0f ns", seconds * 1e9)
}

// MARK: - Bench driver

struct Workload {
    let name: String
    let funcName: String
    var n: Int
    let native: (Int) -> Int
}

var workloads = [
    Workload(name: "fib(n) recursive", funcName: "fib", n: 16, native: nativeFib),
    Workload(name: "sum of squares loop", funcName: "sumSquares", n: 8000, native: nativeSumSquares),
    Workload(name: "build + sort array", funcName: "sortAndSum", n: 3000, native: nativeSortAndSum),
    Workload(name: "string interpolation loop", funcName: "buildString", n: 3000, native: nativeBuildString),
    Workload(name: "map/filter/reduce", funcName: "mapFilterReduce", n: 2000, native: nativeMapFilterReduce),
]

let interp = Interpreter()

// Startup: parse + collect declarations (measured separately; this is the
// one-time cost of loading the program, not of executing it).
let startupStart = now()
try interp.run(source: program)
let startupTime = Double(now() - startupStart) / 1e9

// PROFILE=1: spin the purest interpreted workload for ~15s so `sample`
// can attribute where evaluator time goes.
if ProcessInfo.processInfo.environment["PROFILE"] != nil {
    let fib = interp.globals.lookup("fib")!.closureValue!
    let deadline = now() + 15_000_000_000
    var acc = 0
    while now() < deadline {
        acc &+= try interp.callClosure(fib, arguments: [.native(16)]).intValue ?? 0
    }
    print("profile done \(acc)")
    exit(0)
}

print("SpeedBench — tree-walking interpreter vs natively compiled (release)")
print("parse + collect of \(program.count)-char program: \(fmt(startupTime))\n")

let header = String(
    format: "%-28@ %8@ %14@ %14@ %10@",
    "workload" as NSString, "n" as NSString,
    "interpreted" as NSString, "native" as NSString, "ratio" as NSString)
print(header)
print(String(repeating: "-", count: 80))

var ratios: [Double] = []

for var w in workloads {
    guard let closure = interp.globals.lookup(w.funcName)?.closureValue else {
        print("\(w.name): NOT FOUND in globals")
        continue
    }

    // Shrink n until one interpreted call fits the 100k-step budget.
    var interpreted: (perOp: Double, result: Int)? = nil
    while w.n > 1 {
        do {
            interpreted = try measure {
                try interp.callClosure(closure, arguments: [.native(w.n * opaque)]).intValue ?? -1
            }
            break
        } catch {
            w.n /= 2
        }
    }
    guard let interpTime = interpreted else {
        print("\(w.name): never fit the step budget")
        continue
    }

    let n = w.n
    let native = measure { w.native(n * opaque) }
    sink &+= native.result

    let match = interpTime.result == native.result ? "" : "  ⚠️ RESULT MISMATCH interp=\(interpTime.result) native=\(native.result)"
    let ratio = interpTime.perOp / native.perOp
    ratios.append(ratio)
    let line = String(
        format: "%-28@ %8d %14@ %14@ %9.0fx%@",
        w.name as NSString, n,
        fmt(interpTime.perOp) as NSString, fmt(native.perOp) as NSString,
        ratio, match as NSString)
    print(line)
}

let geo = exp(ratios.map { log($0) }.reduce(0, +) / Double(ratios.count))
print(String(repeating: "-", count: 80))
print(String(format: "geometric-mean slowdown: %.0fx  (sink %d)", geo, sink))
