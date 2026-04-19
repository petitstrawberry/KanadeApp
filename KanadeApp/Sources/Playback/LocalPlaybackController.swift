import Foundation
import Observation
import KanadeKit

#if DEBUG
private let localPlaybackLogDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func localPlaybackDebugLog(_ message: @autoclosure () -> String) {
    print("[LocalPlaybackController][\(localPlaybackLogDateFormatter.string(from: Date()))] \(message())")
}
#endif

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

@MainActor
@Observable
final class LocalPlaybackController {
    private let avRenderer: AVQueuePlayerRenderer
    private let sfbRenderer = SFBPlaybackRenderer()
    private let queue: LocalQueue
    private let nowPlayingManager: NowPlayingManager

    private var renderer: any AudioRenderer { currentTrackIsFLAC ? sfbRenderer : avRenderer }

    @ObservationIgnored private var mediaClient: MediaClient?
    @ObservationIgnored private var updateTimer: Task<Void, Never>?
    @ObservationIgnored private var currentTrackLoadTask: Task<Void, Never>?
    @ObservationIgnored private var nextTrackPreloadTask: Task<Void, Never>?
    @ObservationIgnored private var cachedArtworkAlbumId: String?
    @ObservationIgnored private var cachedArtworkData: Data?
    @ObservationIgnored private var pendingSeekAfterLoad: Double?
    @ObservationIgnored private var playbackIntentIsPlaying = false

    private var currentTrackIsFLAC = false

    @ObservationIgnored var onSnapshotChanged: ((LocalPlaybackSnapshot) -> Void)?

    var isPlaying: Bool { renderer.state.status == .playing }
    var currentTrack: Track? { queue.currentTrack }
    var positionSecs: Double { renderer.state.positionSecs }
    var durationSecs: Double { renderer.state.durationSecs }
    var volume: Int { renderer.state.volume }
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

    init(mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        self.avRenderer = AVQueuePlayerRenderer()
        self.queue = LocalQueue()
        self.nowPlayingManager = NowPlayingManager()

        self.avRenderer.mediaClient = mediaClient

        nowPlayingManager.configureAudioSession()
        bindRenderers()
        configureCommandHandlers()
        publishCommittedNowPlaying()
        startUpdateTimer()
    }

    func updateMediaClient(_ mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        avRenderer.mediaClient = mediaClient
    }

    deinit {
        updateTimer?.cancel()
        currentTrackLoadTask?.cancel()
        nextTrackPreloadTask?.cancel()
    }

    func playTracks(_ tracks: [Track], startIndex: Int = 0) {
        startUpdateTimer()
        queue.setTracks(tracks, startIndex: startIndex)
        loadCurrentTrack(autoplay: true)
    }

    func play() {
        startUpdateTimer()
        playbackIntentIsPlaying = true
        nowPlayingManager.setAudioSessionActive(true)
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
        emitStateUpdate()
        publishTransportNowPlaying()
        debugLogAction("play()")
    }

    func pause() {
        playbackIntentIsPlaying = false
        renderer.pause()
        emitStateUpdate()
        publishTransportNowPlaying()
        debugLogAction("pause()")
    }

    func stop() {
        playbackIntentIsPlaying = false
        updateTimer?.cancel()
        currentTrackLoadTask?.cancel()
        nextTrackPreloadTask?.cancel()
        pendingSeekAfterLoad = nil
        avRenderer.stop()
        sfbRenderer.stop()
        nowPlayingManager.clearNowPlaying()
        emitStateUpdate()
    }

    func seek(to positionSecs: Double) {
        renderer.seek(to: positionSecs)
        emitStateUpdate()
        publishTransportNowPlaying()
        debugLogAction("seek(to: \(positionSecs))")
    }

    func setVolume(_ volume: Int) {
        renderer.setVolume(volume)
        publishCommittedNowPlaying()
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
        publishCommittedNowPlaying()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        preloadNextTrack()
        publishCommittedNowPlaying()
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        if currentTrack == nil {
            queue.jumpToIndex(0)
            loadCurrentTrack(autoplay: false)
        } else {
            preloadNextTrack()
            publishCommittedNowPlaying()
        }
    }

