import SwiftUI
import KanadeKit

struct AddToPlaylistPickerSheet: View {
    let trackIds: [String]
    let onCompletion: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var playlists: [Playlist] = []
    @State private var loadState: LoadState = .loading
    @State private var addedPlaylistId: String?

    private enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .failed(let message):
                    ContentUnavailableView(
                        "Unable to Load Playlists",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )

                case .loaded:
                    let normalPlaylists = playlists.filter { $0.kind == .normal }

                    if normalPlaylists.isEmpty {
                        ContentUnavailableView(
                            "No Playlists",
                            systemImage: "music.note.list",
                            description: Text("Create a playlist from the Playlists tab first.")
                        )
                    } else {
                        List {
                            ForEach(normalPlaylists) { playlist in
                                Button {
                                    addTo(playlist)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "music.note.list")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name)
                                                .font(.body)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            if let desc = playlist.description, !desc.isEmpty {
                                                Text(desc)
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        if addedPlaylistId == playlist.id {
                                            Image(systemName: "checkmark")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(addedPlaylistId != nil)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 320, idealWidth: 380, minHeight: 360, idealHeight: 440)
            #endif
        }
        .task {
            await loadPlaylists()
        }
    }

    private func loadPlaylists() async {
        guard let client = appState.client else {
            loadState = .failed("Not connected to a Kanade server.")
            return
        }

        do {
            playlists = try await client.getPlaylists()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func addTo(_ playlist: Playlist) {
        appState.client?.appendPlaylistTracks(playlistId: playlist.id, trackIds: trackIds)
        addedPlaylistId = playlist.id

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await onCompletion()
            dismiss()
        }
    }
}
