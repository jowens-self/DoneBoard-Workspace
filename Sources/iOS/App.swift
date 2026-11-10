import SwiftUI

@main
struct DoneBoardApp: App {
    @State private var store = Launch.openBoard()
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(app)
        }
    }
}
