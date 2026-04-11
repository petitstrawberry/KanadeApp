import Foundation
import AVFoundation
import KanadeKit

public struct RendererState: Sendable, Equatable {
    public var status: PlaybackStatus
    public var positionSecs: Double
    public var durationSecs: Double
    public var volume: Int

    public init(
        status: PlaybackStatus = .stopped,
        positionSecs: Double = 0,
        durationSecs: Double = 0,
        volume: Int = 100
    ) {
        self.status = status
        self.positionSecs = positionSecs
        self.durationSecs = durationSecs
        self.volume = volume
    }
}

@MainActor
protocol AudioRenderer: AnyObject {
    var state: RendererState { get }
    var onStateChanged: ((RendererState) -> Void)? { get set }
    var onTrackAdvanced: (() -> Void)? { get set }
    var onTrackFinished: (() -> Void)? { get set }

    func loadTrack(url: URL, autoplay: Bool)
    func loadTracks(urls: [URL], startIndex: Int)
    func play()
    func pause()
    func stop()
    func seek(to positionSecs: Double)
    func setVolume(_ volume: Int)
    func advanceToNextTrack() -> Bool
    func prepareNext(url: URL)
}
