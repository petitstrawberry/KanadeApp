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
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []

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
                        if isSelecting {
                            selectableRow(for: playlist)
                        } else {
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                playlistRowContent(for: playlist)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deletePlaylist(playlist)
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

            if !playlists.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if isSelecting {
                            isSelecting = false
                            selectedIds.removeAll()
                        } else {
                            isSelecting = true
                        }
                    } label: {
                        Label(isSelecting ? "Cancel" : "Select", systemImage: isSelecting ? "xmark.circle" : "checklist")
                    }
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
        .overlay(alignment: .bottom) {
            if isSelecting {
                selectionActionBar
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            Button {
                if selectedIds.count == playlists.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(playlists.map(\.id))
                }
            } label: {
                Image(systemName: selectedIds.count == playlists.count ? "xmark.circle" : "checkmark.circle")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if !selectedIds.isEmpty {
                Button(role: .destructive) {
                    for id in selectedIds {
                        appState.client?.deletePlaylist(id)
                    }
                    playlists.removeAll { selectedIds.contains($0.id) }
                    selectedIds.removeAll()
                    isSelecting = false
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func playlistRowContent(for playlist: Playlist) -> some View {
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
                    Text("Smart Playlist")
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

    @ViewBuilder
    private func selectableRow(for playlist: Playlist) -> some View {
        let isSelected = selectedIds.contains(playlist.id)

        Button {
            if isSelected {
                selectedIds.remove(playlist.id)
            } else {
                selectedIds.insert(playlist.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                playlistRowContent(for: playlist)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deletePlaylist(playlist)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        appState.client?.deletePlaylist(playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        selectedIds.remove(playlist.id)
        if playlists.isEmpty {
            isSelecting = false
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
