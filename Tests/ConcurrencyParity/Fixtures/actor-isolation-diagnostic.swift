actor Counter {
    var value = 0
}

func illegalRead(_ counter: Counter) -> Int {
    counter.value
}
