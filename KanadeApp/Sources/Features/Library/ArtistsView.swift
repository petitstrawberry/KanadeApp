import SwiftUI
import KanadeKit

struct ArtistsView: View {
    @Environment(AppState.self) private var appState

    @State private var artists: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && artists.isEmpty {
                ProgressView("Loading Artists")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Artists", systemImage: "music.mic", description: Text(errorMessage))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 10) {
                            ForEach(artists, id: \.self) { artist in
                                NavigationLink {
                                    ArtistDetailView(artist: artist)
                                } label: {
                                    LibraryTextRow(title: artist, systemImage: LibrarySection.artists.systemImage)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle("Artists")
        .task {
            await loadArtists()
        }
        .onChange(of: appState.isConnected) {
            if appState.isConnected && artists.isEmpty {
                Task { await loadArtists() }
            }
        }
    }

    private func loadArtists() async {
        guard !isLoading else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            var seen = Set<String>()
            artists = try await client.getArtists().filter { seen.insert($0).inserted }
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
