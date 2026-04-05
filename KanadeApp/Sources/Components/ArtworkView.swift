import SwiftUI
import KanadeKit
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

enum ArtworkCache {
    static let shared: NSCache<NSString, PlatformImageWrapper> = {
        let cache = NSCache<NSString, PlatformImageWrapper>()
        cache.countLimit = 200
        return cache
    }()
    static var tasks: [String: Task<PlatformImage?, Never>] = [:]
    static let lock = NSLock()

    static func image(for albumId: String) -> PlatformImage? {
        shared.object(forKey: albumId as NSString)?.image
    }

    static func setImage(_ image: PlatformImage, for albumId: String) {
        shared.setObject(PlatformImageWrapper(image), forKey: albumId as NSString)
    }

    static func imageTask(
        for albumId: String,
        create: () -> Task<PlatformImage?, Never>
    ) -> Task<PlatformImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = tasks[albumId] {
            return existing
        }
        let task = create()
        tasks[albumId] = task
        return task
    }

    static func clearTask(for albumId: String) {
        lock.lock()
        defer { lock.unlock() }
        tasks[albumId] = nil
    }
}

final class PlatformImageWrapper: NSObject {
    let image: PlatformImage
    init(_ image: PlatformImage) { self.image = image }
}

struct ArtworkView: View {
    let mediaClient: MediaClient?
    let albumId: String?

    @State private var artworkImage: PlatformImage?
    @State private var loadedAlbumId: String?

    private var displayedArtworkImage: PlatformImage? {
        if let artworkImage {
            return artworkImage
        }

        guard let albumId else {
            return nil
        }

        return ArtworkCache.image(for: albumId)
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
                if let displayedArtworkImage {
                    renderedArtworkImage(displayedArtworkImage)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: taskKey) {
                await loadArtwork()
            }
    }

    private func loadArtwork() async {
        guard let mediaClient, let albumId else {
            await MainActor.run {
                artworkImage = nil
                loadedAlbumId = nil
            }
            return
        }

        if let cached = ArtworkCache.image(for: albumId) {
            await MainActor.run {
                artworkImage = cached
                loadedAlbumId = albumId
            }
            return
        }

        if loadedAlbumId != albumId {
            await MainActor.run {
                artworkImage = nil
            }
        }

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

        if let platformImage = await task.value {
            ArtworkCache.setImage(platformImage, for: albumId)
            await MainActor.run {
                artworkImage = platformImage
                loadedAlbumId = albumId
            }
        }

        ArtworkCache.clearTask(for: albumId)
    }

    @ViewBuilder
    private func renderedArtworkImage(_ artworkImage: PlatformImage) -> some View {
        #if canImport(UIKit)
        Image(uiImage: artworkImage)
            .resizable()
            .scaledToFill()
        #elseif canImport(AppKit)
        Image(nsImage: artworkImage)
            .resizable()
            .scaledToFill()
        #endif
    }
}
