import Darwin
import Foundation
import Testing
@testable import SwiftInterpreter

nonisolated private let structuredMemoryChildReceiptVariable =
    "DYNAMIC_SWIFT_STRUCTURED_MEMORY_CHILD_RECEIPT"

private struct StructuredMemorySnapshot: Codable, Equatable {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let allocatorBytesInUse: UInt64
}

private struct StructuredMemoryPlateauReceipt: Codable {
    let version: Int
    let processIdentifier: Int32
    let warmupSessions: Int
    let measuredSessionsPerBatch: Int
    let measuredBatches: Int
    let structuredNodesPerSession: Int
    let snapshots: [StructuredMemorySnapshot]
}

private struct StructuredMemoryMetricAssessment {
    let firstMedian: UInt64
    let lastMedian: UInt64
    let positiveMedianDrift: UInt64
    let lateWindowSpread: UInt64
    let positiveSlopeBytesPerBatch: Double
}

private struct StructuredMemoryPlateauAssessment {
    let resident: StructuredMemoryMetricAssessment
    let physicalFootprint: StructuredMemoryMetricAssessment
    let allocator: StructuredMemoryMetricAssessment

    init(snapshots: [StructuredMemorySnapshot]) throws {
        guard snapshots.count >= 9 else {
            throw RuntimeError(message:
                "structured memory plateau requires at least 9 snapshots")
        }
        resident = Self.assess(snapshots.map(\.residentBytes))
        physicalFootprint = Self.assess(
            snapshots.map(\.physicalFootprintBytes))
        allocator = Self.assess(snapshots.map(\.allocatorBytesInUse))
    }

    private static func assess(
        _ samples: [UInt64]
    ) -> StructuredMemoryMetricAssessment {
        let windowSize = max(3, samples.count / 3)
        let first = Array(samples.prefix(windowSize))
        let last = Array(samples.suffix(windowSize))
        let firstMedian = median(first)
        let lastMedian = median(last)
        let drift = lastMedian > firstMedian ? lastMedian - firstMedian : 0
        let spread = (last.max() ?? 0) - (last.min() ?? 0)

        let count = Double(samples.count)
        let meanX = (count - 1) / 2
        let meanY = samples.reduce(0.0) { $0 + Double($1) } / count
        var numerator = 0.0
        var denominator = 0.0
        for (index, sample) in samples.enumerated() {
            let x = Double(index) - meanX
            numerator += x * (Double(sample) - meanY)
            denominator += x * x
        }
        let slope = denominator == 0 ? 0 : numerator / denominator

        return StructuredMemoryMetricAssessment(
            firstMedian: firstMedian,
            lastMedian: lastMedian,
            positiveMedianDrift: drift,
            lateWindowSpread: spread,
            positiveSlopeBytesPerBatch: max(0, slope))
    }

    private static func median(_ samples: [UInt64]) -> UInt64 {
        let sorted = samples.sorted()
        if sorted.count.isMultiple(of: 2) {
            let upper = sorted[sorted.count / 2]
            let lower = sorted[sorted.count / 2 - 1]
            return lower + (upper - lower) / 2
        }
        return sorted[sorted.count / 2]
    }
}

private enum StructuredMemoryPlateauHarness {
    static let warmupSessions = 128
    static let measuredSessionsPerBatch = 64
    static let measuredBatches = 12
    static let structuredNodesPerSession = 46

    static let residentDriftLimit: UInt64 = 16 * 1_048_576
    static let residentSpreadLimit: UInt64 = 16 * 1_048_576
    static let residentSlopeLimit = Double(1_048_576)
    static let footprintDriftLimit: UInt64 = 16 * 1_048_576
    static let footprintSpreadLimit: UInt64 = 16 * 1_048_576
    static let footprintSlopeLimit = Double(1_048_576)
    static let allocatorDriftLimit: UInt64 = 8 * 1_048_576
    static let allocatorSpreadLimit: UInt64 = 8 * 1_048_576
    static let allocatorSlopeLimit = Double(512 * 1_024)

