import Foundation
import Observation
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

@MainActor
final class PlaybackCore {
    private let renderer: UnifiedPlaybackRenderer
    private let queue: LocalQueue

    @ObservationIgnored var onSnapshotChanged: ((LocalPlaybackSnapshot) -> Void)?

    @ObservationIgnored private var mediaClient: MediaClient?
    @ObservationIgnored private var currentTrackLoadTask: Task<Void, Never>?
    @ObservationIgnored private var nextTrackPreloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeekAfterLoad: Double?
    @ObservationIgnored private var playbackIntentIsPlaying = false

    var isPlaying: Bool { renderer.state.status == .playing }
    var queuedTracks: [Track] { queue.tracks }
    var currentIndex: Int? { queue.currentIndex }
    var currentTrack: Track? { queue.currentTrack }
    var positionSecs: Double { renderer.state.positionSecs }
    var durationSecs: Double { renderer.state.durationSecs }
    var volume: Int { renderer.state.volume }
    var repeatMode: RepeatMode { queue.repeatMode }
    var shuffleEnabled: Bool { queue.shuffleEnabled }
    var snapshot: LocalPlaybackSnapshot {
        let status = renderer.state.status
        return LocalPlaybackSnapshot(
            queue: queue.tracks,
            currentIndex: queue.currentIndex,
            currentTrack: queue.currentTrack,
            status: status,
            isPlayingLike: status == .playing || (status == .loading && playbackIntentIsPlaying),
            positionSecs: renderer.state.positionSecs,
            durationSecs: max(renderer.state.durationSecs, queue.currentTrack?.durationSecs ?? 0),
            volume: renderer.state.volume,
            repeatMode: queue.repeatMode,
            shuffleEnabled: queue.shuffleEnabled
        )
    }
    var transportSnapshot: LocalPlaybackTransportSnapshot {
        let snapshot = snapshot
        return LocalPlaybackTransportSnapshot(
            positionSecs: snapshot.positionSecs,
            durationSecs: snapshot.durationSecs,
            status: snapshot.status,
            volume: snapshot.volume,
            isPlayingLike: snapshot.isPlayingLike
        )
    }
    var sessionUpdate: LocalPlaybackSessionUpdate {
        let snapshot = snapshot
        return LocalPlaybackSessionUpdate(
            queue: snapshot.queue,
            currentIndex: snapshot.currentIndex,
            transport: transportSnapshot,
            repeatMode: snapshot.repeatMode,
            shuffleEnabled: snapshot.shuffleEnabled
        )
    }
    var handoffState: LocalPlaybackHandoffState {
        let snapshot = snapshot
        return LocalPlaybackHandoffState(
            tracks: snapshot.queue,
            currentIndex: snapshot.currentIndex,
            positionSecs: snapshot.positionSecs,
            repeatMode: snapshot.repeatMode,
            shuffleEnabled: snapshot.shuffleEnabled
        )
    }

    init(mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        self.renderer = UnifiedPlaybackRenderer()
        self.queue = LocalQueue()

        renderer.mediaClient = mediaClient
        bindRenderer()
    }

    deinit {
        currentTrackLoadTask?.cancel()
        nextTrackPreloadTask?.cancel()
    }

    func updateMediaClient(_ mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        renderer.mediaClient = mediaClient
    }

    func playTracks(_ tracks: [Track], startIndex: Int = 0) {
        queue.setTracks(tracks, startIndex: startIndex)
        loadCurrentTrack(autoplay: true)
    }

    func play() {
        playbackIntentIsPlaying = true

        if currentTrack == nil, !queue.tracks.isEmpty {
            queue.jumpToIndex(queue.currentIndex ?? 0)
            loadCurrentTrack(autoplay: true)
            return
        }

        if renderer.state.status == .stopped, currentTrack != nil {
            loadCurrentTrack(autoplay: true)
            return
        }

        renderer.play()
        emitSnapshotChange()
    }

    func pause() {
        playbackIntentIsPlaying = false
        renderer.pause()
        emitSnapshotChange()
    }

    func stop() {
        playbackIntentIsPlaying = false
        currentTrackLoadTask?.cancel()
        nextTrackPreloadTask?.cancel()
        pendingSeekAfterLoad = nil
        renderer.stop()
        emitSnapshotChange()
    }

    func seek(to positionSecs: Double) {
        renderer.seek(to: positionSecs)
        emitSnapshotChange()
    }

    func setVolume(_ volume: Int) {
        renderer.setVolume(volume)
    }

    func next() {
        guard queue.advance() else {
            stop()
            return
        }
        loadCurrentTrack(autoplay: true)
    }

