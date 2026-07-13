import Foundation

enum PrimaryTaskLocal {
    @TaskLocal static var value = "primary-default"
}

enum SecondaryTaskLocal {
    @TaskLocal static var value = "secondary-default"
}

@MainActor
func taskLocalDeclarationProbe() async -> String {
    let before = "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
    let scoped = await PrimaryTaskLocal.$value.withValue("primary-bound") {
        let direct = "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
        let synchronous = SecondaryTaskLocal.$value.withValue(
            "secondary-sync"
        ) {
            "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
        }
        let inherited = await Task {
            _ = await parityYield("source-task-local-inherited")
            return "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
        }.value
        let detached = await Task.detached {
            _ = await parityYield("source-task-local-detached")
            return "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
        }.value
        let nested = await SecondaryTaskLocal.$value.withValue(
            "secondary-bound"
        ) {
            _ = await parityYield("inside-source-task-local-scope")
            return "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
        }
        let restored = "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
        return "\(direct);\(synchronous);\(inherited);\(detached);\(nested);\(restored)"
    }
    let after = "\(PrimaryTaskLocal.value)|\(SecondaryTaskLocal.value)"
    return "\(before);\(scoped);\(after)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskLocalDeclarationProbe()
}