    static func runChildWorkload() async throws -> StructuredMemoryPlateauReceipt {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConcurrencyParity")
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("task-group-bounded-tree.swift")
        let declarations = try String(contentsOf: fixture, encoding: .utf8)
        let interpreter = Interpreter()
        var isFirstSession = true

        func runSession() async throws {
            let entry = "await taskGroupBoundedTreeProbe()\n"
            let source = isFirstSession ? declarations + "\n" + entry : entry
            isFirstSession = false
            let result = try await interpreter.runAsync(source: source)
            guard result.stringValue == "1,5,40" else {
                throw RuntimeError(message:
                    "structured memory workload returned \(result)")
            }
            guard interpreter.concurrencyRuntime.activeRecordCount == 0,
                  interpreter.concurrencyRuntime.activeStructuredScopeCount == 0,
                  interpreter.concurrencyRuntime.activeTaskGroupCount == 0,
                  interpreter.concurrencyRuntime.activeHostOperationCount == 0,
                  interpreter.scheduledTasks.isEmpty else {
                throw RuntimeError(message:
                    "structured memory workload retained runtime ownership")
            }
        }

        for _ in 0..<warmupSessions {
            try await runSession()
        }
        settleAllocator()

        var snapshots = [try memorySnapshot()]
        for _ in 0..<measuredBatches {
            for _ in 0..<measuredSessionsPerBatch {
                try await runSession()
            }
            settleAllocator()
            snapshots.append(try memorySnapshot())
        }

        return StructuredMemoryPlateauReceipt(
            version: 1,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            warmupSessions: warmupSessions,
            measuredSessionsPerBatch: measuredSessionsPerBatch,
            measuredBatches: measuredBatches,
            structuredNodesPerSession: structuredNodesPerSession,
            snapshots: snapshots)
    }

    static func writeChildReceipt(
        _ receipt: StructuredMemoryPlateauReceipt,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }

    static func runIsolatedChild() throws -> StructuredMemoryPlateauReceipt {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-structured-memory-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let receiptURL = temporaryDirectory.appendingPathComponent("receipt.json")
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        _ = FileManager.default.createFile(
            atPath: stdoutURL.path, contents: nil)
        _ = FileManager.default.createFile(
            atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        var environment = ProcessInfo.processInfo.environment
        environment[structuredMemoryChildReceiptVariable] = receiptURL.path
        let process = Process()
        process.executableURL = try testingHelperURL()
        process.standardInput = FileHandle.nullDevice
        process.arguments = [
            "--test-bundle-path", try testBundleExecutableURL().path,
            "--skip-build",
            "--no-parallel",
            "--filter",
            "SwiftInterpreterTests.StructuredMemoryPlateauTests/structuredMemoryProbeChild",
            try testBundleExecutableURL().path,
            "--testing-library", "swift-testing",
        ]
        process.environment = environment
        process.currentDirectoryURL = packageRoot
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning,
                  ProcessInfo.processInfo.systemUptime < terminationDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try stdout.synchronize()
        try stderr.synchronize()

        let standardOutput = try String(
            contentsOf: stdoutURL, encoding: .utf8)
        let standardError = try String(
            contentsOf: stderrURL, encoding: .utf8)
        guard !timedOut, process.terminationStatus == 0 else {
            throw RuntimeError(message:
                "structured memory child failed (status "
                    + "\(process.terminationStatus), timeout \(timedOut)); "
                    + "stdout: \(standardOutput); stderr: \(standardError)")
        }
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            throw RuntimeError(message:
                "structured memory child exited without a receipt; stdout: "
                    + "\(standardOutput); stderr: \(standardError)")
        }
        return try JSONDecoder().decode(
            StructuredMemoryPlateauReceipt.self,
            from: Data(contentsOf: receiptURL))
    }

