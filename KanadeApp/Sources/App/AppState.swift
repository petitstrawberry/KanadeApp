import SwiftUI
import KanadeKit

enum PlaybackMode {
    case remote
    case local
}

@MainActor
@Observable
final class AppState {
    struct EffectiveTransportState: Sendable {
        let positionSecs: Double
        let status: PlaybackStatus
        let volume: Int

        var isPlayingLike: Bool {
            switch status {
            case .playing, .loading:
                return true
            case .paused, .stopped:
                return false
            }
        }
    }

    struct EffectivePlaybackState: Sendable {
        let currentIndex: Int?
        let currentTrack: Track?
        let transport: EffectiveTransportState?
        let repeatMode: RepeatMode
        let shuffleEnabled: Bool
    }

    @ObservationIgnored private static let serverAddressKey = "kanade.serverAddress"
    @ObservationIgnored private static let wsPortKey = "kanade.wsPort"
    @ObservationIgnored private static let httpPortKey = "kanade.httpPort"
    @ObservationIgnored private static let autoConnectKey = "kanade.autoConnect"

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var didAttemptStartupConnect = false

    var client: KanadeClient?
    var mediaClient: MediaClient?
    var playbackMode: PlaybackMode = .remote
    var localPlayback: LocalPlaybackController?
    var lastKnownQueue: [Track] = []
    var lastKnownCurrentIndex: Int?
    var lastKnownRepeatMode: RepeatMode = .off
    var lastKnownShuffleEnabled = false
    var lastKnownSelectedNodeId: String?

    var serverAddress: String {
        didSet { persistConnectionSettings() }
    }

    var wsPort: Int {
        didSet { persistConnectionSettings() }
    }

    var httpPort: Int {
        didSet { persistConnectionSettings() }
    }

    var autoConnectOnLaunch: Bool {
        didSet { persistConnectionSettings() }
    }

    var isConnected: Bool { client?.connected ?? false }

    var isRetryingConnection: Bool {
        client != nil && !isConnected
    }

    var hasSavedConnectionSettings: Bool {
        defaults.object(forKey: Self.serverAddressKey) != nil
    }

    var connectionStatusText: String {
        if isConnected {
            return "Connected"
        }
        if isRetryingConnection {
            return "Reconnecting"
        }
        return "Disconnected"
    }

    var shouldShowMiniPlayer: Bool {
        (playbackMode == .local || isConnected) && effectiveCurrentTrack != nil
    }

    var effectiveQueue: [Track] {
        if playbackMode == .local {
            return localPlayback?.queue.tracks ?? []
        }
        if let queue = client?.state?.queue, !queue.isEmpty {
            return queue
        }
        return lastKnownQueue
    }

    var currentTrack: Track? {
        effectiveCurrentTrack
    }

    var effectiveCurrentIndex: Int? {
        if playbackMode == .local {
            return localPlayback?.queue.currentIndex
        }
        if let currentIndex = client?.state?.currentIndex {
            return currentIndex
        }
        return lastKnownCurrentIndex
    }

    var effectiveCurrentTrack: Track? {
        if let effectiveCurrentIndex,
           effectiveQueue.indices.contains(effectiveCurrentIndex) {
            return effectiveQueue[effectiveCurrentIndex]
        }
        return nil
    }

    var effectiveTransportState: EffectiveTransportState? {
        if playbackMode == .local, let localPlayback {
            return EffectiveTransportState(
                positionSecs: localPlayback.positionSecs,
                status: localPlayback.renderer.state.status,
                volume: localPlayback.volume
            )
        }
        guard let node = selectedPlaybackNode else { return nil }
        return EffectiveTransportState(
            positionSecs: node.positionSecs,
            status: node.status,
            volume: node.volume
        )
    }

    var effectiveRepeatMode: RepeatMode {
        if playbackMode == .local {
            return localPlayback?.queue.repeatMode ?? .off
        }
        if let repeatMode = client?.state?.repeatMode {
            return repeatMode
        }
        return lastKnownRepeatMode
    }

    var effectiveShuffleEnabled: Bool {
        if playbackMode == .local {
            return localPlayback?.queue.shuffleEnabled ?? false
        }
        if let shuffleEnabled = client?.state?.shuffle {
            return shuffleEnabled
        }
        return lastKnownShuffleEnabled
    }

    var localCurrentTrack: Track? { localPlayback?.currentTrack }
    var localPositionSecs: Double { localPlayback?.positionSecs ?? 0 }
    var localDurationSecs: Double { localPlayback?.durationSecs ?? 0 }
    var localIsPlaying: Bool { localPlayback?.isPlaying ?? false }
    var localVolume: Int { localPlayback?.volume ?? 0 }

    var effectivePlaybackState: EffectivePlaybackState {
        EffectivePlaybackState(
            currentIndex: effectiveCurrentIndex,
            currentTrack: effectiveCurrentTrack,
            transport: effectiveTransportState,
            repeatMode: effectiveRepeatMode,
            shuffleEnabled: effectiveShuffleEnabled
        )
    }

    @MainActor init() {
        serverAddress = defaults.string(forKey: Self.serverAddressKey) ?? "127.0.0.1"
        wsPort = defaults.object(forKey: Self.wsPortKey) as? Int ?? 8080
        httpPort = defaults.object(forKey: Self.httpPortKey) as? Int ?? 8081
        autoConnectOnLaunch = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? true
    }

    func startupConnectIfNeeded() {
        guard !didAttemptStartupConnect else { return }
        didAttemptStartupConnect = true
        guard autoConnectOnLaunch, hasSavedConnectionSettings else { return }
        connect()
    }

