struct SampleProgram: Identifiable, Hashable {
    let name: String
    let source: String
    var id: String { name }
}

enum SamplePrograms {
    static let all = [counter, todoMVVM, form, weather, staticLayout, list, segments, material]

    /// A real view-model app: ObservableObject store shared by three views.
    static let todoMVVM = SampleProgram(name: "Todo", source: """
    struct Todo {
        var title = ""
        var done = false
    }

    class TodoStore: ObservableObject {
        @Published var todos: [Todo] = [
            Todo(title: "Interpret Swift", done: true),
            Todo(title: "Render SwiftUI", done: true),
            Todo(title: "Run real projects"),
        ]
        @Published var newTitle = ""

        var remaining: Int {
            todos.filter { !$0.done }.count
        }

        func add() {
            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return
            }
            todos.append(Todo(title: trimmed))
            newTitle = ""
        }

        func toggle(at index: Int) {
            guard index < todos.count else {
                return
            }
            let item = todos[index]
            item.done = !item.done
            todos[index] = item
        }

        func remove(at index: Int) {
            guard index < todos.count else {
                return
            }
            todos.remove(at: index)
        }
    }

    struct AddBar: View {
        @ObservedObject var store: TodoStore

        var body: some View {
            HStack {
                TextField("What needs doing?", text: $store.newTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    store.add()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.newTitle.isEmpty)
            }
        }
    }

    struct ContentView: View {
        @StateObject var store = TodoStore()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Todos (MVVM)")
                    .font(.title2)
                    .bold()

                AddBar(store: store)

                VStack(spacing: 6) {
                    ForEach(store.todos.indices) { i in
                        HStack {
                            Button(store.todos[i].done ? "☑" : "☐") {
                                store.toggle(at: i)
                            }
                            .buttonStyle(.plain)
                            Text(store.todos[i].title)
                                .opacity(store.todos[i].done ? 0.4 : 1.0)
                            Spacer()
                            Button("✕") {
                                store.remove(at: i)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                Divider()

                Text("\\(store.remaining) of \\(store.todos.count) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 360)
        }
    }
    """)

    /// Enums with methods, switch in bodies, gradients, shapes, nested views.
    static let weather = SampleProgram(name: "Weather", source: """
    enum Condition: String, CaseIterable {
        case sunny
        case cloudy
        case rainy
        case snowy

        var icon: String {
            switch self {
            case .sunny: return "sun.max.fill"
            case .cloudy: return "cloud.fill"
            case .rainy: return "cloud.rain.fill"
            case .snowy: return "snowflake"
            }
        }
    }

    struct Forecast {
        var day = ""
        var condition: Condition = .sunny
        var high = 0
        var low = 0
    }

    struct ForecastRow: View {
        var forecast = Forecast()

        var body: some View {
            HStack {
                Text(forecast.day)
                    .frame(width: 44, alignment: .leading)
                Image(systemName: forecast.condition.icon)
                Spacer()
                Text("\\(forecast.low)°")
                    .foregroundStyle(.white.opacity(0.7))
                Text("\\(forecast.high)°")
                    .bold()
            }
            .font(.system(size: 14))
        }
    }

    struct ContentView: View {
        @State var selected: Condition = .sunny

        let week = [
            Forecast(day: "Mon", condition: .sunny, high: 28, low: 17),
            Forecast(day: "Tue", condition: .cloudy, high: 24, low: 16),
            Forecast(day: "Wed", condition: .rainy, high: 19, low: 12),
            Forecast(day: "Thu", condition: .snowy, high: 2, low: -3),
        ]

        var body: some View {
            VStack(spacing: 16) {
                Image(systemName: selected.icon)
                    .font(.system(size: 56))
                Text(selected.rawValue.capitalized)
                    .font(.title)
                    .bold()

                HStack(spacing: 8) {
                    ForEach(Condition.allCases, id: \\.self) { condition in
                        Button {
                            selected = condition
                        } label: {
                            Image(systemName: condition.icon)
                        }
                        .buttonStyle(.plain)
                        .opacity(condition == selected ? 1.0 : 0.5)
                    }
                }

                Divider()

                VStack(spacing: 6) {
                    ForEach(week, id: \\.day) { forecast in
                        ForecastRow(forecast: forecast)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
            .cornerRadius(20)
            .shadow(radius: 12, y: 6)
            .frame(maxWidth: 320)
        }
    }
    """)

