import Foundation
import AVFoundation
import KanadeKit
import FLAC

#if DEBUG
private func flacPlaybackLog(_ message: @autoclosure () -> String) {
    guard PlaybackDebug.decoderLogsEnabled else { return }
    _ = message
}

private func fileDecoderLog(_ message: @autoclosure () -> String) {
    guard PlaybackDebug.decoderLogsEnabled else { return }
    _ = message
}
#endif

@MainActor
protocol AudioDecoderSource: AnyObject {
    var track: Track { get }

    func resolveForPlayback(preferredAccess: AudioDecoderSourceAccess) async throws -> ResolvedAudioDecoderSource
    func prepareForLikelyPlayback() async
}

enum AudioDecoderSourceAccess {
    case localFile
    case progressiveStream
}

enum ResolvedAudioDecoderSource {
    case localFile(URL)
    case cachedTrackBytes(entry: TrackByteCacheEntry, snapshot: TrackByteCacheSnapshot)

    var preferredAccess: AudioDecoderSourceAccess {
        switch self {
        case .localFile:
            return .localFile
        case .cachedTrackBytes:
            return .progressiveStream
        }
    }

    var completeFileURL: URL? {
        switch self {
        case .localFile(let url):
            return url
        case .cachedTrackBytes(_, let snapshot):
            return snapshot.contentInfo.isComplete ? snapshot.backingFileURL : nil
        }
    }

    var cachedFileURL: URL? {
        switch self {
        case .localFile:
            return nil
        case .cachedTrackBytes(_, let snapshot):
            return snapshot.backingFileURL
        }
    }

    var contentInfo: TrackByteCacheContentInfo? {
        switch self {
        case .localFile:
            return nil
        case .cachedTrackBytes(_, let snapshot):
            return snapshot.contentInfo
        }
    }

    #if DEBUG
    var debugSummary: String {
        switch self {
        case .localFile(let url):
            return "localFile(\(url.lastPathComponent))"
        case .cachedTrackBytes(_, let snapshot):
            let info = snapshot.contentInfo
            return "cachedTrackBytes(file=\(snapshot.backingFileURL.lastPathComponent), complete=\(info.isComplete), ranges=\(snapshot.downloadedRanges.count), byteRange=\(info.supportsByteRange))"
        }
    }
    #endif
}

@MainActor
protocol DecoderSession: AnyObject {
    var outputFormat: AVAudioFormat { get }
    var durationSecs: Double { get }

    func seek(to positionSecs: Double) throws
    func decodeNextBuffer(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult
    func close()
    func waitForReadiness() async throws
}

enum DecoderReadResult {
    case buffer(AVAudioPCMBuffer)
    case wouldBlock
    case endOfStream
}

@MainActor
protocol AudioDecodingBackend: AnyObject {
    func makeSession(for source: any AudioDecoderSource) async throws -> any DecoderSession
    func prepareForPlayback(of source: any AudioDecoderSource) async
    func prepareSession(for source: any AudioDecoderSource) async throws -> any DecoderSession
}

fileprivate enum DecoderBackendKind {
    case avAudioFile
    case flac
}

private enum AudioDecodingBackendError: Error {
    case sourceDidNotProvideCompleteLocalFile
}

@MainActor
final class CachedTrackAudioSource: AudioDecoderSource {
    let track: Track

    private let mediaClient: MediaClient

    init(track: Track, mediaClient: MediaClient) {
        self.track = track
        self.mediaClient = mediaClient
    }

    func resolveForPlayback(preferredAccess: AudioDecoderSourceAccess) async throws -> ResolvedAudioDecoderSource {
        switch preferredAccess {
        case .localFile:
            return .localFile(try await mediaClient.downloadTrack(trackId: track.id))
        case .progressiveStream:
            let cacheEntry = try mediaClient.trackByteCacheEntry(trackId: track.id)
            _ = try await cacheEntry.warmInitialBytes(byteCount: MediaClient.defaultTrackWarmupByteCount)
            return .cachedTrackBytes(entry: cacheEntry, snapshot: try cacheEntry.snapshot())
        }
    }

    func prepareForLikelyPlayback() async {
        _ = try? await mediaClient.warmTrackInitialBytes(trackId: track.id)
    }

    fileprivate var preferredDecoderBackend: DecoderBackendKind {
        if track.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "flac" {
            return .flac
        }

        let fileExtension = URL(fileURLWithPath: track.filePath).pathExtension.lowercased()
        if fileExtension == "flac" {
            return .flac
        }

        return .avAudioFile
    }
}

@MainActor
final class AVAudioFileDecodingBackend: AudioDecodingBackend {
    private let outputFormat: AVAudioFormat

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func makeSession(for source: any AudioDecoderSource) async throws -> any DecoderSession {
        let resolvedSource = try await source.resolveForPlayback(preferredAccess: .localFile)
        return try AVAudioFileDecoderSession(source: resolvedSource, outputFormat: outputFormat)
    }

    func prepareForPlayback(of source: any AudioDecoderSource) async {
        await source.prepareForLikelyPlayback()
    }

    func prepareSession(for source: any AudioDecoderSource) async throws -> any DecoderSession {
        try await makeSession(for: source)
    }
}

@MainActor
final class RoutedAudioDecodingBackend: AudioDecodingBackend {
    private let outputFormat: AVAudioFormat
    private let defaultBackend: AVAudioFileDecodingBackend
    private let flacBackend: LibFLACDecodingBackend

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        self.defaultBackend = AVAudioFileDecodingBackend(outputFormat: outputFormat)
        self.flacBackend = LibFLACDecodingBackend(outputFormat: outputFormat)
    }

