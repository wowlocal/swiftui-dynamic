import SwiftUI

struct Expense: Identifiable {
    let id: Int
    var title: String
    var amount: Double
    var categoryName: String
    var note: String
}

enum Category: String, CaseIterable {
    case food = "Food"
    case transport = "Transport"
    case fun = "Fun"
    case bills = "Bills"

    var icon: String {
        switch self {
        case .food: return "fork.knife"
        case .transport: return "car.fill"
        case .fun: return "gamecontroller.fill"
        case .bills: return "bolt.fill"
        }
    }

    var color: Color {
        switch self {
        case .food: return .orange
        case .transport: return .blue
        case .fun: return .purple
        case .bills: return .red
        }
    }
}