    /// The acceptance demo: @State + Button actions with live re-render.
    static let counter = SampleProgram(name: "Counter", source: """
    struct ContentView: View {
        @State var count = 0

        var body: some View {
            VStack(spacing: 16) {
                Text("Count: \\(count)")
                    .font(.largeTitle)
                HStack(spacing: 12) {
                    Button("-") {
                        count -= 1
                    }
                    Button("+") {
                        count += 1
                    }
                }
                if count >= 10 {
                    Text("That's a lot of taps.")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }
    """)

    /// Two-way bindings: $state projections driving Toggle/Slider/TextField.
    static let form = SampleProgram(name: "Form", source: """
    struct ContentView: View {
        @State var name = ""
        @State var notify = true
        @State var volume = 5

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.headline)
                TextField("Your name", text: $name)
                Toggle("Notifications", isOn: $notify)
                HStack {
                    Text("Volume: \\(volume)")
                    Slider(value: $volume, in: 0...10)
                }
                Divider()
                Text("Hi \\(name)! Notifications \\(notify ? "on" : "off"), volume \\(volume).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 340)
        }
    }
    """)

    static let staticLayout = SampleProgram(name: "Layout", source: """
    struct ContentView: View {
        let tags = ["COBOL", "UNIVAC", "Compilers"]

        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Grace Hopper")
                    .font(.title)
                    .bold()
                Text("Rear admiral, computer scientist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 8) {
                    ForEach(tags, id: \\.self) { tag in
                        Text(tag)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(8)
                    }
                }
                .font(.caption)
            }
            .padding(24)
            .frame(maxWidth: 320)
        }
    }
    """)

