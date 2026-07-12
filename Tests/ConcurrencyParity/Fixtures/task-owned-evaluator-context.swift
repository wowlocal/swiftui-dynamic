@MainActor
final class TaskContextRecorder {
    var values: [String] = []
}

@MainActor
func contextIdentity<Value>(_ value: Value) async -> Value {
    _ = await parityYield("")
    return value
}

@MainActor
struct EvenContextWorker {
    enum Token: String {
        case value = "even"
    }

    func run(index: Int, recorder: TaskContextRecorder) async {
        let value: String = await contextIdentity(String(index))
        recorder.values.append(Token.value.rawValue + ":" + value)
    }
}

@MainActor
struct OddContextWorker {
    enum Token: String {
        case value = "odd"
    }

    func run(index: Int, recorder: TaskContextRecorder) async {
        let value: String = await contextIdentity(String(index))
        recorder.values.append(Token.value.rawValue + ":" + value)
    }
}

@MainActor
func startTaskContextProbe() -> TaskContextRecorder {
    let recorder = TaskContextRecorder()
    for index in 0..<100 {
        if index % 2 == 0 {
            Task {
                await EvenContextWorker().run(index: index, recorder: recorder)
            }
        } else {
            Task {
                await OddContextWorker().run(index: index, recorder: recorder)
            }
        }
    }
    return recorder
}

@MainActor
func parityNativeOutput() async throws -> String {
    let recorder = startTaskContextProbe()
    while recorder.values.count < 100 {
        await Task.yield()
    }
    return recorder.values.joined(separator: ",")
}
