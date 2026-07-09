struct SampleProgram: Identifiable, Hashable {
    let name: String
    let source: String
    var id: String { name }
}

enum SamplePrograms {
    static let all = [counter, calculator, tictactoe, todoMVVM, form, weather, staticLayout, list, segments, material, popup, albums]

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

    /// Real-world code from the sample-projects corpus: Kavsoft's
    /// PopUpNavigation — a custom popup built with an `.overlay` extension on
    /// View, hosting a NavigationView with pushable links over a dimmed
    /// backdrop. Adapted for the bridge: the iOS-only keyboard toolbar and
    /// `navigationBarTitleDisplayMode` are dropped; the toolbar Close button
    /// moved below the list.
    static let popup = SampleProgram(name: "Popup", source: #"""
    // MARK: Task Model
    struct Task: Identifiable{
        var id = UUID().uuidString
        var taskTitle: String
        var taskDescription: String
    }

    // MARK: Sample Tasks
    var tasks: [Task] = [

        Task(taskTitle: "Meeting", taskDescription: "Discuss team task for the day"),
        Task(taskTitle: "Icon set", taskDescription: "Edit icons for team task for next week"),
        Task(taskTitle: "Prototype", taskDescription: "Make and send prototype"),
        Task(taskTitle: "Check asset", taskDescription: "Start checking the assets"),
        Task(taskTitle: "Team party", taskDescription: "Make fun with team mates"),
        Task(taskTitle: "Client Meeting", taskDescription: "Explain project to clinet"),

        Task(taskTitle: "Next Project", taskDescription: "Discuss next project with team"),
        Task(taskTitle: "App Proposal", taskDescription: "Meet client for next App Proposal"),
    ]

    // MARK: Custom View Property Extensions
    extension View{

        // MARK: Building a Custom Modifier for Custom Popup navigation View
        func popupNavigationView<Content: View>(horizontalPadding: CGFloat = 40,show: Binding<Bool>,@ViewBuilder content: @escaping ()->Content)->some View{

            return self
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay {

                    if show.wrappedValue{

                        // MARK: Geometry Reader for reading Container Frame
                        GeometryReader{proxy in

                            Color.primary
                                .opacity(0.15)
                                .ignoresSafeArea()

                            let size = proxy.size

                            NavigationView{
                                content()
                            }
                            .frame(width: size.width - horizontalPadding, height: size.height / 1.7, alignment: .center)
                            // Corner Radius
                            .cornerRadius(15)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        }
                    }
                }
        }
    }

    struct Home: View {
        @State var showPopup: Bool = false
        var body: some View {

            NavigationView{

                Button("Show Popup"){
                    withAnimation{
                        showPopup.toggle()
                    }
                }
                .navigationTitle("Custom Popup's")
            }
            .popupNavigationView(horizontalPadding: 40, show: $showPopup) {

                // MARK: Your Popup content which will also performs navigations
                VStack(spacing: 0){
                    List{
                        ForEach(tasks){task in
                            NavigationLink(task.taskTitle) {
                                Text(task.taskDescription)
                                    .navigationTitle("Destination")
                            }
                        }
                    }

                    Divider()

                    Button("Close"){
                        withAnimation{showPopup.toggle()}
                    }
                    .padding(.vertical, 10)
                }
                .navigationTitle("Popup Navigation")
            }
        }
    }
    """#)

    /// Real-world code from the sample-projects corpus: Kavsoft's "Filled"
    /// album list — cards scale and fade as they scroll under the header,
    /// driven by nested GeometryReaders. Adapted for the bridge: deprecated
    /// `edgesIgnoringSafeArea` modernized to `ignoresSafeArea`, and the
    /// bundled cover art (unavailable here) replaced with a tinted
    /// system-image tile.
    static let albums = SampleProgram(name: "Albums", source: #"""
    struct Home : View {

        var body: some View{

            VStack(spacing: 0){

                HStack{

                    Text("Album Songs")
                        .font(.system(size: 40))
                        .fontWeight(.bold)
                        .foregroundColor(.black)

                    Spacer(minLength: 0)
                }
                .padding()
                // since top edge is ignored....
                .padding(.top,UIApplication.shared.windows.first?.safeAreaInsets.top)
                .background(Color.white.shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 5))
                .zIndex(0)
                // moving view in stack for shadow effect...

                // Scaling Effect....

                GeometryReader{mainView in

                    ScrollView{

                        VStack(spacing: 15){

                            // setting name as id...

                            ForEach(albums,id: \.album_name){album in

                                // Album View....

                                GeometryReader{item in

                                    AlbumView(album: album)
                                        // scaling effect from bottom....
                                        .scaleEffect(scaleValue(mainFrame: mainView.frame(in: .global).minY, minY: item.frame(in: .global).minY),anchor: .bottom)
                                    // adding opacity effect...
                                        .opacity(Double(scaleValue(mainFrame: mainView.frame(in: .global).minY, minY: item.frame(in: .global).minY)))
                                }
                                // setting default frame height...
                                // since each card height is 100...
                                .frame(height: 100)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top,25)
                    }
                    .zIndex(1)
                }
            }
            .background(Color.black.opacity(0.06).ignoresSafeArea())
            .ignoresSafeArea(edges: .top)
        }

        // Simple Calculation for scaling Effect...

        func scaleValue(mainFrame : CGFloat,minY : CGFloat)-> CGFloat{

            // adding animation...

            withAnimation(.easeOut){

                // reducing top padding value...

                let scale = (minY - 25) / mainFrame

                // retuning scaling value to Album View if its less than 1...

                if scale > 1{

                    return 1
                }
                else{

                    return scale
                }
            }
        }
    }

    struct AlbumView : View {

        var album : Album

        var body: some View{

            HStack{

                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
                    .frame(width: 100, height: 100)
                    .background(Color.indigo.opacity(0.75))
                    .cornerRadius(15)

                VStack(alignment: .leading, spacing: 12) {

                    Text(album.album_name)
                        .fontWeight(.bold)

                    Text(album.album_author)
                }
                .padding(.leading,10)

                Spacer(minLength: 0)
            }
            .background(Color.white.shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 4))
            .cornerRadius(15)
        }
    }

