private func fileScopedValue() -> Int { 22 }

func secondFileValue() -> Int { fileScopedValue() }
