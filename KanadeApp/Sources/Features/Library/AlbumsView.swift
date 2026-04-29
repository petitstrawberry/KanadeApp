import SwiftUI
import KanadeKit

struct AlbumsView: View {
    @Environment(AppState.self) private var appState

    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cardMinWidth: CGFloat = 150
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var isPinching = false

    var body: some View {
        Group {
            if isLoading && albums.isEmpty {
                ProgressView("Loading Albums")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Albums", systemImage: "square.stack", description: Text(errorMessage))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: albumColumns, spacing: 16) {
                            NavigationLink {
                                AllSongsPlaceholderView()
                            } label: {
                                AlbumTile(
                                    album: allSongsAlbum,
                                    appState: appState,
                                    mediaClient: nil
                                )
                            }
                            .buttonStyle(.plain)
                            .allowsHitTesting(!isPinching)

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
                                .allowsHitTesting(!isPinching)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .simultaneousGesture(magnifyGesture)
            }
        }
        .navigationTitle("Albums")
        .task {
            await loadAlbums()
        }
        .onChange(of: appState.isConnected) {
            if appState.isConnected && albums.isEmpty {
                Task { await loadAlbums() }
            }
        }
    }

    private var albumColumns: [GridItem] {
        [GridItem(.adaptive(minimum: effectiveCardMinWidth, maximum: 300), spacing: 16)]
    }

    private var allSongsAlbum: Album {
        Album(id: "__all_songs__", dirPath: "", title: "All Songs", artworkPath: nil)
    }

    private var effectiveCardMinWidth: CGFloat {
        clampedCardWidth(cardMinWidth * magnification)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($isPinching) { _, state, _ in
                state = true
            }
            .updating($magnification) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                cardMinWidth = clampedCardWidth(cardMinWidth * value.magnification)
            }
    }

    private func clampedCardWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, 120), 300)
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
            albums = try await client.getAlbums()
        } catch {
            if let kanadeError = error as? KanadeError {
                errorMessage = String(describing: kanadeError)
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }
}
