import SwiftUI
import KanadeKit

struct QueueView: View {
    @Environment(AppState.self) private var appState

    private var client: KanadeClient? { appState.client }
    private var queue: [Track] { client?.state?.queue ?? [] }
    private var currentIndex: Int? { appState.effectiveCurrentIndex }

    var body: some View {
        List {
            if queue.isEmpty {
                ContentUnavailableView(
                    "Queue is Empty",
                    systemImage: "music.note.list",
                    description: Text("Add tracks to start building your listening queue.")
                )
            } else {
                Section {
                    Button(role: .destructive) {
                        appState.performClearQueue()
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, track in
                        queueRow(track: track, index: index)
                    }
                    .onMove(perform: moveTracks)
                }
            }
        }
        .navigationTitle("Queue")
        #if os(iOS)
        .toolbar {
            if !queue.isEmpty {
                EditButton()
            }
        }
        #endif
    }

    @ViewBuilder
    private func queueRow(track: Track, index: Int) -> some View {
        let isPlaying = isCurrentTrack(index)

        HStack(spacing: 12) {
            Button {
                appState.performPlayIndex(index)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isPlaying ? Color.accentColor : Color.secondary.opacity(0.12))
                            .frame(width: 34, height: 34)

                        Text("\(index + 1)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isPlaying ? Color.white : Color.primary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title ?? "Untitled")
                            .font(.headline)
                            .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                        Text((track.artist ?? "").isEmpty ? "Unknown Artist" : (track.artist ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(formatDuration(track.durationSecs ?? 0))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            QueueTrackControls(index: index, queueCount: queue.count)
        }
        .listRowBackground(isCurrentTrack(index) ? Color.accentColor.opacity(0.14) : Color.clear)
        .contextMenu {
            queueActions(for: index)
        }
        #if os(iOS)
        .swipeActions {
            queueActions(for: index)
        }
        #endif
    }

    @ViewBuilder
    private func queueActions(for index: Int) -> some View {
        Button {
            playNext(index)
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button(role: .destructive) {
            appState.performRemoveFromQueue(index)
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func isCurrentTrack(_ index: Int) -> Bool {
        currentIndex == index
    }

    private func moveTracks(from offsets: IndexSet, to destination: Int) {
        guard let source = offsets.first, source != destination else { return }
        appState.performMoveInQueue(from: source, to: destination)
    }

    private func playNext(_ index: Int) {
        let target = min((currentIndex ?? -1) + 1, queue.count)
        let adjustedTarget = index < target ? max(0, target - 1) : target
        guard index != adjustedTarget else { return }
        appState.performMoveInQueue(from: index, to: adjustedTarget)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let minutes = total / 60
        let remainingSeconds = total % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct QueueTrackControls: View {
    let index: Int
    let queueCount: Int

    @Environment(AppState.self) private var appState

    @State private var isHovered = false

    var body: some View {
        Group {
            if isHovered {
                HStack(spacing: 4) {
                    Button {
                        appState.performMoveInQueue(from: index, to: index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)

                    Button {
                        appState.performMoveInQueue(from: index, to: index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .disabled(index >= queueCount - 1)

                    Button {
                        appState.performRemoveFromQueue(index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}
