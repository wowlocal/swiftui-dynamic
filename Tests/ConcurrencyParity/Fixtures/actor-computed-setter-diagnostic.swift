actor ComputedSetterCounter {
    var value: Int {
        get { 0 }
        set {}
    }
}

func illegalExternalMutation(_ counter: ComputedSetterCounter) async {
    await counter.value = 1
}
