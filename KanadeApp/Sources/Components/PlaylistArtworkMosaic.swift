import SwiftUI
import KanadeKit

struct PlaylistArtworkMosaic: View {
    let mediaClient: MediaClient?
    let albumIds: [String]
    let size: CGFloat
    let cornerRadius: CGFloat
    let fallbackSystemImage: String
    let fallbackGradient: [Color]

    init(
        mediaClient: MediaClient?,
        albumIds: [String],
        size: CGFloat,
        cornerRadius: CGFloat = 8,
        fallbackSystemImage: String = "music.note.list",
        fallbackGradient: [Color] = [.purple, .blue]
    ) {
        self.mediaClient = mediaClient
        self.albumIds = albumIds
        self.size = size
        self.cornerRadius = cornerRadius
        self.fallbackSystemImage = fallbackSystemImage
        self.fallbackGradient = fallbackGradient
    }

    var body: some View {
        Group {
            switch albumIds.count {
            case 0:
                fallback
            case 1:
                MosaicTile(mediaClient: mediaClient, albumId: albumIds[0])
            case 2:
                HStack(spacing: 0) {
                    MosaicTile(mediaClient: mediaClient, albumId: albumIds[0])
                    MosaicTile(mediaClient: mediaClient, albumId: albumIds[1])
                }
            case 3:
                VStack(spacing: 0) {
                    MosaicTile(mediaClient: mediaClient, albumId: albumIds[0])
                    HStack(spacing: 0) {
                        MosaicTile(mediaClient: mediaClient, albumId: albumIds[1])
                        MosaicTile(mediaClient: mediaClient, albumId: albumIds[2])
                    }
                }
            default:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MosaicTile(mediaClient: mediaClient, albumId: albumIds[0])
                        MosaicTile(mediaClient: mediaClient, albumId: albumIds[1])
                    }
                    HStack(spacing: 0) {
                        MosaicTile(mediaClient: mediaClient, albumId: albumIds[2])
                        MosaicTile(mediaClient: mediaClient, albumId: albumIds[3])
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: fallbackGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: fallbackSystemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct MosaicTile: View {
    let mediaClient: MediaClient?
    let albumId: String?

    @State private var artworkImage: PlatformImage?

    private var displayedImage: PlatformImage? {
        if let albumId, let cached = ArtworkCache.image(for: albumId) {
            return cached
        }
        return artworkImage
    }

    private var taskKey: String {
        let clientKey = mediaClient.map { String(ObjectIdentifier($0).hashValue) } ?? "nil"
        let albumKey = albumId ?? "nil"
        return "\(clientKey):\(albumKey)"
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let displayedImage {
                    rendered(displayedImage)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: taskKey) {
                await loadArtwork()
            }
    }

    @ViewBuilder
    private func rendered(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #endif
    }

    private func loadArtwork() async {
        guard let albumId else { return }

        if let cached = ArtworkCache.image(for: albumId) {
            await MainActor.run { artworkImage = cached }
            return
        }

        let diskTask = ArtworkCache.imageTask(for: "disk:\(albumId)") {
            Task.detached(priority: .utility) {
                ArtworkCache.loadImageFromDisk(for: albumId)
            }
        }
        defer { ArtworkCache.clearTask(for: "disk:\(albumId)") }

        if let diskImage = await diskTask.value {
            await MainActor.run {
                guard self.albumId == albumId else { return }
                artworkImage = diskImage
            }
            return
        }

        guard let mediaClient else { return }

        let task = ArtworkCache.imageTask(for: albumId) {
            Task.detached(priority: .background) {
                guard let data = try? await mediaClient.artwork(albumId: albumId) else {
                    return nil
                }
                #if canImport(UIKit)
                return UIImage(data: data)
                #elseif canImport(AppKit)
                return NSImage(data: data)
                #endif
            }
        }
        defer { ArtworkCache.clearTask(for: albumId) }

        if let platformImage = await task.value {
            ArtworkCache.setImage(platformImage, for: albumId)
            await MainActor.run {
                guard self.albumId == albumId else { return }
                artworkImage = platformImage
            }
        }
    }
}
