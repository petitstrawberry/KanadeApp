import SwiftUI
import KanadeKit

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState

    let album: Album

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                            TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                                playTrack(at: index)
                            }, appState: appState)
                        }
                    }
                }
            }
            .padding()
        }
        .task {
            await loadTracks()
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

                        Button {
                            appState.performAddTracksToQueue(tracks)
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
                    Text("Couldn’t load tracks")
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