    func makeSession(for source: any AudioDecoderSource) async throws -> any DecoderSession {
        switch decoderBackend(for: source) {
        case .avAudioFile:
            return try await defaultBackend.makeSession(for: source)
        case .flac:
            return try await flacBackend.makeSession(for: source)
        }
    }

    func prepareForPlayback(of source: any AudioDecoderSource) async {
        switch decoderBackend(for: source) {
        case .avAudioFile:
            await defaultBackend.prepareForPlayback(of: source)
        case .flac:
            await flacBackend.prepareForPlayback(of: source)
        }
    }

    func prepareSession(for source: any AudioDecoderSource) async throws -> any DecoderSession {
        switch decoderBackend(for: source) {
        case .avAudioFile:
            return try await defaultBackend.prepareSession(for: source)
        case .flac:
            return try await flacBackend.prepareSession(for: source)
        }
    }

    private func decoderBackend(for source: any AudioDecoderSource) -> DecoderBackendKind {
        if let source = source as? CachedTrackAudioSource {
            return source.preferredDecoderBackend
        }

        if source.track.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "flac" {
            return .flac
        }

        let fileExtension = URL(fileURLWithPath: source.track.filePath).pathExtension.lowercased()
        return fileExtension == "flac" ? .flac : .avAudioFile
    }
}

@MainActor
final class LibFLACDecodingBackend: AudioDecodingBackend {
    private let outputFormat: AVAudioFormat

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func makeSession(for source: any AudioDecoderSource) async throws -> any DecoderSession {
        let resolvedSource = try await source.resolveForPlayback(preferredAccess: .progressiveStream)
        #if DEBUG
        flacPlaybackLog("makeSession track=\(source.track.id) source=\(resolvedSource.debugSummary)")
        #endif

        switch resolvedSource {
        case .localFile:
            return try LibFLACDecoderSession(source: resolvedSource, outputFormat: outputFormat)
        case .cachedTrackBytes(let entry, let snapshot):
            let byteSource = CacheBackedFLACByteSource(entry: entry, snapshot: snapshot)

            while true {
                do {
                    return try LibFLACDecoderSession(source: resolvedSource, byteSource: byteSource, outputFormat: outputFormat)
                } catch FLACProgressiveSourceAccessError.wouldBlock {
                    try await byteSource.waitForPendingFetch()
                }
            }
        }
    }

    func prepareForPlayback(of source: any AudioDecoderSource) async {
        await source.prepareForLikelyPlayback()
    }

    func prepareSession(for source: any AudioDecoderSource) async throws -> any DecoderSession {
        try await makeSession(for: source)
    }
}

@MainActor
private final class AVAudioFileDecoderSession: DecoderSession {
    let outputFormat: AVAudioFormat
    let durationSecs: Double

    private let audioFile: AVAudioFile
    private let sourceFormat: AVAudioFormat
    private let requiresConversion: Bool
    private var converter: AVAudioConverter?
    private var reachedEndOfStream = false
    private var emittedTerminalConvertedBuffer = false

    init(source: ResolvedAudioDecoderSource, outputFormat: AVAudioFormat) throws {
        guard let fileURL = source.completeFileURL else {
            throw AudioDecodingBackendError.sourceDidNotProvideCompleteLocalFile
        }

        self.audioFile = try AVAudioFile(forReading: fileURL)
        self.sourceFormat = audioFile.processingFormat
        self.outputFormat = outputFormat
        self.requiresConversion = !Self.supportsDirectRead(from: audioFile.processingFormat, to: outputFormat)
        self.converter = requiresConversion ? AVAudioConverter(from: audioFile.processingFormat, to: outputFormat) : nil

        let sampleRate = audioFile.processingFormat.sampleRate
        if sampleRate > 0 {
            self.durationSecs = Double(audioFile.length) / sampleRate
        } else {
            self.durationSecs = 0
        }
    }

    func seek(to positionSecs: Double) throws {
        let sampleRate = sourceFormat.sampleRate
        guard sampleRate > 0 else {
            audioFile.framePosition = 0
            reachedEndOfStream = false
            emittedTerminalConvertedBuffer = false
            converter?.reset()
            return
        }

        let clampedPosition = min(max(positionSecs, 0), durationSecs)
        let framePosition = AVAudioFramePosition(clampedPosition * sampleRate)
        audioFile.framePosition = min(max(framePosition, 0), audioFile.length)
        reachedEndOfStream = false
        emittedTerminalConvertedBuffer = false
        converter?.reset()
    }

    func decodeNextBuffer(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult {
        guard frameCapacity > 0 else { return .endOfStream }

        if emittedTerminalConvertedBuffer {
            return .endOfStream
        }

        if reachedEndOfStream {
            return .endOfStream
        }

        if !requiresConversion {
            return try decodeBufferWithoutConversion(frameCapacity: frameCapacity)
        }

        return try decodeBufferWithConversion(frameCapacity: frameCapacity)
    }

    func close() {
    }

    func waitForReadiness() async throws {
    }

    private func decodeBufferWithoutConversion(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.AVAudioFileDecoderSession", code: -1)
        }

        try audioFile.read(into: buffer, frameCount: frameCapacity)
        #if DEBUG
        fileDecoderLog("decodeWithoutConversion framePosition=\(audioFile.framePosition) frameLength=\(buffer.frameLength) requested=\(frameCapacity)")
        #endif
        if buffer.frameLength > 0 {
            if buffer.frameLength < frameCapacity {
                reachedEndOfStream = true
                emittedTerminalConvertedBuffer = true
            }
            return .buffer(buffer)
        }

        reachedEndOfStream = true
        return .endOfStream
    }

