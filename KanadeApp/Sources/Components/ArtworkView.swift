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

    @State private var artworkImage: Image?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let artworkImage {
                    artworkImage
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: albumId) {
                await loadArtwork()
            }
    }

    private func loadArtwork() async {
        guard let mediaClient, let albumId else {
            artworkImage = nil
            return
        }

        if let cached = ArtworkCache.image(for: albumId) {
            #if canImport(UIKit)
            artworkImage = Image(uiImage: cached)
            #elseif canImport(AppKit)
            artworkImage = Image(nsImage: cached)
            #endif
            return
        }

        artworkImage = nil

        let task = ArtworkCache.imageTask(for: albumId) {
            Task<PlatformImage?, Never> {
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
            #if canImport(UIKit)
            artworkImage = Image(uiImage: platformImage)
            #elseif canImport(AppKit)
            artworkImage = Image(nsImage: platformImage)
            #endif
        }

        ArtworkCache.clearTask(for: albumId)
    }
}
