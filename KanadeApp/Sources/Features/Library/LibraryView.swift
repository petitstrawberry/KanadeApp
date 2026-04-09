import SwiftUI
import KanadeKit

struct LibraryView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedAlbum: Album?
    @State private var albums: [Album] = []
    @State private var artists: [String] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cardMinWidth: CGFloat = 150
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var isPinching = false

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
        .navigationDestination(item: $selectedAlbum) { album in
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
                            AlbumTile(
                                album: album,
                                appState: appState,
                                mediaClient: appState.mediaClient,
                                isInteractionEnabled: !isPinching,
                                openAlbum: { selectedAlbum = album }
                            )
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

    private var albumColumns: [GridItem] {
        [GridItem(.adaptive(minimum: effectiveCardMinWidth, maximum: 300), spacing: 16)]
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

private struct AlbumTile: View {
    let album: Album
    let appState: AppState?
    let mediaClient: MediaClient?
    let isInteractionEnabled: Bool
    let openAlbum: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ArtworkView(mediaClient: mediaClient, albumId: album.id)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture {
                        guard isInteractionEnabled else { return }
                        openAlbum()
                    }

                if isHovered {
                    artworkActions
                }
            }

            Text(album.title ?? "Untitled")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isInteractionEnabled else { return }
                    openAlbum()
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }

    private var artworkActions: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.5))
                .allowsHitTesting(false)

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
        }
        .aspectRatio(1, contentMode: .fit)
        .transition(.opacity)
    }

    private func addAlbumToQueue() {
        guard let appState, let client = appState.client else { return }
        Task {
            guard let tracks = try? await client.getAlbumTracks(albumId: album.id) else { return }
            await MainActor.run {
                appState.performAddTracksToQueue(tracks)
            }
        }
    }

    private func playAlbum() {
        guard let appState, let client = appState.client else { return }
        Task {
            guard let tracks = try? await client.getAlbumTracks(albumId: album.id) else { return }
            await MainActor.run {
                appState.performReplaceAndPlay(tracks: tracks, index: 0)
            }
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
