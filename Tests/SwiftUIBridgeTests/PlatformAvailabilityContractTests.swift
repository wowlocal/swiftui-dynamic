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
}
