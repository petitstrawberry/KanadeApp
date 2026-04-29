import SwiftUI
import KanadeKit

struct ArtistDetailView: View {
    @Environment(AppState.self) private var appState

    let artist: String

    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if let errorMessage {
                ContentUnavailableView("Unable to Load Artist", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .padding()
            } else if isLoading && albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .padding()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 300), spacing: 16)], spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            AlbumTile(
                                album: album,
                                appState: appState,
                                mediaClient: appState.mediaClient
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
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
