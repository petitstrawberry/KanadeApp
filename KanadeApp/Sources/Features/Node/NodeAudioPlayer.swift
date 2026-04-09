import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
@preconcurrency import SFBAudioEngine

final class NodeAudioPlayer: @unchecked Sendable {
    struct QueueItem: Sendable, Equatable {
        let trackID: String
        let url: URL
        let mimeType: String?
    }

    struct Snapshot: Sendable {
        let status: NodePlaybackStatus
        let positionSecs: Double
        let volume: Int
        let mpdSongIndex: Int?
        let currentTrackID: String?
        let projectionGeneration: Int?
        let repeatMode: LocalRepeatMode
        let shuffleEnabled: Bool
    }

    enum LocalRepeatMode: String, Sendable {
        case off
        case one
        case all
    }

    private struct DecoderContext {
        let epoch: UInt64
        let index: Int
    }

    var stateDidChange: (@Sendable () -> Void)?
    var errorHandler: (@Sendable (any Error) -> Void)?

    private let queue = DispatchQueue(label: "com.petitstrawberry.KanadeApp.node-audio-player", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var player: AudioPlayer
    private var delegateProxy: DelegateProxy
    private let clock = ContinuousClock()
    private var downloadedTempURLs: Set<URL> = []

    private var items: [QueueItem] = []
    private var currentIndex: Int?
    private var volume: Int = 100
    private var status: NodePlaybackStatus = .stopped
    private var positionAnchor: Double = 0
    private var positionTimestamp: ContinuousClock.Instant?
    private var projectionGeneration: Int?
    private var repeatMode: LocalRepeatMode = .off
    private var shuffleEnabled = false
    private var playbackEpoch: UInt64 = 0
    private var suppressRebuildStoppedCallback = false
    private var requiresQueuePreparation = false
    private var decoderContexts: [ObjectIdentifier: DecoderContext] = [:]
    private var preparedDecoderIndices: Set<Int> = []
    private var shuffledIndices: [Int] = []
    private var shuffledCursor: Int?

    init() {
        player = AudioPlayer()
        delegateProxy = DelegateProxy(epoch: 0)
        queue.setSpecific(key: queueKey, value: 1)
        delegateProxy.owner = self
        player.delegate = delegateProxy
        applyVolumeLocked(100)
        configureAudioSession()
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            print("[NodeAudioPlayer] AVAudioSession error: \(error)")
        }
        #endif
    }

    func snapshot() -> Snapshot {
        syncOnQueue {
            Snapshot(
                status: status,
                positionSecs: currentPositionLocked(),
                volume: volume,
                mpdSongIndex: currentIndex,
                currentTrackID: currentIndex.flatMap { items.indices.contains($0) ? items[$0].trackID : nil },
                projectionGeneration: projectionGeneration,
                repeatMode: repeatMode,
                shuffleEnabled: shuffleEnabled
            )
        }
    }

