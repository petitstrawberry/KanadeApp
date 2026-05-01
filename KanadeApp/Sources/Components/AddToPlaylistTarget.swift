import Foundation

struct AddToPlaylistTarget: Identifiable {
    let id = UUID()
    let trackIds: [String]
}
