import SwiftUI
import KanadeKit

struct OutputPickerMenuContent: View {
    @Environment(AppState.self) private var appState

    private var nodes: [Node] {
        appState.client?.state?.nodes ?? []
    }

    private var remoteNodes: [Node] {
        nodes.filter { $0.id != appState.localNodeId }
    }

    private var localNode: Node? {
        guard let localNodeId = appState.localNodeId else { return nil }
        return nodes.first(where: { $0.id == localNodeId })
    }

    private var isLocalPlaybackActive: Bool {
        appState.localPlayback != nil
    }

    private var isControllingLocal: Bool {
        appState.controlledNodeId == appState.localNodeId && appState.localNodeId != nil
    }

    var body: some View {
        Section {
            Button {
                if isLocalPlaybackActive {
                    if let localNodeId = appState.localNodeId {
                        appState.controlledNodeId = localNodeId
                    }
                } else {
                    appState.switchToLocal(
                        tracks: appState.effectiveQueue,
                        index: appState.effectiveCurrentIndex ?? 0,
                        positionSecs: appState.effectiveTransportState?.positionSecs
                    )
                }
            } label: {
                HStack {
                    Label(localDeviceName, systemImage: "headphones")
                    Spacer()
                    if let localNode {
                        Text(localStatusText(localNode.status))
                            .foregroundStyle(localStatusColor(localNode.status))
                    } else if isLocalPlaybackActive {
                        Text("Starting")
                            .foregroundStyle(.orange)
                    }
                    if isControllingLocal {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }

        if !remoteNodes.isEmpty {
            Section("Speakers") {
                ForEach(remoteNodes) { node in
                    Button {
                        appState.switchToRemote(nodeId: node.id)
                    } label: {
                        HStack {
                            Text(node.name)
                            Spacer()
                            Circle()
                                .fill(node.connected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            if appState.controlledNodeId == node.id {
                                Image(systemName: "checkmark")
                            }
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

    private func localStatusText(_ status: PlaybackStatus) -> String {
        switch status {
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .loading:
            return "Loading"
        case .stopped:
            return "Stopped"
        }
    }

    private func localStatusColor(_ status: PlaybackStatus) -> Color {
        switch status {
        case .playing:
            return .green
        case .paused:
            return .orange
        case .loading:
            return .blue
        case .stopped:
            return .secondary
        }
    }
}
