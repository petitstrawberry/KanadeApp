import SwiftUI
import KanadeKit

struct AlbumTile: View {
    let album: Album
    let appState: AppState?
    let mediaClient: MediaClient?
    var coverOverride: (() -> AnyView)?

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Group {
                    if let coverOverride {
                        coverOverride()
                    } else {
                        ArtworkView(mediaClient: mediaClient, albumId: album.id)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))

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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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

struct LibraryTextRow: View {
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
