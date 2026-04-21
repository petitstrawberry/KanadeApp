import SwiftUI

@main
struct KanadeApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task {
                    appState.startupConnectIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    guard appState.hasSavedConnectionSettings else { return }
                    if appState.connectionRequiresManualRetry {
                        appState.retryConnection()
                    }
                }
        }
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
        }
        #endif
    }
}