    private func decodeBufferWithConversion(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult {
        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.AVAudioFileDecoderSession", code: -2)
        }

        let sourceFrameCapacity = sourceFrameCapacity(forOutputFrameCapacity: frameCapacity)
        var hitEndOfStream = false

        for _ in 0..<2 {
            var conversionError: NSError?
            var capturedError: Error?

            let status = converter.convert(to: outputBuffer, error: &conversionError) { [unowned self] _, outStatus in
                guard !hitEndOfStream else {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.sourceFormat, frameCapacity: sourceFrameCapacity) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try self.audioFile.read(into: inputBuffer, frameCount: sourceFrameCapacity)
                    #if DEBUG
                    fileDecoderLog("inputBlock framePosition=\(self.audioFile.framePosition) frameLength=\(inputBuffer.frameLength) requested=\(sourceFrameCapacity) hitEOS=\(hitEndOfStream) reachedEOS=\(self.reachedEndOfStream) emittedTerminal=\(self.emittedTerminalConvertedBuffer)")
                    #endif
                } catch {
                    capturedError = error
                    outStatus.pointee = .noDataNow
                    return nil
                }

                guard inputBuffer.frameLength > 0 else {
                    hitEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if inputBuffer.frameLength < sourceFrameCapacity {
                    hitEndOfStream = true
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let capturedError {
                #if DEBUG
                fileDecoderLog("capturedError=\(capturedError)")
                #endif
                throw capturedError
            }

            if let conversionError {
                #if DEBUG
                fileDecoderLog("conversionError=\(conversionError) outputFrames=\(outputBuffer.frameLength) hitEOS=\(hitEndOfStream) reachedEOS=\(reachedEndOfStream) emittedTerminal=\(emittedTerminalConvertedBuffer)")
                #endif
                throw conversionError
            }

            #if DEBUG
            fileDecoderLog("convert status=\(status.rawValue) outputFrames=\(outputBuffer.frameLength) hitEOS=\(hitEndOfStream) reachedEOS=\(reachedEndOfStream) emittedTerminal=\(emittedTerminalConvertedBuffer)")
            #endif

            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                if outputBuffer.frameLength > 0 {
                    if hitEndOfStream || outputBuffer.frameLength < frameCapacity {
                        reachedEndOfStream = true
                        emittedTerminalConvertedBuffer = true
                    }
                    return .buffer(outputBuffer)
                }

                if status == .inputRanDry, !hitEndOfStream {
                    continue
                }

                reachedEndOfStream = true
                return .endOfStream
            case .error:
                throw NSError(domain: "AudioDecodingBackend.AVAudioFileDecoderSession", code: -3)
            @unknown default:
                return outputBuffer.frameLength > 0 ? .buffer(outputBuffer) : .endOfStream
            }
        }

        return outputBuffer.frameLength > 0 ? .buffer(outputBuffer) : .endOfStream
    }

    private func sourceFrameCapacity(forOutputFrameCapacity frameCapacity: AVAudioFrameCount) -> AVAudioFrameCount {
        let sourceRate = max(sourceFormat.sampleRate, 1)
        let outputRate = max(outputFormat.sampleRate, 1)
        let ratio = sourceRate / outputRate
        let scaledCapacity = Int(ceil(Double(frameCapacity) * ratio)) + 256
        return AVAudioFrameCount(max(scaledCapacity, 1024))
    }

    fileprivate static func supportsDirectRead(from sourceFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> Bool {
        sourceFormat.commonFormat == outputFormat.commonFormat
            && sourceFormat.sampleRate == outputFormat.sampleRate
            && sourceFormat.channelCount == outputFormat.channelCount
            && sourceFormat.isInterleaved == outputFormat.isInterleaved
    }
}

enum FLACProgressiveSourceAccessError: Error {
    case wouldBlock
}

private enum FLACFillResult {
    case frames(AVAudioFrameCount)
    case wouldBlock
    case endOfStream
}

private enum FLACFrameDecodeResult {
    case frame(DecodedFLACFrame)
    case wouldBlock
    case endOfStream
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class CacheBackedFLACByteSource: @unchecked Sendable {
    fileprivate enum LastReadOutcome {
        case none
        case wouldBlock
        case failure(Error)
        case endOfStream
    }

    enum PreparationResult {
        case ready
        case wouldBlock
        case endOfStream
    }

    static let defaultReadHintByteCount: Int64 = 64 * 1024

    private let cacheEntry: TrackByteCacheEntry
    private let prefetchByteCount: Int64
    private let lock = NSLock()

    private var currentOffset: Int64 = 0
    private var knownContentInfo: TrackByteCacheContentInfo
    private var inFlightFetchRange: Range<Int64>?
    private var queuedFetchRange: Range<Int64>?
    private var currentFetchTask: Task<Void, Never>?
    private var pendingFetchError: Error?
    private var lastReadOutcome: LastReadOutcome = .none
    private var isClosed = false

    init(entry: TrackByteCacheEntry, snapshot: TrackByteCacheSnapshot, prefetchByteCount: Int64 = MediaClient.defaultTrackWarmupByteCount) {
        self.cacheEntry = entry
        self.knownContentInfo = snapshot.contentInfo
        self.prefetchByteCount = max(prefetchByteCount, Self.defaultReadHintByteCount)
    }

    func prepareForDecoderRead(minimumByteCount: Int64 = CacheBackedFLACByteSource.defaultReadHintByteCount) -> PreparationResult {
        if let error = consumePendingFetchError() {
            setLastReadOutcome(.failure(error))
            return .wouldBlock
        }

        let snapshot: TrackByteCacheSnapshot
        do {
            snapshot = try cacheEntry.snapshot()
        } catch {
            setLastReadOutcome(.failure(error))
            return .wouldBlock
        }

        updateKnownContentInfo(snapshot.contentInfo)
        let offset = readCurrentOffset()

        if let contentLength = snapshot.contentInfo.contentLength, offset >= contentLength {
            setLastReadOutcome(.endOfStream)
            return .endOfStream
        }

        if let cachedRange = cachedContiguousRange(containing: offset, in: snapshot.downloadedRanges) {
            let targetUpperBound = clampedUpperBound(offset + minimumByteCount, contentLength: snapshot.contentInfo.contentLength)
            if cachedRange.upperBound < targetUpperBound {
                requestFetch(startingAt: cachedRange.upperBound, preferredUpperBound: targetUpperBound, contentLength: snapshot.contentInfo.contentLength)
            }
            setLastReadOutcome(.none)
            return .ready
        }

        requestFetch(startingAt: offset, preferredUpperBound: offset + minimumByteCount, contentLength: snapshot.contentInfo.contentLength)
        setLastReadOutcome(.wouldBlock)
        return .wouldBlock
    }

    func read(buffer: UnsafeMutablePointer<FLAC__byte>, byteCount: UnsafeMutablePointer<size_t>) -> FLAC__StreamDecoderReadStatus {
        let requestedByteCount = Int64(byteCount.pointee)
        guard requestedByteCount > 0 else {
            byteCount.pointee = 0
            setLastReadOutcome(.none)
            return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
        }

        if let error = consumePendingFetchError() {
            byteCount.pointee = 0
            setLastReadOutcome(.failure(error))
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }

        let snapshot: TrackByteCacheSnapshot
        do {
            snapshot = try cacheEntry.snapshot()
        } catch {
            byteCount.pointee = 0
            setLastReadOutcome(.failure(error))
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }

        updateKnownContentInfo(snapshot.contentInfo)
        let offset = readCurrentOffset()

        if let contentLength = snapshot.contentInfo.contentLength, offset >= contentLength {
            byteCount.pointee = 0
            setLastReadOutcome(.endOfStream)
            return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
        }

        guard let cachedRange = cachedContiguousRange(containing: offset, in: snapshot.downloadedRanges) else {
            requestFetch(startingAt: offset, preferredUpperBound: offset + requestedByteCount, contentLength: snapshot.contentInfo.contentLength)
            byteCount.pointee = 0
            setLastReadOutcome(.wouldBlock)
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }

        let requestedUpperBound = clampedUpperBound(offset + requestedByteCount, contentLength: snapshot.contentInfo.contentLength)
        let readRange = offset..<min(requestedUpperBound, cachedRange.upperBound)
        guard !readRange.isEmpty else {
            requestFetch(startingAt: offset, preferredUpperBound: requestedUpperBound, contentLength: snapshot.contentInfo.contentLength)
            byteCount.pointee = 0
            setLastReadOutcome(.wouldBlock)
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }

        do {
            let data = try cacheEntry.read(range: readRange)
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                buffer.update(from: baseAddress.assumingMemoryBound(to: FLAC__byte.self), count: data.count)
            }
            byteCount.pointee = data.count
            updateCurrentOffset(readRange.upperBound)
            setLastReadOutcome(.none)

            if readRange.upperBound < requestedUpperBound {
                requestFetch(startingAt: readRange.upperBound, preferredUpperBound: requestedUpperBound, contentLength: snapshot.contentInfo.contentLength)
            }

            return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
        } catch TrackByteCacheError.missingCachedRange {
            requestFetch(startingAt: offset, preferredUpperBound: requestedUpperBound, contentLength: snapshot.contentInfo.contentLength)
            byteCount.pointee = 0
            setLastReadOutcome(.wouldBlock)
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        } catch {
            byteCount.pointee = 0
            setLastReadOutcome(.failure(error))
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT
        }
    }

    func seek(to absoluteByteOffset: UInt64) -> FLAC__StreamDecoderSeekStatus {
        let offset = Int64(clamping: absoluteByteOffset)
        if let contentLength = resolvedContentLength(), offset > contentLength {
            return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR
        }

        updateCurrentOffset(offset)
        setLastReadOutcome(.none)
        requestFetch(startingAt: offset, preferredUpperBound: offset + Self.defaultReadHintByteCount, contentLength: resolvedContentLength())
        return FLAC__STREAM_DECODER_SEEK_STATUS_OK
    }

    func tell() -> (FLAC__StreamDecoderTellStatus, UInt64) {
        (FLAC__STREAM_DECODER_TELL_STATUS_OK, UInt64(max(readCurrentOffset(), 0)))
    }

    func length() -> (FLAC__StreamDecoderLengthStatus, UInt64) {
        guard let contentLength = resolvedContentLength() else {
            return (FLAC__STREAM_DECODER_LENGTH_STATUS_UNSUPPORTED, 0)
        }
        return (FLAC__STREAM_DECODER_LENGTH_STATUS_OK, UInt64(max(contentLength, 0)))
    }

    func isEOF() -> Bool {
        guard let contentLength = resolvedContentLength() else { return false }
        return readCurrentOffset() >= contentLength
    }

    func waitForPendingFetch() async throws {
        while true {
            if let error = consumePendingFetchError() {
                throw error
            }

            let isFetching = lock.withLock {
                currentFetchTask != nil || inFlightFetchRange != nil || queuedFetchRange != nil
            }

            if !isFetching {
                return
            }

            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func consumeLastReadOutcome() -> LastReadOutcome {
        lock.withLock {
            let outcome = lastReadOutcome
            lastReadOutcome = .none
            return outcome
        }
    }

    func close() {
        lock.withLock {
            isClosed = true
            currentFetchTask?.cancel()
            currentFetchTask = nil
            inFlightFetchRange = nil
            queuedFetchRange = nil
        }
    }

    private func requestFetch(startingAt lowerBound: Int64, preferredUpperBound: Int64, contentLength: Int64?) {
        let clampedLowerBound = max(lowerBound, 0)
        let desiredUpperBound = max(preferredUpperBound, clampedLowerBound + prefetchByteCount)
        let clampedUpperBound = self.clampedUpperBound(desiredUpperBound, contentLength: contentLength)
        let requestedRange = clampedLowerBound..<clampedUpperBound
        guard !requestedRange.isEmpty else { return }

        var shouldStartNow = false
        lock.withLock {
            guard !isClosed else { return }

            if let inFlightFetchRange,
               inFlightFetchRange.lowerBound <= requestedRange.lowerBound,
               inFlightFetchRange.upperBound >= requestedRange.upperBound {
                return
            }

            if let queuedFetchRange {
                self.queuedFetchRange = min(queuedFetchRange.lowerBound, requestedRange.lowerBound)..<max(queuedFetchRange.upperBound, requestedRange.upperBound)
                return
            }

            if inFlightFetchRange != nil {
                queuedFetchRange = requestedRange
                return
            }

            inFlightFetchRange = requestedRange
            shouldStartNow = true
        }

        if shouldStartNow {
            startFetch(requestedRange)
        }
    }

    private func startFetch(_ range: Range<Int64>) {
        let entry = cacheEntry
        currentFetchTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let contentInfo = try await entry.ensureCached(range: range)
                self.finishFetch(range: range, contentInfo: contentInfo, error: nil)
            } catch {
                self.finishFetch(range: range, contentInfo: nil, error: error)
            }
        }
    }

    private func finishFetch(range: Range<Int64>, contentInfo: TrackByteCacheContentInfo?, error: Error?) {
        var nextRange: Range<Int64>?

        lock.withLock {
            currentFetchTask = nil
            if inFlightFetchRange == range {
                inFlightFetchRange = nil
            }

            if let contentInfo {
                knownContentInfo = contentInfo
            }

            if let error {
                pendingFetchError = error
            }

            if let queuedFetchRange {
                nextRange = queuedFetchRange
                self.queuedFetchRange = nil
                inFlightFetchRange = queuedFetchRange
            }
        }

        if let nextRange {
            startFetch(nextRange)
        }
    }

    private func cachedContiguousRange(containing offset: Int64, in ranges: [Range<Int64>]) -> Range<Int64>? {
        ranges.first(where: { $0.lowerBound <= offset && offset < $0.upperBound })
    }

    private func clampedUpperBound(_ upperBound: Int64, contentLength: Int64?) -> Int64 {
        guard let contentLength else { return upperBound }
        return min(upperBound, contentLength)
    }

    private func resolvedContentLength() -> Int64? {
        lock.withLock { knownContentInfo.contentLength }
    }

    private func readCurrentOffset() -> Int64 {
        lock.withLock { currentOffset }
    }

    private func updateCurrentOffset(_ offset: Int64) {
        lock.withLock {
            currentOffset = offset
        }
    }

    private func updateKnownContentInfo(_ contentInfo: TrackByteCacheContentInfo) {
        lock.withLock {
            knownContentInfo = contentInfo
        }
    }

    private func consumePendingFetchError() -> Error? {
        lock.withLock {
            let error = pendingFetchError
            pendingFetchError = nil
            return error
        }
    }

    private func setLastReadOutcome(_ outcome: LastReadOutcome) {
        lock.withLock {
            lastReadOutcome = outcome
        }
    }
}

@MainActor
private final class LibFLACDecoderSession: DecoderSession {
    let outputFormat: AVAudioFormat
    let durationSecs: Double

    private let wrapper: FLACDecoderWrapper
    private let sourceFormat: AVAudioFormat
    private let sourceSampleRate: Double
    private let requiresConversion: Bool
    private var converter: AVAudioConverter?
    private var reachedEndOfStream = false
    private var sessionGeneration = UUID()

    init(source: ResolvedAudioDecoderSource, byteSource: CacheBackedFLACByteSource? = nil, outputFormat: AVAudioFormat) throws {
        self.wrapper = try FLACDecoderWrapper(source: source, byteSource: byteSource)
        self.sourceSampleRate = Double(wrapper.sampleRate)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(wrapper.sampleRate),
            channels: AVAudioChannelCount(wrapper.channels),
            interleaved: false
        ) else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -10)
        }

