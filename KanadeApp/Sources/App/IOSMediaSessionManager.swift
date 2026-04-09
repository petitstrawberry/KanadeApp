#if os(iOS) || os(macOS)
#if os(iOS)
import AVFAudio
#endif
import Foundation
import KanadeKit
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class IOSMediaSessionManager {
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()

    private var client: KanadeClient?
    private var mediaClient: MediaClient?
    private var state: PlaybackState?
    private var effectiveCurrentTrack: Track?
    private var effectiveTransportState: AppState.EffectiveTransportState?
    private var isLocalPlaybackNode = false
    private var artworkTask: Task<Void, Never>?
    private var artworkAlbumId: String?
    private var isRegistered = false
    private var lastSnapshot: Snapshot?

    var performPlay: (() -> Void)?
    var performPause: (() -> Void)?
    var performSeek: ((Double) -> Void)?
    var performSetVolume: ((Int) -> Void)?
    var performNext: (() -> Void)?
    var performPrevious: (() -> Void)?

    init() {
        configureAudioSession()
        registerRemoteCommandsIfNeeded()
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    func update(
        client: KanadeClient?,
        mediaClient: MediaClient?,
        state: PlaybackState?,
        effectiveTransportState: AppState.EffectiveTransportState?,
        isLocalPlaybackNode: Bool
    ) {
        update(
            client: client,
            mediaClient: mediaClient,
            state: state,
            effectiveCurrentTrack: nil,
            effectiveTransportState: effectiveTransportState,
            isLocalPlaybackNode: isLocalPlaybackNode
        )
    }

    func update(
        client: KanadeClient?,
        mediaClient: MediaClient?,
        state: PlaybackState?,
        effectiveCurrentTrack: Track?,
        effectiveTransportState: AppState.EffectiveTransportState?,
        isLocalPlaybackNode: Bool
    ) {
        registerRemoteCommandsIfNeeded()
        self.client = client
        self.mediaClient = mediaClient
        self.state = state
        self.effectiveCurrentTrack = effectiveCurrentTrack
        self.effectiveTransportState = effectiveTransportState
        self.isLocalPlaybackNode = isLocalPlaybackNode

        let snapshot = Snapshot(
            state: state,
            effectiveCurrentTrack: effectiveCurrentTrack,
            effectiveTransportState: effectiveTransportState,
            isLocalPlaybackNode: isLocalPlaybackNode,
            previousSnapshot: lastSnapshot
        )
        
        let shouldRefreshNowPlaying: Bool
        if let last = lastSnapshot {
            shouldRefreshNowPlaying = !snapshot.isEquivalentForNowPlaying(to: last)
        } else {
            shouldRefreshNowPlaying = true
        }
        
        updateCommandAvailability(snapshot)

        refreshTransportState(snapshot: snapshot)

        if shouldRefreshNowPlaying {
            refreshNowPlayingInfo(snapshot: snapshot)
        }
        
        updateArtworkLoading(for: snapshot.track)
        lastSnapshot = snapshot
    }

    func invalidateSnapshotCache() {
        lastSnapshot = nil
    }

    private func registerRemoteCommandsIfNeeded() {
        guard !isRegistered else { return }

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard let performPlay = self.performPlay else { return .commandFailed }
            performPlay()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            guard let performPause = self.performPause else { return .commandFailed }
            performPause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            let willPlay = !(self.lastSnapshot?.isPlayingLike ?? false)
            if willPlay {
                guard let performPlay = self.performPlay else { return .commandFailed }
                performPlay()
            } else {
                guard let performPause = self.performPause else { return .commandFailed }
                performPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isLocalPlaybackNode, let performNext = self.performNext {
                performNext()
                return .success
            }
            guard let client = self.client else { return .commandFailed }
            client.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isLocalPlaybackNode, let performPrevious = self.performPrevious {
                performPrevious()
                return .success
            }
            guard let client = self.client else { return .commandFailed }
            client.previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let performSeek = self.performSeek,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            performSeek(event.positionTime)
            return .success
        }

        isRegistered = true
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
        }
        #endif
    }

    private func updateCommandAvailability(_ snapshot: Snapshot) {
        let hasTrack = snapshot.track != nil
        let localCanSkipForward = hasTrack && (performNext != nil || client != nil)
        let localCanSkipBackward = hasTrack && (performPrevious != nil || client != nil)
        commandCenter.playCommand.isEnabled = hasTrack && !snapshot.isPlayingLike
        commandCenter.pauseCommand.isEnabled = hasTrack && snapshot.isPlayingLike
        commandCenter.togglePlayPauseCommand.isEnabled = hasTrack
        commandCenter.nextTrackCommand.isEnabled = isLocalPlaybackNode ? localCanSkipForward : snapshot.hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = isLocalPlaybackNode ? localCanSkipBackward : snapshot.hasPreviousTrack
        commandCenter.changePlaybackPositionCommand.isEnabled = snapshot.canSeek
    }

    private func refreshNowPlayingInfo(snapshot: Snapshot) {
        guard let track = snapshot.track else {
            guard snapshot.shouldClearNowPlayingInfo else {
                return
            }
            nowPlayingInfoCenter.nowPlayingInfo = nil
            nowPlayingInfoCenter.playbackState = .stopped
            return
        }

        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [:]

        if let title = track.title {
            nowPlayingInfo[MPMediaItemPropertyTitle] = title
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyTitle)
        }

        if let artist = track.artist {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }

        if let albumTitle = track.albumTitle {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = albumTitle
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }

        if let duration = track.durationSecs {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = min(max(snapshot.positionSecs, 0), duration)
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(snapshot.positionSecs, 0)
        }

        if let albumId = track.albumId,
           let image = ArtworkCache.image(for: albumId) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else {
            if !snapshot.shouldPreserveArtwork {
                nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
            }
        }

        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        refreshTransportState(snapshot: snapshot)
    }

    private func refreshTransportState(snapshot: Snapshot) {
        guard !snapshot.shouldClearNowPlayingInfo else {
            nowPlayingInfoCenter.playbackState = .stopped
            return
        }

        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(snapshot.positionSecs, 0)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = snapshot.isPlayingLike ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
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
            guard let image = PlatformImage(data: data) else { return }
            ArtworkCache.setImage(image, for: albumId)
            guard self.artworkAlbumId == albumId else { return }
            let snapshot = Snapshot(
                state: self.state,
                effectiveCurrentTrack: self.effectiveCurrentTrack,
                effectiveTransportState: self.effectiveTransportState,
                isLocalPlaybackNode: self.isLocalPlaybackNode,
                previousSnapshot: self.lastSnapshot
            )
            self.refreshNowPlayingInfo(snapshot: snapshot)
        }
    }

    private struct Snapshot {
        let currentIndex: Int?
        let queueCount: Int
        let track: Track?
        let positionSecs: Double
        let status: PlaybackStatus
        let shouldClearNowPlayingInfo: Bool
        let shouldPreserveArtwork: Bool

        init(
            state: PlaybackState?,
            effectiveCurrentTrack: Track?,
            effectiveTransportState: AppState.EffectiveTransportState?,
            isLocalPlaybackNode: Bool,
            previousSnapshot: Snapshot?
        ) {
            if isLocalPlaybackNode {
                currentIndex = nil
                queueCount = 0
            } else {
                currentIndex = state?.currentIndex
                queueCount = state?.queue.count ?? 0
            }
            let serverTrack: Track?
            if let state,
               let currentIndex = state.currentIndex,
               state.queue.indices.contains(currentIndex) {
                serverTrack = state.queue[currentIndex]
            } else {
                serverTrack = nil
            }

            if isLocalPlaybackNode {
                track = effectiveCurrentTrack ?? previousSnapshot?.track
            } else {
                track = serverTrack
            }

            shouldClearNowPlayingInfo = !isLocalPlaybackNode && track == nil
            if isLocalPlaybackNode {
                if let albumId = track?.albumId {
                    shouldPreserveArtwork = ArtworkCache.image(for: albumId) == nil
                } else {
                    shouldPreserveArtwork = true
                }
            } else {
                shouldPreserveArtwork = false
            }

            let node: Node?
            if let selectedNodeId = state?.selectedNodeId,
               let selectedNode = state?.nodes.first(where: { $0.id == selectedNodeId }) {
                node = selectedNode
            } else {
                node = state?.nodes.first(where: \.connected) ?? state?.nodes.first
            }

            if isLocalPlaybackNode, let effectiveTransportState {
                positionSecs = effectiveTransportState.positionSecs
                status = Self.playbackStatus(for: effectiveTransportState.status)
            } else if isLocalPlaybackNode, let previousSnapshot {
                positionSecs = previousSnapshot.positionSecs
                status = previousSnapshot.status
            } else {
                positionSecs = node?.positionSecs ?? 0
                status = node?.status ?? .stopped
            }
        }

        var isPlayingLike: Bool {
            switch status {
            case .playing, .loading:
                return true
            case .paused, .stopped:
                return false
            }
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
                return .playing
            case .stopped:
                return .stopped
            }
        }

        private static func playbackStatus(for status: NodePlaybackStatus) -> PlaybackStatus {
            switch status {
            case .playing:
                return .playing
            case .paused:
                return .paused
            case .loading:
                return .loading
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
