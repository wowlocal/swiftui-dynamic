enum OptionalComputedAsyncError: Error { case boom }

final class OptionalComputedAsyncTrace: @unchecked Sendable {
    var events = ""
    func record(_ event: String) { events += "\(event)|" }
}

struct OptionalComputedAsyncValue {
    var text: String
    let trace: OptionalComputedAsyncTrace

    mutating func mutate(fail: Bool) async throws {
        trace.record("enter")
        text += "-entered"
        await Task.yield()
        text += "-resumed"
        trace.record("exit:\(text)")
        if fail { throw OptionalComputedAsyncError.boom }
    }
}

struct OptionalComputedAsyncBox {
    var storage: OptionalComputedAsyncValue?
    let trace: OptionalComputedAsyncTrace
    var value: OptionalComputedAsyncValue? {
        get { trace.record("get"); return storage }
        set { trace.record("set:\(newValue?.text ?? "nil")"); storage = newValue }
    }
}

func optionalComputedAsyncRun(fail: Bool) async -> String {
    let trace = OptionalComputedAsyncTrace()
    var box = OptionalComputedAsyncBox(
        storage: OptionalComputedAsyncValue(text: "seed", trace: trace), trace: trace)
    do { try await box.value?.mutate(fail: fail) }
    catch OptionalComputedAsyncError.boom {}
    catch { return "wrong" }
    return trace.events + (box.storage?.text ?? "nil")
}

func optionalComputedValueMutatingAsyncWritebackProbe() async -> String {
    let returned = await optionalComputedAsyncRun(fail: false)
    let thrown = await optionalComputedAsyncRun(fail: true)
    return "\(returned)#\(thrown)"
}

func parityNativeOutput() async throws -> String {
    await optionalComputedValueMutatingAsyncWritebackProbe()
}
