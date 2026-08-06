import Foundation
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

/// The array half of the same rule `StringSliceIndexSpaceTests` pins for
/// strings: a slice SHARES its base's index space. `a[i...].startIndex` is
/// `i`, and an index an `ArraySlice` hands back stays valid in `a`.
///
/// IceCubes reaches it through SwiftSoup, which every status body goes
/// through for HTML. `CharacterReader.nextIndexOf` searches the rest of the
/// input buffer and assigns the result straight back to its cursor:
///
///     return input[pos...].firstIndex(of: targetUtf8[0])   // absolute
///     …
///     pos = targetIx
///
/// Re-based, `pos` is assigned a small offset, jumps backwards, and the
/// entity-table loop `while !reader.isEmpty()` never terminates. That runs on
/// the main thread while the app builds status rows, so the run loop stops
/// entirely: main-queue blocks stop being delivered, Nuke's image-task
/// continuations are never resumed, and the R2 `trending-timeline` capture
/// dies on presentation readiness instead of showing a wrong pixel.
///
/// Every expectation is NATIVE-VERIFIED — see `nativeArraySliceIndexSpaceParity`.
@Suite(.serialized) struct ArraySliceIndexSpaceTests {
    private func run(_ source: String) throws -> Interpreter {
        let interpreter = Interpreter(registry: TraceRegistry())
        try interpreter.run(source: source)
        return interpreter
    }

    @Test func sliceStartIndexIsBaseRelative() throws {
        let interpreter = try run("""
        let a: [UInt8] = [10, 20, 30, 47, 50, 47, 70]
        let sub = a[3...]
        let subStart = sub.startIndex
        let subEnd = sub.endIndex
        """)
        #expect(interpreter.globals.lookup("subStart")?.intValue == 3)
        #expect(interpreter.globals.lookup("subEnd")?.intValue == 7)
    }

    @Test func sliceSearchReturnsBaseRelativeIndex() throws {
        let interpreter = try run("""
        let a: [UInt8] = [10, 20, 30, 47, 50, 47, 70]
        let found = a[1...].firstIndex(of: 47)!
        let lastFound = a[1...].lastIndex(of: 47)!
        """)
        #expect(interpreter.globals.lookup("found")?.intValue == 3)
        #expect(interpreter.globals.lookup("lastFound")?.intValue == 5)
    }

    /// An absolute index reads the element it names in the base.
    @Test func sliceSubscriptsInTheBaseSpace() throws {
        let interpreter = try run("""
        let a: [UInt8] = [10, 20, 30, 47, 50, 47, 70]
        let sub = a[3...]
        let atThree = Int(sub[3])
        let atSix = Int(sub[6])
        """)
        #expect(interpreter.globals.lookup("atThree")?.intValue == 47)
        #expect(interpreter.globals.lookup("atSix")?.intValue == 70)
    }

    /// The SwiftSoup cursor loop itself, distilled. RED before the fix: the
    /// steps read `[3, 1, 1, 1, …]` and only the guard stops it.
    @Test func cursorWalkingLoopTerminates() throws {
        let interpreter = try run("""
        let a: [UInt8] = [10, 20, 30, 47, 50, 47, 70]
        var pos = 0
        var steps: [Int] = []
        var guardCount = 0
        var ranAway = false
        while pos < a.count {
            guard let next = a[pos...].firstIndex(of: 47) else { break }
            steps.append(next)
            pos = next + 1
            guardCount += 1
            if guardCount > 10 { ranAway = true; break }
        }
        """)
        #expect(
            interpreter.globals.lookup("ranAway")?.boolValue == false,
            "the cursor loop must terminate on its own, not on the guard")
        let steps = interpreter.globals.lookup("steps")?.arrayValue?
            .compactMap(\.intValue)
        #expect(steps == [3, 5], "steps: \(steps as Any)")
    }

    @Test func nestedSlicesShareTheSameBase() throws {
        let interpreter = try run("""
        let a = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        let outer = a[2...]
        let inner = outer[4...]
        let innerStart = inner.startIndex
        let innerFirst = inner.first!
        let innerCount = inner.count
        """)
        #expect(interpreter.globals.lookup("innerStart")?.intValue == 4)
        #expect(interpreter.globals.lookup("innerFirst")?.intValue == 4)
        #expect(interpreter.globals.lookup("innerCount")?.intValue == 6)
    }

    /// The negative control: an UNSLICED array is its own index space, so the
    /// plain path may not shift by a single index.
    @Test func wholeArrayIndicesAreUnchanged() throws {
        let interpreter = try run("""
        let a: [UInt8] = [10, 20, 30, 47, 50, 47, 70]
        let start = a.startIndex
        let end = a.endIndex
        let found = a.firstIndex(of: 47)!
        let indicesFirst = a.indices.first!
        let indicesLast = a.indices.last!
        """)
        #expect(interpreter.globals.lookup("start")?.intValue == 0)
        #expect(interpreter.globals.lookup("end")?.intValue == 7)
        #expect(interpreter.globals.lookup("found")?.intValue == 3)
        #expect(interpreter.globals.lookup("indicesFirst")?.intValue == 0)
        #expect(interpreter.globals.lookup("indicesLast")?.intValue == 6)
    }

    /// A slice still reads as its ELEMENTS everywhere elements are what was
    /// asked for — the carrier change must not leak into ordinary array use.
    @Test func sliceStillBehavesAsItsElements() throws {
        let interpreter = try run("""
        let a = [0, 1, 2, 3, 4, 5]
        let sub = a[2...]
        let asArray = Array(sub)
        let count = sub.count
        let sum = sub.reduce(0, +)
        let mapped = sub.map { $0 * 2 }
        let contains = sub.contains(4)
        let iterated = sub.map { $0 }
        """)
        #expect(
            interpreter.globals.lookup("asArray")?.arrayValue?
                .compactMap(\.intValue) == [2, 3, 4, 5])
        #expect(interpreter.globals.lookup("count")?.intValue == 4)
        #expect(interpreter.globals.lookup("sum")?.intValue == 14)
        #expect(
            interpreter.globals.lookup("mapped")?.arrayValue?
                .compactMap(\.intValue) == [4, 6, 8, 10])
        #expect(interpreter.globals.lookup("contains")?.boolValue == true)
        #expect(
            interpreter.globals.lookup("iterated")?.arrayValue?
                .compactMap(\.intValue) == [2, 3, 4, 5])
    }

    /// The expectations above are the real compiler's.
    @Test func nativeArraySliceIndexSpaceParity() throws {
        let source = """
        let a: [UInt8] = [10, 20, 30, 47, 50, 47, 70]
        var pos = 0
        var steps: [Int] = []
        var guardCount = 0
        while pos < a.count {
            guard let next = a[pos...].firstIndex(of: 47) else { break }
            steps.append(next)
            pos = next + 1
            guardCount += 1
            if guardCount > 10 { break }
        }
        print("steps:\\(steps)")
        print("subStart:\\(a[3...].startIndex)")
        print("found:\\(a[1...].firstIndex(of: 47)!)")
        let b = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        print("nested:\\(b[2...][4...].startIndex)")
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-slice-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("main.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let binaryURL = directory.appendingPathComponent("main")

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["swiftc", sourceURL.path, "-o", binaryURL.path]
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
            steps:[3, 5]
            subStart:3
            found:3
            nested:4
            """,
            "native output: \(output)")
    }
}
