struct CircuitGame {
    static let patterns = [
        [
            true, false, false, true,
            false, true, true, false,
            false, true, true, false,
            true, false, false, true
        ],
        [
            true, true, true, true,
            true, false, false, true,
            true, false, false, true,
            true, true, true, true
        ],
        [
            true, false, false, false,
            false, true, false, false,
            false, false, true, false,
            false, false, false, true
        ]
    ]

    var cells = CircuitGame.patterns[0]
    var moves = 0
    var patternIndex = 0
    var lastPulse = -1

    var litCount: Int {
        var count = 0
        for cell in cells {
            if cell {
                count += 1
            }
        }
        return count
    }

    var progress: Double {
        Double(litCount) / Double(cells.count)
    }

    var isComplete: Bool {
        litCount == cells.count
    }

    var patternName: String {
        if patternIndex == 0 {
            return "MIRROR BLOOM"
        }
        if patternIndex == 1 {
            return "ORBIT RING"
        }
        return "DIAGONAL SEED"
    }

    mutating func tap(_ index: Int) {
        if index < 0 || index >= cells.count {
            return
        }

        let row = index / 4
        let column = index % 4

        toggle(index)
        if row > 0 {
            toggle(index - 4)
        }
        if row < 3 {
            toggle(index + 4)
        }
        if column > 0 {
            toggle(index - 1)
        }
        if column < 3 {
            toggle(index + 1)
        }

        moves += 1
        lastPulse = index
    }

    mutating func reset() {
        cells = CircuitGame.patterns[patternIndex]
        moves = 0
        lastPulse = -1
    }

    mutating func nextPattern() {
        patternIndex = (patternIndex + 1) % CircuitGame.patterns.count
        reset()
    }

    private mutating func toggle(_ index: Int) {
        cells[index] = !cells[index]
    }
}
