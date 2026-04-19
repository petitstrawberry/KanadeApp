import Foundation
import AVFoundation
import KanadeKit

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

    private static func supportsDirectRead(from sourceFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> Bool {
        sourceFormat.commonFormat == outputFormat.commonFormat
            && sourceFormat.sampleRate == outputFormat.sampleRate
            && sourceFormat.channelCount == outputFormat.channelCount
            && sourceFormat.isInterleaved == outputFormat.isInterleaved
    }
}
