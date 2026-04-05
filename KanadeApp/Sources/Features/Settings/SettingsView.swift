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
                            .fill(appState.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Server Address") {
                    TextField("127.0.0.1", text: $appState.serverAddress)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }

                LabeledContent("WebSocket Port") {
                    TextField("8080", value: $appState.wsPort, format: .number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                LabeledContent("HTTP Port") {
                    TextField("8081", value: $appState.httpPort, format: .number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                Button(appState.isConnected ? "Disconnect" : "Connect") {
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
