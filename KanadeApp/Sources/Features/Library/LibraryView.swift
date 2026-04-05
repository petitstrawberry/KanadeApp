import SwiftUI
import KanadeKit

struct LibraryView: View {
    @Environment(AppState.self) private var appState

    @State private var albums: [Album] = []
    @State private var artists: [String] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cardMinWidth: CGFloat = 150
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        Group {
            if isLoading && albums.isEmpty && artists.isEmpty && genres.isEmpty {
                ProgressView("Loading Library")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Library", systemImage: "music.note.list", description: Text(errorMessage))
            } else {
                libraryContent
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .task {
            await loadLibrary()
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                librarySection("Albums") {
                    LazyVGrid(columns: albumColumns, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album, client: appState.client, mediaClient: appState.mediaClient)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                librarySection("Artists") {
                    VStack(spacing: 10) {
                        ForEach(artists, id: \.self) { artist in
                            NavigationLink {
                                ArtistAlbumsView(artist: artist)
                            } label: {
                                LibraryTextRow(title: artist, systemImage: "music.mic")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                librarySection("Genres") {
                    VStack(spacing: 10) {
                        ForEach(genres, id: \.self) { genre in
                            LibraryTextRow(title: genre, systemImage: "music.note.list")
                        }
                    }
                }
            }
            .padding()
        }
        .simultaneousGesture(magnifyGesture)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastMagnification
                let proposed = cardMinWidth * delta
                cardMinWidth = min(max(proposed, 120), 300)
                lastMagnification = value.magnification
            }
            .onEnded { _ in
                lastMagnification = 1
            }
    }

    private var albumColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMinWidth, maximum: 300), spacing: 16)]
    }

    @ViewBuilder
    private func librarySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))

            content()
        }
    }

    private func loadLibrary() async {
        guard !isLoading else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            albums = try await client.getAlbums()
            artists = try await client.getArtists()
            genres = try await client.getGenres()
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

private struct AlbumCard: View {
    let album: Album
    let client: KanadeClient?
    let mediaClient: MediaClient?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artworkSection

            Text(album.title ?? "Untitled")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var artworkSection: some View {
        ArtworkView(mediaClient: mediaClient, albumId: album.id)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.5))
                        .transition(.opacity)
                }
            }
            .overlay {
                if isHovered {
                    HStack(spacing: 8) {
                        Button {
                            addAlbumToQueue()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.2), in: Circle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            playAlbum()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(Color.accentColor, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isHovered)
    }

    private func addAlbumToQueue() {
        guard let client else { return }
        Task {
            guard let tracks = try? await client.getAlbumTracks(albumId: album.id) else { return }
            client.addTracksToQueue(tracks)
        }
    }

    private func playAlbum() {
        guard let client else { return }
        Task {
            guard let tracks = try? await client.getAlbumTracks(albumId: album.id) else { return }
            client.replaceAndPlay(tracks: tracks, index: 0)
        }
    }
}

private struct LibraryTextRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            Text(title)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
