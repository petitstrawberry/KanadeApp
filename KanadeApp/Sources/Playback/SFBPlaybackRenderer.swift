import Foundation
import AVFoundation
import Observation
import SFBAudioEngine
import KanadeKit

#if DEBUG
private let sfbPlaybackLogDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func sfbPlaybackDebugLog(_ message: @autoclosure () -> String) {
    print("[SFBPlaybackRenderer][\(sfbPlaybackLogDateFormatter.string(from: Date()))] \(message())")
}
#endif

@MainActor
@Observable
final class SFBPlaybackRenderer: NSObject, AudioRenderer {
    var state = RendererState()

    @ObservationIgnored var onStateChanged: ((RendererState) -> Void)?
    @ObservationIgnored var onTrackAdvanced: (() -> Void)?
    @ObservationIgnored var onTrackFinished: (() -> Void)?

    @ObservationIgnored nonisolated(unsafe) private let player = AudioPlayer()
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored nonisolated(unsafe) private var currentInputSource: InputSource?
    @ObservationIgnored nonisolated(unsafe) private var currentDecoder: AudioDecoder?
    @ObservationIgnored nonisolated(unsafe) private var loadTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?

    @ObservationIgnored private var shouldAutoplay = true
    @ObservationIgnored private var isLoadingTrack = false
    @ObservationIgnored private var pendingSeekPosition: Double?
    @ObservationIgnored private var pendingSeekStartedAt: Date?
    @ObservationIgnored private let pendingSeekTimeout: TimeInterval = 15
    @ObservationIgnored private var activeLoadID = UUID()