    private static func memorySnapshot() throws -> StructuredMemorySnapshot {
        var basicInfo = mach_task_basic_info_data_t()
        var basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self, capacity: Int(basicInfoCount)
            ) {
                task_info(
                    mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0, &basicInfoCount)
            }
        }

        var vmInfo = task_vm_info_data_t()
        var vmInfoCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self, capacity: Int(vmInfoCount)
            ) {
                task_info(
                    mach_task_self_, task_flavor_t(TASK_VM_INFO),
                    $0, &vmInfoCount)
            }
        }
        guard basicStatus == KERN_SUCCESS, vmStatus == KERN_SUCCESS else {
            throw RuntimeError(message:
                "could not read structured memory process metrics")
        }

        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return StructuredMemorySnapshot(
            residentBytes: basicInfo.resident_size,
            physicalFootprintBytes: vmInfo.phys_footprint,
            allocatorBytesInUse: UInt64(statistics.size_in_use))
    }

    private static func settleAllocator() {
        autoreleasepool {}
        for _ in 0..<3 {
            _ = malloc_zone_pressure_relief(nil, 0)
            usleep(20_000)
        }
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func loadedImageURLs() -> [URL] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return URL(fileURLWithPath: String(cString: name))
        }
    }

    private static func testBundleExecutableURL() throws -> URL {
        guard let url = loadedImageURLs().first(where: {
            $0.path.contains(".xctest/Contents/MacOS/")
                && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw RuntimeError(message:
                "could not locate the loaded SwiftPM test bundle executable")
        }
        return url
    }

    private static func testingHelperURL() throws -> URL {
        if let executable = CommandLine.arguments.first {
            let url = URL(fileURLWithPath: executable)
            if url.lastPathComponent == "swiftpm-testing-helper",
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        for testingLibrary in loadedImageURLs()
        where testingLibrary.lastPathComponent == "libTesting.dylib" {
            var toolchainUSR = testingLibrary
            for _ in 0..<5 { toolchainUSR.deleteLastPathComponent() }
            let helper = toolchainUSR.appendingPathComponent(
                "libexec/swift/pm/swiftpm-testing-helper")
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                return helper
            }
        }
        throw RuntimeError(message:
            "could not locate the active toolchain's swiftpm-testing-helper")
    }
}

