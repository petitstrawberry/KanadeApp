import Foundation
import Observation
import KanadeKit

@MainActor
@Observable
final class LocalPlaybackController {
    let renderer: AVQueuePlayerRenderer
    let queue: LocalQueue
    let nowPlayingManager: NowPlayingManager

    @ObservationIgnored private var mediaClient: MediaClient?
    @ObservationIgnored private var updateTimer: Task<Void, Never>?
    @ObservationIgnored private var cachedArtworkAlbumId: String?
    @ObservationIgnored private var cachedArtworkData: Data?

    @ObservationIgnored var onStateUpdate: (([Track], Int?, Double, PlaybackStatus, Int, RepeatMode, Bool) -> Void)?

    var isPlaying: Bool { renderer.state.status == .playing }
    var currentTrack: Track? { queue.currentTrack }
    var positionSecs: Double { renderer.state.positionSecs }
    var durationSecs: Double { renderer.state.durationSecs }
    var volume: Int { renderer.state.volume }

    init(mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        self.renderer = AVQueuePlayerRenderer(mediaClient: mediaClient)
        self.queue = LocalQueue()
        self.nowPlayingManager = NowPlayingManager()

        nowPlayingManager.configureAudioSession()
        bindRenderer()
        configureCommandHandlers()
        updateNowPlaying()
        startUpdateTimer()
    }

    func updateMediaClient(_ mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
        renderer.updateMediaClient(mediaClient)
    }

    deinit {
        updateTimer?.cancel()
    }

    func playTracks(_ tracks: [Track], startIndex: Int = 0) {
        startUpdateTimer()
        queue.setTracks(tracks, startIndex: startIndex)
        loadCurrentTrack(autoplay: true)
    }

    func play() {
        startUpdateTimer()
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
        updateNowPlaying()
    }

    func pause() {
        renderer.pause()
        updateNowPlaying()
    }

    func stop() {
        updateTimer?.cancel()
        renderer.stop()
        nowPlayingManager.clearNowPlaying()
        emitStateUpdate()
    }

    func seek(to positionSecs: Double) {
        renderer.seek(to: positionSecs)
        updateNowPlaying()
    }

    func setVolume(_ volume: Int) {
        renderer.setVolume(volume)
        updateNowPlaying()
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
        updateNowPlaying()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        preloadNextTrack()
        updateNowPlaying()
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        if currentTrack == nil {
            queue.jumpToIndex(0)
            loadCurrentTrack(autoplay: false)
        } else {
            preloadNextTrack()
            updateNowPlaying()
        }
    }

    func addTracksToQueue(_ tracks: [Track]) {
        let hadCurrentTrack = currentTrack != nil
        queue.append(contentsOf: tracks)
        if !hadCurrentTrack, currentTrack != nil {
            loadCurrentTrack(autoplay: false)
        } else {
            preloadNextTrack()
            updateNowPlaying()
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
            updateNowPlaying()
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
        updateNowPlaying()
    }

    func importFromServer(tracks: [Track], index: Int?, positionSecs: Double?) {
        startUpdateTimer()
        queue.importQueue(tracks: tracks, index: index, positionSecs: positionSecs)

        guard currentTrack != nil else {
            stop()
            return
        }

        loadCurrentTrack(autoplay: false)
        if let positionSecs {
            renderer.seek(to: positionSecs)
        }
        updateNowPlaying()
    }

    func exportForHandoff() -> (tracks: [Track], index: Int?, positionSecs: Double) {
        let exported = queue.exportQueue()
        return (tracks: exported.tracks, index: exported.index, positionSecs: renderer.state.positionSecs)
    }

    private func bindRenderer() {
        renderer.onStateChanged = { [weak self] _ in
            guard let self else { return }
            self.updateNowPlaying()
            self.emitStateUpdate()
        }

        renderer.onTrackAdvanced = { [weak self] in
            guard let self else { return }
            guard self.queue.advance() else {
                self.stop()
                return
            }
            self.preloadNextTrack()
            self.updateNowPlaying()
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
        guard let currentTrack, let url = mediaClient?.trackURL(trackId: currentTrack.id) else {
            stop()
            return
        }

        startUpdateTimer()
        renderer.loadTrack(url: url, autoplay: autoplay)
        preloadNextTrack()
        updateNowPlaying()
    }

    private func preloadNextTrack() {
        guard let nextTrack = queue.nextTrack,
              let url = mediaClient?.trackURL(trackId: nextTrack.id) else {
            return
        }

        renderer.prepareNext(url: url)
    }

    private func updateNowPlaying() {
        let playbackRate = renderer.state.status == .playing ? 1.0 : 0.0

        let artwork: Data?
        if let albumId = currentTrack?.albumId, albumId == cachedArtworkAlbumId {
            artwork = cachedArtworkData
        } else {
            artwork = nil
            cachedArtworkAlbumId = nil
            cachedArtworkData = nil
        }

        nowPlayingManager.updateNowPlaying(
            track: currentTrack,
            artworkData: artwork,
            duration: renderer.state.durationSecs > 0 ? renderer.state.durationSecs : (currentTrack?.durationSecs ?? 0),
            position: renderer.state.positionSecs,
            playbackRate: playbackRate
        )

        fetchArtworkIfNeeded()
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
            let playbackRate = renderer.state.status == .playing ? 1.0 : 0.0
            nowPlayingManager.updateNowPlaying(
                track: currentTrack,
                artworkData: data,
                duration: renderer.state.durationSecs > 0 ? renderer.state.durationSecs : (currentTrack?.durationSecs ?? 0),
                position: renderer.state.positionSecs,
                playbackRate: playbackRate
            )
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
            }
        }
    }

    private func emitStateUpdate() {
        onStateUpdate?(
            queue.tracks,
            queue.currentIndex,
            renderer.state.positionSecs,
            renderer.state.status,
            renderer.state.volume,
            queue.repeatMode,
            queue.shuffleEnabled
        )
    }
}