    // Sample Data....

    struct Album{

        var album_name : String
        var album_author : String
        var album_cover : String
    }

    var albums = [

        Album(album_name: "Let Her Go", album_author: "Passenger", album_cover: "p1"),
        Album(album_name: "Bad Blood", album_author: "Taylor Swift", album_cover: "p2"),
        Album(album_name: "Believer", album_author: "Kurt Hugo Schneider", album_cover: "p3"),
        Album(album_name: "Let Me Love You", album_author: "DJ Snake", album_cover: "p4"),
        Album(album_name: "Shape Of You", album_author: "Ed Sherran", album_cover: "p5"),
        Album(album_name: "Blank Space", album_author: "Taylor Swift", album_cover: "p6"),
        Album(album_name: "Havana", album_author: "Camila Cabello", album_cover: "p7"),
        Album(album_name: "Red", album_author: "Taylor Swift", album_cover: "p8"),
        Album(album_name: "I Like It", album_author: "J Balvin", album_cover: "p9"),
        Album(album_name: "Lover", album_author: "Taylor Swift", album_cover: "p10"),
        Album(album_name: "7/27 Harmony", album_author: "Camila Cabello", album_cover: "p11"),
        Album(album_name: "Joanne", album_author: "Lady Gaga", album_cover: "p12"),
        Album(album_name: "Roar", album_author: "Kay Perry", album_cover: "p13"),
        Album(album_name: "My Church", album_author: "Maren Morris", album_cover: "p14"),
        Album(album_name: "Part Of Me", album_author: "Katy Perry", album_cover: "p15"),
    ]
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

