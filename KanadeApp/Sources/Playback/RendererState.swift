import Foundation
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
