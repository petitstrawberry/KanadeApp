import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class UnifiedPlaybackRenderer {
    private enum NextCandidateArmState {
        case none
        case warming
        case preparing
        case warmOnly
        case armed
    }

    private struct NextCandidateContext {
        let trackID: String
        let queueGeneration: UUID
        var armGeneration: UUID
        var source: any AudioDecoderSource
        var state: NextCandidateArmState
    }

    var state = RendererState()

    @ObservationIgnored var onStateChanged: ((RendererState) -> Void)?
    @ObservationIgnored var onCurrentSessionFinishedWithoutHandoff: (() -> Void)?
    @ObservationIgnored var onNaturalHandoffCommitted: (() -> Void)?

    @ObservationIgnored private let transport: AudioTransportEngine
    @ObservationIgnored private let decodingBackend: any AudioDecodingBackend
    @ObservationIgnored private var currentLoadGeneration = UUID()
    @ObservationIgnored private var nextCandidate: NextCandidateContext?
    @ObservationIgnored private var nextCandidateArmTask: Task<Void, Never>?

    init() {
        let transport = AudioTransportEngine()
        self.transport = transport
        self.decodingBackend = RoutedAudioDecodingBackend(outputFormat: transport.outputFormat)

        transport.onStateChanged = { [weak self] rendererState in
            guard let self else { return }
            self.state = rendererState
            if case .warmOnly = self.nextCandidate?.state {
                self.rearmNextCandidateIfNeeded(trigger: "state-refresh")
            }
            self.onStateChanged?(rendererState)
        }

        transport.onCurrentSessionFinishedWithoutHandoff = { [weak self] in
            self?.onCurrentSessionFinishedWithoutHandoff?()
        }

        transport.onNaturalHandoffCommitted = { [weak self] in
            self?.handleNaturalHandoffCommitted()
        }

        state = transport.state
    }

    func beginLoading(durationHint: Double?, autoplay: Bool) {
        transport.markLoading(durationHint: durationHint ?? 0, autoplay: autoplay)
    }

    func loadTrack(source: any AudioDecoderSource, autoplay: Bool) async throws {
        let loadGeneration = UUID()
        currentLoadGeneration = loadGeneration
        transport.markLoading(durationHint: source.track.durationSecs ?? 0, autoplay: autoplay)
        let session = try await decodingBackend.makeSession(for: source)
        guard currentLoadGeneration == loadGeneration else {
            session.close()
            return
        }
        transport.installCurrentSession(session, autoplay: autoplay)
        rearmNextCandidateIfNeeded(trigger: "load-installed")
    }

    func play() {
        transport.play()
    }

    func pause() {
        transport.pause()
    }

    func stop() {
        currentLoadGeneration = UUID()
        clearNextCandidate()
        transport.stop()
    }

    func seek(to positionSecs: Double) {
        transport.seek(to: positionSecs)
        rearmNextCandidateAfterSeek()
    }

    func setVolume(_ volume: Int) {
        transport.setVolume(volume)
    }

    func updateNextCandidate(source: (any AudioDecoderSource)?, queueGeneration: UUID) {
        guard let source else {
            clearNextCandidate()
            return
        }

        if var existing = nextCandidate,
           existing.trackID == source.track.id,
           existing.queueGeneration == queueGeneration {
            existing.source = source
            nextCandidate = existing
            rearmNextCandidateIfNeeded(trigger: "refresh-same-candidate")
            return
        }

        invalidateNextCandidate(reason: "candidate-changed")
        let armGeneration = UUID()
        nextCandidate = NextCandidateContext(
            trackID: source.track.id,
            queueGeneration: queueGeneration,
            armGeneration: armGeneration,
            source: source,
            state: .warming
        )
        armNextCandidate(trackID: source.track.id, queueGeneration: queueGeneration, armGeneration: armGeneration)
    }

    func invalidateNextCandidate(reason: String) {
        nextCandidateArmTask?.cancel()
        nextCandidateArmTask = nil
        guard nextCandidate != nil else {
            transport.clearArmedNextSession()
            return
        }
        nextCandidate = nil
        transport.clearArmedNextSession()
        #if DEBUG
        if PlaybackDebug.lifecycleLogsEnabled {
            print("[UnifiedPlaybackRenderer] invalidateNextCandidate reason=\(reason)")
        }
        #endif
    }

    func clearNextCandidate() {
        invalidateNextCandidate(reason: "cleared")
    }

    func rearmNextCandidateAfterSeek() {
        rearmNextCandidateIfNeeded(trigger: "seek")
    }

    private func handleNaturalHandoffCommitted() {
        nextCandidateArmTask?.cancel()
        nextCandidateArmTask = nil
        nextCandidate = nil
        onNaturalHandoffCommitted?()
    }

    private func rearmNextCandidateIfNeeded(trigger: String) {
        guard let nextCandidate else { return }

        switch nextCandidate.state {
        case .preparing, .warming:
            return
        case .none, .warmOnly, .armed:
            let armGeneration = UUID()
            var updated = nextCandidate
            updated.armGeneration = armGeneration
            updated.state = .warming
            self.nextCandidate = updated
            nextCandidateArmTask?.cancel()
            nextCandidateArmTask = nil
            transport.clearArmedNextSession()
            armNextCandidate(trackID: updated.trackID, queueGeneration: updated.queueGeneration, armGeneration: armGeneration)
            #if DEBUG
            if PlaybackDebug.lifecycleLogsEnabled {
                print("[UnifiedPlaybackRenderer] rearmNextCandidate trigger=\(trigger) track=\(updated.trackID)")
            }
            #endif
        }
    }

    private func armNextCandidate(trackID: String, queueGeneration: UUID, armGeneration: UUID) {
        nextCandidateArmTask?.cancel()
        nextCandidateArmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.matchesNextCandidate(trackID: trackID, queueGeneration: queueGeneration, armGeneration: armGeneration) else { return }

            guard let source = self.nextCandidate?.source else { return }
            await self.decodingBackend.prepareForPlayback(of: source)

            guard self.matchesNextCandidate(trackID: trackID, queueGeneration: queueGeneration, armGeneration: armGeneration) else { return }

            self.nextCandidate?.state = .preparing

            do {
                let session = try await self.decodingBackend.prepareSession(for: source)
                guard self.matchesNextCandidate(trackID: trackID, queueGeneration: queueGeneration, armGeneration: armGeneration) else {
                    session.close()
                    return
                }
                self.transport.installArmedNextSession(session)
                self.nextCandidate?.state = .armed
                self.nextCandidateArmTask = nil
            } catch {
                guard self.matchesNextCandidate(trackID: trackID, queueGeneration: queueGeneration, armGeneration: armGeneration) else { return }
                self.nextCandidate?.state = .warmOnly
                self.nextCandidateArmTask = nil
            }
        }
    }

    private func matchesNextCandidate(trackID: String, queueGeneration: UUID, armGeneration: UUID) -> Bool {
        guard let nextCandidate else { return false }
        return nextCandidate.trackID == trackID
            && nextCandidate.queueGeneration == queueGeneration
            && nextCandidate.armGeneration == armGeneration
    }
}
