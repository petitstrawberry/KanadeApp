import SwiftUI

enum LibrarySection: String, CaseIterable, Hashable {
    case albums, artists, genres, playlists

    var title: String {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .playlists: "Playlists"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .playlists: "music.note.list"
        }
    }
}

enum SidebarItem: Hashable {
    case library(LibrarySection)
    case nodes, settings

    static var allCases: [SidebarItem] {
        LibrarySection.allCases.map { .library($0) }
            + [.nodes, .settings]
    }

    var title: String {
        switch self {
        case .library(let section): section.title
        case .nodes: "Nodes"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library(let section): section.systemImage
        case .nodes: "speaker.wave.2"
        case .settings: "gearshape"
        }
    }

    var isLibrary: Bool {
        switch self {
        case .library: true
        case .nodes, .settings: false
        }
    }
}
