import SwiftUI
import SwiftInterpreter

/// A REAL LabelStyle whose makeBody delegates to the interpreted
/// `makeBody(configuration:)` — user `struct X: LabelStyle` runs its actual
/// body (the InterpretedShape/InterpretedLayout carrier pattern). SwiftUI
/// resolves styles on the main thread during render, so assumeIsolated holds.
private final class StyleCarrier: @unchecked Sendable {
    let instance: Instance
    let interpreter: Interpreter

    nonisolated init(instance: Instance, interpreter: Interpreter) {
        self.instance = instance
        self.interpreter = interpreter
    }
}

struct InterpretedLabelStyle: LabelStyle {
    private let carrier: StyleCarrier

    init(instance: Instance, interpreter: Interpreter) {
        carrier = StyleCarrier(instance: instance, interpreter: interpreter)
    }

    nonisolated func makeBody(configuration: Configuration) -> some View {
        nonisolated(unsafe) let carried = configuration
        nonisolated(unsafe) var result = AnyView(EmptyView())
        MainActor.assumeIsolated {
            let carrier = self.carrier
            do {
                let value = try carrier.interpreter.callMethodLabeled(
                    named: "makeBody", on: carrier.instance,
                    arguments: [(label: "configuration", value: .native(carried))])
                if let view = try? ViewRegistry.anyView(value) {
                    result = view
                } else {
                    // Styles must never LOSE the label: fall back to the
                    // unstyled title+icon rather than a blank.
                    result = AnyView(SwiftUI.Label {
                        carried.title
                    } icon: {
                        carried.icon
                    })
                }
            } catch let error as RuntimeError {
                RenderDiagnostics.record(error, in: carrier.instance.symbol.name)
                result = AnyView(SwiftUI.Label {
                    carried.title
                } icon: {
                    carried.icon
                })
            } catch {
            }
        }
        return result
    }
}

/// Host members for style configurations the interpreted makeBody reads.
@MainActor
func styleHostMember(_ name: String, on value: Any) -> RuntimeValue? {
    if let configuration = value as? LabelStyleConfiguration {
        switch name {
        case "icon": return .native(AnyView(configuration.icon))
        case "title": return .native(AnyView(configuration.title))
        default: return nil
        }
    }
    return nil
}
