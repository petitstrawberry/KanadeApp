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
            if nodes.isEmpty {
                ContentUnavailableView(
                    "No Nodes Available",
                    systemImage: "speaker.slash",
                    description: Text("Connect to a server to discover output nodes and rooms.")
                )
            } else {
                ForEach(nodes) { node in
                    Button {
                        appState.performSelectNode(node.id)
                    } label: {
                        nodeRow(node)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isSelected(node) ? Color.accentColor.opacity(0.14) : Color.clear)
                }
            }
        }
        .navigationTitle("Nodes")
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
