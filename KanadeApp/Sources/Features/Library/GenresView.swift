import SwiftUI
import KanadeKit

struct GenresView: View {
    @Environment(AppState.self) private var appState

    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && genres.isEmpty {
                ProgressView("Loading Genres")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("Unable to Load Genres", systemImage: "guitars", description: Text(errorMessage))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 10) {
                            ForEach(genres, id: \.self) { genre in
                                LibraryTextRow(title: genre, systemImage: LibrarySection.genres.systemImage)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle("Genres")
        .task {
            await loadGenres()
        }
        .onChange(of: appState.isConnected) {
            if appState.isConnected && genres.isEmpty {
                Task { await loadGenres() }
            }
        }
    }

    private func loadGenres() async {
        guard !isLoading else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            var seen = Set<String>()
            genres = try await client.getGenres().filter { seen.insert($0).inserted }
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