        self.sourceFormat = sourceFormat
        self.outputFormat = outputFormat
        self.requiresConversion = !AVAudioFileDecoderSession.supportsDirectRead(from: sourceFormat, to: outputFormat)
        self.converter = requiresConversion ? AVAudioConverter(from: sourceFormat, to: outputFormat) : nil

        if wrapper.sampleRate > 0 {
            self.durationSecs = Double(wrapper.totalSamples) / Double(wrapper.sampleRate)
        } else {
            self.durationSecs = 0
        }

        #if DEBUG
        flacPlaybackLog("sessionInit rate=\(wrapper.sampleRate) channels=\(wrapper.channels) bits=\(wrapper.bitsPerSample) duration=\(durationSecs) requiresConversion=\(requiresConversion) outputRate=\(outputFormat.sampleRate) outputChannels=\(outputFormat.channelCount)")
        #endif
    }

    func seek(to positionSecs: Double) throws {
        let clampedPosition = min(max(positionSecs, 0), durationSecs)
        let sample = UInt64(clampedPosition * sourceSampleRate)
        
        sessionGeneration = UUID()
        
        guard wrapper.seek(toSample: sample) else {
            if let byteSource = wrapper.byteSource {
                switch byteSource.consumeLastReadOutcome() {
                case .wouldBlock:
                    _ = FLAC__stream_decoder_flush(wrapper.decoder)
                    throw FLACProgressiveSourceAccessError.wouldBlock
                case .failure(let error):
                    throw error
                case .endOfStream, .none:
                    throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -11)
                }
            }
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -11)
        }
        reachedEndOfStream = false
        converter?.reset()
    }

    func decodeNextBuffer(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult {
        guard frameCapacity > 0 else { return .endOfStream }

        let result: DecoderReadResult
        if !requiresConversion {
            result = try decodeWithoutConversion(frameCapacity: frameCapacity)
        } else {
            result = try decodeWithConversion(frameCapacity: frameCapacity)
        }

        #if DEBUG
        switch result {
        case .buffer(let buffer):
            flacPlaybackLog("decodeNextBuffer frames=\(buffer.frameLength) format=\(buffer.format.commonFormat.rawValue) interleaved=\(buffer.format.isInterleaved) channels=\(buffer.format.channelCount) rate=\(buffer.format.sampleRate)")
        case .wouldBlock:
            flacPlaybackLog("decodeNextBuffer wouldBlock reachedEndOfStream=\(reachedEndOfStream)")
        case .endOfStream:
            flacPlaybackLog("decodeNextBuffer endOfStream reached=\(reachedEndOfStream)")
        }
        #endif

        return result
    }

    func close() {
        wrapper.close()
        converter = nil
    }

    func waitForReadiness() async throws {
        guard let byteSource = wrapper.byteSource else { return }
        try await byteSource.waitForPendingFetch()
    }

    private func decodeWithoutConversion(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -12)
        }

        switch try Self.fillPCMBuffer(buffer, frameCapacity: frameCapacity, wrapper: wrapper, reachedEndOfStream: &reachedEndOfStream) {
        case .frames(let frameCount):
            return frameCount > 0 ? .buffer(buffer) : .wouldBlock
        case .wouldBlock:
            return .wouldBlock
        case .endOfStream:
            return .endOfStream
        }
    }

    private func decodeWithConversion(frameCapacity: AVAudioFrameCount) throws -> DecoderReadResult {
        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -13)
        }

        var conversionError: NSError?
        var capturedError: Error?
        var hitWouldBlock = false

        let sourceFrameCapacity = sourceFrameCapacity(forOutputFrameCapacity: frameCapacity)
        let wrapper = self.wrapper
        var localReachedEndOfStream = reachedEndOfStream

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            do {
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.sourceFormat, frameCapacity: sourceFrameCapacity) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                switch try Self.fillPCMBuffer(inputBuffer, frameCapacity: sourceFrameCapacity, wrapper: wrapper, reachedEndOfStream: &localReachedEndOfStream) {
                case .frames:
                    outStatus.pointee = .haveData
                    return inputBuffer
                case .wouldBlock:
                    hitWouldBlock = true
                    outStatus.pointee = .noDataNow
                    return nil
                case .endOfStream:
                    outStatus.pointee = .endOfStream
                    return nil
                }
            } catch {
                capturedError = error
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let capturedError {
            throw capturedError
        }

        if let conversionError {
            throw conversionError
        }

        reachedEndOfStream = localReachedEndOfStream

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if outputBuffer.frameLength > 0 {
                return .buffer(outputBuffer)
            }
            return hitWouldBlock && !reachedEndOfStream ? .wouldBlock : .endOfStream
        case .error:
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -14)
        @unknown default:
            return outputBuffer.frameLength > 0 ? .buffer(outputBuffer) : .endOfStream
        }
    }

    private static func fillPCMBuffer(
        _ buffer: AVAudioPCMBuffer,
        frameCapacity: AVAudioFrameCount,
        wrapper: FLACDecoderWrapper,
        reachedEndOfStream: inout Bool
    ) throws -> FLACFillResult {
        switch try wrapper.decodeNextFrame() {
        case .frame(let decodedFrame):
            let framesAvailable = min(frameCapacity, decodedFrame.frameCount)
            guard framesAvailable > 0 else {
                buffer.frameLength = 0
                return .wouldBlock
            }

            guard let channelData = buffer.floatChannelData else {
                throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -16)
            }

            for (channelIndex, sourceChannel) in decodedFrame.channels.enumerated() {
                sourceChannel.withUnsafeBufferPointer { sourceSamples in
                    channelData[channelIndex].update(from: sourceSamples.baseAddress!, count: Int(framesAvailable))
                }
            }

            buffer.frameLength = framesAvailable
            return .frames(framesAvailable)
        case .wouldBlock:
            reachedEndOfStream = false
            buffer.frameLength = 0
            return .wouldBlock
        case .endOfStream:
            reachedEndOfStream = true
            buffer.frameLength = 0
            return .endOfStream
        }
    }

    private func sourceFrameCapacity(forOutputFrameCapacity frameCapacity: AVAudioFrameCount) -> AVAudioFrameCount {
        let sourceRate = max(sourceFormat.sampleRate, 1)
        let outputRate = max(outputFormat.sampleRate, 1)
        let ratio = sourceRate / outputRate
        let scaledCapacity = Int(ceil(Double(frameCapacity) * ratio)) + 256
        return AVAudioFrameCount(max(scaledCapacity, 1024))
    }
}