    /// iOS-style calculator: an immediate-execution state machine (chained
    /// operators, operator replacement, repeat-equals, percent, sign toggle,
    /// divide-by-zero -> Error) — logic-heavy, not just layout.
    static let calculator = SampleProgram(name: "Calculator", source: #"""
    class CalcEngine: ObservableObject {
        @Published var display = "0"
        @Published var activeOp: String? = nil
        var accumulator: Double? = nil
        var pendingOp: String? = nil
        var typing = false
        var lastOp: String? = nil
        var lastOperand: Double? = nil

        func tap(_ key: String) {
            switch key {
            case "AC":
                clear()
            case "±":
                negate()
            case "%":
                percent()
            case "+", "−", "×", "÷":
                operate(key)
            case "=":
                equals()
            case ".":
                dot()
            default:
                digit(key)
            }
        }

        func clear() {
            display = "0"
            accumulator = nil
            pendingOp = nil
            activeOp = nil
            typing = false
            lastOp = nil
            lastOperand = nil
        }

        func digit(_ d: String) {
            if display == "Error" {
                clear()
            }
            if typing {
                if display.count >= 12 {
                    return
                }
                display = display == "0" ? d : display + d
            } else {
                display = d
                typing = true
            }
            activeOp = nil
        }

        func dot() {
            if display == "Error" {
                clear()
            }
            if !typing {
                display = "0."
                typing = true
            } else if !display.contains(".") {
                display = display + "."
            }
            activeOp = nil
        }

        func negate() {
            if display == "Error" || display == "0" {
                return
            }
            if display.hasPrefix("-") {
                display = String(display.dropFirst())
            } else {
                display = "-" + display
            }
        }

        func percent() {
            if display == "Error" {
                return
            }
            display = format(value() / 100)
            typing = false
        }

        func operate(_ op: String) {
            if display == "Error" {
                return
            }
            if !typing && pendingOp != nil {
                pendingOp = op
                activeOp = op
                return
            }
            commit()
            pendingOp = op
            activeOp = op
            typing = false
        }

        func equals() {
            if display == "Error" {
                return
            }
            if let op = pendingOp {
                lastOp = op
                lastOperand = value()
                commit()
                pendingOp = nil
                activeOp = nil
                typing = false
            } else if let op = lastOp, let operand = lastOperand {
                apply(op, value(), operand)
                typing = false
            }
        }

        func commit() {
            let current = value()
            if let a = accumulator, let op = pendingOp {
                apply(op, a, current)
            } else {
                accumulator = current
            }
        }

        func apply(_ op: String, _ a: Double, _ b: Double) {
            if op == "÷" && b == 0 {
                display = "Error"
                accumulator = nil
                pendingOp = nil
                activeOp = nil
                typing = false
                return
            }
            var result = 0.0
            switch op {
            case "+":
                result = a + b
            case "−":
                result = a - b
            case "×":
                result = a * b
            default:
                result = a / b
            }
            accumulator = result
            display = format(result)
        }

        /// Current display as a number; tolerates a trailing "." while typing.
        func value() -> Double {
            Double(display) ?? (Double(display + "0") ?? 0)
        }

        func format(_ number: Double) -> String {
            String(format: "%.10g", number)
        }
    }

    struct CalcKey: View {
        var label: String
        var background: Color
        var foreground = Color.white
        var wide = false
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: wide ? 148 : 68, height: 68)
                    .background(background)
                    .foregroundColor(foreground)
                    .cornerRadius(34)
            }
            .buttonStyle(.plain)
        }
    }

    struct ContentView: View {
        @StateObject var engine = CalcEngine()

        let dark = Color.gray.opacity(0.4)
        let light = Color.gray

        var body: some View {
            VStack(spacing: 12) {
                Text(engine.display)
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 8)
                HStack(spacing: 12) {
                    CalcKey(label: "AC", background: light, foreground: .black) { engine.tap("AC") }
                    CalcKey(label: "±", background: light, foreground: .black) { engine.tap("±") }
                    CalcKey(label: "%", background: light, foreground: .black) { engine.tap("%") }
                    opKey("÷")
                }
                HStack(spacing: 12) {
                    digitKey("7")
                    digitKey("8")
                    digitKey("9")
                    opKey("×")
                }
                HStack(spacing: 12) {
                    digitKey("4")
                    digitKey("5")
                    digitKey("6")
                    opKey("−")
                }
                HStack(spacing: 12) {
                    digitKey("1")
                    digitKey("2")
                    digitKey("3")
                    opKey("+")
                }
                HStack(spacing: 12) {
                    CalcKey(label: "0", background: dark, wide: true) { engine.tap("0") }
                    digitKey(".")
                    opKey("=")
                }
            }
            .padding(20)
            .background(Color.black)
            .cornerRadius(32)
        }

        func digitKey(_ d: String) -> some View {
            CalcKey(label: d, background: dark) { engine.tap(d) }
        }

        func opKey(_ op: String) -> some View {
            CalcKey(
                label: op,
                background: engine.activeOp == op ? Color.white : Color.orange,
                foreground: engine.activeOp == op ? Color.orange : Color.white
            ) { engine.tap(op) }
        }
    }
    """#)

    /// Tic-tac-toe against a rule-based AI (take the win, block the threat,
    /// center, corners, sides) with win/draw detection and line highlighting.
    static let tictactoe = SampleProgram(name: "Tic-Tac-Toe", source: #"""
    class TicTacToe: ObservableObject {
        @Published var board = ["", "", "", "", "", "", "", "", ""]
        @Published var status = "Your move — you are X"
        @Published var winningLine: [Int] = []
        var gameOver = false

        let lines = [
            [0, 1, 2], [3, 4, 5], [6, 7, 8],
            [0, 3, 6], [1, 4, 7], [2, 5, 8],
            [0, 4, 8], [2, 4, 6],
        ]

        func tap(_ index: Int) {
            if gameOver || !board[index].isEmpty {
                return
            }
            board[index] = "X"
            if settle() {
                return
            }
            aiMove()
            _ = settle()
        }

        func aiMove() {
            let move = bestMove()
            if move >= 0 {
                board[move] = "O"
            }
        }

        func bestMove() -> Int {
            if let winning = completingMove(for: "O") {
                return winning
            }
            if let block = completingMove(for: "X") {
                return block
            }
            if board[4].isEmpty {
                return 4
            }
            for corner in [0, 2, 6, 8] {
                if board[corner].isEmpty {
                    return corner
                }
            }
            for index in 0..<9 {
                if board[index].isEmpty {
                    return index
                }
            }
            return -1
        }

        func completingMove(for player: String) -> Int? {
            for line in lines {
                var owned = 0
                var empty = -1
                for index in line {
                    if board[index] == player {
                        owned += 1
                    }
                    if board[index].isEmpty {
                        empty = index
                    }
                }
                if owned == 2 && empty >= 0 {
                    return empty
                }
            }
            return nil
        }

        func settle() -> Bool {
            for line in lines {
                let mark = board[line[0]]
                if !mark.isEmpty && mark == board[line[1]] && mark == board[line[2]] {
                    winningLine = line
                    status = mark == "X" ? "You win!" : "The machine wins"
                    gameOver = true
                    return true
                }
            }
            if !board.contains("") {
                status = "Draw"
                gameOver = true
                return true
            }
            return false
        }

        func reset() {
            board = ["", "", "", "", "", "", "", "", ""]
            status = "Your move — you are X"
            winningLine = []
            gameOver = false
        }
    }

    struct ContentView: View {
        @StateObject var game = TicTacToe()

        var body: some View {
            VStack(spacing: 16) {
                Text("Tic-Tac-Toe")
                    .font(.title2)
                    .bold()
                Text(game.status)
                    .foregroundColor(.secondary)
                VStack(spacing: 8) {
                    ForEach(0..<3) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3) { column in
                                cell(row * 3 + column)
                            }
                        }
                    }
                }
                Button("New game") {
                    game.reset()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }

        func cell(_ index: Int) -> some View {
            Button {
                game.tap(index)
            } label: {
                Text(game.board[index])
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 72, height: 72)
                    .background(game.winningLine.contains(index) ? Color.green.opacity(0.35) : Color.gray.opacity(0.15))
                    .foregroundColor(game.board[index] == "X" ? .blue : .red)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }
    """#)
}
