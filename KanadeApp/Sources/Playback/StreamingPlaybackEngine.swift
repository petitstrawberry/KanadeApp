import AVFoundation
import Foundation

enum StreamingPlaybackStatus: Sendable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case error(String)
}

struct StreamingTransportState: Sendable {
    var status: StreamingPlaybackStatus
    var positionSecs: Double
    var durationSecs: Double
    var volume: Int
}

@MainActor
final class StreamingPlaybackEngine {
    private var queuePlayer: AVQueuePlayer?
    private var currentPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservations: [NSKeyValueObservation] = []
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var itemFinishedObservers: [(AVPlayerItem, NSObjectProtocol)] = []
    private var naturallyEndedItemIDs: Set<ObjectIdentifier> = []
    private var transitionedItemIDsAwaitingNaturalEnd: Set<ObjectIdentifier> = []
    private var shouldAutoplay = true
    private var hasNextPreloaded = false
    private var seekRequestID: UInt64 = 0
    private var seekTimeoutTask: Task<Void, Never>?
    private var seekDisplayOverride: (requestID: UInt64, itemID: ObjectIdentifier, positionSecs: Double, expiresAt: Date)?

    private static let seekTimeoutNanoseconds: UInt64 = 12_000_000_000
    private static let seekDisplayOverrideDuration: TimeInterval = 8.0

    var onStateChanged: ((StreamingTransportState) -> Void)?
    var onPlaybackFinished: (() -> Void)?
    var onTrackAdvanced: (() -> Void)?

    private(set) var state = StreamingTransportState(
        status: .idle,
        positionSecs: 0,
        durationSecs: 0,
        volume: 100
    )

    func load(signedURL: URL, autoplay: Bool = true) {
        cleanupPlayer()

        shouldAutoplay = autoplay
        hasNextPreloaded = false

        let item = AVPlayerItem(url: signedURL)
        let player = AVQueuePlayer(playerItem: item)
        player.volume = Float(state.volume) / 100.0

        self.queuePlayer = player
        currentPlayerItem = item

        observeGlobal(player: player)
        observeItem(item)
        setupPeriodicTimeObserver()

        let initialStatus: StreamingPlaybackStatus = autoplay ? .loading : .paused
        state.positionSecs = 0
        state.durationSecs = 0
        updateState(initialStatus)
    }

    func preloadNext(signedURL: URL) {
        guard let queuePlayer, !hasNextPreloaded else { return }

        let item = AVPlayerItem(url: signedURL)
        queuePlayer.insert(item, after: nil)
        hasNextPreloaded = true
        observeItemFinished(item)
    }

    func replaceCurrentItem(signedURL: URL, seekTo positionSecs: Double) {
        guard let queuePlayer else {
            load(signedURL: signedURL, autoplay: true)
            seek(to: positionSecs)
            return
        }

        let savedVolume = state.volume
        let shouldResume = shouldAutoplay || isPlayingLike(status: state.status)
        shouldAutoplay = shouldResume

        let newItem = AVPlayerItem(url: signedURL)
        queuePlayer.removeAllItems()
        queuePlayer.insert(newItem, after: nil)

        currentPlayerItem = newItem
        hasNextPreloaded = false
        queuePlayer.volume = Float(savedVolume) / 100.0

        observeItem(newItem)
        beginSeek(to: positionSecs, resumePlayback: shouldResume)
    }

    func play() {
        guard let queuePlayer, currentPlayerItem != nil else {
            updateState(.stopped)
            return
        }

        shouldAutoplay = true
        queuePlayer.play()
        if queuePlayer.timeControlStatus != .playing {
            updateState(.loading)
        }
    }

    func pause() {
        guard let queuePlayer else {
            updateState(.stopped)
            return
        }

        shouldAutoplay = false
        queuePlayer.pause()
        state.positionSecs = currentPositionSecs()
        updateState(currentPlayerItem == nil ? .stopped : .paused)
    }

    func stop() {
        shouldAutoplay = false
        cancelSeekTimeout()
        seekDisplayOverride = nil
        cleanupPlayer()
        state.positionSecs = 0
        state.durationSecs = 0
        updateState(.stopped)
    }

    func seek(to positionSecs: Double) {
        guard let queuePlayer else { return }

        let clampedPosition = max(0, min(positionSecs, resolvedDurationSecs(fallback: positionSecs)))
        let resumePlayback = shouldAutoplay || queuePlayer.rate > 0 || isPlayingLike(status: state.status)
        shouldAutoplay = resumePlayback
        beginSeek(to: clampedPosition, resumePlayback: resumePlayback)
    }

    func setVolume(_ volume: Int) {
        let clampedVolume = min(max(volume, 0), 100)
        state.volume = clampedVolume
        queuePlayer?.volume = Float(clampedVolume) / 100.0
        emitStateChanged()
    }

