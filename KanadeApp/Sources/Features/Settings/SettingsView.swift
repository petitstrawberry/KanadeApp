import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let discovery = appState.serverDiscovery

        Form {
            if !discovery.servers.isEmpty || discovery.isBrowsing {
                Section {
                    if discovery.servers.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning...")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        ForEach(discovery.servers) { server in
                            Button {
                                appState.serverAddress = server.host
                                appState.wsPort = server.port
                                if let httpPort = server.httpPort {
                                    appState.httpPort = httpPort
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .font(.headline)
                                        Text("\(server.host):\(server.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if server.persistent {
                                        Image(systemName: "pin.fill")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                    }
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Discovered on Local Network")
                }
            }

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
        .onAppear { discovery.startBrowsing() }
        .onDisappear { discovery.stopBrowsing() }
    }
}
