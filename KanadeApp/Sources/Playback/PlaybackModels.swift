import Foundation
import KanadeKit

struct LocalPlaybackSnapshot: Sendable {
    let queue: [Track]
    let currentIndex: Int?
    let currentTrack: Track?
    let status: PlaybackStatus
    let isPlayingLike: Bool
    let positionSecs: Double
    let durationSecs: Double
    let volume: Int
    let repeatMode: RepeatMode
    let shuffleEnabled: Bool
}

struct LocalPlaybackTransportSnapshot: Sendable {
    let positionSecs: Double
    let durationSecs: Double
    let status: PlaybackStatus
    let volume: Int
    let isPlayingLike: Bool
}

struct LocalPlaybackSessionUpdate: Sendable {
    let queue: [Track]
    let currentIndex: Int?
    let transport: LocalPlaybackTransportSnapshot
    let repeatMode: RepeatMode
    let shuffleEnabled: Bool
}

struct LocalPlaybackHandoffState: Sendable {
    let tracks: [Track]
    let currentIndex: Int?
    let positionSecs: Double
    let repeatMode: RepeatMode
    let shuffleEnabled: Bool
}
