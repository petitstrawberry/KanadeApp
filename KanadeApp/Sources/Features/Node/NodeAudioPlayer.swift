import Foundation
@preconcurrency import SFBAudioEngine

final class NodeAudioPlayer: @unchecked Sendable {
    struct QueueItem: Sendable, Equatable {
        let trackID: String
        let url: URL
    }

    struct Snapshot: Sendable {
        let status: NodePlaybackStatus
        let positionSecs: Double
        let volume: Int
        let mpdSongIndex: Int?
        let projectionGeneration: Int?
    }

    var stateDidChange: (@Sendable () -> Void)?
    var errorHandler: (@Sendable (any Error) -> Void)?

    private let queue = DispatchQueue(label: "com.petitstrawberry.KanadeApp.node-audio-player", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let player: AudioPlayer
    private let delegateProxy: DelegateProxy
    private let metadataSession: URLSession
    private let clock = ContinuousClock()

    private var items: [QueueItem] = []
    private var currentIndex: Int?
    private var volume: Int = 100
    private var status: NodePlaybackStatus = .stopped
    private var positionAnchor: Double = 0
    private var positionTimestamp: ContinuousClock.Instant?
    private var projectionGeneration: Int?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        metadataSession = URLSession(configuration: configuration)
        player = AudioPlayer()
        delegateProxy = DelegateProxy()
        queue.setSpecific(key: queueKey, value: 1)
        delegateProxy.owner = self
        player.delegate = delegateProxy
        applyVolumeLocked(100)
    }

    func snapshot() -> Snapshot {
        syncOnQueue {
            Snapshot(
                status: status,
                positionSecs: currentPositionLocked(),
                volume: volume,
                mpdSongIndex: currentIndex,
                projectionGeneration: projectionGeneration
            )
        }
    }

    func play() {
        queue.async { [weak self] in
            guard let self, self.currentIndex != nil else { return }
            do {
                switch self.status {
                case .paused:
                    _ = self.player.resume()
                    self.setPlaybackStateLocked(.playing)
                case .playing:
                    return
                case .stopped, .loading:
                    self.status = .loading
                    try self.player.play()
                }
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.player.pause()
            self.setPlaybackStateLocked(.paused)
            self.notifyStateDidChange()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player.stop()
            self.positionAnchor = 0
            self.positionTimestamp = nil
            self.status = .stopped
            self.notifyStateDidChange()
        }
    }

    func seek(to positionSecs: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let clampedPosition = max(0, positionSecs)
            _ = self.player.seek(time: clampedPosition)
            self.positionAnchor = clampedPosition
            self.positionTimestamp = self.status == .playing ? self.clock.now : nil
            self.notifyStateDidChange()
        }
    }

