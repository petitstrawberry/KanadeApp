import SwiftUI
import KanadeKit

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif
    #if os(macOS)
    @State private var isEditingMac = false
    #endif

    let album: Album

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedIds: Set<String> = []
    @State private var addToPlaylistTarget: AddToPlaylistTarget? = nil

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                header
                    .trackListRowStyle(top: 16, leading: 16, bottom: 16, trailing: 16)
            }

            Section {
                if let errorMessage {
                    VStack(spacing: 16) {
                        ContentUnavailableView("Unable to Load Album", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        Button("Retry") { Task { await loadTracks() } }
                            .buttonStyle(.bordered)
                    }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .trackListRowStyle()
                } else if tracks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .trackListRowStyle()
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                            playTrack(at: index)
                        }, appState: appState, isEditing: isEditing)
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
                        }
                    }
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
            editToolbarContent
        }
        .shellChromeSuppressed(isEditing, reason: .editing)
        .onChange(of: isEditing) {
            if !isEditing {
                selectedIds.removeAll()
            }
        }
        .navigationBarBackButtonHidden(isEditing)
        .task {
            await loadTracks()
        }
        .sheet(item: $addToPlaylistTarget) { target in
            AddToPlaylistPickerSheet(trackIds: target.trackIds) {
                await loadTracks()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: album.id)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay {
                    if tracks.isEmpty && errorMessage == nil {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(.ultraThinMaterial)
                        ProgressView()
                    }
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title ?? "Album")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !tracks.isEmpty {
                    HStack(spacing: 10) {
                        Button {
                            appState.performReplaceAndPlay(tracks: tracks, index: 0)
                        } label: {
                            HeaderActionButtonLabel(title: "Play", systemImage: "play.fill", style: .primary)
                        }
                        .buttonStyle(.plain)

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
                    }
                } else if errorMessage == nil {
                    ProgressView("Loading tracks")
                        .controlSize(.small)
                } else if errorMessage != nil {
                    Text("Couldn't load tracks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private var currentTrackId: String? {
        appState.effectiveCurrentTrack?.id
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
            tracks = try await withAutoRetry { try await client.getAlbumTracks(albumId: album.id) }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
            onRemove: nil
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
            onRemove: nil
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
}
