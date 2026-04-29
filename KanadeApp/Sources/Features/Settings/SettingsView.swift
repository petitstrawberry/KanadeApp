import AcknowList
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    private enum ImportTarget {
        case clientCertificate
        case trustedCA
    }

    @State private var showImporter = false
    @State private var importTarget: ImportTarget = .clientCertificate
    @State private var passwordInput = ""

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

                LabeledContent("Port") {
                    TextField("8080", value: $appState.serverPort, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                #else
                TextField("Server Address", text: $appState.serverAddress)
                    .multilineTextAlignment(.trailing)

                TextField("Port", value: $appState.serverPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                #endif

                Toggle("Auto-connect on Launch", isOn: $appState.autoConnectOnLaunch)

                Button(appState.isConnected ? "Disconnect" : (appState.hasSavedConnectionSettings ? "Connect / Retry" : "Connect")) {
                    if appState.isConnected {
                        appState.disconnect()
                    } else {
                        if !passwordInput.isEmpty {
                            appState.clientCertificatePassword = passwordInput
                        }
                        appState.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("TLS / mTLS") {
                Toggle("Use TLS (wss://)", isOn: $appState.useTLS)

                if appState.useTLS {
                    Toggle("Allow Self-Signed Server Certificate", isOn: $appState.allowSelfSignedServer)

                    LabeledContent("Client Certificate") {
                        HStack(spacing: 8) {
                            if appState.hasClientCertificate {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Button("Remove") {
                                    appState.removeClientCertificate()
                                }
                                .foregroundStyle(.red)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            Button("Import .p12") {
                                importTarget = .clientCertificate
                                showImporter = true
                            }
                        }
                    }

                    if appState.hasClientCertificate {
                        #if os(iOS)
                        LabeledContent("Password") {
                            SecureField("Required", text: $passwordInput)
                                .multilineTextAlignment(.trailing)
                        }
                        #else
                        SecureField("Certificate Password", text: $passwordInput)
                            .multilineTextAlignment(.trailing)
                        #endif
                    }

                    LabeledContent("Trusted CA") {
                        HStack(spacing: 8) {
                            if appState.trustedCAData != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Button("Remove") {
                                    appState.trustedCAData = nil
                                }
                                .foregroundStyle(.red)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            Button("Import .pem") {
                                importTarget = .trustedCA
                                showImporter = true
                            }
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("App") {
                    Text("Kanade")
                }
                LabeledContent("Version") {
                    Text("1.0.0")
                }
                NavigationLink("Acknowledgements") {
                    AcknowListSwiftUIView()
                }
            }
        }
        .navigationTitle("Settings")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard let urls = try? result.get(), let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { return }
            switch importTarget {
            case .clientCertificate:
                appState.importClientCertificate(data: data)
            case .trustedCA:
                appState.trustedCAData = data
            }
        }
    }
}

