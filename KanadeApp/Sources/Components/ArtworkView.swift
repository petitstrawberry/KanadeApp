import SwiftUI
import KanadeKit
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, PlatformImageWrapper>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 200 * 1024 * 1024
    }

    func image(for albumId: String) -> PlatformImage? {
        cache.object(forKey: albumId as NSString)?.image
    }

    func setImage(_ image: PlatformImage, for albumId: String) {
        let cost = imageCost(image)
        cache.setObject(PlatformImageWrapper(image), forKey: albumId as NSString, cost: cost)
    }

    private func imageCost(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
        #elseif canImport(AppKit)
        guard let tiffRep = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffRep) else { return 0 }
        return bitmap.bytesPerRow * bitmap.pixelsHigh
        #endif
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
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(false)
            .task(id: albumId) {
                await loadArtwork()
            }
    }

    private func loadArtwork() async {
        artworkImage = nil

        guard let mediaClient, let albumId else {
            return
        }

        if let cached = ArtworkCache.shared.image(for: albumId) {
            #if canImport(UIKit)
            artworkImage = Image(uiImage: cached)
            #elseif canImport(AppKit)
            artworkImage = Image(nsImage: cached)
            #endif
            return
        }

        do {
            let data = try await mediaClient.artwork(albumId: albumId)

            #if canImport(UIKit)
            if let platformImage = UIImage(data: data) {
                ArtworkCache.shared.setImage(platformImage, for: albumId)
                artworkImage = Image(uiImage: platformImage)
            }
            #elseif canImport(AppKit)
            if let platformImage = NSImage(data: data) {
                ArtworkCache.shared.setImage(platformImage, for: albumId)
                artworkImage = Image(nsImage: platformImage)
            }
            #endif
        } catch {
        }
    }
}
