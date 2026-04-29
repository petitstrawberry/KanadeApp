import SwiftUI
import KanadeKit

struct AlbumsView: View {
    @Environment(AppState.self) private var appState

    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedAlbum: Album?
    @State private var showAllSongs = false
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
                    LazyVGrid(columns: albumColumns, spacing: 16) {
                        allSongsCard

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
                    .padding(.horizontal)
                }
                .simultaneousGesture(magnifyGesture)
            }
        }
        .navigationTitle("Albums")
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(isPresented: $showAllSongs) {
            AllSongsPlaceholderView()
        }
        .task {
            await loadAlbums()
        }
        .onChange(of: appState.isConnected) {
            if appState.isConnected && albums.isEmpty {
                Task { await loadAlbums() }
            }
        }
    }

    @ViewBuilder
    private var allSongsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .aspectRatio(1, contentMode: .fit)

                Image(systemName: "music.note")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor, in: Circle())
                    .opacity(0.8)
            }

            Text("All Songs")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isPinching else { return }
                    showAllSongs = true
                }        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