    override init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: configuration)

        super.init()

        player.delegate = self
        setVolume(100)
        refreshState()
        startRefreshLoop()
    }

    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
        player.delegate = nil
        player.stop()
        try? currentDecoder?.close()
        try? currentInputSource?.close()
        urlSession.invalidateAndCancel()
    }

    func loadTrack(url: URL, autoplay: Bool) {
        shouldAutoplay = autoplay
        isLoadingTrack = true
        pendingSeekPosition = nil
        pendingSeekStartedAt = nil
        activeLoadID = UUID()

        loadTask?.cancel()
        player.stop()
        replaceResources(decoder: nil, inputSource: nil)

        loadTask = Task { [weak self] in
            guard let self else { return }

            let loadID = self.activeLoadID

            do {
                let contentLength = try await self.contentLength(for: url)
                try Task.checkCancellation()

                let inputSource = try self.makeInputSource(url: url, contentLength: contentLength)

                let decoder = try await Task.detached { [inputSource] in
                    try AudioDecoder(inputSource: inputSource, decoderName: .FLAC)
                }.value
                try Task.checkCancellation()

                if self.activeLoadID != loadID {
                    try? decoder.close()
                    try? inputSource.close()
                    return
                }

                self.replaceResources(decoder: decoder, inputSource: inputSource)

                do {
                    if autoplay {
                        try await Task.detached { [player, decoder] in
                            try player.play(decoder)
                        }.value
                    } else {
                        try await Task.detached { [player, decoder] in
                            try player.enqueue(decoder, immediate: true)
                        }.value
                    }
                    self.isLoadingTrack = false
                    self.refreshState()
                } catch {
                    self.isLoadingTrack = false
                    self.pendingSeekPosition = nil
                    self.pendingSeekStartedAt = nil
                    self.player.stop()
                    self.replaceResources(decoder: nil, inputSource: nil)
                    self.refreshState(forceStatus: .stopped)
                }
            } catch is CancellationError {
            } catch {
                if self.activeLoadID == loadID {
                    self.isLoadingTrack = false
                    self.pendingSeekPosition = nil
                    self.pendingSeekStartedAt = nil
                    self.player.stop()
                    self.replaceResources(decoder: nil, inputSource: nil)
                    self.refreshState(forceStatus: .stopped)
                }
            }
        }

        refreshState(forceStatus: .loading)
    }

    func loadTracks(urls: [URL], startIndex: Int) {
        guard !urls.isEmpty, urls.indices.contains(startIndex) else {
            stop()
            return
        }

        loadTrack(url: urls[startIndex], autoplay: true)
    }

    func play() {
        shouldAutoplay = true

        guard let decoder = currentDecoder else {
            refreshState()
            return
        }

        if player.playbackState == .paused {
            _ = player.resume()
        } else {
            try? player.play(decoder)
        }

        refreshState()
        debugLogAction("play()")
    }

    func pause() {
        shouldAutoplay = false
        _ = player.pause()
        refreshState(forceStatus: .paused)
        debugLogAction("pause()")
    }

    func stop() {
        shouldAutoplay = false
        isLoadingTrack = false
        pendingSeekPosition = nil
        pendingSeekStartedAt = nil
        activeLoadID = UUID()
        loadTask?.cancel()
        player.stop()
        replaceResources(decoder: nil, inputSource: nil)
        applyState(RendererState(status: .stopped, positionSecs: 0, durationSecs: 0, volume: state.volume))
    }

    func seek(to positionSecs: Double) {
        guard let decoder = player.nowPlaying ?? player.currentDecoder ?? currentDecoder else { return }

        let sampleRate = decoder.processingFormat.sampleRate
        guard sampleRate > 0 else { return }

        let clamped = max(0, positionSecs)
        let frame = AVAudioFramePosition(clamped * sampleRate)

        pendingSeekPosition = clamped
        pendingSeekStartedAt = Date()
        applyState(RendererState(status: state.status, positionSecs: clamped, durationSecs: state.durationSecs, volume: state.volume))

        if !player.seek(frame: frame) {
            pendingSeekPosition = nil
            pendingSeekStartedAt = nil
            refreshState()
        }

        debugLogAction("seek(to: \(positionSecs))")
    }

    func setVolume(_ volume: Int) {
        let clampedVolume = min(max(volume, 0), 100)
        player.mainMixerNode.outputVolume = Float(clampedVolume) / 100.0
        state.volume = clampedVolume
        onStateChanged?(state)
    }

    func advanceToNextTrack() -> Bool {
        false
    }

    func prepareNext(url: URL) {
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                guard self.isLoadingTrack || self.state.status != .stopped else { continue }
                self.refreshState()
            }
        }
    }

    private func contentLength(for url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SFBPlaybackRenderer", code: -1)
        }

        if let headerValue = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let contentLength = Int(headerValue),
           contentLength > 0 {
            return contentLength
        }

        let expectedContentLength = Int(httpResponse.expectedContentLength)
        guard expectedContentLength > 0 else {
            throw NSError(domain: "SFBPlaybackRenderer", code: -2)
        }

        return expectedContentLength
    }

    private func makeInputSource(url: URL, contentLength: Int) throws -> InputSource {
        guard let inputSource = SFBProgressiveInputSourceCreate(url, contentLength, urlSession) else {
            throw NSError(domain: "SFBPlaybackRenderer", code: -3)
        }
        return inputSource
    }

    private func replaceResources(decoder: AudioDecoder?, inputSource: InputSource?) {
        let previousDecoder = currentDecoder
        let previousInputSource = currentInputSource

        currentDecoder = decoder
        currentInputSource = inputSource

        if previousDecoder !== decoder {
            Task.detached { try? previousDecoder?.close() }
        }
        if previousInputSource !== inputSource {
            Task.detached { try? previousInputSource?.close() }
        }
    }

    private func refreshState(forceStatus: PlaybackStatus? = nil) {
        let hasManagedDecoder = currentDecoder != nil
        let decoder = hasManagedDecoder ? (player.nowPlaying ?? player.currentDecoder ?? currentDecoder) : nil
        let sampleRate = decoder?.processingFormat.sampleRate ?? 0
        let durationSecs = seconds(fromFramePosition: decoder?.length ?? 0, sampleRate: sampleRate)
        let actualPosition = seconds(fromFramePosition: decoder?.position ?? 0, sampleRate: sampleRate)

        if let pendingSeekPosition {
            let seekMatched = abs(actualPosition - pendingSeekPosition) < 0.5
            let seekTimedOut = pendingSeekStartedAt.map { Date().timeIntervalSince($0) >= pendingSeekTimeout } ?? false

            if seekMatched || seekTimedOut {
                self.pendingSeekPosition = nil
                self.pendingSeekStartedAt = nil
            }
        }

        let positionSecs = pendingSeekPosition ?? actualPosition

        let status: PlaybackStatus
        if let forceStatus {
            status = forceStatus
        } else if isLoadingTrack {
            status = .loading
        } else if hasManagedDecoder {
            switch player.playbackState {
            case .playing:
                status = .playing
            case .paused, .stopped:
                status = .paused
            @unknown default:
                status = .stopped
            }
        } else {
            status = .stopped
        }

        applyState(
            RendererState(
                status: status,
                positionSecs: positionSecs,
                durationSecs: durationSecs,
                volume: state.volume
            )
        )

        debugLogRefreshState(
            forceStatus: forceStatus,
            actualPosition: actualPosition,
            resolvedPosition: positionSecs,
            durationSecs: durationSecs,
            resolvedStatus: status
        )
    }

    private func applyState(_ newState: RendererState) {
        state = newState
        onStateChanged?(state)
    }

    private func seconds(fromFramePosition framePosition: AVAudioFramePosition, sampleRate: Double) -> Double {
        guard framePosition > 0, sampleRate > 0 else { return 0 }
        return Double(framePosition) / sampleRate
    }

    private func debugLogAction(_ action: String) {
#if DEBUG
        sfbPlaybackDebugLog(
            "action=\(action) playerState=\(String(describing: player.playbackState)) status=\(state.status.rawValue) shouldAutoplay=\(shouldAutoplay) pendingSeekPosition=\(String(describing: pendingSeekPosition)) currentDecoder=\(currentDecoder != nil)"
        )
#endif
    }

    private func debugLogRefreshState(
        forceStatus: PlaybackStatus?,
        actualPosition: Double,
        resolvedPosition: Double,
        durationSecs: Double,
        resolvedStatus: PlaybackStatus
    ) {
#if DEBUG
        sfbPlaybackDebugLog(
            "refreshState forceStatus=\(forceStatus?.rawValue ?? "nil") playerState=\(String(describing: player.playbackState)) resolvedStatus=\(resolvedStatus.rawValue) actualPosition=\(actualPosition) resolvedPosition=\(resolvedPosition) duration=\(durationSecs) isLoadingTrack=\(isLoadingTrack) pendingSeekPosition=\(String(describing: pendingSeekPosition)) shouldAutoplay=\(shouldAutoplay)"
        )
#endif
    }
}