    func play() {
        queue.async { [weak self] in
            guard let self, self.currentIndex != nil else { return }
            do {
                switch self.status {
                case .paused:
                    if self.requiresQueuePreparation {
                        try self.rebuildQueueLocked(startPosition: self.positionAnchor, shouldPlay: true)
                    } else {
                        _ = self.player.resume()
                        self.setPlaybackStateLocked(.playing)
                    }
                case .playing:
                    return
                case .stopped, .loading:
                    if self.requiresQueuePreparation {
                        try self.rebuildQueueLocked(startPosition: self.positionAnchor, shouldPlay: true)
                    } else {
                        self.status = .loading
                        try self.player.play()
                    }
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
            self.invalidatePlaybackEpochLocked()
            self.suppressRebuildStoppedCallback = false
            self.player.stop()
            self.player.reset()
            self.cleanupTempFilesLocked()
            self.positionAnchor = 0
            self.positionTimestamp = nil
            self.status = .stopped
            self.requiresQueuePreparation = self.currentIndex != nil
            self.notifyStateDidChange()
        }
    }

    func seek(to positionSecs: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let clampedPosition = max(0, positionSecs)
            let currentPosition = self.currentPositionLocked()
            if abs(clampedPosition - currentPosition) < 0.1 {
                return
            }
            _ = self.player.seek(time: clampedPosition)
            self.positionAnchor = clampedPosition
            self.positionTimestamp = self.status == .playing ? self.clock.now : nil
            self.notifyStateDidChange()
        }
    }

    func play(at index: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.items.indices.contains(index) else { return }
            do {
                try self.transitionToItemLocked(index)
                if self.status == .paused || self.status == .stopped {
                    try self.rebuildQueueLocked(startPosition: 0, shouldPlay: true)
                }
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func setVolume(_ volume: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.applyVolumeLocked(volume)
            self.notifyStateDidChange()
        }
    }

    func next() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let targetIndex = self.nextIndexLocked(userInitiated: true) else { return }
            do {
                try self.transitionToItemLocked(targetIndex)
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func previous() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let currentIndex = self.currentIndex else { return }
            if self.currentPositionLocked() >= 5 {
                _ = self.player.seek(time: 0)
                self.positionAnchor = 0
                self.positionTimestamp = self.status == .playing ? self.clock.now : nil
                self.notifyStateDidChange()
                return
            }

            let targetIndex = self.previousIndexLocked(userInitiated: true) ?? currentIndex
            do {
                try self.transitionToItemLocked(targetIndex)
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func setRepeat(_ repeatMode: LocalRepeatMode) {
        queue.async { [weak self] in
            guard let self else { return }
            self.repeatMode = repeatMode
            self.notifyStateDidChange()
        }
    }

    func setShuffle(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.shuffleEnabled != enabled else { return }
            self.shuffleEnabled = enabled
            self.rebuildShuffleOrderLocked(anchoredAt: self.currentIndex)
            self.notifyStateDidChange()
        }
    }

    func replaceAndPlay(_ items: [QueueItem], at index: Int, projectionGeneration: Int = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            self.items = items
            if items.isEmpty {
                self.currentIndex = nil
            } else {
                self.currentIndex = min(max(index, 0), items.count - 1)
            }
            self.projectionGeneration = projectionGeneration
            self.positionAnchor = 0
            self.positionTimestamp = nil
            self.status = .stopped
            self.requiresQueuePreparation = !items.isEmpty
            self.rebuildShuffleOrderLocked(anchoredAt: self.currentIndex)
            self.resetPlayerForQueueMutationLocked()
            do {
                if !items.isEmpty {
                    try self.rebuildQueueLocked(startPosition: 0, shouldPlay: true)
                }
                self.notifyStateDidChange()
            } catch {
                self.handleError(error)
            }
        }
    }

    func clearQueue() {
        queue.async { [weak self] in
            guard let self else { return }
            self.items = []
            self.currentIndex = nil
            self.projectionGeneration = nil
            self.positionAnchor = 0
            self.positionTimestamp = nil
            self.status = .stopped
            self.requiresQueuePreparation = false
            self.rebuildShuffleOrderLocked(anchoredAt: nil)
            self.resetPlayerForQueueMutationLocked()
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
            self.requiresQueuePreparation = !items.isEmpty
            self.rebuildShuffleOrderLocked(anchoredAt: self.currentIndex)
            self.resetPlayerForQueueMutationLocked()
            self.notifyStateDidChange()
        }
    }

    func add(_ items: [QueueItem]) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousStatus = self.status
            let currentIndex = self.currentIndex
            let appendStartIndex = self.items.endIndex
            self.items.append(contentsOf: items)
            if self.currentIndex == nil, !self.items.isEmpty {
                self.currentIndex = 0
            }
            self.rebuildShuffleOrderLocked(anchoredAt: self.currentIndex)
            do {
                if previousStatus == .playing,
                   let currentIndex,
                   appendStartIndex > currentIndex {
                    let epoch = self.playbackEpoch
                    if self.preparedDecoderIndices.count < 2 {
                        try? self.prefetchNextDecoderLocked(after: currentIndex, epoch: epoch)
                    }
                } else {
                    let previousCurrentTrackID = currentIndex.flatMap { self.items.indices.contains($0) ? self.items[$0].trackID : nil }
                    let previousPosition = self.currentPositionLocked()
                    let shouldPreservePosition = previousCurrentTrackID != nil && previousCurrentTrackID == self.currentIndex.flatMap { self.items[$0].trackID }
                    if previousStatus == .playing {
                        try self.rebuildQueueLocked(
                            startPosition: shouldPreservePosition ? previousPosition : 0,
                            shouldPlay: true
                        )
                    } else {
                        self.requiresQueuePreparation = self.currentIndex != nil
                        self.resetPlayerForQueueMutationLocked()
                        self.status = .stopped
                    }
                    if previousStatus == .paused, shouldPreservePosition {
                        self.status = .paused
                        self.positionAnchor = previousPosition
                        self.positionTimestamp = nil
                        self.suppressRebuildStoppedCallback = true
                    }
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

            self.rebuildShuffleOrderLocked(anchoredAt: self.currentIndex)

            let currentTrackID = self.currentIndex.flatMap { self.items[$0].trackID }
            let shouldPreservePosition = previousCurrentTrackID == currentTrackID
            do {
                if previousStatus == .playing, currentTrackID != nil {
                    try self.rebuildQueueLocked(
                        startPosition: shouldPreservePosition ? previousPosition : 0,
                        shouldPlay: true
                    )
                } else {
                    self.requiresQueuePreparation = currentTrackID != nil
                    self.resetPlayerForQueueMutationLocked()
                    self.status = .stopped
                }
                if previousStatus == .paused, shouldPreservePosition {
                    self.status = .paused
                    self.positionAnchor = previousPosition
                    self.positionTimestamp = nil
                    self.suppressRebuildStoppedCallback = true
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

            self.rebuildShuffleOrderLocked(anchoredAt: self.currentIndex)

            let currentTrackID = self.currentIndex.flatMap { self.items[$0].trackID }
            let shouldPreservePosition = previousCurrentTrackID == currentTrackID
            do {
                if previousStatus == .playing, currentTrackID != nil {
                    try self.rebuildQueueLocked(
                        startPosition: shouldPreservePosition ? previousPosition : 0,
                        shouldPlay: true
                    )
                } else {
                    self.requiresQueuePreparation = currentTrackID != nil
                    self.resetPlayerForQueueMutationLocked()
                    self.status = .stopped
                }
                if previousStatus == .paused, shouldPreservePosition {
                    self.status = .paused
                    self.positionAnchor = previousPosition
                    self.positionTimestamp = nil
                    self.suppressRebuildStoppedCallback = true
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

    private func rebuildShuffleOrderLocked(anchoredAt anchorIndex: Int?) {
        guard shuffleEnabled else {
            shuffledIndices = []
            shuffledCursor = nil
            return
        }

        let allIndices = Array(items.indices)
        guard !allIndices.isEmpty else {
            shuffledIndices = []
            shuffledCursor = nil
            return
        }

        if let anchorIndex, allIndices.contains(anchorIndex) {
            var remaining = allIndices.filter { $0 != anchorIndex }
            remaining.shuffle()
            shuffledIndices = [anchorIndex] + remaining
            shuffledCursor = 0
            return
        }

        shuffledIndices = allIndices.shuffled()
        shuffledCursor = shuffledIndices.isEmpty ? nil : 0
    }

    private func syncShuffleCursorLocked() {
        guard shuffleEnabled else {
            shuffledCursor = nil
            return
        }

        let allIndices = Set(items.indices)
        if Set(shuffledIndices) != allIndices || shuffledIndices.count != items.count {
            rebuildShuffleOrderLocked(anchoredAt: currentIndex)
            return
        }

        guard let currentIndex else {
            shuffledCursor = nil
            return
        }

        if let cursor = shuffledIndices.firstIndex(of: currentIndex) {
            shuffledCursor = cursor
        } else {
            rebuildShuffleOrderLocked(anchoredAt: currentIndex)
        }
    }

    private func nextIndexLocked(userInitiated: Bool) -> Int? {
        guard !items.isEmpty else { return nil }
        guard let currentIndex else { return items.startIndex }

        if shuffleEnabled {
            syncShuffleCursorLocked()
            guard let shuffledCursor, shuffledIndices.indices.contains(shuffledCursor) else { return currentIndex }
            let nextCursor = shuffledCursor + 1
            if shuffledIndices.indices.contains(nextCursor) {
                return shuffledIndices[nextCursor]
            }
            if !userInitiated, repeatMode == .one {
                return currentIndex
            }
            if repeatMode == .all {
                return shuffledIndices.first
            }
            return nil
        }

        let nextIndex = currentIndex + 1
        if items.indices.contains(nextIndex) {
            return nextIndex
        }
        if !userInitiated, repeatMode == .one {
            return currentIndex
        }
        if repeatMode == .all {
            return items.startIndex
        }
        return nil
    }

    private func previousIndexLocked(userInitiated: Bool) -> Int? {
        guard !items.isEmpty else { return nil }
        guard let currentIndex else { return items.startIndex }

        if shuffleEnabled {
            syncShuffleCursorLocked()
            guard let shuffledCursor, shuffledIndices.indices.contains(shuffledCursor) else { return currentIndex }
            let previousCursor = shuffledCursor - 1
            if shuffledIndices.indices.contains(previousCursor) {
                return shuffledIndices[previousCursor]
            }
            if !userInitiated, repeatMode == .one {
                return currentIndex
            }
            if repeatMode == .all {
                return shuffledIndices.last
            }
            return nil
        }

        let previousIndex = currentIndex - 1
        if items.indices.contains(previousIndex) {
            return previousIndex
        }
        if !userInitiated, repeatMode == .one {
            return currentIndex
        }
        if repeatMode == .all {
            return items.endIndex - 1
        }
        return nil
    }

    private func transitionToItemLocked(_ index: Int) throws {
        guard items.indices.contains(index) else { return }

        let previousStatus = status
        currentIndex = index
        syncShuffleCursorLocked()
        positionAnchor = 0
        positionTimestamp = nil

        switch previousStatus {
        case .playing, .loading:
            try rebuildQueueLocked(startPosition: 0, shouldPlay: true)
        case .paused:
            requiresQueuePreparation = true
            _ = resetPlayerForQueueMutationLocked()
            status = .paused
        case .stopped:
            requiresQueuePreparation = true
            _ = resetPlayerForQueueMutationLocked()
            status = .stopped
        }
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

    @discardableResult
    private func invalidatePlaybackEpochLocked() -> UInt64 {
        playbackEpoch &+= 1
        decoderContexts.removeAll()
        preparedDecoderIndices.removeAll()
        return playbackEpoch
    }

    private func shouldHandleDelegateCallbackLocked(epoch: UInt64?) -> Bool {
        guard let epoch else { return false }
        return epoch == playbackEpoch
    }

    private func rebuildQueueLocked(startPosition: Double, shouldPlay: Bool) throws {
        let rebuildEpoch = resetPlayerForQueueMutationLocked()

        guard let currentIndex, items.indices.contains(currentIndex) else {
            requiresQueuePreparation = false
            status = .stopped
            positionAnchor = 0
            positionTimestamp = nil
            return
        }

        do {
            try prepareDecoderIfNeededLocked(at: currentIndex, epoch: rebuildEpoch)

            if startPosition > 0 {
                _ = player.seek(time: startPosition)
            }

            positionAnchor = startPosition
            positionTimestamp = nil
            requiresQueuePreparation = false
            if shouldPlay {
                status = .loading
                try player.play()
                try? prefetchNextDecoderLocked(after: currentIndex, epoch: rebuildEpoch)
            } else {
                status = .stopped
            }
        } catch {
            _ = resetPlayerForQueueMutationLocked()
            requiresQueuePreparation = items.indices.contains(currentIndex)
            status = .stopped
            positionTimestamp = nil
            throw error
        }
    }

    private func prepareDecoderIfNeededLocked(at index: Int, epoch: UInt64) throws {
        guard items.indices.contains(index) else { return }
        guard !preparedDecoderIndices.contains(index) else { return }

        let decoder = try makeDecoder(for: items[index])
        try player.enqueue(decoder, immediate: false)
        let decoderID = ObjectIdentifier(decoder)
        decoderContexts[decoderID] = DecoderContext(epoch: epoch, index: index)
        preparedDecoderIndices.insert(index)
    }

    private func prefetchNextDecoderLocked(after index: Int, epoch: UInt64) throws {
        let nextIndex = index + 1
        guard items.indices.contains(nextIndex) else { return }
        try prepareDecoderIfNeededLocked(at: nextIndex, epoch: epoch)
    }

    @discardableResult
    private func advanceToNextItemLocked(epoch: UInt64) -> Bool {
        guard let currentIndex else { return false }
        guard let nextIndex = nextIndexLocked(userInitiated: false) else { return false }

        self.currentIndex = nextIndex
        syncShuffleCursorLocked()
        positionAnchor = 0
        positionTimestamp = status == .playing ? clock.now : nil

        guard nextIndex == currentIndex + 1 else {
            requiresQueuePreparation = true
            return true
        }

        do {
            try prepareDecoderIfNeededLocked(at: nextIndex, epoch: epoch)
            requiresQueuePreparation = false
            try? prefetchNextDecoderLocked(after: nextIndex, epoch: epoch)
        } catch {
            requiresQueuePreparation = true
        }
        return true
    }

    @discardableResult
    private func resetPlayerForQueueMutationLocked() -> UInt64 {
        let epoch = invalidatePlaybackEpochLocked()
        suppressRebuildStoppedCallback = true
        let previousPlayer = player
        previousPlayer.stop()
        previousPlayer.reset()
        cleanupTempFilesLocked()
        let nextDelegateProxy = DelegateProxy(epoch: epoch)
        let nextPlayer = AudioPlayer()
        nextDelegateProxy.owner = self
        nextPlayer.delegate = nextDelegateProxy
        player = nextPlayer
        delegateProxy = nextDelegateProxy
        applyVolumeLocked(volume)
        return epoch
    }

    private func makeDecoder(for item: QueueItem) throws -> AudioDecoder {
        if shouldDownloadFirst(mimeType: item.mimeType) {
            let ext = fileExtension(for: item.mimeType) ?? item.url.pathExtension
            let localURL = try downloadToTempFile(url: item.url, fileExtension: ext)
            return try AudioDecoder(url: localURL)
        }

        let inputSource = HTTPInputSource(url: item.url, mimeTypeHint: item.mimeType)
        return try AudioDecoder(inputSource: inputSource, mimeTypeHint: inputSource.resolvedMimeTypeHint())
    }

    private func shouldDownloadFirst(mimeType: String?) -> Bool {
        guard let mime = mimeType?.lowercased() else { return false }
        return mime.contains("mp4") || mime.contains("3gp")
    }

    private func fileExtension(for mimeType: String?) -> String? {
        guard let mime = mimeType?.lowercased() else { return nil }
        switch mime {
        case "audio/flac": return "flac"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg", "audio/oga": return "ogg"
        case "audio/opus": return "opus"
        case "audio/aac", "audio/x-aac", "audio/adts": return "aac"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/x-ms-wma": return "wma"
        case "audio/x-ape": return "ape"
        case "audio/x-wavpack": return "wv"
        case "audio/x-dsf": return "dsf"
        case "audio/x-dsdiff": return "dff"
        default: return nil
        }
    }

    private func downloadToTempFile(url: URL, fileExtension ext: String) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        var localURL: URL?
        var downloadError: Error?

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            guard let data = data, !data.isEmpty else {
                downloadError = NSError(domain: "NodeAudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response for \(url.lastPathComponent)"])
                return
            }
            let resolvedExt = ext.isEmpty ? "tmp" : ext
            let filename = "kanade_\(UUID().uuidString).\(resolvedExt)"
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: dest)
                localURL = dest
            } catch {
                downloadError = error
            }
        }
        task.resume()
        semaphore.wait()

        if let error = downloadError {
            throw error
        }
        guard let result = localURL else {
            throw NSError(domain: "NodeAudioPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download file"])
        }
        downloadedTempURLs.insert(result)
        return result
    }

    private func cleanupTempFilesLocked() {
        for url in downloadedTempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedTempURLs.removeAll()
    }

    private func handleError(_ error: any Error) {
        invalidatePlaybackEpochLocked()
        suppressRebuildStoppedCallback = false
        status = .stopped
        positionAnchor = 0
        positionTimestamp = nil
        projectionGeneration = nil
        requiresQueuePreparation = currentIndex != nil
        notifyStateDidChange()
        errorHandler?(error)
    }

    private func notifyStateDidChange() {
        stateDidChange?()
    }

    fileprivate func handlePlaybackStateChange(_ playbackState: AudioPlayer.PlaybackState, epoch: UInt64?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.shouldHandleDelegateCallbackLocked(epoch: epoch) else { return }
            switch playbackState {
            case .playing:
                self.suppressRebuildStoppedCallback = false
                self.setPlaybackStateLocked(.playing)
                if let currentIndex = self.currentIndex, let epoch {
                    try? self.prefetchNextDecoderLocked(after: currentIndex, epoch: epoch)
                }
            case .paused:
                self.suppressRebuildStoppedCallback = false
                self.setPlaybackStateLocked(.paused)
            case .stopped:
                if self.suppressRebuildStoppedCallback, self.status != .stopped {
                    return
                }
                self.suppressRebuildStoppedCallback = false
                if self.status != .stopped {
                    self.setPlaybackStateLocked(.stopped)
                }
            @unknown default:
                break
            }
            self.notifyStateDidChange()
        }
    }

    fileprivate func handleRenderingComplete(_ decoder: any PCMDecoding, epoch: UInt64?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.shouldHandleDelegateCallbackLocked(epoch: epoch) else { return }
            guard let epoch else { return }
            let decoderID = ObjectIdentifier(decoder as AnyObject)
            guard let context = self.decoderContexts.removeValue(forKey: decoderID), context.epoch == epoch else { return }
            self.preparedDecoderIndices.remove(context.index)

            if self.currentIndex == context.index {
                _ = self.advanceToNextItemLocked(epoch: epoch)
            }

            self.notifyStateDidChange()
        }
    }

    fileprivate func handleEndOfAudio(epoch: UInt64?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.shouldHandleDelegateCallbackLocked(epoch: epoch) else { return }

            if self.requiresQueuePreparation,
               let currentIndex = self.currentIndex,
               self.items.indices.contains(currentIndex) {
                do {
                    try self.rebuildQueueLocked(startPosition: 0, shouldPlay: true)
                    self.notifyStateDidChange()
                } catch {
                    self.handleError(error)
                }
                return
            }

            self.suppressRebuildStoppedCallback = false
            self.setPlaybackStateLocked(.stopped)
            self.notifyStateDidChange()
        }
    }

    fileprivate func handleErrorFromDelegate(_ error: any Error, epoch: UInt64?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.shouldHandleDelegateCallbackLocked(epoch: epoch) else { return }
            self.handleError(error)
        }
    }
}

private final class DelegateProxy: NSObject, AudioPlayer.Delegate {
    weak var owner: NodeAudioPlayer?
    private let epoch: UInt64

    init(epoch: UInt64) {
        self.epoch = epoch
        super.init()
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        owner?.handlePlaybackStateChange(playbackState, epoch: epoch)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingComplete decoder: any PCMDecoding) {
        owner?.handleRenderingComplete(decoder, epoch: epoch)
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        owner?.handleEndOfAudio(epoch: epoch)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        owner?.handleErrorFromDelegate(error, epoch: epoch)
    }
}
