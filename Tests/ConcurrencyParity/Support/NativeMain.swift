@MainActor
func parityYield(_ value: String) async -> String {
    await Task.yield()
    return value
}

@MainActor
var parityWaitStarted = false

@MainActor
func parityWaitForever() async throws {
    parityWaitStarted = true
    try await Task.sleep(for: .seconds(30))
}

@MainActor
func parityAwaitWaitStarted() async {
    while !parityWaitStarted {
        await Task.yield()
    }
}

enum ParityNativeTaskLocal {
    @TaskLocal static var value = "default"
}

func parityReadTaskLocal() async -> String {
    ParityNativeTaskLocal.value
}

@MainActor
func parityWithTaskLocalValue(
    _ value: String,
    operation: @escaping @MainActor @Sendable () async throws -> String
) async rethrows -> String {
    try await ParityNativeTaskLocal.$value.withValue(value) {
        try await operation()
    }
}

@MainActor
func parityDetachedInheritance() async -> String {
    await ParityNativeTaskLocal.$value.withValue("parent") {
        await Task.detached {
            ParityNativeTaskLocal.value == "default" ? "lost" : "inherited"
        }.value
    }
}

@MainActor
func parityDetachedReentry(
    _ body: @escaping @MainActor @Sendable () async throws -> String
) async throws -> String {
    try await ParityNativeTaskLocal.$value.withValue("root") {
        let captured = ParityNativeTaskLocal.value
        return try await Task.detached {
            try await parityRunReboundContext(captured, body: body)
        }.value
    }
}

@MainActor
private func parityRunReboundContext(
    _ value: String,
    body: @escaping @MainActor @Sendable () async throws -> String
) async throws -> String {
    try await ParityNativeTaskLocal.$value.withValue(value) {
        try await body()
    }
}

@MainActor
func parityCheckContext() async -> String {
    ParityNativeTaskLocal.value == "root" ? "preserved" : "wrong"
}

@MainActor
var parityHostGatewayEventStorage: [String] = []

@MainActor
var parityHostGatewayStarted = false

@MainActor
var parityHostGatewayOpen = false

@MainActor
func parityRecordHostGatewayEvent(_ event: String) {
    parityHostGatewayEventStorage.append(event)
}

@MainActor
func parityHostGatewayValue(_ value: String) async -> String {
    parityHostGatewayEventStorage.append("host-enter")
    parityHostGatewayStarted = true
    while !parityHostGatewayOpen {
        await Task.yield()
    }
    parityHostGatewayEventStorage.append("host-exit")
    return value
}

@MainActor
func parityAwaitHostGatewayStarted() async {
    while !parityHostGatewayStarted {
        await Task.yield()
    }
}

@MainActor
func parityOpenHostGateway() {
    parityHostGatewayOpen = true
}

@MainActor
func parityHostGatewayEvents() -> String {
    parityHostGatewayEventStorage.joined(separator: ",")
}

@MainActor
var parityTaskValueGateStarted = false

@MainActor
var parityTaskValueGateOpen = false

@MainActor
func parityWaitTaskValueGate() async {
    parityTaskValueGateStarted = true
    while !parityTaskValueGateOpen {
        await Task.yield()
    }
}

@MainActor
func parityAwaitTaskValueGateStarted() async {
    while !parityTaskValueGateStarted {
        await Task.yield()
    }
}

@MainActor
func parityOpenTaskValueGate() {
    parityTaskValueGateOpen = true
}

@MainActor
var parityTaskValueWaiterCount = 0

@MainActor
func parityRegisterTaskValueSource(_ task: Task<String, Never>) {
    _ = task
}

@MainActor
func parityMarkTaskValueWaiter() {
    parityTaskValueWaiterCount += 1
}

@MainActor
func parityAwaitTaskValueWaiters() async {
    while parityTaskValueWaiterCount < 2 {
        await Task.yield()
    }
}

@MainActor
var paritySleepStarted = false

@MainActor
func parityMarkSleepStarted() {
    paritySleepStarted = true
}

@MainActor
func parityCancelWhenSleepStarted(_ task: Task<Void, Never>) async {
    while !paritySleepStarted {
        await Task.yield()
    }
    task.cancel()
}

@main
struct NativeMain {
    static func main() async throws {
        print(try await parityNativeOutput())
    }
}
