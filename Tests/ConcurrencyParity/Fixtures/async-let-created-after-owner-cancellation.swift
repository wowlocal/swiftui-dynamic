@MainActor
var asyncLetPreCancelledOwnerEntered = false

@MainActor
func asyncLetPreCancelledLateChild() async -> String {
    if Task.isCancelled {
        return "child-cancelled"
    }
    return "child-active"
}

@MainActor
func asyncLetPreCancelledOwnerBody() async -> String {
    asyncLetPreCancelledOwnerEntered = true
    while !Task.isCancelled {
        await Task.yield()
    }

    async let child = asyncLetPreCancelledLateChild()
    let owner = Task.isCancelled ? "owner-cancelled" : "owner-active"
    return owner + ":" + (await child)
}

@MainActor
func asyncLetCreatedAfterOwnerCancellationProbe() async -> String {
    let owner = Task {
        await asyncLetPreCancelledOwnerBody()
    }
    while !asyncLetPreCancelledOwnerEntered {
        await Task.yield()
    }
    owner.cancel()
    return await owner.value
}

@MainActor
func parityNativeOutput() async throws -> String {
    await asyncLetCreatedAfterOwnerCancellationProbe()
}
