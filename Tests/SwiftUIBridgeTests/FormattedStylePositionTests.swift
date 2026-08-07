import Foundation
import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// `value.formatted(.someStyle)` is the SECOND position the SDK accepts a
/// format style, after a localization key's interpolation. Only the first was
/// routed, so the second absorbed into a `ChainedImplicitCall` whose
/// `stringValue` is nil — a BLANK reading rather than a wrong one, which is
/// why it never surfaced as a decoding or arithmetic failure.
///
/// IceCubes' `Models/Alias/ServerDate.swift` writes it for every relative
/// timestamp, and `Foundation.swiftinterface` declares the same shape a dozen
/// times over Date, URL, Decimal, Duration, Measurement and the numeric
/// protocols — under three different parameter names, which is why the
/// generated method list matches the CONSTRAINT (a bare `FormatStyle` generic
/// as the only argument) rather than any spelling.
@Suite struct FormattedStylePositionTests {
    /// The position is interface-derived, not spelled in the bridge.
    @Test func theConsumingMethodNameComesFromTheInterface() {
        #expect(GeneratedSDKEnumCoercions.formatStyleConsumingMethodNames
            == ["formatted"])
    }

    /// The routed call reads what the HOST reads for the same spelling. This
    /// is the exact chain the IceCubes example post's timestamp renders.
    @MainActor
    @Test func aDurationFormatsThroughTheRoutedPosition() throws {
        let method = try #require(ViewRegistry().hostMethod(
            "formatted", on: Duration.seconds(100)))
        guard case .hostFunction(let function) = method else {
            Issue.record("formatted did not route to a host function")
            return
        }
        let rendered = try function.invoke(
            CallArguments(arguments: [
                CallArguments.Argument(label: nil, value: .native(ImplicitMemberCall(
                    name: "units",
                    arguments: CallArguments(arguments: [
                        CallArguments.Argument(
                            label: "width", value: .implicitMember("narrow")),
                        CallArguments.Argument(
                            label: "maximumUnitCount", value: .native(1)),
                    ]))))
            ]),
            Interpreter(registry: ViewRegistry()))
        #expect(rendered.stringValue == Duration.seconds(100).formatted(
            .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// A different duration reads differently through the same routed call, so
    /// the assertion above cannot pass by answering one memorised string.
    @MainActor
    @Test func theRoutedPositionReadsTheReceiverNotAConstant() throws {
        func format(_ duration: Duration) throws -> String? {
            let method = try #require(
                ViewRegistry().hostMethod("formatted", on: duration))
            guard case .hostFunction(let function) = method else { return nil }
            return try function.invoke(
                CallArguments(arguments: [
                    CallArguments.Argument(label: nil, value: .native(ImplicitMemberCall(
                        name: "units",
                        arguments: CallArguments(arguments: [
                            CallArguments.Argument(
                                label: "width",
                                value: .implicitMember("narrow")),
                            CallArguments.Argument(
                                label: "maximumUnitCount", value: .native(1)),
                        ]))))
                ]),
                Interpreter(registry: ViewRegistry())).stringValue
        }
        #expect(try format(.seconds(45))
            == Duration.seconds(45).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
        #expect(try format(.seconds(3700))
            == Duration.seconds(3700).formatted(
                .units(width: .narrow, maximumUnitCount: 1)))
    }

    /// Both registries answer the same, which [[two-registries-two-instruments]]
    /// exists to catch: the trace registry drives `renderedStrings` while the
    /// view registry drives the pixel capture, so a routing landed in one only
    /// would read green on one instrument and blank on the board.
    @MainActor
    @Test func bothRegistriesRouteTheSamePosition() {
        for registry in [ViewRegistry() as any HostRegistry, TraceRegistry()] {
            let method = registry.hostMethod(
                "formatted", on: Duration.seconds(100))
            guard case .hostFunction = method else {
                Issue.record("\(type(of: registry)) did not route formatted")
                continue
            }
        }
    }

    /// Counter-direction, and the one that pins the PRECEDENCE the fix depends
    /// on: the router is last, so a receiver a generated arm already serves
    /// keeps that arm. `Measurement.formatted()` is generated (BridgeGen emits
    /// it specially) and takes no style at all.
    ///
    /// Which arm answered is asserted directly rather than through the
    /// rendered string, because that string is locale-dependent (the generated
    /// arm reads "16 ft" here) and a hand-written expectation for it would pin
    /// the machine's region, not the routing. The discriminator is that the
    /// style search REFUSES an empty argument list while the generated arm
    /// answers one — so a success proves the generated arm won.
    @MainActor
    @Test func aGeneratedArmStillWinsOverTheStyleSearch() throws {
        let measurement = Measurement(
            value: 5, unit: UnitLength.meters) as Measurement<Dimension>
        let method = try #require(
            ViewRegistry().hostMethod("formatted", on: measurement))
        guard case .hostFunction(let function) = method else {
            Issue.record("Measurement.formatted did not route")
            return
        }
        let rendered = try function.invoke(
            CallArguments(arguments: []),
            Interpreter(registry: ViewRegistry()))
        #expect(rendered.stringValue?.isEmpty == false)

        // The same receiver through the style search alone: it refuses, which
        // is what makes the success above evidence about precedence.
        guard case .hostFunction(let search)? = bridgeFormatStyleFormattingMethod(
            "formatted", on: measurement) else {
            Issue.record("the style search should still offer the position")
            return
        }
        #expect(throws: RuntimeError.self) {
            try search.invoke(
                CallArguments(arguments: []),
                Interpreter(registry: ViewRegistry()))
        }
    }

    /// Counter-direction: a receiver no declared style accepts is refused with
    /// a diagnostic rather than rendered through whichever style sorts first.
    @MainActor
    @Test func aReceiverNoStyleAcceptsIsRefused() throws {
        let method = try #require(
            ViewRegistry().hostMethod("formatted", on: UUID()))
        guard case .hostFunction(let function) = method else {
            Issue.record("expected a host function to refuse the call")
            return
        }
        #expect(throws: RuntimeError.self) {
            try function.invoke(
                CallArguments(arguments: [
                    CallArguments.Argument(
                        label: nil, value: .native(ImplicitMemberCall(
                            name: "units",
                            arguments: CallArguments(arguments: []))))
                ]),
                Interpreter(registry: ViewRegistry()))
        }
    }
}
