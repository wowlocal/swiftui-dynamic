import SwiftUI

// Distilled from IceCubes StatusesListView row-separator alignment. SwiftUI
// supplies ViewDimensions to the closure; the bridge must preserve the view
// and make the native dimensions readable by interpreted closure code.
struct ContentView: View {
    var body: some View {
        VStack {
            Text("leading guide")
                .alignmentGuide(.leading) { dimensions in
                    dimensions[.leading]
                }
            Text("constant guide")
                .alignmentGuide(.trailing) { _ in
                    12
                }
        }
    }
}
