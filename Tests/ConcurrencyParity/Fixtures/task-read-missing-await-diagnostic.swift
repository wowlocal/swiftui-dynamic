func missingTaskValueAwait(
    _ task: Task<String, Never>
) async -> String {
    task.value
}

func missingTaskResultAwait(
    _ task: Task<String, Never>
) async -> Result<String, Never> {
    task.result
}
