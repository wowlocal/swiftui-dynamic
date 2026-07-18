enum OptionalAsyncThrowingWritebackError: Error { case boom }

struct OptionalAsyncThrowingWritebackValue {
    var text: String

    mutating func mutate(cancelled: Bool) async throws {
        text += "-entered"
        await Task.yield()
        text += "-resumed"
        if cancelled { try Task.checkCancellation() }
        throw OptionalAsyncThrowingWritebackError.boom
    }
}

struct OptionalAsyncThrowingWritebackBox { var value: OptionalAsyncThrowingWritebackValue? }

func optionalValueMutatingAsyncThrowingWritebackProbe() async -> String {
    var thrown: OptionalAsyncThrowingWritebackValue? =
        OptionalAsyncThrowingWritebackValue(text: "throw")
    var thrownOutcome = "missed"
    do { try await thrown?.mutate(cancelled: false) }
    catch OptionalAsyncThrowingWritebackError.boom { thrownOutcome = "threw" }
    catch { thrownOutcome = "wrong" }

    let cancelled = await Task { () -> String in
        var box = OptionalAsyncThrowingWritebackBox(
            value: OptionalAsyncThrowingWritebackValue(text: "cancel"))
        withUnsafeCurrentTask { $0?.cancel() }
        do { try await box.value?.mutate(cancelled: true) }
        catch is CancellationError { return "cancelled:\(box.value?.text ?? "nil")" }
        catch { return "wrong:\(box.value?.text ?? "nil")" }
        return "missed:\(box.value?.text ?? "nil")"
    }.value
    return "\(thrownOutcome):\(thrown?.text ?? "nil")|\(cancelled)"
}

func parityNativeOutput() async throws -> String {
    await optionalValueMutatingAsyncThrowingWritebackProbe()
}
