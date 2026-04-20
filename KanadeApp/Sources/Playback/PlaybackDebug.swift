import Foundation

#if DEBUG
enum PlaybackDebug {
    static let lifecycleLogsEnabled = true
    static let transportLogsEnabled = false
    static let decoderLogsEnabled = false
}
#endif
