import SwiftUI
import KanadeKit

struct GenreDetailView: View {
    @Environment(AppState.self) private var appState

    let genre: String

    @State private var albums: [Album] = []
    @State private var selectedAlbum: Album?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Genre", systemImage: "music.note.list", description: Text(errorMessage))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 300), spacing: 16)], spacing: 16) {
                        ForEach(albums) { album in
                            AlbumTile(
                                album: album,
                                appState: appState,
                                mediaClient: appState.mediaClient,
                                isInteractionEnabled: true,
                                openAlbum: { selectedAlbum = album }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(genre)
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
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
            albums = try await client.getGenreAlbums(genre: genre)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
