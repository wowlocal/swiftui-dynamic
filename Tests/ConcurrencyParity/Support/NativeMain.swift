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

@main
struct NativeMain {
    static func main() async throws {
        print(try await parityNativeOutput())
    }
}
