import SwiftUI
import KanadeKit

struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState

    let artist: String

    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Artist", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                List(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        ArtistAlbumRow(album: album, mediaClient: appState.mediaClient)
                    }
                }
            }
        }
        .navigationTitle(artist)
        .task {
            await loadAlbums()
        }
    }

    private func loadAlbums() async {
        guard !isLoading else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            albums = try await client.getArtistAlbums(artist: artist)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

typealias ArtistAlbumsView = ArtistDetailView

private struct ArtistAlbumRow: View {
    let album: Album
    let mediaClient: MediaClient?

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(mediaClient: mediaClient, albumId: album.id)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title ?? "Untitled")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("Album")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
