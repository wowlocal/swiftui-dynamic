private func fileScopedValue() -> Int { 20 }

func firstFileValue() -> Int { fileScopedValue() }
