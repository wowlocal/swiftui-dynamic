import SwiftUI

struct ContentView: View {
    @StateObject var store = ExpenseStore()
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 12) {
                    Text("Expenses")
                        .font(.title2)
                        .bold()
                        .padding(.top, 12)
                    SummaryCard(store: store)
                    CategoryChips(store: store)
                    TextField("Search expenses", text: $store.search)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                    List {
                        ForEach(store.visible) { expense in
                            NavigationLink(destination: ExpenseDetailView(store: store, expense: expense), label: {
                                ExpenseRow(expense: expense)
                            })
                        }
                    }
                    .listStyle(.plain)
                    Button {
                        showAdd = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add expense")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 12)
                }
                if showAdd {
                    AddExpenseView(store: store, isPresented: $showAdd)
                }
            }
        }
    }
}

struct AddExpenseView: View {
    @ObservedObject var store: ExpenseStore
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var amountText = ""
    @State private var note = ""
    @State private var categoryName = "Food"

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }
            VStack(spacing: 12) {
                Text("New expense")
                    .font(.headline)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                TextField("Amount", text: $amountText)
                    .textFieldStyle(.roundedBorder)
                TextField("Note", text: $note)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    ForEach(0..<4) { index in
                        pickerChip(index)
                    }
                }
                HStack {
                    Button("Cancel") {
                        isPresented = false
                    }
                    Spacer()
                    Button("Save") {
                        let amount = Double(amountText) ?? 0
                        if !title.isEmpty && amount > 0 {
                            store.add(title: title, amount: amount, categoryName: categoryName, note: note)
                            isPresented = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty)
                }
            }
            .padding(16)
            .frame(width: 320)
            .background(Color.white)
            .cornerRadius(16)
            .shadow(radius: 24)
        }
    }

    func pickerChip(_ index: Int) -> some View {
        let category = Category.allCases[index]
        let isActive = categoryName == category.rawValue
        return Button {
            categoryName = category.rawValue
        } label: {
            VStack(spacing: 4) {
                Image(systemName: category.icon)
                Text(category.rawValue)
                    .font(.system(size: 10))
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(isActive ? category.color.opacity(0.25) : Color.gray.opacity(0.12))
            .foregroundColor(.primary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

struct ExpenseDetailView: View {
    @ObservedObject var store: ExpenseStore
    let expense: Expense
    @State private var deleted = false

    var body: some View {
        VStack(spacing: 16) {
            if deleted {
                Image(systemName: "trash")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("Deleted — go back")
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 34))
                    .foregroundColor(.white)
                    .frame(width: 80, height: 80)
                    .background(iconColor)
                    .cornerRadius(40)
                Text(expense.title)
                    .font(.title2)
                    .bold()
                Text("$" + String(format: "%.2f", expense.amount))
                    .font(.system(size: 30, weight: .light))
                Text(expense.categoryName)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(iconColor.opacity(0.2))
                    .cornerRadius(10)
                Text(expense.note)
                    .foregroundColor(.secondary)
                Button("Delete expense") {
                    store.remove(id: expense.id)
                    deleted = true
                }
                .foregroundColor(.red)
                .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var iconName: String {
        Category(rawValue: expense.categoryName)?.icon ?? "questionmark"
    }

    var iconColor: Color {
        Category(rawValue: expense.categoryName)?.color ?? .gray
    }
}
