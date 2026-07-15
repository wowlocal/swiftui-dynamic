@MainActor
func taskGroupBoundedTreeNode(_ depth: Int, _ fanout: Int) async -> Int {
    if depth == 0 {
        return 1
    }

    let descendants = await withTaskGroup(of: Int.self) { group in
        for _ in 0..<fanout {
            group.addTask {
                await taskGroupBoundedTreeNode(depth - 1, fanout)
            }
        }

        var total = 0
        for await value in group {
            total += value
        }
        return total
    }
    return 1 + descendants
}

@MainActor
func taskGroupBoundedTreeProbe() async -> String {
    let leaf = await taskGroupBoundedTreeNode(0, 4)
    let shallow = await taskGroupBoundedTreeNode(1, 4)
    let deep = await taskGroupBoundedTreeNode(3, 3)
    return "\(leaf),\(shallow),\(deep)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await taskGroupBoundedTreeProbe()
}
