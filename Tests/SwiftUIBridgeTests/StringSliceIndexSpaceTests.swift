import Foundation
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

/// A Swift slice SHARES its base's index space: `s[i...].startIndex` is `i`,
/// and an index a slice hands back stays valid in `s`. Copying the slice into
/// a fresh `String` re-bases those indices to zero, and the damage is not a
/// wrong character — it is a loop that stops making progress.
///
/// IceCubes surfaced it in `Models/Alias/HTMLString.swift`'s
/// `URL.init(string:encodePath:)`, which walks a URL's path by repeatedly
/// searching what is left of the string:
///
///     while let endIndex = string[string.index(after: startIndex)...]
///         .firstIndex(of: "/") { … ; startIndex = endIndex }
///
/// `startIndex` is a base-relative cursor; `endIndex` came out of a slice. Once
/// the slice is re-based, the cursor is assigned a small offset, jumps
/// backwards, and the loop never terminates. It runs on the main thread while
/// the app builds status rows, so the whole run loop stops: main-queue blocks
/// stop being delivered, Nuke's image-task continuations are never resumed,
/// and the R2 `trending-timeline` capture dies on presentation readiness
/// rather than showing a wrong pixel.
///
/// Every expectation here is NATIVE-VERIFIED — the same snippet compiled with
/// real `swiftc` produced these values (see `nativeSliceIndexSpaceParity`).
@Suite(.serialized) struct StringSliceIndexSpaceTests {
    private func run(_ source: String) throws -> Interpreter {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        return interpreter
    }

