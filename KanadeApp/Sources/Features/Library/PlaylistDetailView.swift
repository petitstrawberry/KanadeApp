import SwiftUI
import KanadeKit

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist

    @State private var currentPlaylist: Playlist
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingEditor = false
    @State private var addToPlaylistTarget: AddToPlaylistTarget? = nil

    init(playlist: Playlist) {
        self.playlist = playlist
        self._currentPlaylist = State(initialValue: playlist)
    }

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if currentPlaylist.kind == .smart {
                        Text("Tracks are computed from the smart filter and update automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        ContentUnavailableView("Unable to Load Tracks", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if tracks.isEmpty && !isLoading {
                        Text(currentPlaylist.kind == .smart ? "No tracks match the filter." : "No tracks in playlist.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if isLoading && tracks.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                                    playTrack(at: index)
                                }, appState: appState, displayNumber: index + 1)
                                .contextMenu {
                                    Button {
                                        appState.performAddToQueue(track)
                                    } label: {
                                        Label("Add to Queue", systemImage: "plus.circle")
                                    }

                                    Button {
                                        addToPlaylistTarget = AddToPlaylistTarget(trackIds: [track.id])
                                    } label: {
                                        Label("Add to Playlist", systemImage: "text.badge.plus")
                                    }

                                    if currentPlaylist.kind == .normal {
                                        Button(role: .destructive) {
                                            removeTrack(at: index)
                                        } label: {
                                            Label("Remove from Playlist", systemImage: "minus.circle")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isShowingEditor = true
                    } label: {
                        Label("Edit Playlist", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        appState.client?.deletePlaylist(currentPlaylist.id)
                        dismiss()
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            PlaylistEditorSheet(mode: .edit(currentPlaylist)) {
                await reloadAll()
            }
        }
        .sheet(item: $addToPlaylistTarget) { target in
            AddToPlaylistPickerSheet(trackIds: target.trackIds) {
                await reloadAll()
            }
        }
        .task {
            await loadTracks()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PlaylistArtworkMosaic(
                mediaClient: appState.mediaClient,
                albumIds: headerAlbumIds,
                size: 132,
                cornerRadius: 18,
                fallbackSystemImage: currentPlaylist.kind == .smart ? "sparkles" : "music.note.list",
                fallbackGradient: currentPlaylist.kind == .smart ? [.purple, .pink, .orange] : [.purple, .blue]
            )
            .overlay {
                if isLoading && tracks.isEmpty && errorMessage == nil {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.ultraThinMaterial)
                    ProgressView()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(currentPlaylist.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if let description = currentPlaylist.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(currentPlaylist.kind == .smart ? "Smart Playlist" : "Playlist")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        appState.performReplaceAndPlay(tracks: tracks, index: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(tracks.isEmpty)

                    Button {
                        appState.performAddTracksToQueue(tracks)
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(tracks.isEmpty)
                }
            }

            Spacer()
        }
    }

    private var currentTrackId: String? {
        appState.effectiveCurrentTrack?.id
    }

    private var headerAlbumIds: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for track in tracks {
            guard let albumId = track.albumId, !albumId.isEmpty else { continue }
            if seen.insert(albumId).inserted {
                ordered.append(albumId)
                if ordered.count == 4 { break }
            }
        }
        return ordered
    }

    private func loadTracks() async {
        guard !isLoading else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            tracks = try await client.getPlaylistTracks(playlistId: currentPlaylist.id)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func reloadAll() async {
        guard let client = appState.client else { return }
        if let updated = try? await client.getPlaylist(playlistId: currentPlaylist.id) {
            currentPlaylist = updated
        }
        await loadTracks()
    }

    private func playTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }

        let queue = appState.effectiveQueue

        if queue.map(\.id) == tracks.map(\.id) {
            appState.performPlayIndex(index)
        } else {
            appState.performReplaceAndPlay(tracks: tracks, index: index)
        }
    }

    private func removeTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        appState.client?.removePlaylistTrack(playlistId: currentPlaylist.id, position: index)
        tracks.remove(at: index)
    }
}
