import SwiftUI
import KanadeKit

struct SearchView: View {
    @Environment(AppState.self) private var appState

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isLoading = false
    @State private var hasSubmittedSearch = false
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }

            if let errorMessage {
                Section {
                    ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                }
            } else if results.isEmpty {
                Section {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass", description: Text("Find songs by title, artist, or album."))
                    } else if hasSubmittedSearch && !isLoading {
                        ContentUnavailableView("No Results", systemImage: "music.note", description: Text("Try a different search term."))
                    }
                }
            } else {
                Section("Results") {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isPlaying: currentTrackId == track.id, onTap: {
                            playTrack(at: index)
                        }, appState: appState)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .automatic, prompt: "Search tracks")
        .onSubmit(of: .search) {
            runImmediateSearch()
        }
        .onChange(of: query) {
            debounceSearch(for: query)
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    private var currentTrackId: String? {
        appState.effectiveCurrentTrack?.id
    }

    private func runImmediateSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            await performSearch(for: query)
        }
    }

    private func debounceSearch(for value: String) {
        debounceTask?.cancel()

        let trimmedQuery = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            results = []
            errorMessage = nil
            hasSubmittedSearch = false
            isLoading = false
            return
        }

        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await performSearch(for: trimmedQuery)
        }
    }

    private func performSearch(for rawQuery: String) async {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        guard let client = appState.client else {
            errorMessage = "Not connected to a Kanade server."
            results = []
            hasSubmittedSearch = true
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            results = try await client.search(trimmedQuery)
            hasSubmittedSearch = true
        } catch {
            results = []
            errorMessage = error.localizedDescription
            hasSubmittedSearch = true
        }

        isLoading = false
    }

    private func playTrack(at index: Int) {
        guard results.indices.contains(index) else { return }

        let queue = appState.effectiveQueue

        if queue.map(\.id) == results.map(\.id) {
            appState.performPlayIndex(index)
        } else {
            appState.performReplaceAndPlay(tracks: results, index: index)
        }
    }
}
