import AppKitMetalSignal
import Testing

@Suite("Metal signal compute pipeline")
struct MetalSignalEngineTests {
    @Test func deterministicGPUFramesHaveUsefulSignal() throws {
        let engine = try MetalSignalEngine()
        let first = try engine.render(
            width: 192,
            height: 120,
            pattern: .aurora,
            phase: 0.18,
            scale: 1.15
        )
        let repeated = try engine.render(
            width: 192,
            height: 120,
            pattern: .aurora,
            phase: 0.18,
            scale: 1.15
        )
        let contour = try engine.render(
            width: 192,
            height: 120,
            pattern: .contour,
            phase: 0.18,
            scale: 1.15
        )

        #expect(first.width == 192)
        #expect(first.height == 120)
        #expect(first.checksum == repeated.checksum)
        #expect(first.checksum != contour.checksum)
        #expect(first.lumaSpread > 0.35)
        #expect(first.distinctSamples > 50)
        #expect(first.pngData.count > 1_000)
        #expect(!first.deviceName.isEmpty)
    }
}