    func connect() {
        disconnect()
        persistConnectionSettings()
        let wsURL = URL(string: "ws://\(serverAddress):\(wsPort)")!
        let httpURL = URL(string: "http://\(serverAddress):\(httpPort)")!
        let newClient = KanadeClient(
            url: wsURL,
            reconnectPolicy: ReconnectPolicy(initialDelay: 2.0, maxDelay: 10.0, base: 2.0)
        )
        newClient.delegate = self
        client = newClient
        mediaClient = MediaClient(baseURL: httpURL)
        newClient.connect()
    }

    func retryConnection() {
        connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        mediaClient = nil
    }

    func performPlay() {
        if playbackMode == .local {
            localPlayback?.play()
        } else {
            client?.play()
        }
    }

    func performPause() {
        if playbackMode == .local {
            localPlayback?.pause()
        } else {
            client?.pause()
        }
    }

    func performTogglePlayPause() {
        if effectiveTransportState?.isPlayingLike == true {
            performPause()
        } else {
            performPlay()
        }
    }

    func performSeek(to positionSecs: Double) {
        if playbackMode == .local {
            localPlayback?.seek(to: positionSecs)
        } else {
            client?.seek(to: positionSecs)
        }
    }

    func performSetVolume(_ volume: Int) {
        if playbackMode == .local {
            localPlayback?.setVolume(volume)
        } else {
            client?.setVolume(volume)
        }
    }

    func performNext() {
        if playbackMode == .local {
            localPlayback?.next()
        } else {
            client?.next()
        }
    }

    func performPrevious() {
        if playbackMode == .local {
            localPlayback?.previous()
        } else {
            client?.previous()
        }
    }

    func performSetRepeat(_ repeatMode: RepeatMode) {
        if playbackMode == .local {
            localPlayback?.setRepeat(repeatMode)
        } else {
            client?.setRepeat(repeatMode)
        }
    }

    func performSetShuffle(_ enabled: Bool) {
        if playbackMode == .local {
            localPlayback?.setShuffle(enabled)
        } else {
            client?.setShuffle(enabled)
        }
    }

    func performPlayIndex(_ index: Int) {
        if playbackMode == .local {
            localPlayback?.jumpToIndex(index)
        } else {
            client?.playIndex(index)
        }
    }

    func performReplaceAndPlay(tracks: [Track], index: Int) {
        if playbackMode == .local {
            localPlayback?.playTracks(tracks, startIndex: index)
        } else {
            client?.replaceAndPlay(tracks: tracks, index: index)
        }
    }

    func performAddToQueue(_ track: Track) {
        performAddTracksToQueue([track])
    }

    func performAddTracksToQueue(_ tracks: [Track]) {
        if playbackMode == .local {
            localPlayback?.addTracksToQueue(tracks)
        } else {
            client?.addTracksToQueue(tracks)
        }
    }

    func performRemoveFromQueue(_ index: Int) {
        if playbackMode == .local {
            localPlayback?.removeFromQueue(index)
        } else {
            client?.removeFromQueue(index)
        }
    }

    func performMoveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        if playbackMode == .local {
            localPlayback?.moveInQueue(from: sourceIndex, to: destinationIndex)
        } else {
            client?.moveInQueue(from: sourceIndex, to: destinationIndex)
        }
    }

    func performClearQueue() {
        if playbackMode == .local {
            localPlayback?.clearQueue()
        } else {
            client?.clearQueue()
        }
    }

    func performSelectNode(_ nodeId: String) {
        client?.selectNode(nodeId)
    }

    func startLocalPlayback() {
        if localPlayback == nil {
            localPlayback = LocalPlaybackController(mediaClient: mediaClient)
        }
        playbackMode = .local
    }

    func stopLocalPlayback() {
        localPlayback?.stop()
        localPlayback = nil
        playbackMode = .remote
    }

    func switchToLocal(tracks: [Track], index: Int, positionSecs: Double?) {
        startLocalPlayback()
        localPlayback?.importFromServer(tracks: tracks, index: index, positionSecs: positionSecs)
    }

    func switchToRemote(nodeId: String?) {
        guard playbackMode == .local, let exported = localPlayback?.exportForHandoff() else {
            if let nodeId {
                client?.selectNode(nodeId)
            }
            playbackMode = .remote
            return
        }

        if !exported.tracks.isEmpty {
            client?.replaceAndPlay(tracks: exported.tracks, index: exported.index ?? 0)
            client?.seek(to: exported.positionSecs)
        }
        if let nodeId {
            client?.selectNode(nodeId)
        }
        stopLocalPlayback()
    }

    private func persistConnectionSettings() {
        defaults.set(serverAddress, forKey: Self.serverAddressKey)
        defaults.set(wsPort, forKey: Self.wsPortKey)
        defaults.set(httpPort, forKey: Self.httpPortKey)
        defaults.set(autoConnectOnLaunch, forKey: Self.autoConnectKey)
    }

    private var selectedPlaybackNode: Node? {
        guard let state = client?.state else { return nil }

        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = state.nodes.first(where: { $0.id == selectedNodeId }) {
            return selectedNode
        }

        return state.nodes.first(where: \.connected) ?? state.nodes.first
    }
}

extension AppState: KanadeClientDelegate {
    nonisolated func clientDidConnect(_ client: KanadeClient) {}

    nonisolated func clientDidDisconnect(_ client: KanadeClient, error: (any Error)?) {}

    nonisolated func client(_ client: KanadeClient, didUpdateState state: PlaybackState) {
        Task { @MainActor [weak self] in
            self?.lastKnownQueue = state.queue
            self?.lastKnownCurrentIndex = state.currentIndex
            self?.lastKnownRepeatMode = state.repeatMode
            self?.lastKnownShuffleEnabled = state.shuffle
            self?.lastKnownSelectedNodeId = state.selectedNodeId
        }
    }
}
