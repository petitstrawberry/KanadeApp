import SwiftUI
import KanadeKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
        await MainActor.run {
            artworkImage = nil
        }

        guard let mediaClient, let albumId else {
            return
        }

        do {
            let data = try await mediaClient.artwork(albumId: albumId)

            #if canImport(UIKit)
            if let platformImage = UIImage(data: data) {
                await MainActor.run {
                    artworkImage = Image(uiImage: platformImage)
                }
            }
            #elseif canImport(AppKit)
            if let platformImage = NSImage(data: data) {
                await MainActor.run {
                    artworkImage = Image(nsImage: platformImage)
                }
            }
            #endif
        } catch {
        }
    }
}
