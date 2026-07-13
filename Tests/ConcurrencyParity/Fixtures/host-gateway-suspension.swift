@MainActor
func hostGatewaySuspensionProbe() async -> String {
    parityRecordHostGatewayEvent("before")
    let controller = Task {
        await parityAwaitHostGatewayStarted()
        parityRecordHostGatewayEvent("controller")
        parityOpenHostGateway()
    }
    let value = await parityHostGatewayValue("value")
    parityRecordHostGatewayEvent(value)
    _ = await controller.value
    return parityHostGatewayEvents()
}

@MainActor
func parityNativeOutput() async throws -> String {
    await hostGatewaySuspensionProbe()
}
