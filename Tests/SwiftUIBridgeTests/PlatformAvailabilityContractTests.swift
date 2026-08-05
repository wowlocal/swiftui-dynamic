import Foundation
import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

/// A platform member the host cannot RUN still has a contract the host must
/// READ. Distilled from `CustomHUDs`, whose HUD presenter asks a view
/// controller's view whether it already carries a tagged subview — three
/// layers of one class, each pinned separately here.
@Suite(.serialized) struct PlatformAvailabilityContractTests {
    private func run(_ snippet: String) throws -> RuntimeValue {
        try Interpreter(registry: TraceRegistry()).run(
            source: ProjectMaterial.mergedSource(
                source: snippet, moduleName: "PlatformAvailability"))
    }

    /// A member of a framework absent from this host reads its typed inert
    /// answer FROM the swept contract: `[UIView]` answers an empty array, so
    /// `contains(where:)` is an ordinary Bool. Withdraw the registration
    /// off-platform and the same member becomes an unresolved chain — which
    /// coerces nowhere, so an `if` over it throws instead of taking its
    /// false branch.
    @Test func absentFrameworkMemberAnswersFromItsContract() throws {
        let value = try run("""
        import SwiftUI

        let host = UIView()
        let tagged = host.subviews.contains(where: { $0.tag == 1009 })
        (tagged, host.subviews.isEmpty)
        """)

        let tuple = try #require(value.tupleValue)
        #expect(tuple.values[0].boolValue == false)
        #expect(tuple.values[1].boolValue == true)
    }

    /// `UIViewController.view` is declared `UIView!`. The `!` records that the
    /// value is non-nil in practice while the header cannot prove it, and
    /// compiled source relies on exactly that — it passes the member straight
    /// into `UIView` positions. So `nil` is not this member's inert reading;
    /// it is the reading that traps. An off-platform read must be inert AND
    /// present.
    @Test func implicitlyUnwrappedMemberReadsPresentOffPlatform() throws {
        let value = try run("""
        import SwiftUI

        let controller = UIViewController()
        let view = controller.view
        (view == nil, controller.view.subviews.isEmpty)
        """)

        let tuple = try #require(value.tupleValue)
        #expect(tuple.values[0].boolValue == false)
        #expect(tuple.values[1].boolValue == true)
    }

    /// `T!` converts implicitly to `T` at a call boundary — that is what the
    /// spelling means, and `addSubview(controller.view)` compiles because of
    /// it. A plain `T?` in the same position stays the error the compiler
    /// reports, so the rule is keyed on the declared spelling, not on the
    /// value happening to be present.
    @Test func implicitlyUnwrappedArgumentSatisfiesNonOptionalParameter() throws {
        let value = try run("""
        import SwiftUI

        let controller = UIViewController()
        let host = UIView()
        host.addSubview(controller.view)
        host.subviews.count
        """)

        #expect(value.intValue == 0)
    }
}