    func setVolume(_ volume: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.applyVolumeLocked(volume)
            self.notifyStateDidChange()
        }
    }

    func setQueue(_ items: [QueueItem], projectionGeneration: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.items = items
            self.currentIndex = items.isEmpty ? nil : 0
            self.projectionGeneration = projectionGeneration
            self.positionAnchor = 0
            self.positionTimestamp = nil
            self.status = .stopped
            do {
                try self.rebuildQueueLocked(startPosition: 0, shouldPlay: false)
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func add(_ items: [QueueItem]) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousCurrentTrackID = self.currentIndex.flatMap { self.items.indices.contains($0) ? self.items[$0].trackID : nil }
            let previousStatus = self.status
            let previousPosition = self.currentPositionLocked()
            self.items.append(contentsOf: items)
            if self.currentIndex == nil, !self.items.isEmpty {
                self.currentIndex = 0
            }
            let shouldPreservePosition = previousCurrentTrackID != nil && previousCurrentTrackID == self.currentIndex.flatMap { self.items[$0].trackID }
            do {
                try self.rebuildQueueLocked(
                    startPosition: shouldPreservePosition ? previousPosition : 0,
                    shouldPlay: previousStatus == .playing
                )
                if previousStatus == .paused, shouldPreservePosition {
                    self.status = .paused
                    self.positionAnchor = previousPosition
                    self.positionTimestamp = nil
                }
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func remove(at index: Int) {
        queue.async { [weak self] in
            guard let self, self.items.indices.contains(index) else { return }
            let previousCurrentTrackID = self.currentIndex.flatMap { self.items.indices.contains($0) ? self.items[$0].trackID : nil }
            let previousStatus = self.status
            let previousPosition = self.currentPositionLocked()

            self.items.remove(at: index)
            if self.items.isEmpty {
                self.currentIndex = nil
            } else if let currentIndex = self.currentIndex {
                if index < currentIndex {
                    self.currentIndex = currentIndex - 1
                } else if index == currentIndex {
                    self.currentIndex = min(currentIndex, self.items.count - 1)
                    self.positionAnchor = 0
                    self.positionTimestamp = nil
                }
            } else {
                self.currentIndex = 0
            }

            let currentTrackID = self.currentIndex.flatMap { self.items[$0].trackID }
            let shouldPreservePosition = previousCurrentTrackID == currentTrackID
            do {
                try self.rebuildQueueLocked(
                    startPosition: shouldPreservePosition ? previousPosition : 0,
                    shouldPlay: previousStatus == .playing && currentTrackID != nil
                )
                if previousStatus == .paused, shouldPreservePosition {
                    self.status = .paused
                    self.positionAnchor = previousPosition
                    self.positionTimestamp = nil
                }
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func move(from sourceIndex: Int, to destinationIndex: Int) {
        queue.async { [weak self] in
            guard let self, self.items.indices.contains(sourceIndex), self.items.indices.contains(destinationIndex) else { return }
            let previousCurrentTrackID = self.currentIndex.flatMap { self.items.indices.contains($0) ? self.items[$0].trackID : nil }
            let previousStatus = self.status
            let previousPosition = self.currentPositionLocked()

            let item = self.items.remove(at: sourceIndex)
            self.items.insert(item, at: destinationIndex)

            if let currentIndex = self.currentIndex {
                if currentIndex == sourceIndex {
                    self.currentIndex = destinationIndex
                } else if sourceIndex < currentIndex, destinationIndex >= currentIndex {
                    self.currentIndex = currentIndex - 1
                } else if sourceIndex > currentIndex, destinationIndex <= currentIndex {
                    self.currentIndex = currentIndex + 1
                }
            }

            let currentTrackID = self.currentIndex.flatMap { self.items[$0].trackID }
            let shouldPreservePosition = previousCurrentTrackID == currentTrackID
            do {
                try self.rebuildQueueLocked(
                    startPosition: shouldPreservePosition ? previousPosition : 0,
                    shouldPlay: previousStatus == .playing && currentTrackID != nil
                )
                if previousStatus == .paused, shouldPreservePosition {
                    self.status = .paused
                    self.positionAnchor = previousPosition
                    self.positionTimestamp = nil
                }
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }

        return queue.sync(execute: body)
    }

    private func currentPositionLocked() -> Double {
        guard status == .playing, let positionTimestamp else {
            return positionAnchor
        }

        return max(0, positionAnchor + Double(positionTimestamp.duration(to: clock.now).components.seconds))
    }

    private func setPlaybackStateLocked(_ newStatus: NodePlaybackStatus) {
        let currentPosition = currentPositionLocked()
        positionAnchor = newStatus == .stopped ? 0 : currentPosition
        positionTimestamp = newStatus == .playing ? clock.now : nil
        status = newStatus
    }

    private func applyVolumeLocked(_ volume: Int) {
        let clampedVolume = min(max(volume, 0), 100)
        self.volume = clampedVolume
        player.modifyProcessingGraph { [player] _ in
            player.mainMixerNode.outputVolume = Float(clampedVolume) / 100
        }
    }

    private func rebuildQueueLocked(startPosition: Double, shouldPlay: Bool) throws {
        player.stop()
        player.reset()

        guard let currentIndex, items.indices.contains(currentIndex) else {
            status = .stopped
            positionAnchor = 0
            positionTimestamp = nil
            return
        }

        for item in items[currentIndex...] {
            let decoder = try makeDecoder(for: item)
            try player.enqueue(decoder, immediate: false)
        }

        if startPosition > 0 {
            _ = player.seek(time: startPosition)
        }

        positionAnchor = startPosition
        positionTimestamp = nil
        if shouldPlay {
            status = .loading
            try player.play()
        } else {
            status = .stopped
        }
    }

    private func makeDecoder(for item: QueueItem) throws -> AudioDecoder {
        let mimeType = fetchMIMEType(for: item.url)
        let inputSource = HTTPInputSource(url: item.url, mimeTypeHint: mimeType)
        return try AudioDecoder(inputSource: inputSource, mimeTypeHint: mimeType)
    }

    private func fetchMIMEType(for url: URL) -> String? {
        if let mimeType = performMetadataRequest(url: url, method: "HEAD") {
            return mimeType
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        return performMetadataRequest(request: request)
    }

    private func performMetadataRequest(url: URL, method: String) -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return performMetadataRequest(request: request)
    }

    private func performMetadataRequest(request: URLRequest) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var mimeType: String?
        metadataSession.dataTask(with: request) { _, response, _ in
            defer { semaphore.signal() }
            guard let response = response as? HTTPURLResponse,
                  (200 ... 299).contains(response.statusCode) || response.statusCode == 206 else {
                return
            }
            mimeType = response.mimeType
        }.resume()
        _ = semaphore.wait(timeout: .now() + 15)
        return mimeType
    }

    private func handleError(_ error: any Error) {
        status = .stopped
        positionAnchor = 0
        positionTimestamp = nil
        notifyStateDidChange()
        errorHandler?(error)
    }

    private func notifyStateDidChange() {
        stateDidChange?()
    }

    fileprivate func handlePlaybackStateChange(_ playbackState: AudioPlayer.PlaybackState) {
        queue.async { [weak self] in
            guard let self else { return }
            switch playbackState {
            case .playing:
                self.setPlaybackStateLocked(.playing)
            case .paused:
                self.setPlaybackStateLocked(.paused)
            case .stopped:
                if self.status != .stopped {
                    self.setPlaybackStateLocked(.stopped)
                }
            @unknown default:
                break
            }
            self.notifyStateDidChange()
        }
    }

    fileprivate func handleRenderingComplete() {
        queue.async { [weak self] in
            guard let self, let currentIndex else { return }
            if currentIndex < self.items.count - 1 {
                self.currentIndex = currentIndex + 1
                self.positionAnchor = 0
                self.positionTimestamp = self.status == .playing ? self.clock.now : nil
            }
            self.notifyStateDidChange()
        }
    }

    fileprivate func handleEndOfAudio() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setPlaybackStateLocked(.stopped)
            self.notifyStateDidChange()
        }
    }

    fileprivate func handleErrorFromDelegate(_ error: any Error) {
        queue.async { [weak self] in
            self?.handleError(error)
        }
    }
}

private final class DelegateProxy: NSObject, AudioPlayer.Delegate {
    weak var owner: NodeAudioPlayer?

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        owner?.handlePlaybackStateChange(playbackState)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingComplete decoder: any PCMDecoding) {
        owner?.handleRenderingComplete()
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        owner?.handleEndOfAudio()
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        owner?.handleErrorFromDelegate(error)
    }
}
