import SwiftUI
import KanadeKit

struct AlbumDetailView: View {
    @Environment(AppState.self) private var appState

    let album: Album

    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Album", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header

                        LazyVStack(spacing: 8) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                                    playTrack(at: index)
                                }, appState: appState)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(album.title ?? "Album")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadTracks()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkView(mediaClient: appState.mediaClient, albumId: album.id)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title ?? "Album")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)

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
                }
            }

            Spacer()
        }
    }

    private var currentTrackId: String? {
        guard
            let client = appState.client,
            let state = client.state,
            let currentIndex = state.currentIndex,
            state.queue.indices.contains(currentIndex)
        else {
            return nil
        }

        return state.queue[currentIndex].id
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
        guard let client = appState.client, tracks.indices.contains(index) else { return }

        let queue = client.state?.queue ?? []

        if queue.map(\.id) == tracks.map(\.id) {
            appState.performPlayIndex(index)
        } else {
            appState.performReplaceAndPlay(tracks: tracks, index: index)
        }
    }
}