    private func observeGlobal(player: AVQueuePlayer) {
        statusObservations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, player === self.queuePlayer else { return }
                    self.handleTimeControlStatusChanged(player.timeControlStatus)
                }
            }
        ]

        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard player === self.queuePlayer else { return }
                guard let newItem = change.newValue ?? player.currentItem,
                      newItem !== self.currentPlayerItem else { return }

                self.transitionToItem(newItem)
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.currentPlayerItem else { return }
                self.handleItemStatusChanged(item.status)
            }
        }

        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard item === self.currentPlayerItem else { return }
                self.state.durationSecs = self.sanitizedSeconds(item.duration)
                self.emitStateChanged()
            }
        }

        observeItemFinished(item)
        observeItemPlaybackStalled(item)
    }

    private func observeItemFinished(_ item: AVPlayerItem) {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let itemID = ObjectIdentifier(item)

                self.naturallyEndedItemIDs.insert(itemID)

                if self.transitionedItemIDsAwaitingNaturalEnd.remove(itemID) != nil {
                    self.onTrackAdvanced?()
                    return
                }

                // If transitionToItem already advanced to a new item, this
                // notification is for the old item — nothing to do.
                guard item === self.currentPlayerItem else { return }

                // Gapless: if a next item was preloaded, AVQueuePlayer will
                // auto-advance currentItem shortly. Treat this as a pending
                // transition instead of immediate playback end.
                if self.hasNextPreloaded {
                    self.transitionedItemIDsAwaitingNaturalEnd.insert(itemID)
                    return
                }

                self.state.positionSecs = self.resolvedDurationSecs(fallback: self.state.positionSecs)
                self.updateState(.stopped)
                self.onPlaybackFinished?()
            }
        }
        itemFinishedObservers.append((item, observer))
    }

    private func observeItemPlaybackStalled(_ item: AVPlayerItem) {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.currentPlayerItem else { return }
                if self.shouldAutoplay {
                    self.queuePlayer?.play()
                }
                self.updateState(.loading)
            }
        }
        itemFinishedObservers.append((item, observer))
    }

    private func transitionToItem(_ newItem: AVPlayerItem) {
        let previousItem = currentPlayerItem
        currentPlayerItem = newItem
        seekDisplayOverride = nil
        state.positionSecs = 0
        state.durationSecs = 0

        itemStatusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.currentPlayerItem else { return }
                self.handleItemStatusChanged(item.status)
            }
        }

        itemDurationObservation = newItem.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard item === self.currentPlayerItem else { return }
                self.state.durationSecs = self.sanitizedSeconds(item.duration)
                self.emitStateChanged()
            }
        }

        hasNextPreloaded = false

        guard let previousItem else { return }

        let previousItemID = ObjectIdentifier(previousItem)
        if naturallyEndedItemIDs.remove(previousItemID) != nil {
            transitionedItemIDsAwaitingNaturalEnd.remove(previousItemID)
            onTrackAdvanced?()
        } else {
            transitionedItemIDsAwaitingNaturalEnd.insert(previousItemID)
        }
    }

    private func handleTimeControlStatusChanged(_ timeControlStatus: AVPlayer.TimeControlStatus) {
        guard currentPlayerItem != nil else { return }

        switch timeControlStatus {
        case .paused:
            let currentStatus = state.status
            guard !matchesTerminalStatus(currentStatus) else { return }
            if shouldAutoplay {
                queuePlayer?.play()
                updateState(.loading)
                return
            }
            updateState(.paused)
        case .waitingToPlayAtSpecifiedRate:
            updateState(.loading)
        case .playing:
            updateState(.playing)
        @unknown default:
            break
        }
    }

    private func handleItemStatusChanged(_ itemStatus: AVPlayerItem.Status) {
        switch itemStatus {
        case .unknown:
            updateState(shouldAutoplay ? .loading : .paused)
        case .readyToPlay:
            state.durationSecs = resolvedDurationSecs(fallback: state.durationSecs)
            if shouldAutoplay {
                queuePlayer?.play()
                updateState(queuePlayer?.timeControlStatus == .playing ? .playing : .loading)
            } else {
                queuePlayer?.pause()
                updateState(.paused)
            }
        case .failed:
            let message = currentPlayerItem?.error?.localizedDescription ?? "Playback failed"
            updateState(.error(message))
        @unknown default:
            updateState(.error("Playback failed"))
        }
    }

    private func updateState(_ status: StreamingPlaybackStatus) {
        state.status = status
        state.positionSecs = displayPositionSecs(actualPositionSecs: currentPositionSecs())
        state.durationSecs = resolvedDurationSecs(fallback: state.durationSecs)
        emitStateChanged()
    }

    private func emitStateChanged() {
        onStateChanged?(state)
    }

    private func beginSeek(to positionSecs: Double, resumePlayback: Bool) {
        guard let queuePlayer, let currentPlayerItem else { return }

        seekRequestID &+= 1
        let requestID = seekRequestID
        let itemID = ObjectIdentifier(currentPlayerItem)
        let clampedPosition = max(0, min(positionSecs, resolvedDurationSecs(fallback: positionSecs)))
        let target = CMTime(seconds: clampedPosition, preferredTimescale: 600)

        cancelSeekTimeout()
        seekDisplayOverride = (
            requestID: requestID,
            itemID: itemID,
            positionSecs: clampedPosition,
            expiresAt: Date().addingTimeInterval(Self.seekDisplayOverrideDuration)
        )
        state.positionSecs = clampedPosition
        if resumePlayback {
            state.status = .loading
        }
        emitStateChanged()

        queuePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.finishSeek(
                    requestID: requestID,
                    itemID: itemID,
                    positionSecs: clampedPosition,
                    resumePlayback: resumePlayback,
                    finished: finished
                )
            }
        }

        seekTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.seekTimeoutNanoseconds)
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self else { return }
            self.handleSeekTimeout(
                requestID: requestID,
                itemID: itemID,
                positionSecs: clampedPosition,
                resumePlayback: resumePlayback
            )
        }
    }

    private func finishSeek(
        requestID: UInt64,
        itemID: ObjectIdentifier,
        positionSecs: Double,
        resumePlayback: Bool,
        finished: Bool
    ) {
        guard requestID == seekRequestID else { return }
        guard currentPlayerItem.map(ObjectIdentifier.init) == itemID else { return }

        cancelSeekTimeout()
        state.positionSecs = positionSecs

        if resumePlayback {
            queuePlayer?.play()
            updateState(queuePlayer?.timeControlStatus == .playing ? .playing : .loading)
        } else if finished {
            emitStateChanged()
        } else {
            updateState(.paused)
        }
    }

    private func handleSeekTimeout(
        requestID: UInt64,
        itemID: ObjectIdentifier,
        positionSecs: Double,
        resumePlayback: Bool
    ) {
        guard requestID == seekRequestID else { return }
        guard currentPlayerItem.map(ObjectIdentifier.init) == itemID else { return }

        seekTimeoutTask = nil
        state.positionSecs = positionSecs
        if resumePlayback {
            queuePlayer?.play()
            updateState(.loading)
        } else {
            emitStateChanged()
        }
    }

    private func cancelSeekTimeout() {
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
    }

    private func setupPeriodicTimeObserver() {
        guard let queuePlayer else { return }
        let observedPlayer = queuePlayer
        let observedItem = currentPlayerItem

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = queuePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.queuePlayer === observedPlayer else { return }
                guard self.currentPlayerItem === observedItem else { return }
                self.state.positionSecs = self.displayPositionSecs(actualPositionSecs: self.sanitizedSeconds(time))
                self.state.durationSecs = self.resolvedDurationSecs(fallback: self.state.durationSecs)
                self.emitStateChanged()
            }
        }
    }

    private func displayPositionSecs(actualPositionSecs: Double) -> Double {
        guard let override = seekDisplayOverride else { return actualPositionSecs }
        guard override.requestID == seekRequestID,
              currentPlayerItem.map(ObjectIdentifier.init) == override.itemID,
              override.expiresAt > Date()
        else {
            seekDisplayOverride = nil
            return actualPositionSecs
        }

        if abs(actualPositionSecs - override.positionSecs) < 0.75 {
            seekDisplayOverride = nil
            return actualPositionSecs
        }

        return override.positionSecs
    }

    private func currentPositionSecs() -> Double {
        guard let queuePlayer else { return state.positionSecs }
        return sanitizedSeconds(queuePlayer.currentTime())
    }

    private func resolvedDurationSecs(fallback: Double) -> Double {
        if let currentPlayerItem {
            let duration = sanitizedSeconds(currentPlayerItem.duration)
            if duration > 0 {
                return duration
            }
        }
        return max(fallback, 0)
    }

    private func sanitizedSeconds(_ time: CMTime) -> Double {
        guard time.isNumeric else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, !seconds.isNaN else { return 0 }
        return max(seconds, 0)
    }

    private func matchesTerminalStatus(_ status: StreamingPlaybackStatus) -> Bool {
        switch status {
        case .idle, .stopped, .error:
            return true
        case .loading, .playing, .paused:
            return false
        }
    }

    private func isPlayingLike(status: StreamingPlaybackStatus) -> Bool {
        switch status {
        case .loading, .playing:
            return true
        case .idle, .paused, .stopped, .error:
            return false
        }
    }

    private func cleanupPlayer() {
        cancelSeekTimeout()
        seekDisplayOverride = nil
        if let timeObserver, let queuePlayer {
            queuePlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        for (_, observer) in itemFinishedObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemFinishedObservers.removeAll()
        naturallyEndedItemIDs.removeAll()
        transitionedItemIDsAwaitingNaturalEnd.removeAll()

        currentItemObservation = nil
        itemStatusObservation = nil
        itemDurationObservation = nil
        statusObservations.removeAll()

        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        currentPlayerItem = nil
        hasNextPreloaded = false
    }

    deinit {
        MainActor.assumeIsolated {
            cleanupPlayer()
        }
    }
}
