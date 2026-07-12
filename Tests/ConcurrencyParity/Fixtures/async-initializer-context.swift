@MainActor
final class AsyncInitializerRecorder {
    var values: [String] = []
}

struct EvenAsyncValue {
    enum Prefix: String {
        case value = "even"
    }

    let rendered: String
}

extension EvenAsyncValue {
    init(index: Int) async {
        rendered = await parityYield(
            Prefix.value.rawValue + ":" + String(index))
    }
}

struct OddAsyncValue {
    enum Prefix: String {
        case value = "odd"
    }

    let rendered: String
}

extension OddAsyncValue {
    init(index: Int) async {
        rendered = await parityYield(
            Prefix.value.rawValue + ":" + String(index))
    }
}

@MainActor
func startAsyncInitializerProbe() -> AsyncInitializerRecorder {
    let recorder = AsyncInitializerRecorder()
    for index in 0..<100 {
        if index % 2 == 0 {
            Task {
                let value = await EvenAsyncValue(index: index)
                recorder.values.append(value.rendered)
            }
        } else {
            Task {
                let value = await OddAsyncValue(index: index)
                recorder.values.append(value.rendered)
            }
        }
    }
    return recorder
}

@MainActor
func parityNativeOutput() async throws -> String {
    let recorder = startAsyncInitializerProbe()
    while recorder.values.count < 100 {
        await Task.yield()
    }
    return recorder.values.joined(separator: ",")
}
