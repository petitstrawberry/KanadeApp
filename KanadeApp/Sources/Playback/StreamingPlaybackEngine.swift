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

    func play() {
        guard let queuePlayer, currentPlayerItem != nil else {
            updateState(.stopped)
            return
        }

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

        queuePlayer.pause()
        state.positionSecs = currentPositionSecs()
        updateState(currentPlayerItem == nil ? .stopped : .paused)
    }

    func stop() {
        cleanupPlayer()
        state.positionSecs = 0
        state.durationSecs = 0
        updateState(.stopped)
    }

    func seek(to positionSecs: Double) {
        guard let queuePlayer else { return }

        let clampedPosition = max(0, min(positionSecs, resolvedDurationSecs(fallback: positionSecs)))
        let target = CMTime(seconds: clampedPosition, preferredTimescale: 600)
        queuePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.positionSecs = clampedPosition
                self.emitStateChanged()
            }
        }
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
                    self?.handleTimeControlStatusChanged(player.timeControlStatus)
                }
            }
        ]

        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let newItem = change.newValue ?? player.currentItem,
                      newItem !== self.currentPlayerItem else { return }

                self.transitionToItem(newItem)
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChanged(item.status)
            }
        }

        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.durationSecs = self.sanitizedSeconds(item.duration)
                self.emitStateChanged()
            }
        }

        observeItemFinished(item)
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

                self.state.positionSecs = self.resolvedDurationSecs(fallback: self.state.positionSecs)
                self.updateState(.stopped)
                self.onPlaybackFinished?()
            }
        }
        itemFinishedObservers.append((item, observer))
    }

    private func transitionToItem(_ newItem: AVPlayerItem) {
        let previousItem = currentPlayerItem
        currentPlayerItem = newItem
        state.positionSecs = 0
        state.durationSecs = 0

        itemStatusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChanged(item.status)
            }
        }

        itemDurationObservation = newItem.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        state.positionSecs = currentPositionSecs()
        state.durationSecs = resolvedDurationSecs(fallback: state.durationSecs)
        emitStateChanged()
    }

    private func emitStateChanged() {
        onStateChanged?(state)
    }

    private func setupPeriodicTimeObserver() {
        guard let queuePlayer else { return }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = queuePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.positionSecs = self.sanitizedSeconds(time)
                self.state.durationSecs = self.resolvedDurationSecs(fallback: self.state.durationSecs)
                self.emitStateChanged()
            }
        }
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

    private func cleanupPlayer() {
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
