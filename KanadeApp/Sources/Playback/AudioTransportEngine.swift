import Foundation
import AVFoundation
import KanadeKit

#if DEBUG
private let audioTransportLogOrigin = ProcessInfo.processInfo.systemUptime

private func audioTransportLog(_ message: @autoclosure () -> String) {
    guard PlaybackDebug.transportLogsEnabled else { return }
    let elapsed = ProcessInfo.processInfo.systemUptime - audioTransportLogOrigin
    print("[AudioTransport +\(String(format: "%.3f", elapsed))s] \(message())")
}
#endif

@MainActor
final class AudioTransportEngine {
    @MainActor
    private final class QueuedDecoderSession {
        let id = UUID()
        let session: any DecoderSession
        var scheduledBufferCount = 0
        var reachedEndOfStream = false

        init(_ session: any DecoderSession) {
            self.session = session
        }

        var durationSecs: Double { session.durationSecs }

        var shortID: String { String(id.uuidString.prefix(8)) }

        func close() {
            session.close()
        }
    }

    private static let defaultSampleRate = 44_100.0
    private static let bufferFrameCapacity: AVAudioFrameCount = 16_384
    private static let maxScheduledBuffers = 4

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private(set) var state = RendererState()

    var onStateChanged: ((RendererState) -> Void)?
    var onCurrentSessionFinishedWithoutHandoff: (() -> Void)?
    var onNaturalHandoffCommitted: (() -> Void)?

    let outputFormat: AVAudioFormat

