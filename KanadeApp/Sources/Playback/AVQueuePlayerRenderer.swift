import Foundation
import AVFoundation
import Observation
import UniformTypeIdentifiers
import KanadeKit

@MainActor
@Observable
final class AVQueuePlayerRenderer: AudioRenderer {
    var state = RendererState()

    @ObservationIgnored var onStateChanged: ((RendererState) -> Void)?
    @ObservationIgnored var onTrackAdvanced: (() -> Void)?
    @ObservationIgnored var onTrackFinished: (() -> Void)?

    @ObservationIgnored var mediaClient: MediaClient?

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemBufferEmptyObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemLikelyToKeepUpObservation: NSKeyValueObservation?
    @ObservationIgnored private var didPlayToEndObserver: NSObjectProtocol?

    @ObservationIgnored private var allURLs: [URL] = []
    @ObservationIgnored private var loadedURLs: [URL] = []
    @ObservationIgnored private var itemURLMap: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var itemResourceLoaders: [ObjectIdentifier: TrackResourceLoader] = [:]
    @ObservationIgnored private var trackCaches: [URL: ProgressiveTrackByteCache] = [:]
    @ObservationIgnored private var currentTrackIndex = 0
    @ObservationIgnored private var shouldAutoplay = true
    @ObservationIgnored private var isSeekingInternally = false
    @ObservationIgnored private var pendingFinishedItemIDs: Set<ObjectIdentifier> = []
    @ObservationIgnored private var suppressTransientStateUpdates = false

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
        let caches = Array(trackCaches.values)
        for cache in caches {
            Task {
                await cache.cancelAllOperations()
            }
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

        let cachesToCancel = Array(trackCaches.values)
        allURLs = []
        loadedURLs = []
        itemURLMap.removeAll()
        itemResourceLoaders.removeAll()
        trackCaches.removeAll()
        pendingFinishedItemIDs.removeAll()
        currentTrackIndex = 0

        cancelTrackCaches(cachesToCancel)
        applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
    }

    func seek(to positionSecs: Double) {
        guard player.currentItem != nil else { return }

        isSeekingInternally = true
        state.positionSecs = max(positionSecs, 0)
        onStateChanged?(state)

        let time = CMTime(seconds: max(positionSecs, 0), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSeekingInternally = false
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
            suppressTransientStateUpdates = true
            player.advanceToNextItem()
            queueUpcomingTrackIfNeeded(force: true)
            if shouldAutoplay {
                player.play()
            } else {
                player.pause()
            }
        } else {
            rebuildQueue(autoplay: shouldAutoplay)
        }

        return true
    }

    func prepareNext(url: URL) {
        guard !loadedURLs.contains(url) else { return }

        if !allURLs.contains(url) {
            allURLs.append(url)
        }

        guard let nextIndex = allURLs.firstIndex(of: url), nextIndex > currentTrackIndex else { return }
        guard player.currentItem != nil else { return }

        insertQueuedItemIfPossible(sourceURL: url)
    }

    private func rebuildQueue(autoplay: Bool) {
        player.pause()
        player.removeAllItems()
        itemURLMap.removeAll()
        itemResourceLoaders.removeAll()
        loadedURLs = []
        pendingFinishedItemIDs.removeAll()
        trimTrackCaches(to: Set(allURLs))

        guard allURLs.indices.contains(currentTrackIndex) else {
            applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
            return
        }

        guard let item = makeQueuedItem(sourceURL: allURLs[currentTrackIndex]) else {
            handleLoadFailure()
            return
        }

        refreshState(forceStatus: .loading)
        player.replaceCurrentItem(with: item)
        refreshLoadedURLs()
        queueUpcomingTrackIfNeeded(force: true)

        if autoplay {
            player.play()
        } else {
            player.pause()
        }

        refreshState(forceStatus: autoplay ? .loading : .paused)
    }

    private func cancelTrackCaches(_ caches: [ProgressiveTrackByteCache]) {
        for cache in caches {
            Task {
                await cache.cancelAllOperations()
            }
        }
    }

    private func trimTrackCaches(to activeURLs: Set<URL>) {
        let staleEntries = trackCaches.filter { !activeURLs.contains($0.key) }
        trackCaches = trackCaches.filter { activeURLs.contains($0.key) }
        cancelTrackCaches(Array(staleEntries.values))
    }

