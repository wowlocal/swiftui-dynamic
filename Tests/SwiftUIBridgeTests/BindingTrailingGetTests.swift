import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

/// FoodTruck R3 orders-after-preparing/steps: mutations through
/// `model.orderBinding(for:).wrappedValue.markAsPreparing()` no-opped —
/// the Binding(get:set:) gateway only accepted a LABELED get closure,
/// so the Kit's trailing form `Binding<Order> { … } set: { … }` seeded
/// the box with void and the mutation had nothing to land on.
@Suite struct BindingTrailingGetTests {
    @MainActor
    @Test func customBindingWrappedValueMutatingWriteBack() throws {
        let source = """
        struct Order {
            var status: String
            mutating func markAsPreparing() {
                status = "preparing"
            }
        }
        final class Model {
            var orders: [Order] = [Order(status: "placed")]
            func orderBinding() -> Binding<Order> {
                Binding<Order> {
                    self.orders[0]
                } set: { newValue in
                    self.orders[0] = newValue
                }
            }
        }
        let model = Model()
        let binding = model.orderBinding()
        binding.wrappedValue.markAsPreparing()
        let status = model.orders[0].status
        """
        let interpreter = Interpreter(registry: ViewRegistry())
        try interpreter.run(source: source)
        #expect(interpreter.globals.lookup("status")?.stringValue == "preparing")
    }
}
