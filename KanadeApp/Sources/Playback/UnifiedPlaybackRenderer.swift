import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class UnifiedPlaybackRenderer {
    var state = RendererState()

    @ObservationIgnored var onStateChanged: ((RendererState) -> Void)?
    @ObservationIgnored var onTrackFinished: (() -> Void)?

    @ObservationIgnored private let transport: AudioTransportEngine
    @ObservationIgnored private let decodingBackend: any AudioDecodingBackend

    init() {
        let transport = AudioTransportEngine()
        self.transport = transport
        self.decodingBackend = AVAudioFileDecodingBackend(outputFormat: transport.outputFormat)

        transport.onStateChanged = { [weak self] rendererState in
            guard let self else { return }
            self.state = rendererState
            self.onStateChanged?(rendererState)
        }

        transport.onTrackFinished = { [weak self] in
            self?.onTrackFinished?()
        }

        state = transport.state
    }

    func beginLoading(durationHint: Double?, autoplay: Bool) {
        transport.markLoading(durationHint: durationHint ?? 0, autoplay: autoplay)
    }

    func loadTrack(source: any AudioDecoderSource, autoplay: Bool) async throws {
        transport.markLoading(durationHint: source.track.durationSecs ?? 0, autoplay: autoplay)
        let session = try await decodingBackend.makeSession(for: source)
        transport.replaceCurrentSession(session, autoplay: autoplay)
    }

    func play() {
        transport.play()
    }

    func pause() {
        transport.pause()
    }

    func stop() {
        transport.stop()
    }

    func seek(to positionSecs: Double) {
        transport.seek(to: positionSecs)
    }

    func setVolume(_ volume: Int) {
        transport.setVolume(volume)
    }

    func prepareNext(source: any AudioDecoderSource) async {
        await decodingBackend.prepareForPlayback(of: source)
    }
}