    private func handleLoadFailure() {
        player.pause()
        player.removeAllItems()
        loadedURLs = []
        itemURLMap.removeAll()
        itemResourceLoaders.removeAll()
        pendingFinishedItemIDs.removeAll()
        applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
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

                if change.newValue != nil {
                    self.suppressTransientStateUpdates = false
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

                let finishedItemID = ObjectIdentifier(finishedItem)
                let wasQueuedForAdvance = self.pendingFinishedItemIDs.remove(finishedItemID) != nil
                let autoAdvanced = wasQueuedForAdvance || (self.player.currentItem != nil && self.player.currentItem !== finishedItem)

                self.refreshLoadedURLs()
                self.queueUpcomingTrackIfNeeded(force: true)
                self.refreshState()

                if autoAdvanced {
                    self.onTrackAdvanced?()
                } else {
                    self.onTrackFinished?()
                }
            }
        }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
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
                    self.handleLoadFailure()
                case .unknown:
                    self.refreshState(forceStatus: .loading)
                @unknown default:
                    self.handleLoadFailure()
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

        if let currentItem = player.currentItem {
            pendingFinishedItemIDs.insert(ObjectIdentifier(currentItem))
        }

        let nextURL = allURLs[nextIndex]
        if loadedURLs.contains(nextURL) {
            return
        }

        if force || player.items().count <= 1 {
            prepareNext(url: nextURL)
        }
    }

    private func makeQueuedItem(sourceURL: URL) -> AVPlayerItem? {
        guard let mediaClient, let trackID = trackID(from: sourceURL) else { return nil }

        let cache: ProgressiveTrackByteCache
        if let existing = trackCaches[sourceURL] {
            cache = existing
        } else {
            do {
                cache = try ProgressiveTrackByteCache(sourceURL: sourceURL, trackID: trackID, mediaClient: mediaClient)
            } catch {
                return nil
            }
            trackCaches[sourceURL] = cache
        }

        let loader = TrackResourceLoader(sourceURL: sourceURL, cache: cache)
        let asset = AVURLAsset(url: loader.customSchemeURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1

        let itemID = ObjectIdentifier(item)
        itemURLMap[itemID] = sourceURL
        itemResourceLoaders[itemID] = loader
        loader.prefetchForQueuedPlayback()

        return item
    }

    private func insertQueuedItemIfPossible(sourceURL: URL) {
        guard player.currentItem != nil else { return }
        guard !loadedURLs.contains(sourceURL) else { return }
        guard let item = makeQueuedItem(sourceURL: sourceURL) else { return }

        player.insert(item, after: player.items().last)
        refreshLoadedURLs()
    }

    private func refreshLoadedURLs() {
        var urls: [URL] = []
        var activeItemIDs: Set<ObjectIdentifier> = []

        if let currentItem = player.currentItem,
           let currentURL = itemURLMap[ObjectIdentifier(currentItem)] {
            let currentID = ObjectIdentifier(currentItem)
            activeItemIDs.insert(currentID)
            urls.append(currentURL)
        }

        for item in player.items() {
            let itemID = ObjectIdentifier(item)
            activeItemIDs.insert(itemID)
            if let url = itemURLMap[itemID] {
                urls.append(url)
            }
        }

        itemURLMap = itemURLMap.filter { activeItemIDs.contains($0.key) }
        itemResourceLoaders = itemResourceLoaders.filter { activeItemIDs.contains($0.key) }
        loadedURLs = urls
    }

    private func refreshState(forceStatus: PlaybackStatus? = nil) {
        if suppressTransientStateUpdates, forceStatus == nil {
            return
        }

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

        if isSeekingInternally {
            state.status = status
            state.durationSecs = durationSecs
            onStateChanged?(state)
        } else {
            applyState(
                RendererState(
                    status: status,
                    positionSecs: positionSecs,
                    durationSecs: durationSecs,
                    volume: state.volume
                )
            )
        }
    }

    private func applyState(_ newState: RendererState) {
        state = newState
        onStateChanged?(state)
    }

    private func trackID(from url: URL) -> String? {
        let components = url.pathComponents
        guard let mediaIndex = components.firstIndex(of: "media"),
              components.indices.contains(mediaIndex + 2),
              components[mediaIndex + 1] == "tracks"
        else {
            return nil
        }
        return components[mediaIndex + 2]
    }
}

