import Foundation
import Observation
import KanadeKit

@MainActor
@Observable
final class LocalPlaybackController {
    private let engine: StreamingPlaybackEngine
    private let queue: LocalQueue
    private let nowPlayingManager: NowPlayingManager

    @ObservationIgnored private var mediaClient: MediaClient?
    @ObservationIgnored private var updateTimer: Task<Void, Never>?
    @ObservationIgnored private var currentTrackLoadTask: Task<Void, Never>?
    @ObservationIgnored private var cachedArtworkAlbumId: String?
    @ObservationIgnored private var cachedArtworkData: Data?
    @ObservationIgnored private var lastSnapshotTrackID: String?

    @ObservationIgnored private var pendingSeekAfterLoad: Double?
    @ObservationIgnored private var playbackIntentIsPlaying = false
    @ObservationIgnored var onSnapshotChanged: ((LocalPlaybackSnapshot) -> Void)? = nil
    @ObservationIgnored private var lastTransportPublishTime: CFAbsoluteTime = 0
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var didPreloadCurrentNext = false

    private var transportState = StreamingTransportState(
        status: .idle,
        positionSecs: 0,
        durationSecs: 0,
        volume: 100
    )

    var isPlaying: Bool { transportPlaybackStatus == .playing }
    var queuedTracks: [Track] { queue.tracks }
    var currentIndex: Int? { queue.currentIndex }
    var currentTrack: Track? { queue.currentTrack }
    var positionSecs: Double { transportState.positionSecs }
    var durationSecs: Double { max(transportState.durationSecs, currentTrack?.durationSecs ?? 0) }
    var volume: Int { transportState.volume }
    var repeatMode: RepeatMode { queue.repeatMode }
    var shuffleEnabled: Bool { queue.shuffleEnabled }
    var snapshot: LocalPlaybackSnapshot {
        let status = transportPlaybackStatus
        return LocalPlaybackSnapshot(
            queue: queue.tracks,
            currentIndex: queue.currentIndex,
            currentTrack: queue.currentTrack,
            status: status,
            isPlayingLike: status == .playing || (status == .loading && playbackIntentIsPlaying),
            positionSecs: transportState.positionSecs,
            durationSecs: max(transportState.durationSecs, queue.currentTrack?.durationSecs ?? 0),
            volume: transportState.volume,
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

    init(mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        self.engine = StreamingPlaybackEngine()
        self.queue = LocalQueue()
        self.nowPlayingManager = NowPlayingManager()

        nowPlayingManager.configureAudioSession()
        bindEngine()
        configureCommandHandlers()
        publishCommittedNowPlaying()
        startUpdateTimer()
    }

    func updateMediaClient(_ mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
    }

    deinit {
        updateTimer?.cancel()
        currentTrackLoadTask?.cancel()
    }

    func playTracks(_ tracks: [Track], startIndex: Int = 0) {
        startUpdateTimer()
        queue.setTracks(tracks, startIndex: startIndex)
        loadCurrentTrack(autoplay: true)
    }

    func play() {
        startUpdateTimer()
        nowPlayingManager.setAudioSessionActive(true)

        playbackIntentIsPlaying = true

        if currentTrack == nil, !queue.tracks.isEmpty {
            queue.jumpToIndex(queue.currentIndex ?? 0)
            loadCurrentTrack(autoplay: true)
            return
        }

        if transportPlaybackStatus == .stopped, currentTrack != nil {
            loadCurrentTrack(autoplay: true)
            return
        }

        engine.play()
        publishTransportNowPlaying()
    }

    func pause() {
        playbackIntentIsPlaying = false
        engine.pause()
        publishTransportNowPlaying()
    }

    func stop() {
        updateTimer?.cancel()
        currentTrackLoadTask?.cancel()
        pendingSeekAfterLoad = nil
        playbackIntentIsPlaying = false
        engine.stop()
        emitSnapshotChange()
        nowPlayingManager.clearNowPlaying()
    }

    func seek(to positionSecs: Double) {
        engine.seek(to: positionSecs)
        publishTransportNowPlaying()
    }

    func setVolume(_ volume: Int) {
        engine.setVolume(volume)
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
        if transportState.positionSecs > 3 {
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
        publishCommittedNowPlaying()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        emitSnapshotChange()
        publishCommittedNowPlaying()
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        if currentTrack == nil {
            queue.jumpToIndex(0)
            loadCurrentTrack(autoplay: false)
        } else {
            emitSnapshotChange()
        }
    }

    func addTracksToQueue(_ tracks: [Track]) {
        let hadCurrentTrack = currentTrack != nil
        queue.append(contentsOf: tracks)
        if !hadCurrentTrack, currentTrack != nil {
            loadCurrentTrack(autoplay: false)
        } else {
            emitSnapshotChange()
        }
    }

    func removeFromQueue(_ index: Int) {
        let previousTrackId = currentTrack?.id
        let shouldAutoplay = transportPlaybackStatus == .playing || transportPlaybackStatus == .loading

        queue.remove(at: index)

        guard let currentTrack else {
            stop()
            return
        }

        if currentTrack.id != previousTrackId {
            loadCurrentTrack(autoplay: shouldAutoplay)
        } else {
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
        emitSnapshotChange()
    }

    func importPlaybackState(tracks: [Track], index: Int?, positionSecs: Double?) {
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

    func importFromServer(tracks: [Track], index: Int?, positionSecs: Double?) {
        importPlaybackState(tracks: tracks, index: index, positionSecs: positionSecs)
    }

    func exportPlaybackState() -> LocalPlaybackHandoffState {
        let snapshot = snapshot
        return LocalPlaybackHandoffState(
            tracks: snapshot.queue,
            currentIndex: snapshot.currentIndex,
            positionSecs: snapshot.positionSecs,
            repeatMode: snapshot.repeatMode,
            shuffleEnabled: snapshot.shuffleEnabled
        )
    }

    func exportForHandoff() -> (tracks: [Track], index: Int?, positionSecs: Double) {
        let handoffState = exportPlaybackState()
        return (tracks: handoffState.tracks, index: handoffState.currentIndex, positionSecs: handoffState.positionSecs)
    }

    private var transportPlaybackStatus: PlaybackStatus {
        switch transportState.status {
        case .idle, .stopped, .error:
            return .stopped
        case .loading:
            return .loading
        case .playing:
            return .playing
        case .paused:
            return .paused
        }
    }

    private func bindEngine() {
        engine.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.handleEngineStateChanged(state)
        }

        engine.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            self.handlePlaybackFinished()
        }

        engine.onTrackAdvanced = { [weak self] in
            guard let self else { return }
            self.handleTrackAdvanced()
        }
    }

    private func handleEngineStateChanged(_ state: StreamingTransportState) {
        transportState = state

        if let pendingSeekAfterLoad,
           transportPlaybackStatus != .loading,
           state.durationSecs > 0 {
            self.pendingSeekAfterLoad = nil
            engine.seek(to: pendingSeekAfterLoad)
        }

        if case .playing = state.status {
            preloadNextTrackIfNeeded()
        }

        if case .error = state.status {
            playbackIntentIsPlaying = false
        }

        emitSnapshotChange()
    }

    private func handlePlaybackFinished() {
        guard queue.advance() else {
            stop()
            return
        }

        loadCurrentTrack(autoplay: true)
    }

    private func handleTrackAdvanced() {
        guard queue.advance() else {
            stop()
            return
        }

        didPreloadCurrentNext = false
        transportState.positionSecs = 0
        transportState.durationSecs = max(queue.currentTrack?.durationSecs ?? 0, 0)
        emitSnapshotChange()
        preloadNextTrackIfNeeded()
    }

    private func handleSnapshotChanged(_ snapshot: LocalPlaybackSnapshot) {
        if snapshot.currentTrack?.id != lastSnapshotTrackID {
            lastSnapshotTrackID = snapshot.currentTrack?.id
            publishCommittedNowPlaying()
        } else {
            publishTransportNowPlaying()
        }

        if snapshot.currentTrack == nil, snapshot.status == .stopped {
            nowPlayingManager.clearNowPlaying()
        }

        onSnapshotChanged?(snapshot)
    }

    private func loadCurrentTrack(autoplay: Bool) {
        guard let currentTrack, let mediaClient else {
            stop()
            return
        }

        playbackIntentIsPlaying = autoplay
        currentTrackLoadTask?.cancel()
        preloadTask?.cancel()
        didPreloadCurrentNext = false

        let durationHint = max(currentTrack.durationSecs ?? 0, 0)
        transportState.status = autoplay ? .loading : .paused
        transportState.positionSecs = 0
        transportState.durationSecs = durationHint
        emitSnapshotChange()

        let trackID = currentTrack.id
        currentTrackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let signedURL = try await mediaClient.signedHLSURL(trackId: trackID)
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id == trackID else { return }

                self.engine.load(signedURL: signedURL, autoplay: autoplay)
            } catch {
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id == trackID else { return }

                self.playbackIntentIsPlaying = false
                self.transportState.status = .stopped
                self.transportState.positionSecs = 0
                self.emitSnapshotChange()
            }
        }
    }

    private func preloadNextTrackIfNeeded() {
        guard !didPreloadCurrentNext else { return }
        guard let nextTrack = queue.nextTrack, let mediaClient else { return }
        guard nextTrack.id != currentTrack?.id else { return }

        didPreloadCurrentNext = true
        let nextTrackID = nextTrack.id
        preloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let signedURL = try await mediaClient.signedHLSURL(trackId: nextTrackID)
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id != nextTrackID else { return }
                self.engine.preloadNext(signedURL: signedURL)
            } catch {
                didPreloadCurrentNext = false
            }
        }
    }

    private func emitSnapshotChange() {
        let snapshot = snapshot
        queue.positionSecs = snapshot.positionSecs
        handleSnapshotChanged(snapshot)
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

    private func publishCommittedNowPlaying() {
        publishNowPlaying(fetchArtwork: true)
    }

    private func publishTransportNowPlaying() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTransportPublishTime >= 1.0 else { return }
        lastTransportPublishTime = now
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
        updateTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard let self else { return }
                guard self.isPlaying else { continue }
                self.handleSnapshotChanged(self.snapshot)
            }
        }
    }
}
