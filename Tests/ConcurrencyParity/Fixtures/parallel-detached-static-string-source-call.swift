protocol PhysicalStaticStringSourceCallProtocol: Sendable {
    var source: String { get }
    func prepare() async -> String
}

extension PhysicalStaticStringSourceCallProtocol {
    nonisolated static func prepareScriptSource(from source: String) -> String {
        "prepared:\(source.uppercased())"
    }

    func prepare() async -> String {
        await Task.detached { [source] in
            Self.prepareScriptSource(from: source)
        }.result.get()
    }

    func prepareDirectly() -> String {
        Self.prepareScriptSource(from: source)
    }
}

struct PhysicalStaticStringSourceCallProbe:
    PhysicalStaticStringSourceCallProtocol
{
    let source: String
}

func detachedResultGetProbe() async -> String {
    await Task.detached { "result-get" }.result.get()
}

func parallelDetachedStaticStringSourceCallProbe() async -> String {
    let first = await PhysicalStaticStringSourceCallProbe(
        source: "first-script"
    ).prepare()
    let second = await PhysicalStaticStringSourceCallProbe(
        source: "second-script"
    ).prepare()
    return "\(first),\(second)"
}

func parityNativeOutput() async throws -> String {
    await parallelDetachedStaticStringSourceCallProbe()
}
