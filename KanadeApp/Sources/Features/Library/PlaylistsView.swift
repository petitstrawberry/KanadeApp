import SwiftUI
import KanadeKit

struct PlaylistsView: View {
    @Environment(AppState.self) private var appState

    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    #if os(macOS)
    @State private var isEditingMac = false
    #endif

    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var artworkAlbumIds: [String: [String]] = [:]

    @State private var editorPlaylist: Playlist? = nil
    @State private var isCreatingPlaylist = false
    @State private var selectedIds: Set<String> = []

    var body: some View {
        Group {
            if isLoading && playlists.isEmpty {
                ProgressView("Loading Playlists")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Playlists", systemImage: "square.stack", description: Text(errorMessage))
            } else {
                List(selection: selectionBinding) {
                    Button {
                        isCreatingPlaylist = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.tint.opacity(0.12))
                                .frame(width: 48, height: 48)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }

                            Text("New Playlist")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }

                    ForEach(playlists) { playlist in
                        if isEditing {
                            playlistRowContent(for: playlist)
                                .tag(playlist.id)
                        } else {
                            NavigationLink {
                                PlaylistDetailView(playlist: playlist)
                            } label: {
                                playlistRowContent(for: playlist)
                            }
                            .tag(playlist.id)
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
                #if os(iOS)
                .environment(\.editMode, $editMode)
                #endif
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton()
                    .environment(\.editMode, $editMode)
                    .disabled(playlists.isEmpty && !isEditing)
            }

            if isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedIds.count == playlists.count ? "Deselect All" : "Select All") {
                        if selectedIds.count == playlists.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(playlists.map(\.id))
                        }
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedIds.isEmpty)
                    Spacer()
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Button(isEditing ? "Done" : "Edit") {
                    toggleEditMode()
                }
                .disabled(playlists.isEmpty && !isEditing)
            }

            if isEditing {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedIds.isEmpty)
                }
            }
            #endif
        }
        .shellChromeSuppressed(isEditing, reason: .editing)
        .onChange(of: isEditing) {
            if !isEditing {
                selectedIds.removeAll()
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

    private func deletePlaylist(_ playlist: Playlist) {
        appState.client?.deletePlaylist(playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        selectedIds.remove(playlist.id)
        if playlists.isEmpty {
            setEditing(false)
        }
    }

    private func deleteSelected() {
        for id in selectedIds {
            appState.client?.deletePlaylist(id)
        }
        playlists.removeAll { selectedIds.contains($0.id) }
        selectedIds.removeAll()
        setEditing(false)
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

    private var isEditing: Bool {
        #if os(iOS)
        editMode == .active
        #else
        isEditingMac
        #endif
    }

    private func setEditing(_ isEditing: Bool) {
        #if os(iOS)
        editMode = isEditing ? .active : .inactive
        #else
        isEditingMac = isEditing
        #endif
    }

    private func toggleEditMode() {
        setEditing(!isEditing)
    }

    private var selectionBinding: Binding<Set<String>>? {
        isEditing ? $selectedIds : nil
    }
}
