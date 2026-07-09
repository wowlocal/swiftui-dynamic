import SwiftUI

/// Total for the current filter plus a per-category mini bar chart.
struct SummaryCard: View {
    @ObservedObject var store: ExpenseStore

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spent")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("$" + String(format: "%.2f", store.visibleTotal))
                    .font(.system(size: 30, weight: .bold))
                Text(store.filterLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<4) { index in
                    bar(index)
                }
            }
        }
        .padding(16)
        .background(Color.gray.opacity(0.12))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    func bar(_ index: Int) -> some View {
        let category = Category.allCases[index]
        let amount = store.total(for: category)
        let peak = store.peakCategoryTotal
        let height = peak > 0 ? 10 + 50 * amount / peak : 10
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(category.color)
                .frame(width: 22, height: height)
            Image(systemName: category.icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

/// "All" plus one chip per category; tapping filters the list.
struct CategoryChips: View {
    @ObservedObject var store: ExpenseStore

    var body: some View {
        HStack(spacing: 8) {
            chip(name: nil, label: "All", color: .primary)
            ForEach(0..<4) { index in
                categoryChip(index)
            }
        }
        .padding(.horizontal)
    }

    func categoryChip(_ index: Int) -> some View {
        let category = Category.allCases[index]
        return chip(name: category.rawValue, label: category.rawValue, color: category.color)
    }

    func chip(name: String?, label: String, color: Color) -> some View {
        let isActive = store.filter == name
        return Button {
            store.filter = name
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive ? color.opacity(0.25) : Color.gray.opacity(0.12))
                .foregroundColor(.primary)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(iconColor)
                .cornerRadius(17)
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title)
                    .font(.system(size: 14, weight: .medium))
                Text(expense.categoryName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("$" + String(format: "%.2f", expense.amount))
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.vertical, 2)
    }

    var iconName: String {
        Category(rawValue: expense.categoryName)?.icon ?? "questionmark"
    }

    var iconColor: Color {
        Category(rawValue: expense.categoryName)?.color ?? .gray
    }
}
