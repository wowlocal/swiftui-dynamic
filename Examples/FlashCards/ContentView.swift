import SwiftUI

struct StudyCard {
    let prompt: String
    let answer: String
    let symbol: String
}

struct ContentView: View {
    let cards = [
        StudyCard(prompt: "What does a Swift actor protect?", answer: "Its mutable state", symbol: "lock.shield"),
        StudyCard(prompt: "Which wrapper creates local view state?", answer: "@State", symbol: "switch.2"),
        StudyCard(prompt: "What builds a vertical layout?", answer: "VStack", symbol: "rectangle.stack"),
        StudyCard(prompt: "Which protocol defines a SwiftUI screen?", answer: "View", symbol: "macwindow")
    ]

    @State private var cardIndex = 0
    @State private var score = 0
    @State private var answerVisible = false
    @State private var finished = false

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Swift Study")
                        .font(.title2)
                        .bold()
                    Text(finished ? "Session complete" : "Card \(cardIndex + 1) of \(cards.count)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("\(score)", systemImage: "star.fill")
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                ForEach(0..<4) { index in
                    Capsule()
                        .fill(index <= cardIndex ? Color.blue : Color.gray.opacity(0.2))
                        .frame(height: 6)
                }
            }

            if finished {
                VStack(spacing: 16) {
                    Image(systemName: "party.popper.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.purple)
                    Text("Nice work!")
                        .font(.largeTitle)
                        .bold()
                    Text("You knew \(score) of \(cards.count) cards.")
                        .foregroundStyle(.secondary)
                    Button("Study again") {
                        cardIndex = 0
                        score = 0
                        answerVisible = false
                        finished = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: cards[cardIndex].symbol)
                        .font(.system(size: 42))
                        .foregroundStyle(.blue)

                    Text(cards[cardIndex].prompt)
                        .font(.title2)
                        .multilineTextAlignment(.center)

                    Divider()

                    if answerVisible {
                        Text(cards[cardIndex].answer)
                            .font(.title)
                            .bold()
                            .foregroundStyle(.green)
                    } else {
                        Text("Think of the answer, then reveal it")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: 280)
                .background(.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 24))

                if answerVisible {
                    HStack(spacing: 12) {
                        Button("Study again") {
                            advanceCard(knewAnswer: false)
                        }
                        .buttonStyle(.bordered)

                        Button("I knew it") {
                            advanceCard(knewAnswer: true)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Reveal answer") {
                        answerVisible = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 600)
    }

    func advanceCard(knewAnswer: Bool) {
        if knewAnswer {
            score += 1
        }

        if cardIndex + 1 < cards.count {
            cardIndex += 1
            answerVisible = false
        } else {
            finished = true
        }
    }
}