    private var decoderSession: QueuedDecoderSession?
    private var preparedNextSession: QueuedDecoderSession?
    private var stateRefreshTask: Task<Void, Never>?
    private var completionGeneration = UUID()
    private var scheduledBufferCount = 0
    private var desiredPlayback = false
    private var isFinishingTrack = false
    private var trackDurationSecs = 0.0
    private var startPositionSecs = 0.0
    private var anchoredPositionSecs = 0.0
    private var playbackAnchorSampleTime: AVAudioFramePosition = 0
    private var isLoadingSession = false
    private var sessionGeneration = UUID()
    private var seekRetryTask: Task<Void, Never>?

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
        seekRetryTask?.cancel()
    }

    func markLoading(durationHint: Double, autoplay: Bool) {
        completionGeneration = UUID()
        sessionGeneration = UUID()
        seekRetryTask?.cancel()
        seekRetryTask = nil
        desiredPlayback = autoplay
        isLoadingSession = true
        isFinishingTrack = false
        scheduledBufferCount = 0
        anchoredPositionSecs = 0
        startPositionSecs = 0
        playbackAnchorSampleTime = 0
        playerNode.stop()
        playerNode.reset()
        #if DEBUG
        audioTransportLog("markLoading durationHint=\(String(format: "%.3f", durationHint)) autoplay=\(autoplay) current=\(sessionSummary(decoderSession)) prepared=\(sessionSummary(preparedNextSession))")
        #endif
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

    func installCurrentSession(_ session: any DecoderSession, autoplay: Bool) {
        let previousSession = decoderSession
        completionGeneration = UUID()
        sessionGeneration = UUID()
        seekRetryTask?.cancel()
        seekRetryTask = nil
        desiredPlayback = autoplay
        isLoadingSession = false
        isFinishingTrack = false
        scheduledBufferCount = 0
        startPositionSecs = 0
        anchoredPositionSecs = 0
        playbackAnchorSampleTime = 0
        playerNode.stop()
        playerNode.reset()
        previousSession?.close()
        decoderSession = QueuedDecoderSession(session)
        #if DEBUG
        audioTransportLog("installCurrentSession newCurrent=\(sessionSummary(decoderSession)) previous=\(sessionSummary(previousSession)) autoplay=\(autoplay) prepared=\(sessionSummary(preparedNextSession))")
        #endif
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
        let currentSession = decoderSession
        let nextSession = preparedNextSession
        completionGeneration = UUID()
        sessionGeneration = UUID()
        seekRetryTask?.cancel()
        seekRetryTask = nil
        desiredPlayback = false
        isLoadingSession = false
        isFinishingTrack = false
        scheduledBufferCount = 0
        startPositionSecs = 0
        anchoredPositionSecs = 0
        playbackAnchorSampleTime = 0
        trackDurationSecs = 0
        playerNode.stop()
        playerNode.reset()
        decoderSession = nil
        preparedNextSession = nil
        currentSession?.close()
        nextSession?.close()
        #if DEBUG
        audioTransportLog("stop previousCurrent=\(sessionSummary(currentSession)) previousPrepared=\(sessionSummary(nextSession))")
        #endif

        applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
    }

    func seek(to positionSecs: Double) {
        guard let decoderSession else { return }

        seekRetryTask?.cancel()
        seekRetryTask = nil

        let wasPlaying = desiredPlayback || playerNode.isPlaying
        let clampedPosition = min(max(positionSecs, 0), max(trackDurationSecs, positionSecs))

        let currentGeneration = UUID()
        sessionGeneration = currentGeneration

        do {
            try decoderSession.session.seek(to: clampedPosition)
        } catch is FLACProgressiveSourceAccessError {
            seekRetryTask = Task { [weak self] in
                guard let self else { return }
                
                do {
                    try await decoderSession.session.waitForReadiness()
                    
                    guard self.sessionGeneration == currentGeneration else { return }
                    
                    try decoderSession.session.seek(to: clampedPosition)
                    
                    self.completeSeek(
                        clampedPosition: clampedPosition,
                        wasPlaying: wasPlaying,
                        generation: currentGeneration
                    )
                } catch {
                    guard self.sessionGeneration == currentGeneration else { return }
                    self.stop()
                }
            }
            
            completionGeneration = UUID()
            decoderSession.reachedEndOfStream = false
            decoderSession.scheduledBufferCount = 0
            isFinishingTrack = false
            scheduledBufferCount = 0
            startPositionSecs = clampedPosition
            anchoredPositionSecs = clampedPosition
            playbackAnchorSampleTime = 0
            desiredPlayback = wasPlaying
            
            playerNode.stop()
            playerNode.reset()
            preparedNextSession?.close()
            preparedNextSession = nil
            
            refreshState(forceStatus: wasPlaying ? .loading : .paused)
            return
        } catch {
            stop()
            return
        }

        completeSeek(clampedPosition: clampedPosition, wasPlaying: wasPlaying, generation: currentGeneration)
    }
    
    private func completeSeek(clampedPosition: Double, wasPlaying: Bool, generation: UUID) {
        guard sessionGeneration == generation else { return }
        
        completionGeneration = UUID()
        decoderSession?.reachedEndOfStream = false
        decoderSession?.scheduledBufferCount = 0
        isFinishingTrack = false
        scheduledBufferCount = 0
        startPositionSecs = clampedPosition
        anchoredPositionSecs = clampedPosition
        playbackAnchorSampleTime = 0
        desiredPlayback = wasPlaying

        playerNode.stop()
        playerNode.reset()
        preparedNextSession?.close()
        preparedNextSession = nil
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

    func installArmedNextSession(_ session: any DecoderSession) {
        let previousPrepared = preparedNextSession
        preparedNextSession?.close()
        preparedNextSession = QueuedDecoderSession(session)
        #if DEBUG
        audioTransportLog("installArmedNextSession previous=\(sessionSummary(previousPrepared)) newPrepared=\(sessionSummary(preparedNextSession)) current=\(sessionSummary(decoderSession))")
        #endif
    }

    func clearArmedNextSession() {
        let previousPrepared = preparedNextSession
        preparedNextSession?.close()
        preparedNextSession = nil
        #if DEBUG
        audioTransportLog("clearArmedNextSession previous=\(sessionSummary(previousPrepared)) current=\(sessionSummary(decoderSession))")
        #endif
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
        guard decoderSession != nil else { return }

        while scheduledBufferCount < Self.maxScheduledBuffers {
            guard let session = nextSessionToFill() else {
                #if DEBUG
                audioTransportLog("schedule none current=\(sessionSummary(decoderSession)) prepared=\(sessionSummary(preparedNextSession)) totalScheduled=\(scheduledBufferCount)")
                #endif
                finishTrackIfNeeded()
                return
            }

            let readResult: DecoderReadResult
            do {
                readResult = try session.session.decodeNextBuffer(frameCapacity: Self.bufferFrameCapacity)
            } catch {
                stop()
                return
            }

            switch readResult {
            case .buffer(let buffer):
                session.scheduledBufferCount += 1
                scheduledBufferCount += 1
                let generation = completionGeneration
                let sessionID = session.id
                #if DEBUG
                audioTransportLog("schedule buffer owner=\(session.shortID) frames=\(buffer.frameLength) ownerScheduled=\(session.scheduledBufferCount) totalScheduled=\(scheduledBufferCount) current=\(sessionSummary(decoderSession)) prepared=\(sessionSummary(preparedNextSession))")
                #endif
                playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.completionGeneration == generation else { return }
                        self.handleScheduledBufferCompletion(for: sessionID)
                    }
                }
            case .wouldBlock:
                #if DEBUG
                audioTransportLog("schedule wouldBlock owner=\(session.shortID) current=\(sessionSummary(decoderSession)) prepared=\(sessionSummary(preparedNextSession)) totalScheduled=\(scheduledBufferCount)")
                #endif
                finishTrackIfNeeded()
                return
            case .endOfStream:
                session.reachedEndOfStream = true
                #if DEBUG
                audioTransportLog("schedule endOfStream owner=\(session.shortID) ownerScheduled=\(session.scheduledBufferCount) current=\(sessionSummary(decoderSession)) prepared=\(sessionSummary(preparedNextSession)) totalScheduled=\(scheduledBufferCount)")
                #endif
                finishTrackIfNeeded()
            }
        }
    }

    private func finishTrackIfNeeded() {
        guard let activeSession = decoderSession, activeSession.reachedEndOfStream, activeSession.scheduledBufferCount == 0, !isFinishingTrack else { return }

        #if DEBUG
        audioTransportLog("finish candidate current=\(sessionSummary(activeSession)) prepared=\(sessionSummary(preparedNextSession)) totalScheduled=\(scheduledBufferCount)")
        #endif

        if let preparedNextSession {
            activatePreparedNextSession(preparedNextSession, replacing: activeSession)
            scheduleBuffersIfNeeded()
            refreshState(forceStatus: desiredPlayback && scheduledBufferCount > 0 ? .playing : .loading)
            return
        }

        guard scheduledBufferCount == 0 else { return }

        isFinishingTrack = true
        desiredPlayback = false
        anchoredPositionSecs = trackDurationSecs
        let finishedSession = activeSession
        #if DEBUG
        audioTransportLog("finish terminal current=\(sessionSummary(activeSession)) prepared=\(sessionSummary(preparedNextSession)) totalScheduled=\(scheduledBufferCount)")
        #endif
        completionGeneration = UUID()
        sessionGeneration = UUID()
        decoderSession = nil
        playerNode.stop()
        playerNode.reset()
        finishedSession.close()
        refreshState(forceStatus: .stopped)
        onCurrentSessionFinishedWithoutHandoff?()
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

        let renderedSamples = playerTime.sampleTime - playbackAnchorSampleTime
        let renderedSecs = Double(max(renderedSamples, 0)) / playerTime.sampleRate
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
        } else if isLoadingSession || (desiredPlayback && scheduledBufferCount == 0 && !(decoderSession?.reachedEndOfStream ?? true)) {
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

    private func nextSessionToFill() -> QueuedDecoderSession? {
        if let decoderSession, !decoderSession.reachedEndOfStream {
            return decoderSession
        }

        if let preparedNextSession {
            return preparedNextSession.reachedEndOfStream ? nil : preparedNextSession
        }

        return nil
    }

    private func handleScheduledBufferCompletion(for sessionID: UUID) {
        guard let session = queuedSession(withID: sessionID) else { return }

        session.scheduledBufferCount = max(0, session.scheduledBufferCount - 1)
        scheduledBufferCount = max(0, scheduledBufferCount - 1)

        #if DEBUG
        audioTransportLog("complete owner=\(session.shortID) ownerScheduled=\(session.scheduledBufferCount) totalScheduled=\(scheduledBufferCount) current=\(sessionSummary(decoderSession)) prepared=\(sessionSummary(preparedNextSession))")
        #endif

        finishTrackIfNeeded()
        scheduleBuffersIfNeeded()
        finishTrackIfNeeded()
        refreshState()
    }

    private func queuedSession(withID sessionID: UUID) -> QueuedDecoderSession? {
        if let decoderSession, decoderSession.id == sessionID {
            return decoderSession
        }

        if let preparedNextSession, preparedNextSession.id == sessionID {
            return preparedNextSession
        }

        return nil
    }

    private func activatePreparedNextSession(
        _ nextSession: QueuedDecoderSession,
        replacing currentSession: QueuedDecoderSession
    ) {
        #if DEBUG
        audioTransportLog("activate prepared next=\(sessionSummary(nextSession)) replacing current=\(sessionSummary(currentSession)) totalScheduled=\(scheduledBufferCount)")
        #endif
        preparedNextSession = nil
        decoderSession = nextSession
        currentSession.close()

        isLoadingSession = false
        trackDurationSecs = max(nextSession.durationSecs, 0)
        startPositionSecs = 0
        anchoredPositionSecs = 0
        playbackAnchorSampleTime = currentPlaybackSampleTime() ?? playbackAnchorSampleTime

        onNaturalHandoffCommitted?()
    }

    #if DEBUG
    private func sessionSummary(_ session: QueuedDecoderSession?) -> String {
        guard let session else { return "<nil>" }
        return "\(session.shortID){eos=\(session.reachedEndOfStream),scheduled=\(session.scheduledBufferCount),duration=\(String(format: "%.3f", session.durationSecs))}"
    }
    #endif

    private func currentPlaybackSampleTime() -> AVAudioFramePosition? {
        guard let lastRenderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime)
        else {
            return nil
        }

        return playerTime.sampleTime
    }
}
