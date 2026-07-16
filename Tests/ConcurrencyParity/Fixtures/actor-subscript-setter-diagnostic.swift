actor SubscriptSetterCounter {
    subscript(_ index: Int) -> Int {
        get { index }
        set {}
    }
}

func illegalExternalMutation(_ counter: SubscriptSetterCounter) async {
    await counter[0] = 1
}
