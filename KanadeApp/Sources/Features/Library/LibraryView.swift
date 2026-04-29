import SwiftUI
import KanadeKit

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum LibraryCategory: String, CaseIterable, Hashable {
    case albums, artists, genres

    var title: String {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .genres: "music.note.list"
        }
    }
}

struct LibraryView: View {
    @Environment(AppState.self) private var appState

    let category: LibraryCategory?

    @State private var selectedCategory: LibraryCategory

    @State private var selectedAlbum: Album?
    @State private var albums: [Album] = []
    @State private var artists: [String] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cardMinWidth: CGFloat = 150
    @State private var scrollOffset: CGFloat = 0
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var isPinching = false

    init(category: LibraryCategory? = nil) {
        self.category = category
        self._selectedCategory = State(initialValue: category ?? .albums)
    }

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
        .navigationTitle(category?.title ?? "Library")
        .navigationDestination(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
        }
        .task {
            await loadLibrary()
        }
        .onChange(of: appState.isConnected) {
            if appState.isConnected && albums.isEmpty {
                Task { await loadLibrary() }
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        #if os(iOS)
        if category == nil {
            iphoneCustomLibraryContent
        } else {
            standardLibraryContent
        }
        #else
        standardLibraryContent
        #endif
    }

    @ViewBuilder
    private var standardLibraryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Group {
                    switch selectedCategory {
                    case .albums:
                        albumsSection
                    case .artists:
                        artistsSection
                    case .genres:
                        genresSection
                    }
                }
                .padding(.horizontal)
            }
        }
        .simultaneousGesture(magnifyGesture)
    }

    #if os(iOS)
    @ViewBuilder
    private var iphoneCustomLibraryContent: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top

            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GeometryReader { scrollProxy in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self, value: scrollProxy.frame(in: .named("CustomScroll")).minY)
                        }
                        .frame(height: 0)

                        Color.clear
                            .frame(height: expandedHeaderHeight + topInset)

                        Group {
                            switch selectedCategory {
                            case .albums:
                                albumsSection
                            case .artists:
                                artistsSection
                            case .genres:
                                genresSection
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .coordinateSpace(name: "CustomScroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
                .simultaneousGesture(magnifyGesture)

                iphoneCollapsingHeader(topInset: topInset)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func iphoneCollapsingHeader(topInset: CGFloat) -> some View {
        let currentHeight = expandedHeaderHeight - ((expandedHeaderHeight - collapsedHeaderHeight) * headerCollapseProgress)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: 12) {
                Text("Library")
                    .font(.largeTitle.weight(.bold))
                    .opacity(1 - headerCollapseProgress)
                    .scaleEffect(1 - (headerCollapseProgress * 0.12), anchor: .bottomLeading)

                chipsView
                    .offset(y: -headerCollapseProgress * 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset + 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            Text("Library")
                .font(.headline)
                .opacity(headerCollapseProgress)
                .frame(maxWidth: .infinity)
                .padding(.top, topInset + 10)
        }
        .frame(height: currentHeight + topInset)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(headerCollapseProgress)
        }
    }

    private var expandedHeaderHeight: CGFloat {
        112
    }

    private var collapsedHeaderHeight: CGFloat {
        64
    }

    private var headerCollapseProgress: CGFloat {
        min(max((-scrollOffset - 16) / 72.0, 0), 1)
    }
    #endif

    @ViewBuilder
    private var chipsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryCategory.allCases, id: \.self) { cat in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedCategory = cat
                        }
                    } label: {
                        Text(cat.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(selectedCategory == cat ? Color.accentColor : Color.secondary.opacity(0.12))
                            )
                            .foregroundStyle(selectedCategory == cat ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var albumsSection: some View {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var artistsSection: some View {
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

    @ViewBuilder
    private var genresSection: some View {
        VStack(spacing: 10) {
            ForEach(genres, id: \.self) { genre in
                LibraryTextRow(title: genre, systemImage: "music.note.list")
            }
        }
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
            var seenArtists = Set<String>()
            artists = try await client.getArtists().filter { seenArtists.insert($0).inserted }
            var seenGenres = Set<String>()
            genres = try await client.getGenres().filter { seenGenres.insert($0).inserted }
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

struct AlbumTile: View {
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
