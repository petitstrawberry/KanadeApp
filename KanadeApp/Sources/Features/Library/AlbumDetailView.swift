import SwiftUI
import KanadeKit

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState

    let album: Album

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var addToPlaylistTarget: AddToPlaylistTarget? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let errorMessage {
                    ContentUnavailableView("Unable to Load Album", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if tracks.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            selectableRow(track: track, index: index)
                        }
                    }
                }
            }
            .padding()
        }
        .toolbar {
            if !tracks.isEmpty {
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
            await loadTracks()
        }
        .sheet(item: $addToPlaylistTarget) { target in
            AddToPlaylistPickerSheet(trackIds: target.trackIds) {
                await loadTracks()
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
                if selectedIds.count == tracks.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(tracks.map(\.id))
                }
            } label: {
                Image(systemName: selectedIds.count == tracks.count ? "xmark.circle" : "checkmark.circle")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if !selectedIds.isEmpty {
                Menu {
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
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
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
    private func selectableRow(track: Track, index: Int) -> some View {
        let isSelected = selectedIds.contains(track.id)

        Button {
            if isSelecting {
                if isSelected {
                    selectedIds.remove(track.id)
                } else {
                    selectedIds.insert(track.id)
                }
            } else {
                playTrack(at: index)
            }
        } label: {
            HStack(spacing: 0) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 32)
                        .padding(.trailing, 4)
                }

                TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {}, appState: appState)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            Label("Play", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

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
            tracks = try await client.getAlbumTracks(albumId: album.id)
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
}

struct AddToPlaylistTarget: Identifiable {
    let id = UUID()
    let trackIds: [String]
}
