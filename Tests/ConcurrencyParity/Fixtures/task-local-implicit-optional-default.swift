import Foundation

enum ImplicitOptionalTaskLocal {
    @TaskLocal static var value: String?
}

@MainActor
func taskLocalImplicitOptionalDefaultProbe() async -> String {
    let before = ImplicitOptionalTaskLocal.value ?? "nil"
    let scoped = await ImplicitOptionalTaskLocal.$value.withValue("bound") {
        _ = await parityYield("inside-implicit-optional-task-local")
        return ImplicitOptionalTaskLocal.value ?? "nil"
    }
    let after = ImplicitOptionalTaskLocal.value ?? "nil"
    return "\(before),\(scoped),\(after)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskLocalImplicitOptionalDefaultProbe()
}