    func previous() {
        if renderer.state.positionSecs > 3 {
            seek(to: 0)
            return
        }

        guard queue.goBack() else {
            seek(to: 0)
            return
        }
        loadCurrentTrack(autoplay: true)
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.setRepeat(mode)
        emitSnapshotChange()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        preloadNextTrack()
        emitSnapshotChange()
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        if currentTrack == nil {
            queue.jumpToIndex(0)
            loadCurrentTrack(autoplay: false)
        } else {
            preloadNextTrack()
            emitSnapshotChange()
        }
    }

    func addTracksToQueue(_ tracks: [Track]) {
        let hadCurrentTrack = currentTrack != nil
        queue.append(contentsOf: tracks)
        if !hadCurrentTrack, currentTrack != nil {
            loadCurrentTrack(autoplay: false)
        } else {
            preloadNextTrack()
            emitSnapshotChange()
        }
    }

    func removeFromQueue(_ index: Int) {
        let previousTrackId = currentTrack?.id
        let shouldAutoplay = renderer.state.status == .playing || renderer.state.status == .loading

        queue.remove(at: index)

        guard let currentTrack else {
            stop()
            return
        }

        if currentTrack.id != previousTrackId {
            loadCurrentTrack(autoplay: shouldAutoplay)
        } else {
            preloadNextTrack()
            emitSnapshotChange()
        }
    }

    func clearQueue() {
        queue.clear()
        stop()
    }

    func jumpToIndex(_ index: Int) {
        queue.jumpToIndex(index)
        loadCurrentTrack(autoplay: true)
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        queue.move(from: sourceIndex, to: destinationIndex)
        preloadNextTrack()
        emitSnapshotChange()
    }

    func importFromServer(tracks: [Track], index: Int?, positionSecs: Double?) {
        queue.importQueue(tracks: tracks, index: index, positionSecs: positionSecs)

        guard currentTrack != nil else {
            stop()
            return
        }

        pendingSeekAfterLoad = positionSecs
        loadCurrentTrack(autoplay: false)
    }

    func exportForHandoff() -> (tracks: [Track], index: Int?, positionSecs: Double) {
        let snapshot = snapshot
        return (tracks: snapshot.queue, index: snapshot.currentIndex, positionSecs: snapshot.positionSecs)
    }

    private func bindRenderer() {
        renderer.onStateChanged = { [weak self] rendererState in
            guard let self else { return }

            if let pendingSeekAfterLoad = self.pendingSeekAfterLoad,
               rendererState.status != .loading,
               rendererState.durationSecs > 0 {
                self.pendingSeekAfterLoad = nil
                self.renderer.seek(to: pendingSeekAfterLoad)
            }

            self.emitSnapshotChange()
        }

        renderer.onTrackAdvanced = { [weak self] in
            guard let self else { return }
            guard self.queue.advance() else {
                self.stop()
                return
            }
            self.preloadNextTrack()
            self.emitSnapshotChange()
        }

        renderer.onTrackFinished = { [weak self] in
            guard let self else { return }
            guard self.queue.advance() else {
                self.stop()
                return
            }
            self.loadCurrentTrack(autoplay: true)
        }
    }

    private func loadCurrentTrack(autoplay: Bool) {
        guard let currentTrack, let mediaClient else {
            stop()
            return
        }

        playbackIntentIsPlaying = autoplay
        currentTrackLoadTask?.cancel()
        nextTrackPreloadTask?.cancel()

        let track = currentTrack
        currentTrackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let url = try await self.playbackURL(for: track, mediaClient: mediaClient)
                guard self.currentTrack?.id == track.id else { return }

                self.renderer.loadTrack(url: url, autoplay: autoplay)
                self.preloadNextTrack()
                self.emitSnapshotChange()
            } catch {
                guard self.currentTrack?.id == track.id else { return }
                self.stop()
            }
        }
    }

    private func preloadNextTrack() {
        nextTrackPreloadTask?.cancel()

        guard let nextTrack = queue.nextTrack,
              let mediaClient else {
            return
        }

        nextTrackPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let url = try await self.playbackURL(for: nextTrack, mediaClient: mediaClient)
                guard self.queue.nextTrack?.id == nextTrack.id else { return }
                self.renderer.prepareNext(url: url)
            } catch {
            }
        }
    }

    private func playbackURL(for track: Track, mediaClient: MediaClient) async throws -> URL {
        try await mediaClient.signedTrackURL(trackId: track.id)
    }

    private func emitSnapshotChange() {
        onSnapshotChanged?(snapshot)
    }
}