private final class FLACDecoderWrapper {
    fileprivate let decoder: UnsafeMutablePointer<FLAC__StreamDecoder>
    fileprivate let byteSource: CacheBackedFLACByteSource?
    private let source: ResolvedAudioDecoderSource
    private var reachedEndOfStream = false
    private var decodedChannels: [[Float]] = []
    private var decodedFrameCount: AVAudioFrameCount = 0

    private(set) var channels: UInt32
    private(set) var bitsPerSample: UInt32
    private(set) var sampleRate: UInt32
    private(set) var totalSamples: UInt64

    init(source: ResolvedAudioDecoderSource, byteSource: CacheBackedFLACByteSource?) throws {
        guard let decoder = FLAC__stream_decoder_new() else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -20)
        }

        self.decoder = decoder
        self.byteSource = byteSource
        self.source = source
        self.channels = 0
        self.bitsPerSample = 0
        self.sampleRate = 0
        self.totalSamples = 0

        if let byteSource {
            try open(byteSource: byteSource)
        } else if let fileURL = source.completeFileURL {
            try open(fileURL: fileURL)
        } else {
            throw AudioDecodingBackendError.sourceDidNotProvideCompleteLocalFile
        }
    }

    private func open(fileURL: URL) throws {
        reachedEndOfStream = false
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0

        #if DEBUG
        flacPlaybackLog("wrapperOpen start access=\(source.preferredAccess) path=\(fileURL.lastPathComponent)")
        #endif

        let initStatus = fileURL.withUnsafeFileSystemRepresentation { path in
            FLAC__stream_decoder_init_file(
                decoder,
                path,
                flacWriteCallback,
                flacMetadataCallback,
                flacErrorCallback,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
        }

        #if DEBUG
        flacPlaybackLog("wrapperOpen initStatus=\(initStatus.rawValue)")
        #endif

        guard initStatus == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: Int(initStatus.rawValue))
        }

        let didProcessMetadata = FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0
        #if DEBUG
        flacPlaybackLog("wrapperOpen metadata ok=\(didProcessMetadata) state=\(FLAC__stream_decoder_get_state(decoder).rawValue)")
        #endif

        guard didProcessMetadata else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -21)
        }

        var streamInfo = FLAC__StreamMetadata()
        let didReadStreamInfo = fileURL.withUnsafeFileSystemRepresentation { path in
            FLAC__metadata_get_streaminfo(path, &streamInfo) != 0
        }

        #if DEBUG
        flacPlaybackLog("wrapperOpen metadata_get_streaminfo ok=\(didReadStreamInfo)")
        #endif

        if didReadStreamInfo, streamInfo.type == FLAC__METADATA_TYPE_STREAMINFO {
            applyMetadata(streamInfo)
        } else {
            totalSamples = FLAC__stream_decoder_get_total_samples(decoder)
        }

        #if DEBUG
        flacPlaybackLog("wrapperOpen streamInfo rate=\(sampleRate) channels=\(channels) bits=\(bitsPerSample) totalSamples=\(totalSamples)")
        #endif

        guard channels > 0, sampleRate > 0, bitsPerSample > 0 else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -22)
        }
    }

    private func open(byteSource: CacheBackedFLACByteSource) throws {
        reachedEndOfStream = false
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0

        let initStatus = FLAC__stream_decoder_init_stream(
            decoder,
            flacReadCallback,
            flacSeekCallback,
            flacTellCallback,
            flacLengthCallback,
            flacEOFCallback,
            flacWriteCallback,
            flacMetadataCallback,
            flacErrorCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard initStatus == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: Int(initStatus.rawValue))
        }

        let didProcessMetadata = FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0
        guard didProcessMetadata else {
            switch byteSource.consumeLastReadOutcome() {
            case .wouldBlock:
                _ = FLAC__stream_decoder_flush(decoder)
                throw FLACProgressiveSourceAccessError.wouldBlock
            case .failure(let error):
                throw error
            case .endOfStream, .none:
                throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -21)
            }
        }

        guard channels > 0, sampleRate > 0, bitsPerSample > 0 else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -22)
        }
    }

    deinit {
        FLAC__stream_decoder_delete(decoder)
    }

    func seek(toSample sample: UInt64) -> Bool {
        reachedEndOfStream = false
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0
        let didSeek = FLAC__stream_decoder_seek_absolute(decoder, sample) != 0
        #if DEBUG
        flacPlaybackLog("seek sample=\(sample) ok=\(didSeek)")
        #endif
        return didSeek
    }

    func decodeNextFrame() throws -> FLACFrameDecodeResult {
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0

        if let byteSource {
            switch byteSource.prepareForDecoderRead() {
            case .ready:
                break
            case .wouldBlock:
                return .wouldBlock
            case .endOfStream:
                reachedEndOfStream = true
                return .endOfStream
            }
        }

        while decodedFrameCount == 0 && !reachedEndOfStream {
            let success = FLAC__stream_decoder_process_single(decoder)
            if success == 0 {
                if let byteSource {
                    switch byteSource.consumeLastReadOutcome() {
                    case .wouldBlock:
                        _ = FLAC__stream_decoder_flush(decoder)
                        return .wouldBlock
                    case .failure(let error):
                        throw error
                    case .endOfStream:
                        reachedEndOfStream = true
                        return .endOfStream
                    case .none:
                        break
                    }
                }

                #if DEBUG
                flacPlaybackLog("decodeNextFrame process_single failed state=\(FLAC__stream_decoder_get_state(decoder).rawValue)")
                #endif
                throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -23)
            }

            if FLAC__stream_decoder_get_state(decoder) == FLAC__STREAM_DECODER_END_OF_STREAM {
                reachedEndOfStream = true
            }
        }

        guard decodedFrameCount > 0 else {
            return .endOfStream
        }

        #if DEBUG
        flacPlaybackLog("decodeNextFrame block=\(decodedFrameCount) channels=\(decodedChannels.count)")
        #endif
        return .frame(DecodedFLACFrame(channels: decodedChannels, frameCount: decodedFrameCount))
    }

    func close() {
        reachedEndOfStream = true
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0
        byteSource?.close()
    }

    fileprivate func appendDecodedFrame(_ frame: FLAC__Frame, buffers: UnsafePointer<UnsafePointer<FLAC__int32>?>) -> FLAC__StreamDecoderWriteStatus {
        let channelCount = Int(frame.header.channels)
        let blockSize = Int(frame.header.blocksize)
        let bitDepth = Int(frame.header.bits_per_sample)

        guard channelCount == Int(channels), blockSize > 0 else {
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
        }

        let scale = max(Float(1 << max(bitDepth - 1, 1)), 1)
        decodedChannels = Array(repeating: Array(repeating: 0, count: blockSize), count: channelCount)
        decodedFrameCount = AVAudioFrameCount(blockSize)

        for channelIndex in 0..<channelCount {
            guard let source = buffers[channelIndex] else {
                return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
            }

            for frameIndex in 0..<blockSize {
                decodedChannels[channelIndex][frameIndex] = Float(source[frameIndex]) / scale
            }
        }

        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
    }

    fileprivate func applyMetadata(_ metadata: FLAC__StreamMetadata) {
        guard metadata.type == FLAC__METADATA_TYPE_STREAMINFO else { return }

        channels = metadata.data.stream_info.channels
        bitsPerSample = metadata.data.stream_info.bits_per_sample
        sampleRate = metadata.data.stream_info.sample_rate
        totalSamples = metadata.data.stream_info.total_samples
    }
}

