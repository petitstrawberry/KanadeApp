import SwiftUI

@main
struct KanadeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    appState.startupConnectIfNeeded()
                }
        }
    }
}
