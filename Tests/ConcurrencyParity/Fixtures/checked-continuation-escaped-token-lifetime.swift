final class CheckedContinuationEscapedLifetimeSentinel: @unchecked Sendable {
    let marker = 0
}

final class CheckedContinuationEscapedLifetimeState: @unchecked Sendable {
    weak var sentinel: CheckedContinuationEscapedLifetimeSentinel?
}

final class CheckedThrowingContinuationEscapedLifetimeState:
    @unchecked Sendable
{
    weak var sentinel: CheckedContinuationEscapedLifetimeSentinel?
}

@MainActor
var checkedContinuationEscapedNonthrowingToken:
    CheckedContinuation<Int, Never>? = nil

@MainActor
var checkedContinuationEscapedThrowingToken:
    CheckedContinuation<Int, any Error>? = nil

@MainActor
func checkedContinuationEscapedTokenLifetimeNonthrowing() async -> String {
    let state = CheckedContinuationEscapedLifetimeState()
    let owner = Task.immediate(executorPreference: nil) {
        let sentinel = CheckedContinuationEscapedLifetimeSentinel()
        state.sentinel = sentinel
        let value: Int = await withCheckedContinuation(
            isolation: MainActor.shared,
            function: "checkedContinuationEscapedTokenLifetimeNonthrowing()"
        ) { continuation in
            checkedContinuationEscapedNonthrowingToken = continuation
        }
        return value + sentinel.marker
    }

    let retainedWhileSuspended = state.sentinel != nil
    checkedContinuationEscapedNonthrowingToken!.resume(returning: 47)
    let value = await owner.value
    let releasedAfterCompletion = state.sentinel == nil
    let tokenStillEscaped = checkedContinuationEscapedNonthrowingToken != nil
    return "\(retainedWhileSuspended):\(value):"
        + "\(releasedAfterCompletion):\(tokenStillEscaped)"
}

@MainActor
func checkedContinuationEscapedTokenLifetimeThrowing() async throws -> String {
    let state = CheckedThrowingContinuationEscapedLifetimeState()
    let owner = Task.immediate(executorPreference: nil) {
        let sentinel = CheckedContinuationEscapedLifetimeSentinel()
        state.sentinel = sentinel
        let value: Int = try await withCheckedThrowingContinuation(
            isolation: MainActor.shared,
            function: "checkedContinuationEscapedTokenLifetimeThrowing()"
        ) { continuation in
            checkedContinuationEscapedThrowingToken = continuation
        }
        return value + sentinel.marker
    }

    let retainedWhileSuspended = state.sentinel != nil
    checkedContinuationEscapedThrowingToken!.resume(returning: 53)
    let value = try await owner.value
    let releasedAfterCompletion = state.sentinel == nil
    let tokenStillEscaped = checkedContinuationEscapedThrowingToken != nil
    return "\(retainedWhileSuspended):\(value):"
        + "\(releasedAfterCompletion):\(tokenStillEscaped)"
}

@MainActor
func checkedContinuationEscapedTokenLifetimeProbe() async throws -> String {
    let nonthrowing =
        await checkedContinuationEscapedTokenLifetimeNonthrowing()
    let throwing = try await checkedContinuationEscapedTokenLifetimeThrowing()
    return nonthrowing + "|" + throwing
}

@MainActor
func parityNativeOutput() async throws -> String {
    try await checkedContinuationEscapedTokenLifetimeProbe()
}
