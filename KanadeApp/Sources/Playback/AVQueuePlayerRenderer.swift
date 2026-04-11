import Foundation
import AVFoundation
import Observation
import KanadeKit

@MainActor
@Observable
final class AVQueuePlayerRenderer: AudioRenderer {
    var state = RendererState()

    @ObservationIgnored var onStateChanged: ((RendererState) -> Void)?
    @ObservationIgnored var onTrackAdvanced: (() -> Void)?
    @ObservationIgnored var onTrackFinished: (() -> Void)?

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemBufferEmptyObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemLikelyToKeepUpObservation: NSKeyValueObservation?
    @ObservationIgnored private var didPlayToEndObserver: NSObjectProtocol?
    @ObservationIgnored private var accessLogObserver: NSObjectProtocol?

    @ObservationIgnored private var allURLs: [URL] = []
    @ObservationIgnored private var loadedURLs: [URL] = []
    @ObservationIgnored private var itemURLMap: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var currentTrackIndex = 0
    @ObservationIgnored private var shouldAutoplay = true

    init() {
        player.actionAtItemEnd = .advance
        installObservers()
        installTimeObserver()
        setVolume(100)
        refreshState()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
        }
        if let accessLogObserver {
            NotificationCenter.default.removeObserver(accessLogObserver)
        }
    }

    func loadTrack(url: URL, autoplay: Bool) {
        allURLs = [url]
        currentTrackIndex = 0
        shouldAutoplay = autoplay
        rebuildQueue(autoplay: autoplay)
    }

    func loadTracks(urls: [URL], startIndex: Int) {
        guard !urls.isEmpty else {
            stop()
            return
        }

        allURLs = urls
        currentTrackIndex = min(max(startIndex, 0), urls.count - 1)
        shouldAutoplay = true
        rebuildQueue(autoplay: true)
    }

    func play() {
        guard player.currentItem != nil else { return }
        shouldAutoplay = true
        player.play()
        refreshState()
    }

    func pause() {
        shouldAutoplay = false
        player.pause()
        refreshState(forceStatus: .paused)
    }

    func stop() {
        shouldAutoplay = false
        player.pause()
        player.removeAllItems()
        allURLs = []
        loadedURLs = []
        itemURLMap.removeAll()
        currentTrackIndex = 0
        applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
    }

    func seek(to positionSecs: Double) {
        guard player.currentItem != nil else { return }

        let time = CMTime(seconds: max(positionSecs, 0), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }
    }

    func setVolume(_ volume: Int) {
        let clampedVolume = min(max(volume, 0), 100)
        player.volume = Float(clampedVolume) / 100.0
        state.volume = clampedVolume
        onStateChanged?(state)
    }

    func advanceToNextTrack() -> Bool {
        let nextIndex = currentTrackIndex + 1
        guard allURLs.indices.contains(nextIndex) else {
            return false
        }

        currentTrackIndex = nextIndex

        if player.items().count > 1 {
            player.advanceToNextItem()
        } else {
            let item = makeItem(url: allURLs[nextIndex])
            player.removeAllItems()
            player.replaceCurrentItem(with: item)
        }

        queueUpcomingTrackIfNeeded(force: true)

        if shouldAutoplay {
            player.play()
            refreshState(forceStatus: .loading)
        } else {
            player.pause()
            refreshState(forceStatus: .paused)
        }

        return true
    }

    func prepareNext(url: URL) {
        guard player.currentItem != nil else { return }
        guard !loadedURLs.contains(url) else { return }

        let item = makeItem(url: url)
        item.preferredForwardBufferDuration = 3
        player.insert(item, after: player.items().last)
        refreshLoadedURLs()
    }

    private func rebuildQueue(autoplay: Bool) {
        player.pause()
        player.removeAllItems()
        itemURLMap.removeAll()
        loadedURLs = []

        guard allURLs.indices.contains(currentTrackIndex) else {
            applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
            return
        }

        let currentURL = allURLs[currentTrackIndex]
        let currentItem = makeItem(url: currentURL)
        player.replaceCurrentItem(with: currentItem)
        queueUpcomingTrackIfNeeded(force: true)

        refreshLoadedURLs()
        refreshState(forceStatus: autoplay ? .loading : .paused)

        if autoplay {
            player.play()
        } else {
            player.pause()
        }
    }

    private func installObservers() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }

        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let item = change.newValue as? AVPlayerItem,
                   let url = self.itemURLMap[ObjectIdentifier(item)],
                   let index = self.allURLs.firstIndex(of: url) {
                    self.currentTrackIndex = index
                }

                self.observeCurrentItem()
                self.refreshLoadedURLs()
                self.queueUpcomingTrackIfNeeded(force: false)
                self.refreshState()
            }
        }

        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let finishedItem = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }

                let autoAdvanced = player.currentItem != nil && player.currentItem !== finishedItem

                if autoAdvanced {
                    if let nextURL = player.currentItem.flatMap({ self.itemURLMap[ObjectIdentifier($0)] }) {
                        allURLs = [nextURL]
                        currentTrackIndex = 0
                    }
                    refreshLoadedURLs()
                    queueUpcomingTrackIfNeeded(force: true)
                    refreshState()
                    onTrackAdvanced?()
                } else {
                    refreshLoadedURLs()
                    refreshState()
                    onTrackFinished?()
                }
            }
        }

        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      item === self.player.currentItem,
                      let event = item.accessLog()?.events.last else { return }

                if self.state.status == .loading,
                   event.numberOfBytesTransferred > 0 || event.segmentsDownloadedDuration > 0 {
                    self.refreshState()
                }
            }
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshState()
                self.prepareUpcomingTrackIfNeeded()
            }
        }
    }

    private func observeCurrentItem() {
        itemStatusObservation = nil
        itemBufferEmptyObservation = nil
        itemLikelyToKeepUpObservation = nil

        guard let item = player.currentItem else { return }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.refreshState()
                case .failed:
                    self.applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: self.state.volume))
                case .unknown:
                    self.refreshState(forceStatus: .loading)
                @unknown default:
                    self.applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: self.state.volume))
                }
            }
        }

        itemBufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard item.isPlaybackBufferEmpty else { return }
                self?.refreshState(forceStatus: .loading)
            }
        }

        itemLikelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard item.isPlaybackLikelyToKeepUp else { return }
                self?.refreshState()
            }
        }
    }

    private func prepareUpcomingTrackIfNeeded() {
        guard state.status == .playing else { return }
        guard state.durationSecs > 0, state.durationSecs - state.positionSecs <= 3 else { return }
        queueUpcomingTrackIfNeeded(force: false)
    }

    private func queueUpcomingTrackIfNeeded(force: Bool) {
        let nextIndex = currentTrackIndex + 1
        guard allURLs.indices.contains(nextIndex) else { return }

        let nextURL = allURLs[nextIndex]
        if loadedURLs.contains(nextURL) {
            return
        }

        if force || player.items().count <= 1 {
            prepareNext(url: nextURL)
        }
    }

    private func makeItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        itemURLMap[ObjectIdentifier(item)] = url
        return item
    }

    private func refreshLoadedURLs() {
        var urls: [URL] = []

        if let currentItem = player.currentItem,
           let currentURL = itemURLMap[ObjectIdentifier(currentItem)] {
            urls.append(currentURL)
        }

        urls.append(contentsOf: player.items().compactMap { itemURLMap[ObjectIdentifier($0)] })
        loadedURLs = urls
    }

    private func refreshState(forceStatus: PlaybackStatus? = nil) {
        let currentTime = player.currentTime().seconds
        let positionSecs = currentTime.isFinite ? max(currentTime, 0) : 0
        let durationTime = player.currentItem?.duration.seconds ?? 0
        let durationSecs = durationTime.isFinite ? max(durationTime, 0) : 0

        let status: PlaybackStatus
        if let forceStatus {
            status = forceStatus
        } else if player.currentItem == nil {
            status = .stopped
        } else if player.currentItem?.status == .failed {
            status = .stopped
        } else {
            switch player.timeControlStatus {
            case .playing:
                status = .playing
            case .waitingToPlayAtSpecifiedRate:
                status = .loading
            case .paused:
                status = durationSecs == 0 && shouldAutoplay ? .loading : .paused
            @unknown default:
                status = .stopped
            }
        }

        applyState(
            RendererState(
                status: status,
                positionSecs: positionSecs,
                durationSecs: durationSecs,
                volume: state.volume
            )
        )
    }

    private func applyState(_ newState: RendererState) {
        state = newState
        onStateChanged?(state)
    }
}
