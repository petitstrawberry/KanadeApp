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
    @ObservationIgnored private var currentURLRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var playbackStallRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var trackRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var trackRecoveryAttempt = 0
    @ObservationIgnored private var externalPauseSuppressionUntil = Date.distantPast

    private static let signedURLRetryDelaysNanoseconds: [UInt64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
        8_000_000_000,
    ]
    private static let playbackStallRecoveryDelayNanoseconds: UInt64 = 18_000_000_000
    private static let trackRecoveryMaxDelaySeconds: TimeInterval = 30
    private static let signedURLRefreshLeadTime: TimeInterval = 90
    private static let externalPauseSuppressionDuration: TimeInterval = 2.0

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
    var durationSecs: Double { transportState.durationSecs > 0 ? transportState.durationSecs : (currentTrack?.durationSecs ?? 0) }
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
            durationSecs: transportState.durationSecs > 0 ? transportState.durationSecs : (queue.currentTrack?.durationSecs ?? 0),
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
        guard mediaClient != nil else { return }
        guard currentTrack != nil else { return }

        if playbackIntentIsPlaying || isRecoverable(status: transportPlaybackStatus) {
            reloadCurrentTrack(forceRefresh: true, cancelRecovery: false)
        }
    }

    func reloadCurrentTrack() {
        reloadCurrentTrack(forceRefresh: true, cancelRecovery: true)
    }

    private func reloadCurrentTrack(forceRefresh: Bool, cancelRecovery: Bool) {
        guard let currentTrack else { return }
        let position = transportState.positionSecs
        let wasPlaying = transportPlaybackStatus == .playing || playbackIntentIsPlaying
        let trackID = currentTrack.id

        guard let mediaClient else {
            handleUnavailableMediaClient(autoplay: wasPlaying)
            return
        }

        if cancelRecovery {
            trackRecoveryTask?.cancel()
            trackRecoveryTask = nil
        }
        playbackStallRecoveryTask?.cancel()
        playbackStallRecoveryTask = nil
        currentTrackLoadTask?.cancel()
        preloadTask?.cancel()
        preloadTask = nil
        didPreloadCurrentNext = false
        playbackIntentIsPlaying = wasPlaying
        if wasPlaying {
            protectAgainstSpuriousExternalPause()
            transportState.status = .loading
            emitSnapshotChange()
        }

        currentTrackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let signedURL = try await self.fetchSignedHLSURLWithRetry(
                    mediaClient: mediaClient,
                    trackID: trackID,
                    forceRefresh: forceRefresh
                )
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id == trackID else { return }

                self.markTrackLoadSucceeded(signedURL: signedURL, trackID: trackID)

                if case .idle = self.engine.state.status {
                    self.engine.load(signedURL: signedURL, autoplay: wasPlaying, startPositionSecs: position)
                } else if case .stopped = self.engine.state.status {
                    self.engine.load(signedURL: signedURL, autoplay: wasPlaying, startPositionSecs: position)
                } else if case .error = self.engine.state.status {
                    self.engine.load(signedURL: signedURL, autoplay: wasPlaying, startPositionSecs: position)
                } else {
                    self.engine.replaceCurrentItem(signedURL: signedURL, seekTo: position)
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id == trackID else { return }
                self.handleTrackLoadFailure(
                    error,
                    trackID: trackID,
                    positionSecs: position,
                    shouldResume: wasPlaying,
                    phase: "reload"
                )
            }
        }
    }

    deinit {
        updateTimer?.cancel()
        currentTrackLoadTask?.cancel()
        preloadTask?.cancel()
        currentURLRefreshTask?.cancel()
        playbackStallRecoveryTask?.cancel()
        trackRecoveryTask?.cancel()
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
        protectAgainstSpuriousExternalPause()

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
        externalPauseSuppressionUntil = Date.distantPast
        engine.pause()
        publishTransportNowPlaying()
    }

    func stop() {
        updateTimer?.cancel()
        currentTrackLoadTask?.cancel()
        preloadTask?.cancel()
        currentURLRefreshTask?.cancel()
        playbackStallRecoveryTask?.cancel()
        trackRecoveryTask?.cancel()
        currentTrackLoadTask = nil
        preloadTask = nil
        currentURLRefreshTask = nil
        playbackStallRecoveryTask = nil
        trackRecoveryTask = nil
        pendingSeekAfterLoad = nil
        playbackIntentIsPlaying = false
        externalPauseSuppressionUntil = Date.distantPast
        engine.stop()
        emitSnapshotChange()
        nowPlayingManager.clearNowPlaying()
    }

    func seek(to positionSecs: Double) {
        if playbackIntentIsPlaying || transportPlaybackStatus == .playing || transportPlaybackStatus == .loading {
            playbackIntentIsPlaying = true
            protectAgainstSpuriousExternalPause()
        }
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
           transportPlaybackStatus != .stopped,
           state.durationSecs > 0 {
            self.pendingSeekAfterLoad = nil
            engine.seek(to: pendingSeekAfterLoad)
        }

        switch state.status {
        case .playing:
            playbackIntentIsPlaying = true
            trackRecoveryAttempt = 0
            playbackStallRecoveryTask?.cancel()
            playbackStallRecoveryTask = nil
            preloadNextTrackIfNeeded()
        case .loading:
            if playbackIntentIsPlaying {
                schedulePlaybackStallRecovery()
            }
        case .paused:
            playbackStallRecoveryTask?.cancel()
            playbackStallRecoveryTask = nil
            if playbackIntentIsPlaying {
                protectAgainstSpuriousExternalPause()
                transportState.status = .loading
                engine.play()
                schedulePlaybackStallRecovery()
            }
        case .error:
            playbackStallRecoveryTask?.cancel()
            playbackStallRecoveryTask = nil
            if playbackIntentIsPlaying, let trackID = currentTrack?.id {
                transportState.status = .loading
                scheduleTrackRecovery(
                    trackID: trackID,
                    positionSecs: transportState.positionSecs,
                    shouldResume: true,
                    reason: "transport error"
                )
            } else {
                playbackIntentIsPlaying = false
            }
        case .idle, .stopped:
            playbackStallRecoveryTask?.cancel()
            playbackStallRecoveryTask = nil
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
        transportState.durationSecs = 0
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
        guard let currentTrack else {
            stop()
            return
        }

        guard let mediaClient else {
            handleUnavailableMediaClient(autoplay: autoplay)
            return
        }

        playbackIntentIsPlaying = autoplay
        if autoplay {
            protectAgainstSpuriousExternalPause()
        }
        currentTrackLoadTask?.cancel()
        preloadTask?.cancel()
        currentURLRefreshTask?.cancel()
        playbackStallRecoveryTask?.cancel()
        trackRecoveryTask?.cancel()
        currentTrackLoadTask = nil
        preloadTask = nil
        currentURLRefreshTask = nil
        playbackStallRecoveryTask = nil
        trackRecoveryTask = nil
        trackRecoveryAttempt = 0
        didPreloadCurrentNext = false

        transportState.status = autoplay ? .loading : .paused
        transportState.positionSecs = 0
        transportState.durationSecs = 0
        emitSnapshotChange()

        let trackID = currentTrack.id
        currentTrackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let signedURL = try await self.fetchSignedHLSURLWithRetry(
                    mediaClient: mediaClient,
                    trackID: trackID,
                    forceRefresh: false
                )
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id == trackID else { return }

                self.markTrackLoadSucceeded(signedURL: signedURL, trackID: trackID)
                self.engine.load(signedURL: signedURL, autoplay: autoplay)
            } catch {
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id == trackID else { return }

                self.handleTrackLoadFailure(
                    error,
                    trackID: trackID,
                    positionSecs: 0,
                    shouldResume: autoplay,
                    phase: "initial load"
                )
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
                let signedURL = try await self.fetchSignedHLSURLWithRetry(
                    mediaClient: mediaClient,
                    trackID: nextTrackID,
                    forceRefresh: false
                )
                guard !Task.isCancelled else { return }
                guard self.currentTrack?.id != nextTrackID else { return }
                self.engine.preloadNext(signedURL: signedURL)
            } catch {
                guard !Task.isCancelled else { return }
                self.didPreloadCurrentNext = false
                print("[LocalPlaybackController] Failed to preload HLS URL for track \(nextTrackID): \(error)")
            }
        }
    }

    private func fetchSignedHLSURLWithRetry(
        mediaClient: MediaClient,
        trackID: String,
        forceRefresh: Bool
    ) async throws -> URL {
        let path = mediaClient.hlsPath(trackId: trackID)
        let signer = mediaClient.mediaAuthSignerReference()
        var lastError: (any Error)?

        for attempt in 0...Self.signedURLRetryDelaysNanoseconds.count {
            try Task.checkCancellation()

            if forceRefresh || attempt > 0 {
                await signer?.invalidate(path: path)
            }

            do {
                return try await mediaClient.signedHLSURL(trackId: trackID)
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastError = error
                guard attempt < Self.signedURLRetryDelaysNanoseconds.count else { break }

                let delay = Self.signedURLRetryDelaysNanoseconds[attempt]
                print("[LocalPlaybackController] signed HLS URL fetch failed for track \(trackID) (attempt \(attempt + 1)): \(error)")
                try await Task.sleep(nanoseconds: delay)
            }
        }

        throw lastError ?? KanadeError.connectionLost
    }

    private func markTrackLoadSucceeded(signedURL: URL, trackID: String) {
        trackRecoveryAttempt = 0
        trackRecoveryTask?.cancel()
        trackRecoveryTask = nil
        playbackStallRecoveryTask?.cancel()
        playbackStallRecoveryTask = nil
        scheduleSignedURLRefresh(for: signedURL, trackID: trackID)
    }

    private func handleUnavailableMediaClient(autoplay: Bool) {
        playbackIntentIsPlaying = autoplay || playbackIntentIsPlaying
        if playbackIntentIsPlaying, let trackID = currentTrack?.id {
            transportState.status = .loading
            emitSnapshotChange()
            scheduleTrackRecovery(
                trackID: trackID,
                positionSecs: transportState.positionSecs,
                shouldResume: true,
                reason: "media client unavailable"
            )
        } else {
            transportState.status = .stopped
            emitSnapshotChange()
        }
    }

    private func handleTrackLoadFailure(
        _ error: any Error,
        trackID: String,
        positionSecs: Double,
        shouldResume: Bool,
        phase: String
    ) {
        print("[LocalPlaybackController] HLS \(phase) failed for track \(trackID): \(error)")

        if shouldResume {
            playbackIntentIsPlaying = true
            transportState.status = .loading
            transportState.positionSecs = max(positionSecs, 0)
            emitSnapshotChange()
            scheduleTrackRecovery(
                trackID: trackID,
                positionSecs: positionSecs,
                shouldResume: true,
                reason: "HLS \(phase) failed: \(error)"
            )
        } else {
            playbackIntentIsPlaying = false
            transportState.status = .stopped
            transportState.positionSecs = max(positionSecs, 0)
            emitSnapshotChange()
        }
    }

    private func schedulePlaybackStallRecovery() {
        guard playbackStallRecoveryTask == nil else { return }
        guard let trackID = currentTrack?.id else { return }

        playbackStallRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.playbackStallRecoveryDelayNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self else { return }
            self.playbackStallRecoveryTask = nil
            guard self.currentTrack?.id == trackID else { return }
            guard self.playbackIntentIsPlaying, self.transportPlaybackStatus == .loading else { return }

            print("[LocalPlaybackController] Playback remained loading; refreshing HLS for track \(trackID)")
            self.reloadCurrentTrack(forceRefresh: true, cancelRecovery: false)
        }
    }

    private func scheduleTrackRecovery(
        trackID: String,
        positionSecs: Double,
        shouldResume: Bool,
        reason: String
    ) {
        guard currentTrack?.id == trackID else { return }

        trackRecoveryTask?.cancel()
        let delay = recoveryDelayNanoseconds(forAttempt: trackRecoveryAttempt)
        trackRecoveryAttempt += 1

        trackRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self else { return }
            self.trackRecoveryTask = nil
            guard self.currentTrack?.id == trackID else { return }

            if shouldResume {
                self.playbackIntentIsPlaying = true
                self.transportState.status = .loading
                self.transportState.positionSecs = max(positionSecs, 0)
                self.emitSnapshotChange()
            }

            guard self.mediaClient != nil else {
                self.scheduleTrackRecovery(
                    trackID: trackID,
                    positionSecs: positionSecs,
                    shouldResume: shouldResume,
                    reason: reason
                )
                return
            }

            print("[LocalPlaybackController] Retrying HLS recovery for track \(trackID): \(reason)")
            self.reloadCurrentTrack(forceRefresh: true, cancelRecovery: false)
        }
    }

    private func recoveryDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let base = min(pow(2.0, Double(max(attempt, 0))), Self.trackRecoveryMaxDelaySeconds)
        let jitter = Double.random(in: 0...(base * 0.2))
        return UInt64((base + jitter) * 1_000_000_000)
    }

    private func scheduleSignedURLRefresh(for signedURL: URL, trackID: String) {
        currentURLRefreshTask?.cancel()
        currentURLRefreshTask = nil

        guard let expiry = signedURLExpiryDate(from: signedURL) else { return }

        let secondsUntilExpiry = expiry.timeIntervalSinceNow
        guard secondsUntilExpiry > 5 else {
            scheduleTrackRecovery(
                trackID: trackID,
                positionSecs: transportState.positionSecs,
                shouldResume: playbackIntentIsPlaying,
                reason: "signed HLS URL already near expiry"
            )
            return
        }

        let delaySeconds = max(5, min(secondsUntilExpiry - Self.signedURLRefreshLeadTime, secondsUntilExpiry * 0.75))
        let delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)

        currentURLRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self else { return }
            self.currentURLRefreshTask = nil
            guard self.currentTrack?.id == trackID else { return }
            guard self.playbackIntentIsPlaying || self.transportPlaybackStatus != .stopped else { return }

            print("[LocalPlaybackController] Refreshing signed HLS URL before expiry for track \(trackID)")
            self.reloadCurrentTrack(forceRefresh: true, cancelRecovery: false)
        }
    }

    private func signedURLExpiryDate(from url: URL) -> Date? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expValue = components.queryItems?.first(where: { $0.name == "exp" })?.value,
              let exp = TimeInterval(expValue)
        else { return nil }

        return Date(timeIntervalSince1970: exp)
    }

    private func isRecoverable(status: PlaybackStatus) -> Bool {
        switch status {
        case .loading:
            return currentTrack != nil
        case .playing, .paused, .stopped:
            return false
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
            onPause: { [weak self] in self?.handleExternalPauseCommand() },
            onNext: { [weak self] in self?.next() },
            onPrevious: { [weak self] in self?.previous() },
            onSeek: { [weak self] position in
                self?.seek(to: position)
            }
        )
    }

    private func protectAgainstSpuriousExternalPause() {
        externalPauseSuppressionUntil = Date().addingTimeInterval(Self.externalPauseSuppressionDuration)
    }

    private func handleExternalPauseCommand() {
        if playbackIntentIsPlaying,
           Date() < externalPauseSuppressionUntil,
           transportPlaybackStatus == .loading || transportPlaybackStatus == .playing {
            transportState.status = .loading
            engine.play()
            emitSnapshotChange()
            publishTransportNowPlaying()
            return
        }

        pause()
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
        let playbackRate = snapshot.isPlayingLike ? 1.0 : 0.0

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
