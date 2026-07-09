import SwiftUI
import SwiftInterpreter

/// An interpreted gesture under construction: `DragGesture()` /
/// `TapGesture()` plus chained `.onChanged` / `.onEnded` interpreted
/// closures. The `.gesture` modifier turns it into the real SwiftUI gesture,
/// whose callbacks re-enter the interpreter (mouse drags on macOS).
public final class GestureBox {
    enum Kind {
        case drag(minimumDistance: Double)
        case tap
    }

    let kind: Kind
    var onChanged: [ClosureValue] = []
    var onEnded: [ClosureValue] = []

    init(kind: Kind) {
        self.kind = kind
    }

    /// Gesture values are immutable chains in SwiftUI — copy on chain.
    func chained(_ member: String, _ closure: ClosureValue) -> GestureBox {
        let copy = GestureBox(kind: kind)
        copy.onChanged = onChanged
        copy.onEnded = onEnded
        if member == "onChanged" {
            copy.onChanged.append(closure)
        } else {
            copy.onEnded.append(closure)
        }
        return copy
    }

    /// The real gesture, attached. Interpreted callbacks receive the native
    /// DragGesture.Value (its members resolve via bridgeHostMember).
    @MainActor
    func attach(to view: AnyView, ctx: EvalContext) -> AnyView {
        switch kind {
        case .drag(let minimumDistance):
            let changed = onChanged
            let ended = onEnded
            let drag = DragGesture(minimumDistance: minimumDistance, coordinateSpace: .local)
                .onChanged { value in
                    for closure in changed {
                        _ = try? ctx.callClosure(closure, arguments: [.native(value)])
                    }
                }
                .onEnded { value in
                    for closure in ended {
                        _ = try? ctx.callClosure(closure, arguments: [.native(value)])
                    }
                }
            return AnyView(view.gesture(drag))
        case .tap:
            let ended = onEnded
            return AnyView(view.onTapGesture {
                for closure in ended {
                    _ = try? ctx.callClosure(closure, arguments: [])
                }
            })
        }
    }
}