    /// The whole class in one value: a slice's `startIndex` is where the slice
    /// begins IN THE BASE, not zero.
    @Test func sliceStartIndexIsBaseRelative() throws {
        let interpreter = try run("""
        let s = "https://example.com/a/b"
        let sub = s[s.index(s.startIndex, offsetBy: 10)...]
        let subStartOffset = s.distance(from: s.startIndex, to: sub.startIndex)
        """)
        #expect(
            interpreter.globals.lookup("subStartOffset")?.intValue == 10,
            "a slice starting at offset 10 must report offset 10, not 0")
    }

    /// An index a slice RETURNS is an index into the base.
    @Test func sliceSearchReturnsBaseRelativeIndex() throws {
        let interpreter = try run("""
        let s = "https://example.com/a/b"
        let sub = s[s.index(s.startIndex, offsetBy: 10)...]
        let found = sub.firstIndex(of: "/")!
        let offset = s.distance(from: s.startIndex, to: found)
        """)
        #expect(
            interpreter.globals.lookup("offset")?.intValue == 19,
            "the first '/' at or after offset 10 is at base offset 19")
    }

    /// The IceCubes loop itself, distilled. RED before the fix: the offsets
    /// oscillate `[5, 0, 5, 0, …]` and the loop only stops on the guard.
    @Test func sliceWalkingLoopTerminates() throws {
        let interpreter = try run("""
        let s = "https://example.com/a/b/c/d?q=1"
        var startIndex = s[s.index(s.firstIndex(of: "/")!, offsetBy: 1)...]
            .firstIndex(of: "/")!
        var trace: [Int] = []
        var guardCount = 0
        var ranAway = false
        while let endIndex = s[s.index(after: startIndex)...].firstIndex(of: "/") {
            trace.append(s.distance(from: s.startIndex, to: endIndex))
            startIndex = endIndex
            guardCount += 1
            if guardCount > 20 { ranAway = true; break }
        }
        """)
        #expect(
            interpreter.globals.lookup("ranAway")?.boolValue == false,
            "the loop must terminate on its own, not on the guard")
        let trace = interpreter.globals.lookup("trace")?.arrayValue?
            .compactMap(\.intValue)
        #expect(trace == [19, 21, 23, 25], "trace: \(trace as Any)")
    }

    /// Slicing a slice composes in ONE index space rather than re-basing at
    /// each step — otherwise nesting reintroduces the bug one level down.
    @Test func nestedSlicesShareTheSameBase() throws {
        let interpreter = try run("""
        let s = "0123456789"
        let outer = s[s.index(s.startIndex, offsetBy: 2)...]
        let inner = outer[outer.index(outer.startIndex, offsetBy: 3)...]
        let innerStart = s.distance(from: s.startIndex, to: inner.startIndex)
        let innerText = String(inner)
        """)
        #expect(interpreter.globals.lookup("innerStart")?.intValue == 5)
        #expect(
            interpreter.globals.lookup("innerText")?.stringValue == "56789")
    }

    /// The negative control: an UNSLICED string is its own index space, so
    /// nothing about the plain path may shift. A rule that only fires for
    /// slices is the rule; one that also moves whole-string indices is a bug.
    @Test func wholeStringIndicesAreUnchanged() throws {
        let interpreter = try run("""
        let s = "https://example.com/a/b"
        let startOffset = s.distance(from: s.startIndex, to: s.startIndex)
        let endOffset = s.distance(from: s.startIndex, to: s.endIndex)
        let firstSlash = s.distance(
            from: s.startIndex, to: s.firstIndex(of: "/")!)
        let afterFirst = s.distance(
            from: s.startIndex, to: s.index(after: s.firstIndex(of: "/")!))
        """)
        #expect(interpreter.globals.lookup("startOffset")?.intValue == 0)
        #expect(interpreter.globals.lookup("endOffset")?.intValue == 23)
        #expect(interpreter.globals.lookup("firstSlash")?.intValue == 6)
        #expect(interpreter.globals.lookup("afterFirst")?.intValue == 7)
    }

    /// A slice still reads as its TEXT everywhere text is what was asked for —
    /// the carrier change must not leak into ordinary string use.
    @Test func sliceStillBehavesAsItsText() throws {
        let interpreter = try run("""
        let s = "https://example.com/a/b"
        let sub = s[s.index(s.startIndex, offsetBy: 8)...]
        let text = String(sub)
        let interpolated = "<\\(sub)>"
        let upper = sub.uppercased()
        let count = sub.count
        let hasPrefix = sub.hasPrefix("example")
        let equal = sub == "example.com/a/b"
        """)
        #expect(
            interpreter.globals.lookup("text")?.stringValue
                == "example.com/a/b")
        #expect(
            interpreter.globals.lookup("interpolated")?.stringValue
                == "<example.com/a/b>")
        #expect(
            interpreter.globals.lookup("upper")?.stringValue
                == "EXAMPLE.COM/A/B")
        #expect(interpreter.globals.lookup("count")?.intValue == 15)
        #expect(interpreter.globals.lookup("hasPrefix")?.boolValue == true)
        #expect(interpreter.globals.lookup("equal")?.boolValue == true)
    }

    /// The expectations above are the real compiler's, not mine. This compiles
    /// and runs the same program with `swiftc` so the pins cannot drift into
    /// agreeing with the interpreter instead of with Swift.
    @Test func nativeSliceIndexSpaceParity() throws {
        let source = """
        let s = "https://example.com/a/b/c/d?q=1"
        var startIndex = s[s.index(s.firstIndex(of: "/")!, offsetBy: 1)...]
            .firstIndex(of: "/")!
        var trace: [Int] = []
        var guardCount = 0
        while let endIndex = s[s.index(after: startIndex)...].firstIndex(of: "/") {
            trace.append(s.distance(from: s.startIndex, to: endIndex))
            startIndex = endIndex
            guardCount += 1
            if guardCount > 20 { break }
        }
        let sub = s[s.index(s.startIndex, offsetBy: 10)...]
        print("trace:\\(trace)")
        print("subStart:\\(s.distance(from: s.startIndex, to: sub.startIndex))")
        print("firstSlash:\\(s.distance(from: s.startIndex, to: sub.firstIndex(of: "/")!))")
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice-index-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("main.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let binaryURL = directory.appendingPathComponent("main")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = [
            "swiftc", sourceURL.path, "-o", binaryURL.path,
        ]
        try compile.run()
        compile.waitUntilExit()
        try #require(
            compile.terminationStatus == 0, "swiftc failed on the parity source")

        let run = Process()
        run.executableURL = binaryURL
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(
            output == """
            trace:[19, 21, 23, 25]
            subStart:10
            firstSlash:19
            """,
            "native output: \(output)")
    }
}
