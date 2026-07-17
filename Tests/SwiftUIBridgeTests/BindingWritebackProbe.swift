import Testing
@testable import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct BindingWritebackProbe {
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
        print("PROBE status=", interpreter.globals.lookup("status") ?? "nil")
        #expect(interpreter.globals.lookup("status")?.stringValue == "preparing")
    }
}
