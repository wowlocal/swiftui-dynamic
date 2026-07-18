import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

// The generic-struct-carrier tier (BridgeGen genericStructCarriers):
// Measurement sweeps as Measurement<Dimension>, bare unit implicit members
// resolve through the swept Dimension statics (203 across 22 classes), and
// the member table serves formatted()/value/unit/converted(to:). The city
// screens' weather label was the class: the stub description rendered as
// UI text where the twin showed "72°F".
@Suite struct MeasurementBridgeTests {
    @MainActor
    @Test func constructsFormatsAndConverts() throws {
        let source = """
        import Foundation
        let t = Measurement(value: 72, unit: .fahrenheit)
        let s = Measurement(value: 100.0, unit: UnitSpeed.kilometersPerHour)
        let c = t.converted(to: UnitTemperature.celsius)
        t.formatted() + "|" + s.formatted() + "|" +
            String(Int(c.value.rounded())) + "|" + String(Int(t.value))
        """
        let result = try Interpreter(registry: ViewRegistry()).run(source: source)
        let native = Measurement(value: 72, unit: UnitTemperature.fahrenheit)
        let nativeSpeed = Measurement(value: 100.0, unit: UnitSpeed.kilometersPerHour)
        let expected = native.formatted() + "|" + nativeSpeed.formatted() + "|22|72"
        #expect(result.stringValue == expected)
    }

    @MainActor
    @Test func ambiguousBareUnitThrows() throws {
        let source = """
        import Foundation
        Measurement(value: 1.0, unit: .degrees)
        """
        // UnitAngle.degrees vs UnitTemperature? — whatever the sweep holds,
        // a bare name with multiple containers must throw, not guess.
        let containers = GeneratedMembers.dimensionContainersByBareName["degrees"] ?? []
        let result = try? Interpreter(registry: ViewRegistry()).run(source: source)
        if containers.count > 1 {
            #expect(result == nil)
        } else {
            #expect(result != nil)
        }
    }
}