private struct DecodedFLACFrame {
    let channels: [[Float]]
    let frameCount: AVAudioFrameCount
}

private let flacReadCallback: FLAC__StreamDecoderReadCallback = { _, buffer, bytes, clientData in
    guard let clientData,
          let buffer,
          let bytes else {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    guard let byteSource = wrapper.byteSource else {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }

    return byteSource.read(buffer: buffer, byteCount: bytes)
}

private let flacSeekCallback: FLAC__StreamDecoderSeekCallback = { _, absoluteByteOffset, clientData in
    guard let clientData else {
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR
    }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    guard let byteSource = wrapper.byteSource else {
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR
    }

    return byteSource.seek(to: absoluteByteOffset)
}

private let flacTellCallback: FLAC__StreamDecoderTellCallback = { _, absoluteByteOffset, clientData in
    guard let clientData,
          let absoluteByteOffset else {
        return FLAC__STREAM_DECODER_TELL_STATUS_ERROR
    }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    guard let byteSource = wrapper.byteSource else {
        return FLAC__STREAM_DECODER_TELL_STATUS_ERROR
    }

    let (status, offset) = byteSource.tell()
    absoluteByteOffset.pointee = offset
    return status
}

private let flacLengthCallback: FLAC__StreamDecoderLengthCallback = { _, streamLength, clientData in
    guard let clientData,
          let streamLength else {
        return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR
    }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    guard let byteSource = wrapper.byteSource else {
        return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR
    }

    let (status, length) = byteSource.length()
    streamLength.pointee = length
    return status
}

private let flacEOFCallback: FLAC__StreamDecoderEofCallback = { _, clientData in
    guard let clientData else {
        return 1
    }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    guard let byteSource = wrapper.byteSource else {
        return 1
    }

    return byteSource.isEOF() ? 1 : 0
}

private let flacWriteCallback: FLAC__StreamDecoderWriteCallback = { _, frame, buffer, clientData in
    guard let clientData,
          let frame,
          let buffer else {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
    }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    return wrapper.appendDecodedFrame(frame.pointee, buffers: buffer)
}

private let flacMetadataCallback: FLAC__StreamDecoderMetadataCallback = { _, metadata, clientData in
    guard let metadata, let clientData else { return }

    let wrapper = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
    wrapper.applyMetadata(metadata.pointee)
}

private let flacErrorCallback: FLAC__StreamDecoderErrorCallback = { _, _, _ in
}
