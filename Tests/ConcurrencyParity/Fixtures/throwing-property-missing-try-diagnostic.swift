struct EffectfulValue {
    var count: Int {
        get throws { 5 }
    }
}

func invalidRead(_ value: EffectfulValue) {
    _ = value.count
}
