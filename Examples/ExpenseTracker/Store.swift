import SwiftUI

class ExpenseStore: ObservableObject {
    @Published var expenses: [Expense] = [
        Expense(id: 1, title: "Groceries", amount: 54.20, categoryName: "Food", note: "Weekly shop at the market"),
        Expense(id: 2, title: "Metro card", amount: 30.00, categoryName: "Transport", note: "Monthly pass top-up"),
        Expense(id: 3, title: "Coffee", amount: 4.50, categoryName: "Food", note: "Flat white, no sugar"),
        Expense(id: 4, title: "Cinema", amount: 16.00, categoryName: "Fun", note: "Evening show, row F"),
        Expense(id: 5, title: "Electricity", amount: 62.35, categoryName: "Bills", note: "April invoice"),
        Expense(id: 6, title: "Taxi home", amount: 12.80, categoryName: "Transport", note: "Late night ride"),
        Expense(id: 7, title: "Board game", amount: 39.99, categoryName: "Fun", note: "Birthday present"),
        Expense(id: 8, title: "Internet", amount: 25.00, categoryName: "Bills", note: "Fiber, 500 Mbit"),
    ]
    @Published var filter: String? = nil
    @Published var search = ""
    var nextID = 100

    var visible: [Expense] {
        var result: [Expense] = []
        for expense in expenses {
            if let name = filter, expense.categoryName != name {
                continue
            }
            if !search.isEmpty && !expense.title.lowercased().contains(search.lowercased()) {
                continue
            }
            result.append(expense)
        }
        return result
    }

    var visibleTotal: Double {
        var total = 0.0
        for expense in visible {
            total += expense.amount
        }
        return total
    }

    func total(for category: Category) -> Double {
        var total = 0.0
        for expense in expenses {
            if expense.categoryName == category.rawValue {
                total += expense.amount
            }
        }
        return total
    }

    var peakCategoryTotal: Double {
        var peak = 0.0
        for category in Category.allCases {
            let amount = total(for: category)
            if amount > peak {
                peak = amount
            }
        }
        return peak
    }

    var filterLabel: String {
        filter ?? "All categories"
    }

    func add(title: String, amount: Double, categoryName: String, note: String) {
        expenses.insert(Expense(id: nextID, title: title, amount: amount, categoryName: categoryName, note: note), at: 0)
        nextID += 1
    }

    func remove(id: Int) {
        expenses = expenses.filter { $0.id != id }
    }
}
