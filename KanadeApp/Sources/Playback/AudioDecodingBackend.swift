import Foundation
import AVFoundation
import KanadeKit
import FLAC

#if DEBUG
private func flacPlaybackLog(_ message: @autoclosure () -> String) {
    print("[FLACPlayback] \(message())")
}
#endif

@MainActor
protocol AudioDecoderSource: AnyObject {
    var track: Track { get }

    func resolveForImmediatePlayback() async throws -> URL
    func prepareForLikelyPlayback() async
}

@MainActor
protocol DecoderSession: AnyObject {
    var outputFormat: AVAudioFormat { get }
    var durationSecs: Double { get }

    func seek(to positionSecs: Double) throws
    func decodeNextBuffer(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer?
    func close()
}

@MainActor
protocol AudioDecodingBackend: AnyObject {
    func makeSession(for source: any AudioDecoderSource) async throws -> any DecoderSession
    func prepareForPlayback(of source: any AudioDecoderSource) async
}

fileprivate enum DecoderBackendKind {
    case avAudioFile
    case flac
}

@MainActor
final class CachedTrackAudioSource: AudioDecoderSource {
    let track: Track

    private let mediaClient: MediaClient

    init(track: Track, mediaClient: MediaClient) {
        self.track = track
        self.mediaClient = mediaClient
    }

    func resolveForImmediatePlayback() async throws -> URL {
        try await mediaClient.downloadTrack(trackId: track.id)
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
        let localFileURL = try await source.resolveForImmediatePlayback()
        return try AVAudioFileDecoderSession(fileURL: localFileURL, outputFormat: outputFormat)
    }

    func prepareForPlayback(of source: any AudioDecoderSource) async {
        await source.prepareForLikelyPlayback()
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
        let localFileURL = try await source.resolveForImmediatePlayback()
        #if DEBUG
        flacPlaybackLog("makeSession track=\(source.track.id) url=\(localFileURL.lastPathComponent)")
        #endif
        return try LibFLACDecoderSession(fileURL: localFileURL, outputFormat: outputFormat)
    }

    func prepareForPlayback(of source: any AudioDecoderSource) async {
        await source.prepareForLikelyPlayback()
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

    init(fileURL: URL, outputFormat: AVAudioFormat) throws {
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
            converter?.reset()
            return
        }

        let clampedPosition = min(max(positionSecs, 0), durationSecs)
        let framePosition = AVAudioFramePosition(clampedPosition * sampleRate)
        audioFile.framePosition = min(max(framePosition, 0), audioFile.length)
        converter?.reset()
    }

    func decodeNextBuffer(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard frameCapacity > 0 else { return nil }

        if !requiresConversion {
            return try decodeBufferWithoutConversion(frameCapacity: frameCapacity)
        }

        return try decodeBufferWithConversion(frameCapacity: frameCapacity)
    }

    func close() {
    }

    private func decodeBufferWithoutConversion(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.AVAudioFileDecoderSession", code: -1)
        }

        try audioFile.read(into: buffer, frameCount: frameCapacity)
        return buffer.frameLength > 0 ? buffer : nil
    }

    private func decodeBufferWithConversion(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.AVAudioFileDecoderSession", code: -2)
        }

        var conversionError: NSError?
        var capturedError: Error?
        var hitEndOfStream = false

        let sourceFrameCapacity = sourceFrameCapacity(forOutputFrameCapacity: frameCapacity)

        let status = converter.convert(to: outputBuffer, error: &conversionError) { [unowned self] _, outStatus in
            if hitEndOfStream {
                outStatus.pointee = .endOfStream
                return nil
            }

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.sourceFormat, frameCapacity: sourceFrameCapacity) else {
                outStatus.pointee = .noDataNow
                return nil
            }

