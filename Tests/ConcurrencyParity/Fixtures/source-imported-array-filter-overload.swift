struct FilterItem {
    let value: Int
    let accepted: Bool
}

struct FilterRule {
    let divisor: Int

    func validate(_ item: FilterItem) -> Bool {
        item.value % divisor == 0
    }
}

extension Array where Element == FilterItem {
    func filter(_ rules: [FilterRule]) -> [FilterItem] {
        self.filter { item in
            rules.allSatisfy { rule in
                rule.validate(item)
            }
        }
    }
}

func sourceImportedArrayFilterOverloadOutput() async -> String {
    await Task.yield()

    let items = [
        FilterItem(value: 2, accepted: true),
        FilterItem(value: 3, accepted: false),
        FilterItem(value: 6, accepted: true),
        FilterItem(value: 12, accepted: true),
    ]
    let rules = [FilterRule(divisor: 2), FilterRule(divisor: 3)]
    let selected = items.filter(rules)
    let accepted = items.filter(\.accepted)
    let selectedOutput = selected.map { String($0.value) }
        .joined(separator: ",")
    let acceptedOutput = accepted.map { String($0.value) }
        .joined(separator: ",")
    return "\(selectedOutput)|\(acceptedOutput)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await sourceImportedArrayFilterOverloadOutput()
}