private final class TrackResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let customScheme = "kanade-stream"
    private static let responseChunkLength = 64 * 1024
    private static let fetchChunkLength: Int64 = 256 * 1024
    private static let prefetchLength: Int64 = 512 * 1024

    let customSchemeURL: URL
    let delegateQueue: DispatchQueue

    private let cache: ProgressiveTrackByteCache
    private var requestTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(sourceURL: URL, cache: ProgressiveTrackByteCache) {
        self.cache = cache
        self.customSchemeURL = Self.makeCustomSchemeURL(from: sourceURL)
        self.delegateQueue = DispatchQueue(label: "kanade.resource-loader.\(UUID().uuidString)")
    }

    deinit {
        let tasks = delegateQueue.sync {
            let tasks = Array(requestTasks.values)
            requestTasks.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    func prefetchForQueuedPlayback() {
        Task {
            await cache.startPrefetchIfNeeded(length: Self.prefetchLength)
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let requestID = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            await self.handleLoadingRequest(loadingRequest, requestID: requestID)
        }

        requestTasks[requestID]?.cancel()
        requestTasks[requestID] = task
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let requestID = ObjectIdentifier(loadingRequest)
        let task = requestTasks.removeValue(forKey: requestID)
        task?.cancel()
    }

    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest, requestID: ObjectIdentifier) async {
        defer {
            Task {
                await runOnDelegateQueue {
                    self.requestTasks.removeValue(forKey: requestID)
                }
            }
        }

        do {
            let contentInfo = try await cache.ensureContentInfo()
            try Task.checkCancellation()

            await runOnDelegateQueue {
                Self.populateContentInformationRequest(loadingRequest.contentInformationRequest, with: contentInfo)
            }

            try await respondData(for: loadingRequest, contentInfo: contentInfo)
            try Task.checkCancellation()

            await runOnDelegateQueue {
                loadingRequest.finishLoading()
            }
        } catch is CancellationError {
        } catch {
            await runOnDelegateQueue {
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    private func respondData(for loadingRequest: AVAssetResourceLoadingRequest, contentInfo: TrackContentInfo) async throws {
        guard let dataRequest = loadingRequest.dataRequest else { return }

        let requestedStart = max(dataRequest.requestedOffset, 0)
        let currentOffset = max(dataRequest.currentOffset > 0 ? dataRequest.currentOffset : requestedStart, requestedStart)
        let requestedLength = Int64(max(dataRequest.requestedLength, 0))

        let requestEnd: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            requestEnd = contentInfo.contentLength
        } else {
            requestEnd = min(contentInfo.contentLength, requestedStart + requestedLength)
        }

        var offset = currentOffset

        while offset < requestEnd {
            try Task.checkCancellation()

            let maxReadableLength = Int(min(Int64(Self.responseChunkLength), requestEnd - offset))
            if let cachedData = try await cache.readAvailableData(offset: offset, maxLength: maxReadableLength), !cachedData.isEmpty {
                await runOnDelegateQueue {
                    dataRequest.respond(with: cachedData)
                }
                offset += Int64(cachedData.count)
                continue
            }

            let fetchEnd = min(requestEnd, max(offset + 1, offset + Self.fetchChunkLength))
            guard fetchEnd > offset else { break }

            try await cache.fetch(range: offset..<fetchEnd)
        }
    }

    private func runOnDelegateQueue(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            delegateQueue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private static func populateContentInformationRequest(_ request: AVAssetResourceLoadingContentInformationRequest?, with contentInfo: TrackContentInfo) {
        guard let request else { return }
        request.contentLength = contentInfo.contentLength
        request.isByteRangeAccessSupported = contentInfo.isByteRangeAccessSupported
        request.contentType = contentInfo.uniformTypeIdentifier
    }

    private static func makeCustomSchemeURL(from sourceURL: URL) -> URL {
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = customScheme

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "kanade-loader", value: UUID().uuidString))
        components.queryItems = queryItems

        if let url = components.url {
            return url
        }

        return URL(string: "\(customScheme)://track/\(UUID().uuidString)")!
    }
}

private struct TrackContentInfo: Sendable {
    let contentLength: Int64
    let isByteRangeAccessSupported: Bool
    let mimeType: String?
    let pathExtension: String

    var uniformTypeIdentifier: String? {
        if let mimeType,
           let type = UTType(mimeType: mimeType) {
            return type.identifier
        }

        let trimmedExtension = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtension.isEmpty,
           let type = UTType(filenameExtension: trimmedExtension) {
            return type.identifier
        }

        return nil
    }
}

private struct TrackResponseByteRange: Sendable {
    let range: Range<Int64>
    let totalLength: Int64?
}

private struct TrackFetchKey: Hashable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64
}

