@MainActor
func parityYield(_ value: String) async -> String {
    await Task.yield()
    return value
}

@main
struct NativeMain {
    static func main() async throws {
        print(try await parityNativeOutput())
    }
}
