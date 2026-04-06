#if os(iOS)
import AVFAudio
import Foundation
import KanadeKit
import MediaPlayer
import UIKit

@MainActor
final class IOSMediaSessionManager {
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()

    private var client: KanadeClient?
    private var mediaClient: MediaClient?
    private var state: PlaybackState?
    private var artworkTask: Task<Void, Never>?
    private var artworkAlbumId: String?
    private var isRegistered = false
    private var lastSnapshot: Snapshot?

    init() {
        configureAudioSession()
        registerRemoteCommandsIfNeeded()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func update(client: KanadeClient?, mediaClient: MediaClient?, state: PlaybackState?) {
        registerRemoteCommandsIfNeeded()
        self.client = client
        self.mediaClient = mediaClient
        self.state = state

        let snapshot = Snapshot(state: state)
        
        let shouldRefreshNowPlaying: Bool
        if let last = lastSnapshot {
            shouldRefreshNowPlaying = !snapshot.isEquivalentForNowPlaying(to: last)
        } else {
            shouldRefreshNowPlaying = true
        }
        
        updateCommandAvailability(snapshot)
        
        if shouldRefreshNowPlaying {
            refreshNowPlayingInfo()
        }
        
        updateArtworkLoading(for: snapshot.track)
        lastSnapshot = snapshot
    }

    private func registerRemoteCommandsIfNeeded() {
        guard !isRegistered else { return }

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self, self.client != nil else { return .commandFailed }
            self.client?.play()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.client != nil else { return .commandFailed }
            self.client?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let client = self.client else { return .commandFailed }
            if Snapshot(state: self.state).isPlaying {
                client.pause()
            } else {
                client.play()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.client != nil else { return .commandFailed }
            self.client?.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.client != nil else { return .commandFailed }
            self.client?.previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let client = self.client,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            client.seek(to: event.positionTime)
            return .success
        }

        isRegistered = true
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
        }
    }

    private func updateCommandAvailability(_ snapshot: Snapshot) {
        let hasTrack = snapshot.track != nil
        commandCenter.playCommand.isEnabled = hasTrack && !snapshot.isPlaying
        commandCenter.pauseCommand.isEnabled = hasTrack && snapshot.isPlaying
        commandCenter.togglePlayPauseCommand.isEnabled = hasTrack
        commandCenter.nextTrackCommand.isEnabled = snapshot.hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = snapshot.hasPreviousTrack
        commandCenter.changePlaybackPositionCommand.isEnabled = snapshot.canSeek
    }

    private func refreshNowPlayingInfo() {
        let snapshot = Snapshot(state: state)
        guard let track = snapshot.track else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            nowPlayingInfoCenter.playbackState = .stopped
            return
        }

        var nowPlayingInfo: [String: Any] = [:]

        if let title = track.title {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        }

        if let artist = track.artist {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }

        if let albumTitle = track.albumTitle {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = albumTitle
        }

        if let duration = track.durationSecs {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(max(snapshot.positionSecs, 0), duration)
        } else {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(snapshot.positionSecs, 0)
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if let albumId = track.albumId,
           let image = ArtworkCache.image(for: albumId) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        nowPlayingInfoCenter.playbackState = snapshot.nowPlayingPlaybackState
    }

    private func updateArtworkLoading(for track: Track?) {
        let nextAlbumId = track?.albumId
        
        if artworkAlbumId != nextAlbumId {
            artworkTask?.cancel()
            artworkTask = nil
            artworkAlbumId = nextAlbumId
        }

        guard let track,
              let albumId = track.albumId,
              ArtworkCache.image(for: albumId) == nil,
              artworkTask == nil,
              let mediaClient else {
            return
        }

        artworkTask = Task { [weak self] in
            guard let self else { return }
            guard let data = try? await mediaClient.artwork(albumId: albumId) else { return }
            guard !Task.isCancelled else { return }
            guard let image = UIImage(data: data) else { return }
            ArtworkCache.setImage(image, for: albumId)
            guard self.artworkAlbumId == albumId else { return }
            self.refreshNowPlayingInfo()
        }
    }

    private struct Snapshot {
        let currentIndex: Int?
        let queueCount: Int
        let track: Track?
        let positionSecs: Double
        let status: PlaybackStatus

        init(state: PlaybackState?) {
            currentIndex = state?.currentIndex
            queueCount = state?.queue.count ?? 0
            guard let state,
                  let currentIndex = state.currentIndex,
                  state.queue.indices.contains(currentIndex) else {
                track = nil
                positionSecs = 0
                status = .stopped
                return
            }

            track = state.queue[currentIndex]
            let node: Node?
            if let selectedNodeId = state.selectedNodeId,
               let selectedNode = state.nodes.first(where: { $0.id == selectedNodeId }) {
                node = selectedNode
            } else {
                node = state.nodes.first(where: \.connected) ?? state.nodes.first
            }
            positionSecs = node?.positionSecs ?? 0
            status = node?.status ?? .stopped
        }

        var isPlaying: Bool {
            status == .playing
        }

        var canSeek: Bool {
            track?.durationSecs != nil
        }

        var hasNextTrack: Bool {
            guard let currentIndex else { return false }
            return currentIndex + 1 < queueCount
        }

        var hasPreviousTrack: Bool {
            guard let currentIndex else { return false }
            return currentIndex > 0
        }

        var nowPlayingPlaybackState: MPNowPlayingPlaybackState {
            switch status {
            case .playing:
                return .playing
            case .paused:
                return .paused
            case .loading:
                return .paused
            case .stopped:
                return .stopped
            }
        }
        
        func isEquivalentForNowPlaying(to other: Snapshot) -> Bool {
            if track?.id != other.track?.id {
                return false
            }
            if track?.title != other.track?.title {
                return false
            }
            if track?.artist != other.track?.artist {
                return false
            }
            if track?.albumTitle != other.track?.albumTitle {
                return false
            }
            if track?.durationSecs != other.track?.durationSecs {
                return false
            }
            if status != other.status {
                return false
            }
            if abs(positionSecs - other.positionSecs) > 2.0 {
                return false
            }
            return true
        }
    }
}
#endif
