import SwiftUI

struct PlaylistsView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ContentUnavailableView(
                    "Playlists Coming Soon",
                    systemImage: LibrarySection.playlists.systemImage,
                    description: Text("Playlist support isn't implemented yet.")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
                .padding(.horizontal)
            }
        }
        .navigationTitle(LibrarySection.playlists.title)
    }
}
