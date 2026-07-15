@MainActor
func taskNameProbe() async -> String {
    let root = Task.name ?? "nil"

    let ordinary = Task(name: "ordinary") {
        Task.name ?? "nil"
    }
    let optionalName: String? = "optional"
    let optional = Task(name: optionalName) {
        Task.name ?? "nil"
    }
    let absentName: String? = nil
    let explicitNil = Task(name: absentName) {
        Task.name ?? "nil"
    }
    let nested = Task(name: "parent") {
        let parent = Task.name ?? "nil"
        let child = Task {
            Task.name ?? "nil"
        }
        let childName = await child.value
        return parent + "/" + childName
    }
    let detached = Task.detached(name: "detached") {
        Task.name ?? "nil"
    }
    let empty = Task(name: "") {
        Task.name == "" ? "empty" : "not-empty"
    }

    let groupNames = await withTaskGroup(
        of: String.self,
        returning: String.self
    ) { group in
        group.addTask(name: "group") {
            Task.name ?? "nil"
        }
        group.addTask {
            Task.name ?? "nil"
        }
        var values: [String] = []
        for await value in group {
            values.append(value)
        }
        return values.sorted().joined(separator: ",")
    }

    let ordinaryName = await ordinary.value
    let optionalValue = await optional.value
    let explicitNilValue = await explicitNil.value
    let nestedNames = await nested.value
    let detachedName = await detached.value
    let emptyName = await empty.value
    return root
        + "|" + ordinaryName
        + "|" + optionalValue
        + "|" + explicitNilValue
        + "|" + nestedNames
        + "|" + detachedName
        + "|" + emptyName
        + "|" + groupNames
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskNameProbe()
}
