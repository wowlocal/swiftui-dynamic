import Testing
@testable import CircuitGardenLogic

@Suite
struct CircuitGameTests {
    @Test
    func initialState() {
        let game = CircuitGame()

        #expect(game.litCount == 8)
        #expect(game.progress == 0.5)
        #expect(!game.isComplete)
        #expect(game.moves == 0)
        #expect(game.patternIndex == 0)
        #expect(game.patternName == "MIRROR BLOOM")
    }

    @Test
    func pulseFlipsSelectedNodeAndOrthogonalNeighbors() {
        var game = CircuitGame()
        game.tap(5)

        #expect(game.moves == 1)
        #expect(game.lastPulse == 5)
        #expect(game.cells[5] == false)
        #expect(game.cells[1] == true)
        #expect(game.cells[4] == true)
        #expect(game.cells[6] == false)
        #expect(game.cells[9] == false)
        #expect(game.litCount == 7)
    }

    @Test
    func repeatingPulseRestoresBoard() {
        var game = CircuitGame()
        let initialCells = game.cells

        game.tap(5)
        game.tap(5)

        #expect(game.cells == initialCells)
        #expect(game.moves == 2)
        #expect(game.lastPulse == 5)
    }

    @Test
    func resetRestoresActivePattern() {
        var game = CircuitGame()
        let initialCells = game.cells

        game.tap(10)
        game.reset()

        #expect(game.cells == initialCells)
        #expect(game.moves == 0)
        #expect(game.lastPulse == -1)
    }

    @Test
    func invalidPulseDoesNothing() {
        var game = CircuitGame()
        let initialCells = game.cells

        game.tap(-1)
        game.tap(16)

        #expect(game.cells == initialCells)
        #expect(game.moves == 0)
        #expect(game.lastPulse == -1)
    }

    @Test
    func directCollectionWritesPersist() {
        var game = CircuitGame()

        game.cells[0] = false
        #expect(game.cells[0] == false)

        game.cells = CircuitGame.patterns[1]
        #expect(game.cells == CircuitGame.patterns[1])
        #expect(game.litCount == 12)
    }

    @Test
    func pulsePersistsScalarMetadata() {
        var game = CircuitGame()
        game.tap(5)

        #expect(game.moves == 1)
        #expect(game.lastPulse == 5)
    }

    @Test
    func nestedMutatingResetPersistsScalarMetadata() {
        var game = CircuitGame()
        game.tap(5)
        #expect(game.moves == 1)
        #expect(game.lastPulse == 5)

        game.nextPattern()
        #expect(game.moves == 0)
        #expect(game.lastPulse == -1)
    }

    @Test
    func nextPatternReplacesCellsAndMetadata() {
        var game = CircuitGame()
        game.tap(5)
        game.nextPattern()

        #expect(game.patternIndex == 1)
        #expect(game.patternName == "ORBIT RING")
        #expect(game.cells == CircuitGame.patterns[1])
        #expect(game.litCount == 12)
        #expect(game.moves == 0)
        #expect(game.lastPulse == -1)
    }

    @Test
    func scriptedPulsesReachKnownBoard() {
        var game = CircuitGame()
        game.tap(5)
        game.tap(10)
        game.tap(3)

        let expected = [
            true, true, true, false,
            true, false, true, true,
            false, true, false, true,
            true, false, true, true
        ]

        #expect(game.cells == expected)
        #expect(game.litCount == 11)
        #expect(game.moves == 3)
        #expect(game.lastPulse == 3)
    }

    @Test
    func allLitBoardCompletesGarden() {
        var game = CircuitGame()
        game.cells = [
            true, true, true, true,
            true, true, true, true,
            true, true, true, true,
            true, true, true, true
        ]

        #expect(game.isComplete)
        #expect(game.litCount == 16)
        #expect(game.progress == 1)
    }
}
