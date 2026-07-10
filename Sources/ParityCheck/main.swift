import Foundation
import SwiftInterpreter
import SwiftUIBridge

// The native-baseline doctrine, mechanized for the generated API surface:
// the SAME expression evaluates in a COMPILED twin and in the interpreter;
// representational noise is normalized away; anything left is either a
// real divergence or a missing seed/constructor — both are findings.

func runTwin() -> [String: String]? {
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0])
    let twin = selfPath.deletingLastPathComponent().appendingPathComponent("ParityTwin")
    guard FileManager.default.fileExists(atPath: twin.path) else {
        print("ParityTwin binary not found next to ParityCheck — build it first")
        return nil
    }
    let process = Process()
    process.executableURL = twin
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var out: [String: String] = [:]
    for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
        guard let tab = line.firstIndex(of: "\u{9}") else { continue }
        out[String(line[..<tab])] = String(line[line.index(after: tab)...])
    }
    return out
}

func normalize(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespaces)
    // Optional wrappers collapse: Optional("x") -> x (repeatedly).
    while text.hasPrefix("Optional("), text.hasSuffix(")") {
        text = String(text.dropFirst("Optional(".count).dropLast())
    }
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
        text = String(text.dropFirst().dropLast())
    }
    // Range(a..<b) wrapper vs bare bounds.
    while text.hasPrefix("Range("), text.hasSuffix(")") {
        text = String(text.dropFirst("Range(".count).dropLast())
    }
    // Interpreted arrays print elements unquoted — drop quotes everywhere
    // (coarse but symmetric; real diffs still differ without quotes).
    text = text.replacingOccurrences(of: "\"", with: "")
    // Numeric canonicalization: 3 == 3.0.
    if let value = Double(text), value == value.rounded(), abs(value) < 1e15 {
        text = String(Int64(value))
    }
    return text
}

enum ProbeOutcome {
    case value(String)
    case failed(String)
}

@MainActor
func interpret(_ expression: String) -> ProbeOutcome {
    let source = parityPrelude + "\n" + expression + "\n"
    do {
        let value = try Interpreter(registry: ViewRegistry()).run(source: source)
        if value.isNil { return .value("nil") }
        return .value(value.stringified)
    } catch {
        return .failed("\(error)")
    }
}

// Stability filter: run the twin twice, drop probes whose native output
// differs run-to-run (clock/locale-volatile members filter themselves).
guard let first = runTwin(), let second = runTwin() else { exit(1) }
let stable = first.filter { second[$0.key] == $0.value }
let unstable = first.count - stable.count

var pass = 0
var diffs: [(String, String, String)] = []
var interpErrors: [(String, String)] = []
var missing = 0

for probe in parityProbes {
    guard let native = stable[probe.id] else {
        if first[probe.id] == nil { missing += 1 }
        continue // unstable or missing
    }
    switch interpret(probe.expression) {
    case .value(let interpreted):
        if normalize(interpreted) == normalize(native) {
            pass += 1
        } else {
            diffs.append((probe.id, normalize(native), normalize(interpreted)))
        }
    case .failed(let message):
        interpErrors.append((probe.id, String(message.prefix(90))))
    }
}

print("═══ API parity: \(pass) match / \(diffs.count) diverge / \(interpErrors.count) interp-error / \(unstable) unstable / \(missing) no-twin — of \(parityProbes.count) probes ═══")
if !diffs.isEmpty {
    print("\ndivergences (native ≠ interpreted):")
    for (id, native, interpreted) in diffs.prefix(30) {
        print("  \(id)\n      native: \(native.prefix(80))\n      interp: \(interpreted.prefix(80))")
    }
}
if !interpErrors.isEmpty {
    print("\ninterpreter errors (constructor/seed gaps are findings too):")
    var byMessage: [String: [String]] = [:]
    for (id, message) in interpErrors { byMessage[message, default: []].append(id) }
    for (message, ids) in byMessage.sorted(by: { $0.value.count > $1.value.count }).prefix(12) {
        print("  ×\(ids.count)  \(message)\n        e.g. \(ids.prefix(3).joined(separator: ", "))")
    }
}