    func addTracksToQueue(_ tracks: [Track]) {
        let hadCurrentTrack = currentTrack != nil
        queue.append(contentsOf: tracks)
        if !hadCurrentTrack, currentTrack != nil {
            loadCurrentTrack(autoplay: false)
        } else {
            preloadNextTrack()
            publishCommittedNowPlaying()
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
            publishCommittedNowPlaying()
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
        publishCommittedNowPlaying()
    }

    func importFromServer(tracks: [Track], index: Int?, positionSecs: Double?) {
        startUpdateTimer()
        queue.importQueue(tracks: tracks, index: index, positionSecs: positionSecs)

        guard currentTrack != nil else {
            stop()
            return
        }

        pendingSeekAfterLoad = positionSecs
        loadCurrentTrack(autoplay: false)
        publishCommittedNowPlaying()
    }

    func exportForHandoff() -> (tracks: [Track], index: Int?, positionSecs: Double) {
        let snapshot = snapshot
        return (tracks: snapshot.queue, index: snapshot.currentIndex, positionSecs: snapshot.positionSecs)
    }

    private func bindRenderers() {
        bindRenderer(avRenderer, isFLACRenderer: false)
        bindRenderer(sfbRenderer, isFLACRenderer: true)
    }

    private func bindRenderer<Renderer: AudioRenderer>(_ renderer: Renderer, isFLACRenderer: Bool) {
        renderer.onStateChanged = { [weak self] _ in
            guard let self else { return }
            guard self.currentTrackIsFLAC == isFLACRenderer else { return }

            self.debugLogRendererStateChange(
                source: isFLACRenderer ? "SFB" : "AVQueue",
                rendererState: renderer.state
            )

            if let pendingSeekAfterLoad = self.pendingSeekAfterLoad,
               renderer.state.status != .loading,
               renderer.state.durationSecs > 0 {
                self.pendingSeekAfterLoad = nil
                renderer.seek(to: pendingSeekAfterLoad)
            }

            self.emitStateUpdate()
        }

        renderer.onTrackAdvanced = { [weak self] in
            guard let self else { return }
            guard self.currentTrackIsFLAC == isFLACRenderer else { return }
            guard self.queue.advance() else {
                self.stop()
                return
            }
            self.preloadNextTrack()
            self.emitStateUpdate()
            self.publishCommittedNowPlaying()
        }

        renderer.onTrackFinished = { [weak self] in
            guard let self else { return }
            guard self.currentTrackIsFLAC == isFLACRenderer else { return }
            guard self.queue.advance() else {
                self.stop()
                return
            }
            self.loadCurrentTrack(autoplay: true)
        }
    }

    private func configureCommandHandlers() {
        nowPlayingManager.setPlaybackHandlers(
            onPlay: { [weak self] in self?.play() },
            onPause: { [weak self] in self?.pause() },
            onNext: { [weak self] in self?.next() },
            onPrevious: { [weak self] in self?.previous() },
            onSeek: { [weak self] position in
                self?.seek(to: position)
            }
        )
    }

    private func loadCurrentTrack(autoplay: Bool) {
        guard let currentTrack, let mediaClient else {
            stop()
            return
        }

        playbackIntentIsPlaying = autoplay
        if autoplay {
            nowPlayingManager.setAudioSessionActive(true)
        }
        startUpdateTimer()
        currentTrackLoadTask?.cancel()
        nextTrackPreloadTask?.cancel()

        let track = currentTrack
        let isCurrentTrackFLAC = isFLAC(track)
        currentTrackIsFLAC = isCurrentTrackFLAC

        if isCurrentTrackFLAC {
            avRenderer.stop()
        } else {
            sfbRenderer.stop()
        }

        currentTrackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let url = try await self.playbackURL(for: track, mediaClient: mediaClient)
                guard self.currentTrack?.id == track.id else { return }

                if isCurrentTrackFLAC {
                    self.sfbRenderer.loadTrack(url: url, autoplay: autoplay)
                } else {
                    self.avRenderer.loadTrack(url: url, autoplay: autoplay)
                }

                self.preloadNextTrack()
                self.emitStateUpdate()
                self.publishCommittedNowPlaying()
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
                if self.isFLAC(nextTrack) {
                    self.sfbRenderer.prepareNext(url: url)
                } else {
                    self.avRenderer.prepareNext(url: url)
                }
            } catch {
            }
        }
    }

    private func playbackURL(for track: Track, mediaClient: MediaClient) async throws -> URL {
        try await mediaClient.signedTrackURL(trackId: track.id)
    }

    private func isFLAC(_ track: Track) -> Bool {
        track.format?.localizedCaseInsensitiveCompare("flac") == .orderedSame
    }

    private func publishCommittedNowPlaying() {
        publishNowPlaying(fetchArtwork: true)
    }

    private func publishTransportNowPlaying() {
        publishNowPlaying(fetchArtwork: false)
    }

    private func publishNowPlaying(fetchArtwork: Bool) {
        let snapshot = snapshot
        let playbackRate = snapshot.status == .playing ? 1.0 : 0.0

        let artwork: Data?
        if let albumId = currentTrack?.albumId, albumId == cachedArtworkAlbumId {
            artwork = cachedArtworkData
        } else {
            artwork = nil
            cachedArtworkAlbumId = nil
            cachedArtworkData = nil
        }

        nowPlayingManager.updateNowPlaying(
            track: snapshot.currentTrack,
            artworkData: artwork,
            duration: snapshot.durationSecs,
            position: snapshot.positionSecs,
            playbackRate: playbackRate,
            status: snapshot.status,
            isPlayingLike: snapshot.isPlayingLike
        )

        nowPlayingManager.handlePlaybackStateTransition(
            status: snapshot.status,
            isPlayingLike: snapshot.isPlayingLike
        )

        debugLogNowPlayingPublish(snapshot: snapshot, playbackRate: playbackRate, fetchArtwork: fetchArtwork)

        if fetchArtwork {
            fetchArtworkIfNeeded()
        }
    }

    private func fetchArtworkIfNeeded() {
        guard let albumId = currentTrack?.albumId,
              albumId != cachedArtworkAlbumId,
              let mediaClient
        else { return }

        let albumIdCopy = albumId
        Task { @MainActor in
            guard let data = try? await mediaClient.artwork(albumId: albumIdCopy),
                  !data.isEmpty
            else { return }
            cachedArtworkAlbumId = albumIdCopy
            cachedArtworkData = data
            self.publishCommittedNowPlaying()
        }
    }

    private func startUpdateTimer() {
        updateTimer?.cancel()
        updateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard let self else { return }
                guard self.isPlaying || self.renderer.state.status != .stopped else { continue }
                self.emitStateUpdate()
                self.publishTransportNowPlaying()
            }
        }
    }

    private func emitStateUpdate() {
        onSnapshotChanged?(snapshot)
        debugLogSnapshotEmission(snapshot)
    }

    private func debugLogAction(_ action: String) {
#if DEBUG
        let snapshot = snapshot
        let trackID = snapshot.currentTrack?.id ?? "nil"
        localPlaybackDebugLog(
            "action=\(action) flac=\(currentTrackIsFLAC) rendererStatus=\(renderer.state.status.rawValue) snapshotStatus=\(snapshot.status.rawValue) isPlayingLike=\(snapshot.isPlayingLike) position=\(snapshot.positionSecs) duration=\(snapshot.durationSecs) track=\(trackID)"
        )
#endif
    }

    private func debugLogRendererStateChange(source: String, rendererState: RendererState) {
#if DEBUG
        let trackID = currentTrack?.id ?? "nil"
        localPlaybackDebugLog(
            "renderer=\(source) stateChanged flac=\(currentTrackIsFLAC) rendererStatus=\(rendererState.status.rawValue) rendererPosition=\(rendererState.positionSecs) rendererDuration=\(rendererState.durationSecs) playbackIntentIsPlaying=\(playbackIntentIsPlaying) pendingSeekAfterLoad=\(String(describing: pendingSeekAfterLoad)) track=\(trackID)"
        )
#endif
    }

    private func debugLogNowPlayingPublish(snapshot: LocalPlaybackSnapshot, playbackRate: Double, fetchArtwork: Bool) {
#if DEBUG
        let trackID = snapshot.currentTrack?.id ?? "nil"
        localPlaybackDebugLog(
            "publishNowPlaying fetchArtwork=\(fetchArtwork) flac=\(currentTrackIsFLAC) status=\(snapshot.status.rawValue) isPlayingLike=\(snapshot.isPlayingLike) position=\(snapshot.positionSecs) duration=\(snapshot.durationSecs) playbackRate=\(playbackRate) track=\(trackID)"
        )
#endif
    }

    private func debugLogSnapshotEmission(_ snapshot: LocalPlaybackSnapshot) {
#if DEBUG
        let trackID = snapshot.currentTrack?.id ?? "nil"
        localPlaybackDebugLog(
            "emitStateUpdate flac=\(currentTrackIsFLAC) status=\(snapshot.status.rawValue) isPlayingLike=\(snapshot.isPlayingLike) position=\(snapshot.positionSecs) duration=\(snapshot.durationSecs) track=\(trackID)"
        )
#endif
    }
}
