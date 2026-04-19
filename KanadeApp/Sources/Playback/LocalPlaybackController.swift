import Foundation
import Observation
import KanadeKit

@MainActor
@Observable
final class LocalPlaybackController {
    private let core: PlaybackCore
    private let nowPlayingManager: NowPlayingManager

    @ObservationIgnored private var mediaClient: MediaClient?
    @ObservationIgnored private var updateTimer: Task<Void, Never>?
    @ObservationIgnored private var cachedArtworkAlbumId: String?
    @ObservationIgnored private var cachedArtworkData: Data?
    @ObservationIgnored private var lastSnapshotTrackID: String?

    @ObservationIgnored var onSnapshotChanged: ((LocalPlaybackSnapshot) -> Void)? = nil {
        didSet {
            core.onSnapshotChanged = { [weak self] snapshot in
                self?.handleCoreSnapshotChanged(snapshot)
            }
        }
    }

    var isPlaying: Bool { core.isPlaying }
    var queuedTracks: [Track] { core.queuedTracks }
    var currentIndex: Int? { core.currentIndex }
    var currentTrack: Track? { core.currentTrack }
    var positionSecs: Double { core.positionSecs }
    var durationSecs: Double { core.durationSecs }
    var volume: Int { core.volume }
    var repeatMode: RepeatMode { core.repeatMode }
    var shuffleEnabled: Bool { core.shuffleEnabled }
    var snapshot: LocalPlaybackSnapshot { core.snapshot }
    var transportSnapshot: LocalPlaybackTransportSnapshot { core.transportSnapshot }
    var sessionUpdate: LocalPlaybackSessionUpdate { core.sessionUpdate }

    init(mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        self.core = PlaybackCore(mediaClient: mediaClient)
        self.nowPlayingManager = NowPlayingManager()

        nowPlayingManager.configureAudioSession()
        bindCore()
        configureCommandHandlers()
        publishCommittedNowPlaying()
        startUpdateTimer()
    }

    func updateMediaClient(_ mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        core.updateMediaClient(mediaClient)
    }

    deinit {
        updateTimer?.cancel()
    }

    func playTracks(_ tracks: [Track], startIndex: Int = 0) {
        startUpdateTimer()
        core.playTracks(tracks, startIndex: startIndex)
    }

    func play() {
        startUpdateTimer()
        nowPlayingManager.setAudioSessionActive(true)
        core.play()
        publishTransportNowPlaying()
    }

    func pause() {
        core.pause()
        publishTransportNowPlaying()
    }

    func stop() {
        updateTimer?.cancel()
        core.stop()
        nowPlayingManager.clearNowPlaying()
    }

    func seek(to positionSecs: Double) {
        core.seek(to: positionSecs)
        publishTransportNowPlaying()
    }

    func setVolume(_ volume: Int) {
        core.setVolume(volume)
        publishCommittedNowPlaying()
    }

    func next() {
        core.next()
    }

    func previous() {
        core.previous()
    }

    func setRepeat(_ mode: RepeatMode) {
        core.setRepeat(mode)
        publishCommittedNowPlaying()
    }

    func setShuffle(_ enabled: Bool) {
        core.setShuffle(enabled)
        publishCommittedNowPlaying()
    }

    func addToQueue(_ track: Track) {
        core.addToQueue(track)
    }

    func addTracksToQueue(_ tracks: [Track]) {
        core.addTracksToQueue(tracks)
    }

    func removeFromQueue(_ index: Int) {
        core.removeFromQueue(index)
    }

    func clearQueue() {
        core.clearQueue()
        stop()
    }

    func jumpToIndex(_ index: Int) {
        core.jumpToIndex(index)
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        core.moveInQueue(from: sourceIndex, to: destinationIndex)
    }

    func importPlaybackState(tracks: [Track], index: Int?, positionSecs: Double?) {
        startUpdateTimer()
        core.importFromServer(tracks: tracks, index: index, positionSecs: positionSecs)
        publishCommittedNowPlaying()
    }

    func importFromServer(tracks: [Track], index: Int?, positionSecs: Double?) {
        importPlaybackState(tracks: tracks, index: index, positionSecs: positionSecs)
    }

    func exportPlaybackState() -> LocalPlaybackHandoffState {
        core.handoffState
    }

    func exportForHandoff() -> (tracks: [Track], index: Int?, positionSecs: Double) {
        let handoffState = exportPlaybackState()
        return (tracks: handoffState.tracks, index: handoffState.currentIndex, positionSecs: handoffState.positionSecs)
    }

    private func bindCore() {
        core.onSnapshotChanged = { [weak self] snapshot in
            self?.handleCoreSnapshotChanged(snapshot)
        }
    }

    private func handleCoreSnapshotChanged(_ snapshot: LocalPlaybackSnapshot) {
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
        updateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(800))
                guard let self else { return }
                guard self.isPlaying || self.snapshot.status != .stopped else { continue }
                self.handleCoreSnapshotChanged(self.snapshot)
            }
        }
    }
}
