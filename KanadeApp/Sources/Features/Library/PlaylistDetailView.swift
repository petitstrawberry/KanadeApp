import SwiftUI
import KanadeKit

struct PlaylistDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    #if os(macOS)
    @State private var isEditingMac = false
    #endif

    let playlist: Playlist

    @State private var currentPlaylist: Playlist
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingEditor = false
    @State private var selectedIds: Set<String> = []
    @State private var addToPlaylistTarget: AddToPlaylistTarget? = nil

    init(playlist: Playlist) {
        self.playlist = playlist
        self._currentPlaylist = State(initialValue: playlist)
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                header
                    .trackListRowStyle(top: 16, leading: 16, bottom: 16, trailing: 16)
            }

            Section {
                if currentPlaylist.kind == .smart {
                    Text("Tracks are computed from the smart filter and update automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .trackListRowStyle()
                }

                if let errorMessage {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Unable to Load Tracks", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        Button("Retry") { Task { await loadTracks() } }
                            .buttonStyle(.bordered)
                    }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .trackListRowStyle()
                } else if tracks.isEmpty && !isLoading {
                    Text(currentPlaylist.kind == .smart ? "No tracks match the filter." : "No tracks in playlist.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .trackListRowStyle()
                } else if isLoading && tracks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .trackListRowStyle()
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                            playTrack(at: index)
                        }, appState: appState, displayNumber: index + 1, isEditing: isEditing)
                        .tag(track.id)
                        .trackListRowStyle()
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
                                Divider()

                                Button(role: .destructive) {
                                    removeTrack(at: index)
                                } label: {
                                    Label("Remove from Playlist", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                    .onMove(perform: currentPlaylist.kind == .normal ? moveTracks : nil)
                }
            }
        }
        .listStyle(.plain)
        .barBottomAvoidance()
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingEditor = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }

            editToolbarContent
        }
        .shellChromeSuppressed(isEditing, reason: .editing)
        .onChange(of: isEditing) {
            if !isEditing {
                selectedIds.removeAll()
            }
        }
        .navigationBarBackButtonHidden(isEditing)
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
                        HeaderActionButtonLabel(title: "Play", systemImage: "play.fill", style: .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(tracks.isEmpty)

                    Menu {
                        Button {
                            appState.performAddTracksToQueue(tracks)
                        } label: {
                            Label("Add to Queue", systemImage: "plus.circle")
                        }

                        Button {
                            addToPlaylistTarget = AddToPlaylistTarget(trackIds: tracks.map(\.id))
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                        }
                    } label: {
                        HeaderActionButtonLabel(title: "Add", systemImage: "plus", style: .secondary)
                    }
                    .buttonStyle(.plain)
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
            tracks = try await withAutoRetry { try await client.getPlaylistTracks(playlistId: currentPlaylist.id) }
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

    #if os(iOS)
    private var editToolbarContent: some ToolbarContent {
        TrackListEditToolbar(
            isEditing: isEditing,
            allSelected: trackListAllSelected(selectedIds: selectedIds, trackIds: tracks.map(\.id)),
            hasSelection: !selectedIds.isEmpty,
            editMode: $editMode,
            onToggleEditMac: toggleEditMode,
            onToggleSelectAll: {
                toggleTrackListSelection(selectedIds: &selectedIds, trackIds: tracks.map(\.id))
            },
            onAddToQueue: {
                appState.performAddTracksToQueue(selectedTracks(from: tracks, selectedIds: selectedIds))
            },
            onAddToPlaylist: {
                addToPlaylistTarget = AddToPlaylistTarget(trackIds: Array(selectedIds))
                selectedIds.removeAll()
                setEditing(false)
            },
            onRemove: currentPlaylist.kind == .normal ? {
                removeSelectedTracks()
            } : nil
        )
    }
    #else
    private var editToolbarContent: some ToolbarContent {
        TrackListEditToolbar(
            isEditing: isEditing,
            allSelected: trackListAllSelected(selectedIds: selectedIds, trackIds: tracks.map(\.id)),
            hasSelection: !selectedIds.isEmpty,
            onToggleEditMac: toggleEditMode,
            onToggleSelectAll: {
                toggleTrackListSelection(selectedIds: &selectedIds, trackIds: tracks.map(\.id))
            },
            onAddToQueue: {
                appState.performAddTracksToQueue(selectedTracks(from: tracks, selectedIds: selectedIds))
            },
            onAddToPlaylist: {
                addToPlaylistTarget = AddToPlaylistTarget(trackIds: Array(selectedIds))
                selectedIds.removeAll()
                setEditing(false)
            },
            onRemove: currentPlaylist.kind == .normal ? {
                removeSelectedTracks()
            } : nil
        )
    }
    #endif

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

    private func moveTracks(from offsets: IndexSet, to destination: Int) {
        guard let source = offsets.first else { return }
        appState.client?.movePlaylistTrack(playlistId: currentPlaylist.id, from: source, to: destination)
        tracks.move(fromOffsets: offsets, toOffset: destination)
    }

    private func removeTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        appState.client?.removePlaylistTrack(playlistId: currentPlaylist.id, position: index)
        tracks.remove(at: index)
    }

    private func removeSelectedTracks() {
        let sortedIndices = tracks.enumerated()
            .filter { selectedIds.contains($0.element.id) }
            .map(\.offset)
            .sorted(by: >)

        for index in sortedIndices {
            appState.client?.removePlaylistTrack(playlistId: currentPlaylist.id, position: index)
            tracks.remove(at: index)
        }

        selectedIds.removeAll()
        setEditing(false)
    }
}
