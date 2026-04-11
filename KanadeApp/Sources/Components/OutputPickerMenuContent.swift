import SwiftUI
import KanadeKit

struct OutputPickerMenuContent: View {
    @Environment(AppState.self) private var appState

    private var nodes: [Node] {
        appState.client?.state?.nodes ?? []
    }

    var body: some View {
        Section {
            Button {
                if appState.playbackMode == .local {
                    appState.stopLocalPlayback()
                } else {
                    appState.switchToLocal(
                        tracks: appState.effectiveQueue,
                        index: appState.effectiveCurrentIndex ?? 0,
                        positionSecs: appState.effectiveTransportState?.positionSecs
                    )
                }
            } label: {
                Label(
                    localDeviceName,
                    systemImage: appState.playbackMode == .local ? "headphones" : "headphones"
                )
            }
        }

        if !nodes.isEmpty {
            Section("Speakers") {
                ForEach(nodes) { node in
                    Button {
                        appState.switchToRemote(nodeId: node.id)
                    } label: {
                        HStack {
                            Text(node.name)
                            Spacer()
                            Circle()
                                .fill(node.connected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .disabled(!node.connected)
                }
            }
        }
    }

    private var localDeviceName: String {
#if os(iOS)
        UIDevice.current.name
#else
        Host.current().localizedName ?? "This Mac"
#endif
    }
}
