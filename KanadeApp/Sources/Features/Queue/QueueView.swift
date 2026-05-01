import SwiftUI
import KanadeKit

struct QueueView: View {
    @Environment(AppState.self) private var appState

    private var queue: [Track] { appState.effectiveQueue }
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

                    let otherNodes = appState.remoteNodes.filter {
                        $0.id != appState.controlledNodeId
                    }

                    if !otherNodes.isEmpty {
                        Menu {
                            ForEach(otherNodes) { node in
                                Button {
                                    appState.switchToRemote(nodeId: node.id)
                                } label: {
                                    Label(node.name, systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                        } label: {
                            Label("Transfer Queue to...", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Section {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            isPlaying: isCurrentTrack(index),
                            onTap: { appState.performPlayIndex(index) },
                            appState: appState,
                            displayNumber: index + 1
                        )
                        .tag(track.id)
                        .trackListRowStyle()
                        .contextMenu {
                            queueActions(for: index)
                        }
                        #if os(iOS)
                        .swipeActions {
                            queueActions(for: index)
                        }
                        #endif
                    }
                    .onMove(perform: moveTracks)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .navigationTitle("Queue")
        .toolbar {
            if !queue.isEmpty {
                EditButton()
            }
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
}