private struct TrackFetchResult: Sendable {
    let response: HTTPURLResponse
    let data: Data
    let requestedRange: Range<Int64>
}

private actor ProgressiveTrackByteCache {
    private static let bootstrapProbeLength = 64 * 1024
    private static let defaultRangeFetchLength: Int64 = 256 * 1024

    private let sourceURL: URL
    private let trackID: String
    private let mediaClient: MediaClient
    private let fileURL: URL
    private let fileHandle: FileHandle

    private var contentInfo: TrackContentInfo?
    private var downloadedRanges: [Range<Int64>] = []
    private var inFlightFetches: [TrackFetchKey: Task<TrackFetchResult, Error>] = [:]
    private var prefetchTask: Task<Void, Never>?

    init(sourceURL: URL, trackID: String, mediaClient: MediaClient) throws {
        self.sourceURL = sourceURL
        self.trackID = trackID
        self.mediaClient = mediaClient

        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent("kanade_progressive_tracks", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent("\(UUID().uuidString).part", isDirectory: false)
        if !fileManager.fileExists(atPath: fileURL.path()) {
            fileManager.createFile(atPath: fileURL.path(), contents: nil)
        }

        self.fileURL = fileURL
        self.fileHandle = try FileHandle(forUpdating: fileURL)
    }

    deinit {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func cancelAllOperations() {
        prefetchTask?.cancel()
        prefetchTask = nil

        for task in inFlightFetches.values {
            task.cancel()
        }
        inFlightFetches.removeAll()
    }

    func startPrefetchIfNeeded(length: Int64) {
        guard prefetchTask == nil else { return }

        prefetchTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task {
                    await self.clearPrefetchTask()
                }
            }

            do {
                let info = try await self.ensureContentInfo()
                let prefetchEnd = min(info.contentLength, max(length, Self.defaultRangeFetchLength))
                guard prefetchEnd > 0 else { return }
                try await self.fetch(range: 0..<prefetchEnd)
            } catch {
            }
        }
    }

    func clearPrefetchTask() {
        prefetchTask = nil
    }

    func ensureContentInfo() async throws -> TrackContentInfo {
        if let contentInfo {
            return contentInfo
        }

        let requestedUpperBound = Self.bootstrapProbeLength
        let (data, response) = try await mediaClient.trackData(trackId: trackID, range: 0..<requestedUpperBound)

        let resolvedInfo = try Self.makeContentInfo(
            from: response,
            dataCount: data.count,
            pathExtension: sourceURL.pathExtension
        )

        contentInfo = resolvedInfo

        if !data.isEmpty {
            let byteRange = Self.resolvedByteRange(from: response, requestedRange: 0..<Int64(requestedUpperBound), dataCount: data.count)
            try write(data, at: byteRange.range.lowerBound)
            insertDownloadedRange(byteRange.range)
        }

        return resolvedInfo
    }

    func readAvailableData(offset: Int64, maxLength: Int) throws -> Data? {
        guard offset >= 0, maxLength > 0 else { return nil }
        let contiguousEnd = contiguousCachedEnd(startingAt: offset)
        guard contiguousEnd > offset else { return nil }

        let readLength = min(Int64(maxLength), contiguousEnd - offset)
        guard readLength > 0 else { return nil }

        try fileHandle.seek(toOffset: UInt64(offset))
        return try fileHandle.read(upToCount: Int(readLength))
    }

    func fetch(range: Range<Int64>) async throws {
        let info = try await ensureContentInfo()
        let clampedRange = max(range.lowerBound, 0)..<min(range.upperBound, info.contentLength)
        guard !clampedRange.isEmpty else { return }

        for missingRange in missingSubranges(in: clampedRange) {
            try await fetchMissingRange(missingRange)
        }
    }

    private func fetchMissingRange(_ range: Range<Int64>) async throws {
        var currentOffset = range.lowerBound

        while currentOffset < range.upperBound {
            let requestedUpperBound = min(range.upperBound, currentOffset + Self.defaultRangeFetchLength)
            let requestRange = currentOffset..<requestedUpperBound
            let fetchKey = TrackFetchKey(lowerBound: requestRange.lowerBound, upperBound: requestRange.upperBound)

            let fetchTask: Task<TrackFetchResult, Error>
            if let existingTask = inFlightFetches[fetchKey] {
                fetchTask = existingTask
            } else {
                let trackID = self.trackID
                let mediaClient = self.mediaClient
                fetchTask = Task {
                    let (data, response) = try await mediaClient.trackData(
                        trackId: trackID,
                        range: Int(requestRange.lowerBound)..<Int(requestRange.upperBound)
                    )
                    return TrackFetchResult(response: response, data: data, requestedRange: requestRange)
                }
                inFlightFetches[fetchKey] = fetchTask
            }

            let result: TrackFetchResult
            do {
                result = try await fetchTask.value
            } catch {
                if inFlightFetches[fetchKey] != nil {
                    inFlightFetches.removeValue(forKey: fetchKey)
                }
                throw error
            }

            if inFlightFetches[fetchKey] != nil {
                inFlightFetches.removeValue(forKey: fetchKey)
            }

            let resolvedByteRange = Self.resolvedByteRange(
                from: result.response,
                requestedRange: result.requestedRange,
                dataCount: result.data.count
            )

            if contentInfo == nil {
                contentInfo = try Self.makeContentInfo(
                    from: result.response,
                    dataCount: result.data.count,
                    pathExtension: sourceURL.pathExtension
                )
            } else if let totalLength = resolvedByteRange.totalLength, var currentContentInfo = contentInfo, currentContentInfo.contentLength != totalLength {
                currentContentInfo = TrackContentInfo(
                    contentLength: totalLength,
                    isByteRangeAccessSupported: currentContentInfo.isByteRangeAccessSupported,
                    mimeType: currentContentInfo.mimeType ?? result.response.mimeType,
                    pathExtension: currentContentInfo.pathExtension
                )
                contentInfo = currentContentInfo
            }

            if !result.data.isEmpty {
                try write(result.data, at: resolvedByteRange.range.lowerBound)
                insertDownloadedRange(resolvedByteRange.range)
            }

            let nextOffset = max(currentOffset + 1, contiguousCachedEnd(startingAt: currentOffset))
            guard nextOffset > currentOffset else {
                throw NSError(domain: "AVQueuePlayerRenderer.ProgressiveTrackByteCache", code: -1)
            }
            currentOffset = nextOffset
        }
    }

    private func write(_ data: Data, at offset: Int64) throws {
        guard !data.isEmpty else { return }
        try fileHandle.seek(toOffset: UInt64(offset))
        try fileHandle.write(contentsOf: data)
    }

    private func missingSubranges(in requestedRange: Range<Int64>) -> [Range<Int64>] {
        guard !requestedRange.isEmpty else { return [] }

        var missingRanges: [Range<Int64>] = []
        var cursor = requestedRange.lowerBound

        for downloadedRange in downloadedRanges {
            if downloadedRange.upperBound <= cursor { continue }
            if downloadedRange.lowerBound >= requestedRange.upperBound { break }

            if downloadedRange.lowerBound > cursor {
                missingRanges.append(cursor..<min(downloadedRange.lowerBound, requestedRange.upperBound))
            }

            cursor = max(cursor, min(downloadedRange.upperBound, requestedRange.upperBound))
            if cursor >= requestedRange.upperBound {
                break
            }
        }

        if cursor < requestedRange.upperBound {
            missingRanges.append(cursor..<requestedRange.upperBound)
        }

        return missingRanges
    }

    private func contiguousCachedEnd(startingAt offset: Int64) -> Int64 {
        guard offset >= 0 else { return offset }

        var contiguousEnd = offset
        var hasContainingRange = false

        for downloadedRange in downloadedRanges {
            if downloadedRange.upperBound <= contiguousEnd { continue }

            if !hasContainingRange {
                guard downloadedRange.lowerBound <= offset, downloadedRange.upperBound > offset else {
                    if downloadedRange.lowerBound > offset {
                        break
                    }
                    continue
                }
                contiguousEnd = downloadedRange.upperBound
                hasContainingRange = true
                continue
            }

            guard downloadedRange.lowerBound <= contiguousEnd else { break }
            contiguousEnd = max(contiguousEnd, downloadedRange.upperBound)
        }

        return hasContainingRange ? contiguousEnd : offset
    }

    private func insertDownloadedRange(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }

        var mergedRange = range
        var mergedRanges: [Range<Int64>] = []
        var inserted = false

        for existingRange in downloadedRanges {
            if existingRange.upperBound < mergedRange.lowerBound {
                mergedRanges.append(existingRange)
            } else if mergedRange.upperBound < existingRange.lowerBound {
                if !inserted {
                    mergedRanges.append(mergedRange)
                    inserted = true
                }
                mergedRanges.append(existingRange)
            } else {
                mergedRange = min(existingRange.lowerBound, mergedRange.lowerBound)..<max(existingRange.upperBound, mergedRange.upperBound)
            }
        }

        if !inserted {
            mergedRanges.append(mergedRange)
        }

        downloadedRanges = mergedRanges
    }

    private static func makeContentInfo(from response: HTTPURLResponse, dataCount: Int, pathExtension: String) throws -> TrackContentInfo {
        let resolvedByteRange = resolvedByteRange(from: response, requestedRange: 0..<Int64(dataCount), dataCount: dataCount)

        let contentLength = resolvedByteRange.totalLength
            ?? response.expectedContentLength.nonNegativeValue
            ?? Int64(dataCount)

        guard contentLength > 0 else {
            throw NSError(domain: "AVQueuePlayerRenderer.TrackContentInfo", code: -1)
        }

        let acceptsRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?.localizedCaseInsensitiveContains("bytes") == true
        let byteRangeSupported = acceptsRanges || response.statusCode == 206 || resolvedByteRange.totalLength != nil

        return TrackContentInfo(
            contentLength: contentLength,
            isByteRangeAccessSupported: byteRangeSupported,
            mimeType: response.mimeType,
            pathExtension: pathExtension
        )
    }

    private static func resolvedByteRange(from response: HTTPURLResponse, requestedRange: Range<Int64>, dataCount: Int) -> TrackResponseByteRange {
        if let headerValue = response.value(forHTTPHeaderField: "Content-Range"),
           let parsedRange = parseContentRangeHeader(headerValue) {
            return parsedRange
        }

        if response.statusCode == 200 {
            let totalLength = response.expectedContentLength.nonNegativeValue ?? Int64(dataCount)
            return TrackResponseByteRange(range: 0..<Int64(dataCount), totalLength: totalLength)
        }

        let end = requestedRange.lowerBound + Int64(dataCount)
        let totalLength = response.expectedContentLength.nonNegativeValue
        return TrackResponseByteRange(range: requestedRange.lowerBound..<end, totalLength: totalLength)
    }

    private static func parseContentRangeHeader(_ headerValue: String) -> TrackResponseByteRange? {
        let pattern = #"bytes\s+(\d+)-(\d+)/(\d+|\*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(headerValue.startIndex..<headerValue.endIndex, in: headerValue)
        guard let match = regex.firstMatch(in: headerValue, range: range), match.numberOfRanges == 4,
              let startRange = Range(match.range(at: 1), in: headerValue),
              let endRange = Range(match.range(at: 2), in: headerValue),
              let totalRange = Range(match.range(at: 3), in: headerValue),
              let start = Int64(headerValue[startRange]),
              let endInclusive = Int64(headerValue[endRange])
        else {
            return nil
        }

        let totalLength: Int64?
        let totalValue = String(headerValue[totalRange])
        if totalValue == "*" {
            totalLength = nil
        } else {
            totalLength = Int64(totalValue)
        }

        return TrackResponseByteRange(range: start..<(endInclusive + 1), totalLength: totalLength)
    }
}

private extension Int64 {
    var nonNegativeValue: Int64? {
        self >= 0 ? self : nil
    }
}
