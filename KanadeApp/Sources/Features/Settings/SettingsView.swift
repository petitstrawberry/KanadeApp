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

                #if os(iOS)
                LabeledContent("Server Address") {
                    TextField("127.0.0.1", text: $appState.serverAddress)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                LabeledContent("WebSocket Port") {
                    TextField("8080", value: $appState.wsPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }

                LabeledContent("HTTP Port") {
                    TextField("8081", value: $appState.httpPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                #else
                TextField("Server Address", text: $appState.serverAddress)
                    .multilineTextAlignment(.trailing)

                TextField("WebSocket Port", value: $appState.wsPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)

                TextField("HTTP Port", value: $appState.httpPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
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

            Section("Playback Node") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.isNodeConnected ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(appState.isNodeConnected ? "Connected" : "Disconnected")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Act as Playback Node", isOn: $appState.nodeEnabled)

                #if os(iOS)
                LabeledContent("Node Name") {
                    TextField("Living Room", text: $appState.nodeName)
                        .multilineTextAlignment(.trailing)
                }
                #else
                TextField("Node Name", text: $appState.nodeName)
                    .multilineTextAlignment(.trailing)
                #endif
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