extension SFBPlaybackRenderer: AudioPlayer.Delegate {
    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        Task { @MainActor [weak self] in
            #if DEBUG
            sfbPlaybackDebugLog("delegate=playbackStateChanged playerState=\(String(describing: playbackState))")
            #endif
            self?.refreshState()
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: PCMDecoding?) {
        Task { @MainActor [weak self] in
            #if DEBUG
            sfbPlaybackDebugLog("delegate=nowPlayingChanged hasDecoder=\(nowPlaying != nil)")
            #endif
            self?.refreshState()
        }
    }

    nonisolated func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            sfbPlaybackDebugLog("delegate=endOfAudio")
            #endif
            self.refreshState(forceStatus: .stopped)
            self.onTrackFinished?()
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoadingTrack = false
            self.pendingSeekPosition = nil
            self.pendingSeekStartedAt = nil
            self.player.stop()
            self.replaceResources(decoder: nil, inputSource: nil)
            self.refreshState(forceStatus: .stopped)
        }
    }

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, decodingAborted decoder: PCMDecoding, error: Error, framesRendered: AVAudioFramePosition) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoadingTrack = false
            self.pendingSeekPosition = nil
            self.pendingSeekStartedAt = nil
            self.player.stop()
            self.replaceResources(decoder: nil, inputSource: nil)
            self.refreshState(forceStatus: .stopped)
        }
    }
}
