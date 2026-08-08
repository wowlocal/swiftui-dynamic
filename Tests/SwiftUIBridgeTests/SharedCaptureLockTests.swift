import Foundation
import Testing

/// Distilled repro for the one-sided capture-lock class.
///
/// `Scripts/icecubes-r2.sh` and `Scripts/icecubes-r3.sh` share three mutable
/// paths: the macabi scratch path (and the `.app` bundle rebuilt and
/// re-codesigned inside it), `Examples/IceCubesNativeTwin/.build`, and the
/// frozen clock dylib both stages inject into every capture process. Two of
/// those are WRITTEN by one stage while the other may be EXECUTING them — the
/// rebuild-during-a-prebuilt-test-run trap — and even where nothing is
/// rewritten, two capture windows race through the window server, which is the
/// measured 141k-AE nondeterminism both reproducibility gates exist to reject.
///
/// R3 took a lock; R2 did not. R3's own comment conceded the asymmetry: "this
/// only excludes another R3 run, because `Scripts/icecubes-r2.sh` does not take
/// the lock yet ... until it lands a concurrent R2 stage is still invisible
/// here." A one-sided mutual exclusion excludes nothing — the unlocked side
/// walks straight past a held lock and starts rebuilding underneath the holder.
///
/// RED BEFORE THE FIX: `r2RefusesAHeldLock` fails at the parent commit, where
/// `Scripts/icecubes-r2.sh` contains no lock check at all and runs on to
/// capture. `r3RefusesAHeldLock` passes there and here — it is kept as the
/// control that proves the fixture itself holds a lock the scripts can see, so
/// a green R2 case cannot be a fixture that silently locks nothing.
///
/// Both cases are BEHAVIOURAL rather than a grep for the call, because the
/// property is "the lock is taken before the first shared write", and a
/// correctly-spelled call placed after the captures begin would satisfy any
/// text assertion while excluding nothing.
@Suite("Shared capture lock")
struct SharedCaptureLockTests {
    /// Ample for a script that is meant to refuse within milliseconds, and
    /// short enough that a REGRESSION — a board that ignores the lock and
    /// starts capturing — is killed rather than left to run a multi-minute
    /// build. The scratch and capture paths are redirected into the temporary
    /// directory for the same reason: a regression must not be able to write
    /// the real capture dirs that a concurrent gate may be scoring.
    private static let refusalDeadline: TimeInterval = 90

    @Test func r2RefusesAHeldLock() throws {
        try expectRefusal(of: "Scripts/icecubes-r2.sh", named: "IceCubes R2")
    }

    @Test func r3RefusesAHeldLock() throws {
        try expectRefusal(of: "Scripts/icecubes-r3.sh", named: "IceCubes R3")
    }

    /// One definition, not two copies. The boards have to agree on the lock
    /// PATH, and two copies of a path default is exactly how a mutual-exclusion
    /// primitive stops being mutual: each side takes a lock the other never
    /// looks at and both report success.
    @Test func neitherBoardRedefinesTheLock() throws {
        for script in ["Scripts/icecubes-r2.sh", "Scripts/icecubes-r3.sh"] {
            let source = try String(
                contentsOf: Self.packageRoot.appendingPathComponent(script),
                encoding: .utf8)
            #expect(
                source.contains("Scripts/icecubes-capture-lock.zsh"),
                Comment(rawValue:
                    "\(script) does not source the shared lock definition"))
            #expect(
                !source.contains("take_shared_capture_lock() {"),
                Comment(rawValue:
                    "\(script) defines its own take_shared_capture_lock; two "
                        + "definitions can disagree about the lock path, and "
                        + "then each board takes a lock the other never reads"))
        }
    }

    private func expectRefusal(of script: String, named stage: String) throws {
        try inTemporaryDirectory { directory in
            let lock = directory.appendingPathComponent("probe.lock")
            // A lock is only held if its owner is ALIVE — the scripts reclaim a
            // lock whose owner has exited, on purpose, so a crash cannot wedge
            // every later run. The fixture therefore needs a real live process,
            // not a fabricated pid.
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
            holder.arguments = ["\(Int(Self.refusalDeadline) + 30)"]
            try holder.run()
            defer { holder.terminate() }

            try FileManager.default.createDirectory(
                at: lock, withIntermediateDirectories: true)
            try "pid=\(holder.processIdentifier) started=fixture\n".write(
                to: lock.appendingPathComponent("owner"),
                atomically: true, encoding: .utf8)

            let result = try run(script, lockPath: lock.path, scratch: directory)
            #expect(
                result.status == 2,
                Comment(rawValue:
                    "\(script) exited \(result.status) against a HELD lock; it "
                        + "must refuse with 2 rather than rebuild and "
                        + "re-codesign paths the holder may be executing. "
                        + "Output: \(result.output)"))
            #expect(
                result.output.contains("SHARED-CAPTURE-LOCK-HELD"),
                Comment(rawValue:
                    "\(script) refused without naming the class; a reader "
                        + "cannot tell a lock refusal from a capture failure. "
                        + "Output: \(result.output)"))
            #expect(
                result.output.contains(stage),
                Comment(rawValue:
                    "\(script) did not identify itself as '\(stage)' in the "
                        + "refusal, so the message cannot say which stage is "
                        + "blocked. Output: \(result.output)"))
        }
    }

    private func run(
        _ script: String, lockPath: String, scratch: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.packageRoot
            .appendingPathComponent(script)
        process.currentDirectoryURL = Self.packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["ICECUBES_CAPTURE_LOCK"] = lockPath
        // Redirected so that a REGRESSION cannot write the real capture
        // directories a concurrent gate may be scoring.
        for key in [
            "ICECUBES_R2_SCRATCH_PATH", "ICECUBES_R3_SCRATCH_PATH",
            "ICECUBES_R2_TWIN_DIR", "ICECUBES_R2_INTERP_DIR",
            "ICECUBES_R3_TWIN_DIR", "ICECUBES_R3_INTERP_DIR",
        ] {
            environment[key] = scratch.appendingPathComponent(key).path
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // Read on a background queue: a board that ignores the lock produces
        // more output than a pipe buffer holds, and reading only after
        // `waitUntilExit` would deadlock the very regression this pins.
        let collected = DispatchQueue(label: "shared-capture-lock.output")
        nonisolated(unsafe) var output = Data()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            collected.sync { output = data }
        }

        let deadline = Date().addingTimeInterval(Self.refusalDeadline)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (
                -1,
                "did not refuse within \(Int(Self.refusalDeadline))s — it ran "
                    + "on past the held lock")
        }
        process.waitUntilExit()
        // Give the reader a moment to drain the closed pipe before reporting.
        Thread.sleep(forTimeInterval: 0.1)
        return (
            process.terminationStatus,
            collected.sync {
                String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            })
    }

    private func inTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shared-capture-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
