import Foundation
import AVFoundation
import KanadeKit

@MainActor
final class AudioTransportEngine {
    private static let defaultSampleRate = 44_100.0
    private static let bufferFrameCapacity: AVAudioFrameCount = 16_384
    private static let maxScheduledBuffers = 4

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private(set) var state = RendererState()

    var onStateChanged: ((RendererState) -> Void)?
    var onTrackFinished: (() -> Void)?

    let outputFormat: AVAudioFormat

    private var decoderSession: (any DecoderSession)?
    private var stateRefreshTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private var scheduledBufferCount = 0
    private var reachedEndOfStream = false
    private var desiredPlayback = false
    private var isFinishingTrack = false
    private var trackDurationSecs = 0.0
    private var startPositionSecs = 0.0
    private var anchoredPositionSecs = 0.0
    private var isLoadingSession = false

    init(outputFormat: AVAudioFormat? = nil) {
        self.outputFormat = outputFormat ?? AVAudioFormat(standardFormatWithSampleRate: Self.defaultSampleRate, channels: 2)!

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: self.outputFormat)
        engine.prepare()
        startEngineIfNeeded()
        setVolume(100)
        startStateRefreshLoop()
        refreshState()
    }

    deinit {
        stateRefreshTask?.cancel()
    }

    func markLoading(durationHint: Double, autoplay: Bool) {
        completionGeneration = UUID()
        desiredPlayback = autoplay
        isLoadingSession = true
        isFinishingTrack = false
        reachedEndOfStream = false
        scheduledBufferCount = 0
        anchoredPositionSecs = 0
        startPositionSecs = 0
        playerNode.stop()
        playerNode.reset()
        trackDurationSecs = max(durationHint, 0)
        applyState(
            RendererState(
                status: autoplay ? .loading : .paused,
                positionSecs: 0,
                durationSecs: trackDurationSecs,
                volume: state.volume
            )
        )
    }

    func replaceCurrentSession(_ session: any DecoderSession, autoplay: Bool) {
        completionGeneration = UUID()
        desiredPlayback = autoplay
        isLoadingSession = false
        isFinishingTrack = false
        playerNode.stop()
        playerNode.reset()
        decoderSession?.close()
        decoderSession = session

        scheduledBufferCount = 0
        reachedEndOfStream = false
        startPositionSecs = 0
        anchoredPositionSecs = 0
        trackDurationSecs = max(session.durationSecs, 0)

        startEngineIfNeeded()
        scheduleBuffersIfNeeded()

        if autoplay, scheduledBufferCount > 0 {
            playerNode.play()
        }

        refreshState(forceStatus: autoplay ? (scheduledBufferCount > 0 ? .playing : .loading) : .paused)
    }

    func play() {
        desiredPlayback = true
        guard decoderSession != nil else {
            refreshState(forceStatus: .stopped)
            return
        }

        startEngineIfNeeded()
        scheduleBuffersIfNeeded()

        if scheduledBufferCount > 0 {
            playerNode.play()
        }

        refreshState(forceStatus: scheduledBufferCount > 0 ? .playing : .loading)
    }

    func pause() {
        anchoredPositionSecs = measuredPlaybackPositionSecs()
        desiredPlayback = false
        playerNode.pause()
        refreshState(forceStatus: decoderSession == nil ? .stopped : .paused)
    }

    func stop() {
        completionGeneration = UUID()
        desiredPlayback = false
        isLoadingSession = false
        isFinishingTrack = false
        reachedEndOfStream = false
        scheduledBufferCount = 0
        startPositionSecs = 0
        anchoredPositionSecs = 0
        trackDurationSecs = 0
        playerNode.stop()
        playerNode.reset()
        decoderSession?.close()
        decoderSession = nil

        applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
    }

    func seek(to positionSecs: Double) {
        guard let decoderSession else { return }

        let wasPlaying = desiredPlayback || playerNode.isPlaying
        let clampedPosition = min(max(positionSecs, 0), max(trackDurationSecs, positionSecs))

        do {
            try decoderSession.seek(to: clampedPosition)
        } catch {
            stop()
            return
        }

        completionGeneration = UUID()
        reachedEndOfStream = false
        isFinishingTrack = false
        scheduledBufferCount = 0
        startPositionSecs = clampedPosition
        anchoredPositionSecs = clampedPosition
        desiredPlayback = wasPlaying

        playerNode.stop()
        playerNode.reset()
        scheduleBuffersIfNeeded()

        if wasPlaying, scheduledBufferCount > 0 {
            playerNode.play()
        }

        refreshState(forceStatus: wasPlaying ? (scheduledBufferCount > 0 ? .playing : .loading) : .paused)
    }

    func setVolume(_ volume: Int) {
        let clampedVolume = min(max(volume, 0), 100)
        playerNode.volume = Float(clampedVolume) / 100.0
        state.volume = clampedVolume
        onStateChanged?(state)
    }

    private func startStateRefreshLoop() {
        stateRefreshTask?.cancel()
        stateRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run {
                    self?.refreshState()
                }
            }
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    private func scheduleBuffersIfNeeded() {
        guard let decoderSession else { return }

        while scheduledBufferCount < Self.maxScheduledBuffers && !reachedEndOfStream {
            let buffer: AVAudioPCMBuffer?
            do {
                buffer = try decoderSession.decodeNextBuffer(frameCapacity: Self.bufferFrameCapacity)
            } catch {
                stop()
                return
            }

            guard let buffer else {
                reachedEndOfStream = true
                finishTrackIfNeeded()
                return
            }

            scheduledBufferCount += 1
            let generation = completionGeneration
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.completionGeneration == generation else { return }
                    self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
                    self.scheduleBuffersIfNeeded()
                    self.finishTrackIfNeeded()
                    self.refreshState()
                }
            }
        }
    }

    private func finishTrackIfNeeded() {
        guard reachedEndOfStream, scheduledBufferCount == 0, !isFinishingTrack else { return }

        isFinishingTrack = true
        desiredPlayback = false
        anchoredPositionSecs = trackDurationSecs
        playerNode.stop()
        playerNode.reset()
        refreshState(forceStatus: .stopped)
        onTrackFinished?()
        isFinishingTrack = false
    }

    private func measuredPlaybackPositionSecs() -> Double {
        guard playerNode.isPlaying,
              let lastRenderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime),
              playerTime.sampleRate > 0
        else {
            return anchoredPositionSecs
        }

        let renderedSecs = Double(playerTime.sampleTime) / playerTime.sampleRate
        return max(startPositionSecs + renderedSecs, 0)
    }

    private func refreshState(forceStatus: PlaybackStatus? = nil) {
        let rawPosition = max(measuredPlaybackPositionSecs(), 0)
        let measuredPosition = trackDurationSecs > 0 ? min(rawPosition, trackDurationSecs) : rawPosition

        if !playerNode.isPlaying {
            anchoredPositionSecs = measuredPosition
        }

        let resolvedStatus: PlaybackStatus
        if let forceStatus {
            resolvedStatus = forceStatus
        } else if decoderSession == nil {
            resolvedStatus = .stopped
        } else if isLoadingSession || (desiredPlayback && scheduledBufferCount == 0 && !reachedEndOfStream) {
            resolvedStatus = .loading
        } else if playerNode.isPlaying {
            resolvedStatus = .playing
        } else {
            resolvedStatus = .paused
        }

        applyState(
            RendererState(
                status: resolvedStatus,
                positionSecs: measuredPosition,
                durationSecs: trackDurationSecs,
                volume: state.volume
            )
        )
    }

    private func applyState(_ newState: RendererState) {
        state = newState
        onStateChanged?(state)
    }
}
