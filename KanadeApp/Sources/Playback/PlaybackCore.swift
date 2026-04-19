import Foundation
import Observation
import KanadeKit

#if DEBUG
private let playbackCoreLogOrigin = ProcessInfo.processInfo.systemUptime

private func playbackCoreLog(_ message: @autoclosure () -> String) {
    guard PlaybackDebug.lifecycleLogsEnabled else { return }
    let elapsed = ProcessInfo.processInfo.systemUptime - playbackCoreLogOrigin
    print("[PlaybackCore +\(String(format: "%.3f", elapsed))s] \(message())")
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
    @ObservationIgnored private var pendingSeekAfterLoad: Double?
    @ObservationIgnored private var playbackIntentIsPlaying = false
    @ObservationIgnored private var queueGeneration = UUID()

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
        bindRenderer()
    }

    deinit {
        currentTrackLoadTask?.cancel()
    }

    func updateMediaClient(_ mediaClient: MediaClient?) {
        self.mediaClient = mediaClient
    }

    func playTracks(_ tracks: [Track], startIndex: Int = 0) {
        queue.setTracks(tracks, startIndex: startIndex)
        queueGeneration = UUID()
        loadCurrentTrack(autoplay: true)
    }

    func play() {
        playbackIntentIsPlaying = true

        if currentTrack == nil, !queue.tracks.isEmpty {
            queue.jumpToIndex(queue.currentIndex ?? 0)
            queueGeneration = UUID()
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
        pendingSeekAfterLoad = nil
        renderer.clearNextCandidate()
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
        queueGeneration = UUID()
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
        queueGeneration = UUID()
        loadCurrentTrack(autoplay: true)
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.setRepeat(mode)
        queueGeneration = UUID()
        refreshNextCandidate()
        emitSnapshotChange()
    }

    func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        queueGeneration = UUID()
        refreshNextCandidate()
        emitSnapshotChange()
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        if currentTrack == nil {
            queue.jumpToIndex(0)
            queueGeneration = UUID()
            loadCurrentTrack(autoplay: false)
        } else {
            queueGeneration = UUID()
            refreshNextCandidate()
            emitSnapshotChange()
        }
    }

    func addTracksToQueue(_ tracks: [Track]) {
        let hadCurrentTrack = currentTrack != nil
        queue.append(contentsOf: tracks)
        if !hadCurrentTrack, currentTrack != nil {
            queueGeneration = UUID()
            loadCurrentTrack(autoplay: false)
        } else {
            queueGeneration = UUID()
            refreshNextCandidate()
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
            queueGeneration = UUID()
            loadCurrentTrack(autoplay: shouldAutoplay)
        } else {
            queueGeneration = UUID()
            refreshNextCandidate()
            emitSnapshotChange()
        }
    }

    func clearQueue() {
        queue.clear()
        stop()
    }

    func jumpToIndex(_ index: Int) {
        queue.jumpToIndex(index)
        queueGeneration = UUID()
        loadCurrentTrack(autoplay: true)
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        queue.move(from: sourceIndex, to: destinationIndex)
        queueGeneration = UUID()
        refreshNextCandidate()
        emitSnapshotChange()
    }

    func importFromServer(tracks: [Track], index: Int?, positionSecs: Double?) {
        queue.importQueue(tracks: tracks, index: index, positionSecs: positionSecs)

        guard currentTrack != nil else {
            stop()
            return
        }

        pendingSeekAfterLoad = positionSecs
        queueGeneration = UUID()
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

        renderer.onCurrentSessionFinishedWithoutHandoff = { [weak self] in
            guard let self else { return }

            #if DEBUG
            let finishingTrack = self.currentTrack
            playbackCoreLog("finished track=\(self.describeTrack(finishingTrack)) index=\(self.queue.currentIndex.map(String.init) ?? "nil")")
            #endif

            guard self.queue.advance() else {
                self.stop()
                return
            }
            self.queueGeneration = UUID()
            self.loadCurrentTrack(autoplay: true)
        }

        renderer.onNaturalHandoffCommitted = { [weak self] in
            guard let self else { return }

            #if DEBUG
            let outgoingTrack = self.currentTrack
            let incomingTrack = self.queue.nextTrack
            playbackCoreLog("prepared-handoff from=\(self.describeTrack(outgoingTrack)) to=\(self.describeTrack(incomingTrack)) currentIndex=\(self.queue.currentIndex.map(String.init) ?? "nil")")
            #endif

            guard self.queue.advance() else {
                self.stop()
                return
            }

            self.queueGeneration = UUID()

            #if DEBUG
            playbackCoreLog("activated track=\(self.describeTrack(self.currentTrack)) index=\(self.queue.currentIndex.map(String.init) ?? "nil")")
            #endif

            self.refreshNextCandidate()
            self.emitSnapshotChange()
        }
    }

    private func loadCurrentTrack(autoplay: Bool) {
        guard let currentTrack, let mediaClient else {
            stop()
            return
        }

        let track = currentTrack
        let source = CachedTrackAudioSource(track: track, mediaClient: mediaClient)

        #if DEBUG
        playbackCoreLog("load track=\(describeTrack(track)) autoplay=\(autoplay) index=\(queue.currentIndex.map(String.init) ?? "nil")")
        #endif

        playbackIntentIsPlaying = autoplay
        currentTrackLoadTask?.cancel()
        renderer.beginLoading(durationHint: track.durationSecs, autoplay: autoplay)
        refreshNextCandidate()
        emitSnapshotChange()

        currentTrackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                guard self.currentTrack?.id == track.id else { return }

                try await self.renderer.loadTrack(source: source, autoplay: autoplay)
                self.refreshNextCandidate()
                self.emitSnapshotChange()
            } catch {
                guard self.currentTrack?.id == track.id else { return }

                if let progressiveError = error as? FLACProgressiveSourceAccessError,
                   progressiveError == .wouldBlock {
                    self.emitSnapshotChange()
                    return
                }

                self.stop()
            }
        }
    }

    private func refreshNextCandidate() {
        guard let mediaClient,
              let nextTrack = queue.nextTrack else {
            renderer.updateNextCandidate(source: nil, queueGeneration: queueGeneration)
            return
        }

        let source = CachedTrackAudioSource(track: nextTrack, mediaClient: mediaClient)
        renderer.updateNextCandidate(source: source, queueGeneration: queueGeneration)
    }

    private func emitSnapshotChange() {
        onSnapshotChanged?(snapshot)
    }

    #if DEBUG
    private func describeTrack(_ track: Track?) -> String {
        guard let track else { return "<nil>" }

        let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false ? title! : URL(fileURLWithPath: track.filePath).lastPathComponent)
        let resolvedArtist = (artist?.isEmpty == false ? artist! : "Unknown Artist")
        return "\(resolvedArtist) - \(resolvedTitle) [id=\(track.id)]"
    }
    #endif
}
