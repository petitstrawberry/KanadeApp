import SwiftUI
import KanadeKit

struct PlaylistsView: View {
    @Environment(AppState.self) private var appState

    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var artworkAlbumIds: [String: [String]] = [:]
    
    @State private var editorPlaylist: Playlist? = nil
    @State private var isCreatingPlaylist = false

    var body: some View {
        Group {
            if isLoading && playlists.isEmpty {
                ProgressView("Loading Playlists")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Playlists", systemImage: "square.stack", description: Text(errorMessage))
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                PlaylistArtworkMosaic(
                                    mediaClient: appState.mediaClient,
                                    albumIds: artworkAlbumIds[playlist.id] ?? [],
                                    size: 48,
                                    cornerRadius: 8,
                                    fallbackSystemImage: playlist.kind == .smart ? "sparkles" : "music.note.list",
                                    fallbackGradient: playlist.kind == .smart ? [.purple, .pink, .orange] : [.purple, .blue]
                                )
                                .task(id: playlist.id) {
                                    await loadArtworkAlbumIds(for: playlist)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .font(.headline)
                                    
                                    if playlist.kind == .smart {
                                        Text(playlist.description ?? "Smart Playlist")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    } else if let description = playlist.description, !description.isEmpty {
                                        Text(description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.client?.deletePlaylist(playlist.id)
                                Task { await loadPlaylists() }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editorPlaylist = playlist
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingPlaylist = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await loadPlaylists()
        }
        .onChange(of: appState.isConnected) {
            if appState.isConnected && playlists.isEmpty {
                Task { await loadPlaylists() }
            }
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            PlaylistEditorSheet(mode: .create) {
                await loadPlaylists()
            }
        }
        .sheet(item: $editorPlaylist) { playlist in
            PlaylistEditorSheet(mode: .edit(playlist)) {
                await loadPlaylists()
            }
        }
    }

    private func loadPlaylists() async {
        guard !isLoading else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            playlists = try await client.getPlaylists()
        } catch {
            if let kanadeError = error as? KanadeError {
                errorMessage = String(describing: kanadeError)
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func loadArtworkAlbumIds(for playlist: Playlist) async {
        if artworkAlbumIds[playlist.id] != nil { return }
        guard let client = appState.client else { return }

        let tracks: [Track]
        do {
            tracks = try await client.getPlaylistTracks(playlistId: playlist.id)
        } catch {
            await MainActor.run {
                artworkAlbumIds[playlist.id] = []
            }
            return
        }

        var seen = Set<String>()
        var ordered: [String] = []
        for track in tracks {
            guard let albumId = track.albumId, !albumId.isEmpty else { continue }
            if seen.insert(albumId).inserted {
                ordered.append(albumId)
                if ordered.count == 4 { break }
            }
        }

        await MainActor.run {
            artworkAlbumIds[playlist.id] = ordered
        }
    }
}