    /// Real-world code from the sample-projects corpus: Kavsoft's
    /// AnimatedSegmentedControl — a generic view with a @ViewBuilder closure
    /// property, GeometryReader indicator math, and completion-chained
    /// withAnimation. Adapted for the bridge: the preference-based initial
    /// indicator offset is dropped (the indicator starts on the first tab
    /// anyway) and the iOS-only `.toolbarBackground(for: .navigationBar)`
    /// is removed.
    static let segments = SampleProgram(name: "Segments", source: #"""
    enum SegmentedTab: String, CaseIterable {
        case home = "house.fill"
        case favourites = "suit.heart.fill"
        case notifications = "bell.fill"
        case profile = "person.fill"
    }

    struct SegmentedControl<Indicator: View>: View {
        var tabs: [SegmentedTab]
        @Binding var activeTab: SegmentedTab
        var height: CGFloat = 45
        /// Customization Properties
        var displayAsText: Bool = false
        var font: Font = .title3
        var activeTint: Color
        var inActiveTint: Color
        /// Indicator View
        @ViewBuilder var indicatorView: (CGSize) -> Indicator
        /// View Properties
        @State private var excessTabWidth: CGFloat = .zero
        @State private var minX: CGFloat = .zero
        var body: some View {
            GeometryReader {
                let size = $0.size
                let containerWidthForEachTab = size.width / CGFloat(tabs.count)

                HStack(spacing: 0) {
                    ForEach(tabs, id: \.rawValue) { tab in
                        Group {
                            if displayAsText {
                                Text(tab.rawValue)
                            } else {
                                Image(systemName: tab.rawValue)
                            }
                        }
                        .font(font)
                        .foregroundStyle(activeTab == tab ? activeTint : inActiveTint)
                        .animation(.snappy, value: activeTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                        .onTapGesture {
                            if let index = tabs.firstIndex(of: tab), let activeIndex = tabs.firstIndex(of: activeTab) {
                                activeTab = tab

                                withAnimation(.snappy(duration: 0.25, extraBounce: 0), completionCriteria: .logicallyComplete) {
                                    excessTabWidth = containerWidthForEachTab * CGFloat(index - activeIndex)
                                } completion: {
                                    withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                                        minX = containerWidthForEachTab * CGFloat(index)
                                        excessTabWidth = 0
                                    }
                                }
                            }
                        }
                        .background(alignment: .leading) {
                            if tabs.first == tab {
                                GeometryReader {
                                    let size = $0.size

                                    indicatorView(size)
                                        .frame(width: size.width + (excessTabWidth < 0 ? -excessTabWidth : excessTabWidth), height: size.height)
                                        .frame(width: size.width, alignment: excessTabWidth < 0 ? .trailing : .leading)
                                        .offset(x: minX)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: height)
        }
    }

    struct ContentView: View {
        /// View Properties
        @State private var activeTab: SegmentedTab = .home
        @State private var type2: Bool = false
        var body: some View {
            NavigationStack {
                VStack(spacing: 15) {
                    SegmentedControl(
                        tabs: SegmentedTab.allCases,
                        activeTab: $activeTab,
                        height: 35,
                        font: .body,
                        activeTint: type2 ? .white : .primary,
                        inActiveTint: .gray.opacity(0.5)
                    ) { size in
                        RoundedRectangle(cornerRadius: type2 ? 30 : 0)
                            .fill(.blue)
                            .frame(height: type2 ? size.height : 4)
                            .padding(.horizontal, type2 ? 0 : 10)
                            .offset(y: type2 ? 0 : 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.top, type2 ? 0 : 10)
                    .background {
                        RoundedRectangle(cornerRadius: type2 ? 30 : 0)
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                    }
                    .padding(.horizontal, type2 ? 15 : 0)

                    Toggle("Segmented Control Type - 2", isOn: $type2)
                        .padding(10)
                        .background(.regularMaterial, in: .rect(cornerRadius: 10))
                        .padding(15)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, type2 ? 15 : 0)
                .animation(.snappy, value: type2)
                .navigationTitle("Segmented Control")
            }
        }
    }
    """#)

    /// Real-world code from the sample-projects corpus: Kavsoft's MaterialTF —
    /// a floating-label material text field whose ObservableObject manager
    /// drives the character counter. Verbatim except for headers/previews.
    static let material = SampleProgram(name: "Material", source: #"""
    struct ContentView: View {
        var body: some View {

            NavigationView{

                Home()
                    .navigationTitle("Material Design")
            }
        }
    }

    struct Home: View {

        @StateObject var manager = TFManager()
        // Animation Properites...
        @State var isTapped = false

        var body: some View{

            VStack{

                VStack(alignment: .leading, spacing: 4, content: {

                    HStack(spacing: 15){

                        // were going to limit the textfiled length....

                        TextField("", text: $manager.text) { (status) in
                            // it will fire when textfield is clicked...
                            if status{
                                withAnimation(.easeIn){
                                    // moving hint to top..
                                    isTapped = true
                                }
                            }
                        } onCommit: {
                            // it will fire when return button is pressed...
                            // only if no text typed..
                            if manager.text == ""{
                                withAnimation(.easeOut){
                                    isTapped = false
                                }
                            }
                        }

                        // Trailing Icon Or Button...

                        Button(action: {}, label: {
                            Image(systemName: "suit.heart")
                                .foregroundColor(.gray)
                        })
                    }
                    // if tapped...
                    .padding(.top,isTapped ? 15 : 0)
                    // overlay will avoid clicking the textfiled...
                    // so moving it below the textfield..
                    .background(

                        Text("UserName")
                            .scaleEffect(isTapped ? 0.8 : 1)
                            .offset(x: isTapped ? -7 : 0, y: isTapped ? -15 : 0)
                            .foregroundColor(isTapped ? .accentColor : .gray)


                        ,alignment: .leading
                    )
                    .padding(.horizontal)

                    // Divider Color...
                    Rectangle()
                        .fill(isTapped ? Color.accentColor : Color.gray)
                        .opacity(isTapped ? 1 : 0.5)
                        .frame(height: 1)
                        .padding(.top,10)
                })
                .padding(.top,12)
                .background(Color.gray.opacity(0.09))
                .cornerRadius(5)

                // Displaying Count...
                HStack{

                    Spacer()

                    Text("\(manager.text.count)/15")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.trailing)
                        .padding(.top,4)
                }
            }
            .padding()
        }
    }

    class TFManager: ObservableObject{

        @Published var text = ""{
            // were going to use didSet Function before assigning the new value...
            // so that we can check the count...
            didSet{
                if text.count > 15 && oldValue.count <= 15{
                    text = oldValue
                }
            }
        }
    }
    """#)

    static let list = SampleProgram(name: "List", source: """
    struct Row: View {
        var name = ""
        var index = 0

        var body: some View {
            HStack {
                Image(systemName: "person")
                Text(name)
                Spacer()
                Text("#\\(index)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    struct ContentView: View {
        let names = ["Ada Lovelace", "Grace Hopper", "Katherine Johnson", "Margaret Hamilton"]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pioneers")
                    .font(.headline)
                Divider()
                ForEach(0..<names.count) { i in
                    Row(name: names[i], index: i + 1)
                }
            }
            .padding()
            .frame(maxWidth: 320)
        }
    }
    """)
}
