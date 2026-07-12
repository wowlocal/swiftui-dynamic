@main
struct NativeMain {
    static func main() async throws {
        print(try await parityNativeOutput())
    }
}
