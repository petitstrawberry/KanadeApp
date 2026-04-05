import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Server Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.isConnected ? Color.green : (appState.isRetryingConnection ? Color.orange : Color.red))
                            .frame(width: 10, height: 10)
                        Text(appState.connectionStatusText)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Server Address", text: $appState.serverAddress)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                TextField("WebSocket Port", value: $appState.wsPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif

                TextField("HTTP Port", value: $appState.httpPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif

                Toggle("Auto-connect on Launch", isOn: $appState.autoConnectOnLaunch)

                Button(appState.isConnected ? "Disconnect" : (appState.hasSavedConnectionSettings ? "Connect / Retry" : "Connect")) {
                    if appState.isConnected {
                        appState.disconnect()
                    } else {
                        appState.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("About") {
                LabeledContent("App") {
                    Text("Kanade")
                }
                LabeledContent("Version") {
                    Text("1.0.0")
                }
            }
        }
        .navigationTitle("Settings")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}
