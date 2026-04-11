import SwiftUI
import KanadeKit

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
    @ObservationIgnored private static let controlledNodeIdKey = "kanade.controlledNodeId"

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var didAttemptStartupConnect = false

    var client: KanadeClient?
    var mediaClient: MediaClient?
    var controlledNodeId: String? {
        didSet { persistControlledNodeId() }
    }
    var localPlayback: LocalPlaybackController?
    var localNodeId: String?
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

    var isControllingLocalNode: Bool {
        controlledNodeId != nil && controlledNodeId == localNodeId
    }

    var shouldShowMiniPlayer: Bool {
        effectiveCurrentTrack != nil && (isConnected || localPlayback != nil)
    }

    var effectiveQueue: [Track] {
        if isControllingLocalNode {
            return localPlayback?.queue.tracks ?? []
        }
        if let node = controlledRemoteNode, let queue = node.queue {
            return queue
        }
        return lastKnownQueue
    }

    var currentTrack: Track? {
        effectiveCurrentTrack
    }

    var effectiveCurrentIndex: Int? {
        if isControllingLocalNode {
            return localPlayback?.queue.currentIndex
        }
        if let node = controlledRemoteNode, let currentIndex = node.currentIndex {
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
        if isControllingLocalNode, let localPlayback {
            return EffectiveTransportState(
                positionSecs: localPlayback.positionSecs,
                status: localPlayback.renderer.state.status,
                volume: localPlayback.volume
            )
        }
        guard let node = controlledRemoteNode else { return nil }
        return EffectiveTransportState(
            positionSecs: node.positionSecs,
            status: node.status,
            volume: node.volume
        )
    }

    var effectiveRepeatMode: RepeatMode {
        if isControllingLocalNode {
            return localPlayback?.queue.repeatMode ?? .off
        }
        if let node = controlledRemoteNode, let repeatMode = node.repeatMode {
            return repeatMode
        }
        return lastKnownRepeatMode
    }

    var effectiveShuffleEnabled: Bool {
        if isControllingLocalNode {
            return localPlayback?.queue.shuffleEnabled ?? false
        }
        if let node = controlledRemoteNode, let shuffle = node.shuffle {
            return shuffle
        }
        return lastKnownShuffleEnabled
    }

    var effectiveDurationSecs: Double {
        if isControllingLocalNode {
            return max(localPlayback?.durationSecs ?? 0, effectiveCurrentTrack?.durationSecs ?? 0)
        }
        return effectiveCurrentTrack?.durationSecs ?? 0
    }

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
        controlledNodeId = defaults.string(forKey: Self.controlledNodeIdKey)
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
        if let localPlayback {
            localPlayback.onStateUpdate = { [weak self] queue, index, position, status, volume, repeatMode, shuffle in
                guard let self, let client = self.client else { return }
                client.localSessionUpdate(
                    queue: queue,
                    currentIndex: index,
                    positionSecs: position,
                    status: status,
                    volume: volume,
                    repeatMode: repeatMode,
                    shuffle: shuffle
                )
            }
        }
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
        if isControllingLocalNode {
            localPlayback?.play()
        } else {
            syncRemoteSelectionIfNeeded()
            client?.play()
        }
    }

    func performPause() {
        if isControllingLocalNode {
            localPlayback?.pause()
        } else {
            syncRemoteSelectionIfNeeded()
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
        if isControllingLocalNode {
            localPlayback?.seek(to: positionSecs)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.seek(to: positionSecs)
        }
    }

    func performSetVolume(_ volume: Int) {
        if isControllingLocalNode {
            localPlayback?.setVolume(volume)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.setVolume(volume)
        }
    }

    func performNext() {
        if isControllingLocalNode {
            localPlayback?.next()
        } else {
            syncRemoteSelectionIfNeeded()
            client?.next()
        }
    }

    func performPrevious() {
        if isControllingLocalNode {
            localPlayback?.previous()
        } else {
            syncRemoteSelectionIfNeeded()
            client?.previous()
        }
    }

    func performSetRepeat(_ repeatMode: RepeatMode) {
        if isControllingLocalNode {
            localPlayback?.setRepeat(repeatMode)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.setRepeat(repeatMode)
        }
    }

    func performSetShuffle(_ enabled: Bool) {
        if isControllingLocalNode {
            localPlayback?.setShuffle(enabled)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.setShuffle(enabled)
        }
    }

    func performPlayIndex(_ index: Int) {
        if isControllingLocalNode {
            localPlayback?.jumpToIndex(index)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.playIndex(index)
        }
    }

    func performReplaceAndPlay(tracks: [Track], index: Int) {
        if isControllingLocalNode {
            localPlayback?.playTracks(tracks, startIndex: index)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.replaceAndPlay(tracks: tracks, index: index)
        }
    }

    func performAddToQueue(_ track: Track) {
        performAddTracksToQueue([track])
    }

    func performAddTracksToQueue(_ tracks: [Track]) {
        if isControllingLocalNode {
            localPlayback?.addTracksToQueue(tracks)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.addTracksToQueue(tracks)
        }
    }

    func performRemoveFromQueue(_ index: Int) {
        if isControllingLocalNode {
            localPlayback?.removeFromQueue(index)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.removeFromQueue(index)
        }
    }

    func performMoveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        if isControllingLocalNode {
            localPlayback?.moveInQueue(from: sourceIndex, to: destinationIndex)
        } else {
            syncRemoteSelectionIfNeeded()
            client?.moveInQueue(from: sourceIndex, to: destinationIndex)
        }
    }

    func performClearQueue() {
        if isControllingLocalNode {
            localPlayback?.clearQueue()
        } else {
            syncRemoteSelectionIfNeeded()
            client?.clearQueue()
        }
    }

    func performSelectNode(_ nodeId: String) {
        controlledNodeId = nodeId
        client?.selectNode(nodeId)
    }

    func startLocalPlayback() {
        if localPlayback == nil {
            localPlayback = LocalPlaybackController(mediaClient: mediaClient)
        }

        localPlayback?.onStateUpdate = { [weak self] queue, index, position, status, volume, repeatMode, shuffle in
            guard let self, let client = self.client else { return }
            client.localSessionUpdate(
                queue: queue,
                currentIndex: index,
                positionSecs: position,
                status: status,
                volume: volume,
                repeatMode: repeatMode,
                shuffle: shuffle
            )
        }

        if let client {
            client.localSessionStart(deviceName: currentDeviceName)
        }
    }

    func stopLocalPlayback() {
        localPlayback?.stop()
        localPlayback = nil
        client?.localSessionStop()
        if controlledNodeId == localNodeId {
            controlledNodeId = fallbackRemoteNodeId
        }
        localNodeId = nil
    }

    func switchToLocal(tracks: [Track], index: Int, positionSecs: Double?) {
        startLocalPlayback()
        localPlayback?.importFromServer(tracks: tracks, index: index, positionSecs: positionSecs)
        controlledNodeId = localNodeId
    }

    func switchToRemote(nodeId: String) {
        if isControllingLocalNode, let localNodeId {
            client?.handoff(fromNodeId: localNodeId, toNodeId: nodeId)
        }
        controlledNodeId = nodeId
        client?.selectNode(nodeId)
    }

    private func persistConnectionSettings() {
        defaults.set(serverAddress, forKey: Self.serverAddressKey)
        defaults.set(wsPort, forKey: Self.wsPortKey)
        defaults.set(httpPort, forKey: Self.httpPortKey)
        defaults.set(autoConnectOnLaunch, forKey: Self.autoConnectKey)
    }

    private func persistControlledNodeId() {
        defaults.set(controlledNodeId, forKey: Self.controlledNodeIdKey)
    }

    private var currentDeviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "This Mac"
        #endif
    }

    private var fallbackRemoteNodeId: String? {
        if let selectedNodeId = client?.state?.selectedNodeId,
           selectedNodeId != localNodeId {
            return selectedNodeId
        }

        if let connectedNode = client?.state?.nodes.first(where: { $0.id != localNodeId && $0.connected }) {
            return connectedNode.id
        }

        return client?.state?.nodes.first(where: { $0.id != localNodeId })?.id
    }

    private var controlledRemoteNode: Node? {
        guard !isControllingLocalNode, let id = controlledNodeId else { return nil }
        return client?.state?.nodes.first(where: { $0.id == id })
    }

    private func syncRemoteSelectionIfNeeded() {
        guard !isControllingLocalNode,
              let controlledNodeId,
              controlledNodeId != client?.state?.selectedNodeId
        else { return }

        client?.selectNode(controlledNodeId)
    }

    private func refreshEffectiveFallbacks(from state: PlaybackState) {
        self.lastKnownQueue = state.queue
        self.lastKnownCurrentIndex = state.currentIndex
        self.lastKnownRepeatMode = state.repeatMode
        self.lastKnownShuffleEnabled = state.shuffle
        self.lastKnownSelectedNodeId = state.selectedNodeId

        if let controlledNodeId,
           let controlledNode = state.nodes.first(where: { $0.id == controlledNodeId }) {
            if let queue = controlledNode.queue {
                self.lastKnownQueue = queue
            }
            if let currentIndex = controlledNode.currentIndex {
                self.lastKnownCurrentIndex = currentIndex
            }
            if let repeatMode = controlledNode.repeatMode {
                self.lastKnownRepeatMode = repeatMode
            }
            if let shuffle = controlledNode.shuffle {
                self.lastKnownShuffleEnabled = shuffle
            }
            return
        }

        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = state.nodes.first(where: { $0.id == selectedNodeId }) {
            if let queue = selectedNode.queue {
                self.lastKnownQueue = queue
            }
            if let currentIndex = selectedNode.currentIndex {
                self.lastKnownCurrentIndex = currentIndex
            }
            if let repeatMode = selectedNode.repeatMode {
                self.lastKnownRepeatMode = repeatMode
            }
            if let shuffle = selectedNode.shuffle {
                self.lastKnownShuffleEnabled = shuffle
            }
        }
    }
}

