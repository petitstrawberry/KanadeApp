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
    private var player: AVPlayer?
    private var currentPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservations: [NSKeyValueObservation] = []
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var itemDidPlayToEndTimeObserver: NSObjectProtocol?
    private var shouldAutoplay = true

    var onStateChanged: ((StreamingTransportState) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    private(set) var state = StreamingTransportState(
        status: .idle,
        positionSecs: 0,
        durationSecs: 0,
        volume: 100
    )

    func load(signedURL: URL, autoplay: Bool = true) {
        cleanupPlayer()

        shouldAutoplay = autoplay
        let item = AVPlayerItem(url: signedURL)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(state.volume) / 100.0

        self.player = player
        currentPlayerItem = item

        observe(player: player, item: item)
        setupPeriodicTimeObserver()

        let initialStatus: StreamingPlaybackStatus = autoplay ? .loading : .paused
        state.positionSecs = 0
        state.durationSecs = 0
        updateState(initialStatus)
    }

    func play() {
        guard let player, currentPlayerItem != nil else {
            updateState(.stopped)
            return
        }

        player.play()
        if player.timeControlStatus != .playing {
            updateState(.loading)
        }
    }

    func pause() {
        guard let player else {
            updateState(.stopped)
            return
        }

        player.pause()
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
        guard let player else { return }

        let clampedPosition = max(0, min(positionSecs, resolvedDurationSecs(fallback: positionSecs)))
        let target = CMTime(seconds: clampedPosition, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
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
        player?.volume = Float(clampedVolume) / 100.0
        emitStateChanged()
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        statusObservations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    self?.handleTimeControlStatusChanged(player.timeControlStatus)
                }
            }
        ]

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

        itemDidPlayToEndTimeObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.positionSecs = self.resolvedDurationSecs(fallback: self.state.positionSecs)
                self.updateState(.stopped)
                self.onPlaybackFinished?()
            }
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
                player?.play()
            } else {
                player?.pause()
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
        guard let player else { return }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.positionSecs = self.sanitizedSeconds(time)
                self.state.durationSecs = self.resolvedDurationSecs(fallback: self.state.durationSecs)
                self.emitStateChanged()
            }
        }
    }

    private func currentPositionSecs() -> Double {
        guard let player else { return state.positionSecs }
        return sanitizedSeconds(player.currentTime())
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
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let itemDidPlayToEndTimeObserver {
            NotificationCenter.default.removeObserver(itemDidPlayToEndTimeObserver)
        }
        itemDidPlayToEndTimeObserver = nil

        itemStatusObservation = nil
        itemDurationObservation = nil
        statusObservations.removeAll()

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentPlayerItem = nil
    }

    deinit {
        MainActor.assumeIsolated {
            cleanupPlayer()
        }
    }
}
