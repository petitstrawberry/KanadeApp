import SwiftUI
import KanadeKit

struct NodesView: View {
    @Environment(AppState.self) private var appState

    private var client: KanadeClient? { appState.client }
    private var nodes: [Node] { client?.state?.nodes ?? [] }
    private var selectedNodeId: String? { client?.state?.selectedNodeId }
    private var currentTrack: Track? {
        guard let state = client?.state,
              let currentIndex = state.currentIndex,
              state.queue.indices.contains(currentIndex) else {
            return nil
        }

        return state.queue[currentIndex]
    }

    var body: some View {
        List {
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
                    localDeviceRow
                }
                .buttonStyle(.plain)
                .listRowBackground(appState.playbackMode == .local ? Color.accentColor.opacity(0.14) : Color.clear)
            }

            if nodes.isEmpty {
                ContentUnavailableView(
                    "No Remote Nodes",
                    systemImage: "speaker.slash",
                    description: Text("Connect to a server to discover output nodes.")
                )
            } else {
                Section("Remote Nodes") {
                    ForEach(nodes) { node in
                        Button {
                            if appState.playbackMode == .local {
                                appState.switchToRemote(nodeId: node.id)
                            } else {
                                appState.performSelectNode(node.id)
                            }
                        } label: {
                            nodeRow(node)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isSelected(node) ? Color.accentColor.opacity(0.14) : Color.clear)
                        .contextMenu {
                            Button {
                                appState.switchToRemote(nodeId: node.id)
                            } label: {
                                Label("Transfer Playback Here", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Output")
    }

    @ViewBuilder
    private var localDeviceRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(appState.playbackMode == .local ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 12, height: 12)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "headphones")
                        .font(.headline)
                        .foregroundStyle(appState.playbackMode == .local ? Color.accentColor : .primary)
                    Text(localDeviceName)
                        .font(.headline)
                        .foregroundStyle(appState.playbackMode == .local ? Color.accentColor : .primary)
                    if appState.playbackMode == .local {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    statusBadge(
                        title: appState.playbackMode == .local ? "Local" : "Idle",
                        tint: appState.playbackMode == .local ? .accentColor : .secondary
                    )
                    if appState.playbackMode == .local, let track = appState.localCurrentTrack {
                        Text(track.title ?? "Untitled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var localDeviceName: String {
#if os(iOS)
        UIDevice.current.name
#else
        Host.current().localizedName ?? "This Mac"
#endif
    }

    @ViewBuilder
    private func nodeRow(_ node: Node) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(node.connected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(node.name)
                        .font(.headline)
                        .foregroundStyle(isSelected(node) ? Color.accentColor : Color.primary)
                    if isSelected(node) {
                        Label("Selected", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                HStack(spacing: 10) {
                    statusBadge(title: node.connected ? "Connected" : "Disconnected", tint: node.connected ? .green : .red)
                    statusBadge(title: playbackStatusText(node.status), tint: playbackStatusColor(node.status))
                }

                if let currentTrack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentTrack.title ?? "Untitled")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text((currentTrack.artist ?? "").isEmpty ? "Unknown Artist" : (currentTrack.artist ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 14) {
                    Label(formatTime(node.positionSecs), systemImage: "clock")
                    Label("\(node.volume)%", systemImage: "speaker.wave.2")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func isSelected(_ node: Node) -> Bool {
        selectedNodeId == node.id
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func playbackStatusText(_ status: PlaybackStatus?) -> String {
        switch status {
        case .stopped:
            return "Stopped"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .loading:
            return "Loading"
        case nil:
            return "Unknown"
        }
    }

    private func playbackStatusColor(_ status: PlaybackStatus?) -> Color {
        switch status {
        case .playing:
            return .green
        case .paused:
            return .orange
        case .loading:
            return .blue
        case .stopped:
            return .secondary
        case nil:
            return .secondary
        }
    }

    @ViewBuilder
    private func statusBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