extension AppState: KanadeClientDelegate {
    nonisolated func clientDidConnect(_ client: KanadeClient) {}

    nonisolated func clientDidDisconnect(_ client: KanadeClient, error: (any Error)?) {}

    nonisolated func client(_ client: KanadeClient, didUpdateState state: PlaybackState) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.refreshEffectiveFallbacks(from: state)

            if self.localNodeId == nil,
               let localNode = state.nodes.first(where: { $0.nodeType == .local && $0.name == self.currentDeviceName }) {
                self.localNodeId = localNode.id
                if self.localPlayback != nil && self.controlledNodeId == nil {
                    self.controlledNodeId = localNode.id
                }
            }

            if self.controlledNodeId == nil {
                if self.localPlayback != nil, let localNodeId = self.localNodeId {
                    self.controlledNodeId = localNodeId
                } else if let selectedNodeId = state.selectedNodeId {
                    self.controlledNodeId = selectedNodeId
                } else if let connectedNode = state.nodes.first(where: \.connected) {
                    self.controlledNodeId = connectedNode.id
                } else {
                    self.controlledNodeId = state.nodes.first?.id
                }
            }

            if let controlledNodeId = self.controlledNodeId,
               controlledNodeId != self.localNodeId,
               state.nodes.contains(where: { $0.id == controlledNodeId }),
               state.selectedNodeId != controlledNodeId {
                client.selectNode(controlledNodeId)
            }

            if let controlledNodeId = self.controlledNodeId,
               controlledNodeId != self.localNodeId,
               !state.nodes.contains(where: { $0.id == controlledNodeId }) {
                self.controlledNodeId = state.selectedNodeId
                    ?? state.nodes.first(where: \.connected)?.id
                    ?? state.nodes.first?.id
            }
        }
    }
}