@Suite("Structured concurrency retained-memory plateau", .serialized)
struct StructuredMemoryPlateauTests {
    @Test
    func retainedStructuredWorkloadMemoryPlateausAcrossBatches() throws {
        guard ProcessInfo.processInfo.environment[
            structuredMemoryChildReceiptVariable] == nil else { return }

        let receipt = try StructuredMemoryPlateauHarness.runIsolatedChild()
        let assessment = try StructuredMemoryPlateauAssessment(
            snapshots: receipt.snapshots)

        #expect(receipt.version == 1)
        #expect(receipt.processIdentifier
            != ProcessInfo.processInfo.processIdentifier)
        #expect(receipt.warmupSessions
            == StructuredMemoryPlateauHarness.warmupSessions)
        #expect(receipt.measuredSessionsPerBatch
            == StructuredMemoryPlateauHarness.measuredSessionsPerBatch)
        #expect(receipt.measuredBatches
            == StructuredMemoryPlateauHarness.measuredBatches)
        #expect(receipt.snapshots.count == receipt.measuredBatches + 1)

        #expect(assessment.resident.positiveMedianDrift
            <= StructuredMemoryPlateauHarness.residentDriftLimit)
        #expect(assessment.resident.lateWindowSpread
            <= StructuredMemoryPlateauHarness.residentSpreadLimit)
        #expect(assessment.resident.positiveSlopeBytesPerBatch
            <= StructuredMemoryPlateauHarness.residentSlopeLimit)
        #expect(assessment.physicalFootprint.positiveMedianDrift
            <= StructuredMemoryPlateauHarness.footprintDriftLimit)
        #expect(assessment.physicalFootprint.lateWindowSpread
            <= StructuredMemoryPlateauHarness.footprintSpreadLimit)
        #expect(assessment.physicalFootprint.positiveSlopeBytesPerBatch
            <= StructuredMemoryPlateauHarness.footprintSlopeLimit)
        #expect(assessment.allocator.positiveMedianDrift
            <= StructuredMemoryPlateauHarness.allocatorDriftLimit)
        #expect(assessment.allocator.lateWindowSpread
            <= StructuredMemoryPlateauHarness.allocatorSpreadLimit)
        #expect(assessment.allocator.positiveSlopeBytesPerBatch
            <= StructuredMemoryPlateauHarness.allocatorSlopeLimit)

        let totalSessions = receipt.warmupSessions
            + receipt.measuredSessionsPerBatch * receipt.measuredBatches
        print("@@structured-memory-plateau-summary "
            + "{\"version\":1,\"pid\":\(receipt.processIdentifier),"
            + "\"sessions\":\(totalSessions),"
            + "\"nodesPerSession\":\(receipt.structuredNodesPerSession),"
            + "\"residentDrift\":"
            + "\(assessment.resident.positiveMedianDrift),"
            + "\"residentSlope\":"
            + "\(Int(assessment.resident.positiveSlopeBytesPerBatch)),"
            + "\"footprintDrift\":"
            + "\(assessment.physicalFootprint.positiveMedianDrift),"
            + "\"footprintSlope\":"
            + "\(Int(assessment.physicalFootprint.positiveSlopeBytesPerBatch)),"
            + "\"allocatorDrift\":"
            + "\(assessment.allocator.positiveMedianDrift),"
            + "\"allocatorSlope\":"
            + "\(Int(assessment.allocator.positiveSlopeBytesPerBatch))}")
    }

    @Test
    func plateauAnalyzerRejectsLinearRetentionAndAcceptsBoundedJitter()
    throws {
        let mib = UInt64(1_048_576)
        let linear = (0..<13).map { index in
            StructuredMemorySnapshot(
                residentBytes: UInt64(index) * 2 * mib,
                physicalFootprintBytes: UInt64(index) * 2 * mib,
                allocatorBytesInUse: UInt64(index) * mib)
        }
        let linearAssessment = try StructuredMemoryPlateauAssessment(
            snapshots: linear)
        #expect(linearAssessment.resident.positiveMedianDrift
            > StructuredMemoryPlateauHarness.residentDriftLimit)
        #expect(linearAssessment.resident.positiveSlopeBytesPerBatch
            > StructuredMemoryPlateauHarness.residentSlopeLimit)
        #expect(linearAssessment.allocator.positiveSlopeBytesPerBatch
            > StructuredMemoryPlateauHarness.allocatorSlopeLimit)

        let jitter = (0..<13).map { index in
            let offset = UInt64([0, 128, 64, 192][index % 4]) * 1_024
            return StructuredMemorySnapshot(
                residentBytes: 80 * mib + offset,
                physicalFootprintBytes: 60 * mib + offset,
                allocatorBytesInUse: 20 * mib + offset)
        }
        let jitterAssessment = try StructuredMemoryPlateauAssessment(
            snapshots: jitter)
        #expect(jitterAssessment.resident.positiveMedianDrift
            <= StructuredMemoryPlateauHarness.residentDriftLimit)
        #expect(jitterAssessment.resident.lateWindowSpread
            <= StructuredMemoryPlateauHarness.residentSpreadLimit)
        #expect(jitterAssessment.resident.positiveSlopeBytesPerBatch
            <= StructuredMemoryPlateauHarness.residentSlopeLimit)
        #expect(jitterAssessment.allocator.positiveSlopeBytesPerBatch
            <= StructuredMemoryPlateauHarness.allocatorSlopeLimit)
    }

    @Test
    func structuredMemoryProbeChild() async throws {
        guard let receiptPath = ProcessInfo.processInfo.environment[
            structuredMemoryChildReceiptVariable] else { return }
        let receipt = try await StructuredMemoryPlateauHarness.runChildWorkload()
        try StructuredMemoryPlateauHarness.writeChildReceipt(
            receipt, to: URL(fileURLWithPath: receiptPath))
    }
}
