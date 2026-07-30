import Foundation
import SwiftInterpreter
import Testing
@testable import SwiftUIBridge

/// How much of BridgeGen's hand-emitted `invoke` surface could a purely
/// mechanical, signature-driven emitter take over? Measured against every
/// method signature the generator actually registered.
@Suite(.serialized)
@MainActor
struct CompiledBoundaryCoverageTests {

    private var allSignatures: [HostSignature] {
        GeneratedMembers.methods
            .values
            .flatMap(\.overloads)
            .map(\.signature)
            .sorted { $0.declaration < $1.declaration }
    }

    @Test func reportsMechanicalExpressibility() throws {
        let signatures = allSignatures
        var expressible: [HostSignature] = []
        var skipped: [String: Int] = [:]

        for signature in signatures {
            if CompiledBoundary.shimSource(
                for: signature, symbol: "cb_probe") != nil {
                expressible.append(signature)
            } else if !signature.genericParameters.isEmpty {
                skipped["generic parameters", default: 0] += 1
            } else if signature.isAsync {
                skipped["async", default: 0] += 1
            } else if signature.parameters.contains(where: \.isVariadic) {
                skipped["variadic", default: 0] += 1
            } else {
                skipped["other", default: 0] += 1
            }
        }

        let percent = Double(expressible.count) * 100 / Double(signatures.count)
        print("""

        ── mechanical expressibility over registered generated methods ──
        total registered method overloads : \(signatures.count)
        mechanically expressible          : \(expressible.count) \
        (\(String(format: "%.1f", percent))%)
        """)
        for (reason, count) in skipped.sorted(by: { $0.value > $1.value }) {
            print("  skipped — \(reason): \(count)")
        }
        #expect(signatures.count > 100)
        #expect(expressible.count > 0)
    }

    /// Expressible is cheap to claim; COMPILING is the real test. Take a
    /// deterministic spread across the registered surface and build each one
    /// against the real SDK.
    @Test func compilesRepresentativeSample() throws {
        let expressible = allSignatures.filter {
            CompiledBoundary.shimSource(for: $0, symbol: "cb_probe") != nil
        }
        let sampleSize = 60
        let stride = max(1, expressible.count / sampleSize)
        let sample = Swift.stride(
            from: 0, to: expressible.count, by: stride
        ).prefix(sampleSize).map { expressible[$0] }

        var compiled = 0
        var failures: [(String, String)] = []
        for signature in sample {
            do {
                _ = try CompiledBoundary.shared.entry(for: signature)
                compiled += 1
            } catch {
                failures.append((signature.declaration, "\(error)"))
            }
        }

        let percent = Double(compiled) * 100 / Double(sample.count)
        print("""

        ── compiled against the real SDK ──
        sampled          : \(sample.count)
        compiled + loaded: \(compiled) \
        (\(String(format: "%.1f", percent))%)
        """)
        for (declaration, reason) in failures.prefix(12) {
            let firstLine = reason
                .split(separator: "\n")
                .first(where: { $0.contains("error:") })
                .map(String.init) ?? String(reason.prefix(160))
            print("  FAILED \(declaration)\n         \(firstLine)")
        }
        if failures.count > 12 {
            print("  … and \(failures.count - 12) more")
        }
        #expect(compiled > 0)
    }

    /// Associated-generic receivers must retain their concrete argument in the
    /// generated contract. An erased spelling can execute through the static
    /// closure but cannot be recompiled by the signature-driven boundary.
    @Test func genericReceiverContractsCompileAgainstRealSDK() throws {
        let signatures = allSignatures.filter {
            $0.receiverType?.contains("<") == true
        }
        #expect(!signatures.isEmpty)
        for signature in signatures {
            #expect(throws: Never.self) {
                _ = try CompiledBoundary.shared.entry(for: signature)
            }
        }
    }
}
