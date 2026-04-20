import SwiftUI
import KanadeKit

struct NodesView: View {
    @Environment(AppState.self) private var appState

    private var remoteNodes: [Node] { appState.remoteNodes }

    var body: some View {
        List {
            Section {
                Button {
                    if appState.localPlayback != nil {
                        appState.controlTarget = .local
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
                .listRowBackground(isLocalSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            }

            if remoteNodes.isEmpty {
                ContentUnavailableView(
                    "No Remote Nodes",
                    systemImage: "speaker.slash",
                    description: Text("Connect to a server to discover output nodes.")
                )
            } else {
                Section("Remote Nodes") {
                    ForEach(remoteNodes) { node in
                        let isLocalSession = node.nodeType == .local
                        Button {
                            appState.performSelectNode(node.id)
                        } label: {
                            nodeRow(node)
                                .foregroundStyle(isLocalSession ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLocalSession)
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
                .fill(isLocalSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 12, height: 12)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "headphones")
                        .font(.headline)
                        .foregroundStyle(isLocalSelected ? Color.accentColor : .primary)
                    Text(localDeviceName)
                        .font(.headline)
                        .foregroundStyle(isLocalSelected ? Color.accentColor : .primary)
                    if isLocalSelected {
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
                        title: localNode.map { playbackStatusText($0.status) } ?? (appState.localPlayback != nil ? "Starting" : "Idle"),
                        tint: localNode.map { playbackStatusColor($0.status) } ?? (isLocalSelected ? .accentColor : .secondary)
                    )
                    if let track = localCurrentTrack {
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
        let currentTrack = currentTrack(for: node)
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
        appState.controlledNodeId == node.id
    }

    private var isLocalSelected: Bool {
        appState.isControllingLocalNode
    }

    private var localNode: Node? {
        guard let localNodeId = appState.localNodeId else { return nil }
        return appState.client?.state?.nodes.first(where: { $0.id == localNodeId })
    }

    private var localCurrentTrack: Track? {
        if isLocalSelected {
            return appState.effectiveCurrentTrack
        }
        guard let localNode else { return nil }
        return currentTrack(for: localNode)
    }

    private func currentTrack(for node: Node) -> Track? {
        guard let queue = node.queue,
              let currentIndex = node.currentIndex,
              queue.indices.contains(currentIndex) else {
            return nil
        }

        return queue[currentIndex]
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