            do {
                try self.audioFile.read(into: inputBuffer, frameCount: sourceFrameCapacity)
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

            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let capturedError {
            throw capturedError
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            throw NSError(domain: "AudioDecodingBackend.AVAudioFileDecoderSession", code: -3)
        @unknown default:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        }
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

    init(fileURL: URL, outputFormat: AVAudioFormat) throws {
        self.wrapper = try FLACDecoderWrapper(fileURL: fileURL)
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
        guard wrapper.seek(toSample: sample) else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -11)
        }
        reachedEndOfStream = false
        converter?.reset()
    }

    func decodeNextBuffer(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard frameCapacity > 0 else { return nil }

        let buffer: AVAudioPCMBuffer?
        if !requiresConversion {
            buffer = try decodeWithoutConversion(frameCapacity: frameCapacity)
        } else {
            buffer = try decodeWithConversion(frameCapacity: frameCapacity)
        }

        #if DEBUG
        if let buffer {
            flacPlaybackLog("decodeNextBuffer frames=\(buffer.frameLength) format=\(buffer.format.commonFormat.rawValue) interleaved=\(buffer.format.isInterleaved) channels=\(buffer.format.channelCount) rate=\(buffer.format.sampleRate)")
        } else {
            flacPlaybackLog("decodeNextBuffer nil reachedEndOfStream=\(reachedEndOfStream)")
        }
        #endif

        return buffer
    }

    func close() {
        wrapper.close()
        converter = nil
    }

    private func decodeWithoutConversion(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -12)
        }

        let framesRead = try Self.fillPCMBuffer(
            buffer,
            frameCapacity: frameCapacity,
            wrapper: wrapper,
            reachedEndOfStream: &reachedEndOfStream
        )
        return framesRead > 0 ? buffer : nil
    }

    private func decodeWithConversion(frameCapacity: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -13)
        }

        var conversionError: NSError?
        var capturedError: Error?

        let sourceFrameCapacity = sourceFrameCapacity(forOutputFrameCapacity: frameCapacity)

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            do {
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: self.sourceFormat, frameCapacity: sourceFrameCapacity) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                let framesRead = try Self.fillPCMBuffer(
                    inputBuffer,
                    frameCapacity: sourceFrameCapacity,
                    wrapper: self.wrapper,
                    reachedEndOfStream: &self.reachedEndOfStream
                )

                if framesRead == 0 {
                    outStatus.pointee = self.reachedEndOfStream ? .endOfStream : .noDataNow
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
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

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if outputBuffer.frameLength > 0 {
                return outputBuffer
            }

            if status == .inputRanDry, !reachedEndOfStream {
                return try decodeWithConversion(frameCapacity: frameCapacity)
            }

            return nil
        case .error:
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -14)
        @unknown default:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        }
    }

    private static func fillPCMBuffer(
        _ buffer: AVAudioPCMBuffer,
        frameCapacity: AVAudioFrameCount,
        wrapper: FLACDecoderWrapper,
        reachedEndOfStream: inout Bool
    ) throws -> AVAudioFrameCount {
        guard let decodedFrame = try wrapper.decodeNextFrame() else {
            reachedEndOfStream = true
            buffer.frameLength = 0
            return 0
        }

        let framesAvailable = min(frameCapacity, decodedFrame.frameCount)
        guard framesAvailable > 0 else {
            buffer.frameLength = 0
            return 0
        }

        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "AudioDecodingBackend.LibFLACDecoderSession", code: -16)
        }

        for (channelIndex, sourceChannel) in decodedFrame.channels.enumerated() {
            sourceChannel.withUnsafeBufferPointer { sourceSamples in
                channelData[channelIndex].assign(from: sourceSamples.baseAddress!, count: Int(framesAvailable))
            }
        }

        buffer.frameLength = framesAvailable
        return framesAvailable
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
    private let decoder: UnsafeMutablePointer<FLAC__StreamDecoder>
    private var reachedEndOfStream = false
    private var decodedChannels: [[Float]] = []
    private var decodedFrameCount: AVAudioFrameCount = 0

    private(set) var channels: UInt32
    private(set) var bitsPerSample: UInt32
    private(set) var sampleRate: UInt32
    private(set) var totalSamples: UInt64

    init(fileURL: URL) throws {
        guard let decoder = FLAC__stream_decoder_new() else {
            throw NSError(domain: "AudioDecodingBackend.FLACDecoderWrapper", code: -20)
        }

        self.decoder = decoder
        self.channels = 0
        self.bitsPerSample = 0
        self.sampleRate = 0
        self.totalSamples = 0

        try self.open(fileURL: fileURL)
    }

    private func open(fileURL: URL) throws {
        reachedEndOfStream = false
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0

        #if DEBUG
        flacPlaybackLog("wrapperOpen start path=\(fileURL.lastPathComponent)")
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

    func decodeNextFrame() throws -> DecodedFLACFrame? {
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0

        while decodedFrameCount == 0 && !reachedEndOfStream {
            let success = FLAC__stream_decoder_process_single(decoder)
            if success == 0 {
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
            #if DEBUG
            flacPlaybackLog("decodeNextFrame nil endOfStream=\(reachedEndOfStream)")
            #endif
            return nil
        }

        #if DEBUG
        flacPlaybackLog("decodeNextFrame block=\(decodedFrameCount) channels=\(decodedChannels.count)")
        #endif
        return DecodedFLACFrame(channels: decodedChannels, frameCount: decodedFrameCount)
    }

    func close() {
        reachedEndOfStream = true
        decodedChannels.removeAll(keepingCapacity: false)
        decodedFrameCount = 0
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
