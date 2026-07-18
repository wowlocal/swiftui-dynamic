struct NativeCoroutineOptionalValue {
    var text: String

    mutating func mutate() async {
        text += "-entered"
        await Task.yield()
        text += "-resumed"
    }
}

struct NativeCoroutineOptionalBox {
    var storage: NativeCoroutineOptionalValue?
    var value: NativeCoroutineOptionalValue? {
        read { yield storage }
        modify { yield &storage }
    }
}

func nativeCoroutineOptionalWritebackProbe() async -> String {
    var box = NativeCoroutineOptionalBox(
        storage: NativeCoroutineOptionalValue(text: "seed"))
    await box.value?.mutate()
    return box.storage?.text ?? "nil"
}

@main struct NativeCoroutineOptionalMain {
    static func main() async {
        print(await nativeCoroutineOptionalWritebackProbe())
    }
}
