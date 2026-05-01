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
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var addToPlaylistTarget: AddToPlaylistTarget? = nil
    @State private var draggingTrackId: String? = nil

    init(playlist: Playlist) {
        self.playlist = playlist
        self._currentPlaylist = State(initialValue: playlist)
    }

    var body: some View {
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
                            selectableRow(track: track, index: index)
                                .opacity(draggingTrackId == track.id ? 0.4 : 1)
                                .if(currentPlaylist.kind == .normal && !isSelecting) { view in
                                    view
                                        .draggable(track.id) {
                                            dragPreview(for: track)
                                        }
                                        .dropDestination(for: String.self) { droppedIds, _ in
                                            guard let droppedId = droppedIds.first,
                                                  let fromIndex = tracks.firstIndex(where: { $0.id == droppedId }),
                                                  let toIndex = tracks.firstIndex(where: { $0.id == track.id }),
                                                  fromIndex != toIndex else { return false }
                                            moveTrack(from: fromIndex, to: toIndex)
                                            return true
                                        }
                                }
                        }
                    }
                }
            }
            .padding()
        }
        .toolbar {
            if isSelecting {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedIds.count == tracks.count ? "Deselect All" : "Select All") {
                        if selectedIds.count == tracks.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(tracks.map(\.id))
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    selectionMenuContent
                        .disabled(selectedIds.isEmpty)
                    if currentPlaylist.kind == .normal {
                        Button(role: .destructive) {
                            removeSelectedTracks()
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                        .disabled(selectedIds.isEmpty)
                    }
                    Spacer()
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(selectedIds.count == tracks.count ? "Deselect All" : "Select All") {
                        if selectedIds.count == tracks.count {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(tracks.map(\.id))
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        selectionMenuContent

                        if currentPlaylist.kind == .normal {
                            Divider()

                            Button(role: .destructive) {
                                removeSelectedTracks()
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .disabled(selectedIds.isEmpty)
                }
                #endif
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingEditor = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                if !tracks.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checklist")
                        }
                    }
                }
            }
        }
        .onChange(of: isSelecting) { appState.isInSelectionMode = isSelecting }
        .navigationBarBackButtonHidden(isSelecting)
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

    @ViewBuilder
    private func dragPreview(for track: Track) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Text(track.title ?? "Untitled")
                .font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Selection Toolbar

    @ViewBuilder
    private var selectionMenuContent: some View {
        Button {
            let selected = tracks.filter { selectedIds.contains($0.id) }
            appState.performAddTracksToQueue(selected)
        } label: {
            Label("Add to Queue", systemImage: "plus.circle")
        }

        Button {
            addToPlaylistTarget = AddToPlaylistTarget(trackIds: Array(selectedIds))
            isSelecting = false
            selectedIds.removeAll()
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }

    @ViewBuilder
    private func selectableRow(track: Track, index: Int) -> some View {
        let isSelected = selectedIds.contains(track.id)

        HStack(spacing: 0) {
            if isSelecting {
                Button {
                    if isSelected {
                        selectedIds.remove(track.id)
                    } else {
                        selectedIds.insert(track.id)
                    }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 32)
                        .padding(.trailing, 4)
                }
                .buttonStyle(.plain)
            }

            TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                if isSelecting {
                    if isSelected {
                        selectedIds.remove(track.id)
                    } else {
                        selectedIds.insert(track.id)
                    }
                } else {
                    playTrack(at: index)
                }
            }, appState: appState, displayNumber: index + 1)
        }
        .contentShape(Rectangle())
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

    private func moveTrack(from source: Int, to destination: Int) {
        guard source != destination else { return }
        guard tracks.indices.contains(source), tracks.indices.contains(destination) else { return }
        appState.client?.movePlaylistTrack(playlistId: currentPlaylist.id, from: source, to: destination)
        let track = tracks.remove(at: source)
        tracks.insert(track, at: destination)
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
        isSelecting = false
    }
}

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
