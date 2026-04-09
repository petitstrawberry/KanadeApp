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
    static let fileManager = FileManager.default

    static var cacheDirectoryURL: URL {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = baseURL.appendingPathComponent("KanadeArtwork", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    static func cacheFileURL(for albumId: String) -> URL {
        cacheDirectoryURL.appendingPathComponent(albumId).appendingPathExtension("img")
    }

    static func image(for albumId: String) -> PlatformImage? {
        shared.object(forKey: albumId as NSString)?.image
    }

    static func loadImageFromDisk(for albumId: String) -> PlatformImage? {
        guard let data = try? Data(contentsOf: cacheFileURL(for: albumId)) else {
            return nil
        }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        #endif
        shared.setObject(PlatformImageWrapper(image), forKey: albumId as NSString)
        return image
    }

    static func setImage(_ image: PlatformImage, for albumId: String) {
        shared.setObject(PlatformImageWrapper(image), forKey: albumId as NSString)
        persistImageToDisk(image, for: albumId)
    }

    private static func persistImageToDisk(_ image: PlatformImage, for albumId: String) {
        let fileURL = cacheFileURL(for: albumId)
        DispatchQueue.global(qos: .utility).async {
            #if canImport(UIKit)
            let data = image.pngData()
            #elseif canImport(AppKit)
            let data = image.tiffRepresentation
            #endif
            if let data {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
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
        if let albumId,
           let cachedArtwork = ArtworkCache.image(for: albumId) {
            return cachedArtwork
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
        guard let albumId else {
            return
        }

        if let cached = ArtworkCache.image(for: albumId) {
            await MainActor.run {
                artworkImage = cached
                loadedAlbumId = albumId
            }
            return
        }

        let diskTask = ArtworkCache.imageTask(for: "disk:\(albumId)") {
            Task.detached(priority: .utility) {
                ArtworkCache.loadImageFromDisk(for: albumId)
            }
        }

        defer {
            ArtworkCache.clearTask(for: "disk:\(albumId)")
        }

        if let diskImage = await diskTask.value {
            await MainActor.run {
                guard self.albumId == albumId else { return }
                artworkImage = diskImage
                loadedAlbumId = albumId
            }
            return
        }

        guard let mediaClient else {
            return
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

        defer {
            ArtworkCache.clearTask(for: albumId)
        }

        if let platformImage = await task.value {
            ArtworkCache.setImage(platformImage, for: albumId)
            await MainActor.run {
                guard self.albumId == albumId else { return }
                artworkImage = platformImage
                loadedAlbumId = albumId
            }
        }
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
