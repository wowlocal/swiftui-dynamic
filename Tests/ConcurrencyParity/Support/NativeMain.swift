import Foundation

private final class PriorityEscalationEventStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.sorted().joined(separator: ",")
    }
}

private let priorityEscalationEventStorage = PriorityEscalationEventStorage()

private actor ActorReentrancyGate {
    private var suspended = false
    private var isOpen = false

    func suspendUntilOpen() async {
        suspended = true
        while !isOpen {
            await Task.yield()
        }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
    }
}

private let actorReentrancyGate = ActorReentrancyGate()

private final class ActorQueueCancellationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var actorSegmentEntered = false
    private var released = false

    func blockActorSegmentUntilReleased() {
        condition.lock()
        actorSegmentEntered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func hasEnteredActorSegment() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return actorSegmentEntered
    }

    func releaseActorSegment() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private let actorQueueCancellationGate = ActorQueueCancellationGate()

nonisolated func parityRecordPriorityEscalationEvent(_ event: String) {
    priorityEscalationEventStorage.record(event)
}

nonisolated func parityPriorityEscalationEvents() -> String {
    priorityEscalationEventStorage.snapshot()
}

nonisolated func parityCurrentExecutorLane() -> String {
    Thread.isMainThread ? "main" : "worker"
}

func parityCurrentIsolationKind(
    isolation: isolated (any Actor)? = #isolation
) -> String {
    isolation == nil ? "none" : "actor"
}

func parityCurrentIsolationMatches(
    _ expected: any Actor,
    isolation: isolated (any Actor)? = #isolation
) -> String {
    guard let isolation else { return "none" }
    return (isolation as AnyObject) === (expected as AnyObject)
        ? "same" : "other"
}

/// Native actor isolation implies ownership of one mutually-exclusive
/// executor segment until this synchronous function returns. The interpreter
/// twin additionally requires an explicit runtime mailbox lease instead of
/// treating its physical MainActor host as proof of source-actor ownership.
func parityActorSegmentOwnership(
    _ expected: any Actor,
    isolation: isolated (any Actor)? = #isolation
) -> String {
    guard let isolation else { return "unowned" }
    return (isolation as AnyObject) === (expected as AnyObject)
        ? "owned" : "other"
}

nonisolated func paritySuspendActorMessage() async {
    await actorReentrancyGate.suspendUntilOpen()
}

nonisolated func parityAwaitActorMessageSuspension() async {
    await actorReentrancyGate.waitUntilSuspended()
}

nonisolated func parityResumeActorMessage() async {
    await actorReentrancyGate.open()
}

nonisolated func parityBlockActorUntilReleased() {
    actorQueueCancellationGate.blockActorSegmentUntilReleased()
}

nonisolated func parityAwaitActorBlockEntered() async {
    while !actorQueueCancellationGate.hasEnteredActorSegment() {
        await Task.yield()
    }
}

nonisolated func parityReleaseActorBlock() {
    actorQueueCancellationGate.releaseActorSegment()
}

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

struct ParityHostAsyncSequence: AsyncSequence, Sendable {
    struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        var index = 0

        mutating func next() async -> Int? {
            await Task.yield()
            let values = [2, 4, 6]
            guard index < values.count else { return nil }
            defer { index += 1 }
            return values[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
}

nonisolated func parityHostAsyncSequence() -> ParityHostAsyncSequence {
    ParityHostAsyncSequence()
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
