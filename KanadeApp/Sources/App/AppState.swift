import SwiftUI
import KanadeKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import Foundation
#endif

@MainActor
@Observable
final class AppState {
    struct EffectiveTransportState: Sendable {
        let positionSecs: Double
        let status: NodePlaybackStatus
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
    @ObservationIgnored private static let nodeEnabledKey = "kanade.nodeEnabled"
    @ObservationIgnored private static let nodeNameKey = "kanade.nodeName"

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var didAttemptStartupConnect = false
    @ObservationIgnored private var nodeClient: NodeClient?
    #if os(iOS) || os(macOS)
    @ObservationIgnored private var mediaSessionManager: IOSMediaSessionManager?
    #endif

    var client: KanadeClient?
    var mediaClient: MediaClient?
    var isNodeConnected = false
    var localSnapshot: NodeAudioPlayer.Snapshot?
    var lastLocalSnapshotAt: ContinuousClock.Instant?
    var lastKnownQueue: [Track] = []
    var lastKnownCurrentIndex: Int?
    var lastKnownRepeatMode: RepeatMode = .off
    var lastKnownShuffleEnabled = false
    var lastKnownSelectedNodeId: String?

    var serverAddress: String {
        didSet {
            persistConnectionSettings()
            restartNodeIfNeeded()
        }
    }

    var wsPort: Int {
        didSet {
            persistConnectionSettings()
            restartNodeIfNeeded()
        }
    }

    var httpPort: Int {
        didSet { persistConnectionSettings() }
    }

    var autoConnectOnLaunch: Bool {
        didSet { persistConnectionSettings() }
    }

    var nodeEnabled: Bool {
        didSet {
            persistConnectionSettings()
            if nodeEnabled {
                startNode()
            } else {
                stopNode()
            }
        }
    }

    var nodeName: String {
        didSet {
            persistConnectionSettings()
            restartNodeIfNeeded()
        }
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
        effectiveCurrentTrack != nil || hasFreshLocalSnapshot
    }

    var currentTrack: Track? {
        effectiveCurrentTrack
    }

    var isLocalPlaybackNode: Bool {
        if let selectedNodeId = client?.state?.selectedNodeId,
           let localNodeId = nodeClient?.nodeID {
            return selectedNodeId == localNodeId
        }
        if let selectedNodeId = lastKnownSelectedNodeId,
           let localNodeId = nodeClient?.nodeID {
            return selectedNodeId == localNodeId
        }
        return hasFreshLocalSnapshot
    }

    var effectiveCurrentIndex: Int? {
        if isLocalPlaybackNode,
           let localIndex = effectiveLocalSnapshot?.mpdSongIndex {
            return localIndex
        }
        if let currentIndex = client?.state?.currentIndex {
            return currentIndex
        }
        return lastKnownCurrentIndex
    }

    var effectiveCurrentTrack: Track? {
        if isLocalPlaybackNode,
           let currentTrackID = effectiveLocalSnapshot?.currentTrackID {
            if let track = client?.state?.queue.first(where: { $0.id == currentTrackID }) {
                return track
            }
            if let track = lastKnownQueue.first(where: { $0.id == currentTrackID }) {
                return track
            }
        }
        if let effectiveCurrentIndex,
           let state = client?.state,
           state.queue.indices.contains(effectiveCurrentIndex) {
            return state.queue[effectiveCurrentIndex]
        }
        if let effectiveCurrentIndex,
           lastKnownQueue.indices.contains(effectiveCurrentIndex) {
            return lastKnownQueue[effectiveCurrentIndex]
        }
        return nil
    }

    var effectiveTransportState: EffectiveTransportState? {
        if isLocalPlaybackNode,
           let localSnapshot = effectiveLocalSnapshot {
            return EffectiveTransportState(
                positionSecs: localSnapshot.positionSecs,
                status: localSnapshot.status,
                volume: localSnapshot.volume
            )
        }

        guard let node = selectedPlaybackNode else { return nil }
        return EffectiveTransportState(
            positionSecs: node.positionSecs,
            status: nodePlaybackStatus(for: node.status),
            volume: node.volume
        )
    }

    var effectiveRepeatMode: RepeatMode {
        if isLocalPlaybackNode,
           let localRepeatMode = effectiveLocalSnapshot?.repeatMode {
            return repeatMode(for: localRepeatMode)
        }
        if let repeatMode = client?.state?.repeatMode {
            return repeatMode
        }
        return lastKnownRepeatMode
    }

    var effectiveShuffleEnabled: Bool {
        if isLocalPlaybackNode,
           let shuffleEnabled = effectiveLocalSnapshot?.shuffleEnabled {
            return shuffleEnabled
        }
        if let shuffleEnabled = client?.state?.shuffle {
            return shuffleEnabled
        }
        return lastKnownShuffleEnabled
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
        nodeEnabled = defaults.object(forKey: Self.nodeEnabledKey) as? Bool ?? false
        nodeName = defaults.string(forKey: Self.nodeNameKey) ?? Self.defaultNodeName
        #if os(iOS) || os(macOS)
        mediaSessionManager = IOSMediaSessionManager()
        #endif
        if nodeEnabled {
            startNode()
        }
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
        updateIOSMediaSession()
        newClient.connect()
    }

    func retryConnection() {
        connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        mediaClient = nil
        updateIOSMediaSession()
    }

    func performPlay() {
        if isLocalPlaybackNode {
            nodeClient?.playLocal()
        }
        client?.play()
        invalidateMediaSnapshotAndRefresh()
    }

    func performPause() {
        if isLocalPlaybackNode {
            nodeClient?.pauseLocal()
        }
        client?.pause()
        invalidateMediaSnapshotAndRefresh()
    }

    func performSeek(to positionSecs: Double) {
        if isLocalPlaybackNode {
            nodeClient?.seekLocal(to: positionSecs)
        }
        client?.seek(to: positionSecs)
        invalidateMediaSnapshotAndRefresh()
    }

    func performSetVolume(_ volume: Int) {
        if isLocalPlaybackNode {
            nodeClient?.setVolumeLocal(volume)
        }
        client?.setVolume(volume)
    }

    func performNext() {
        if isLocalPlaybackNode {
            nodeClient?.nextLocal()
        }
        client?.next()
        invalidateMediaSnapshotAndRefresh()
    }

    func performPrevious() {
        if isLocalPlaybackNode {
            nodeClient?.previousLocal()
        }
        client?.previous()
        invalidateMediaSnapshotAndRefresh()
    }

    func performSetRepeat(_ repeatMode: RepeatMode) {
        if isLocalPlaybackNode {
            nodeClient?.setRepeatLocal(localRepeatMode(for: repeatMode))
        }
        client?.setRepeat(repeatMode)
    }

    func performSetShuffle(_ enabled: Bool) {
        if isLocalPlaybackNode {
            nodeClient?.setShuffleLocal(enabled)
        }
        client?.setShuffle(enabled)
    }

    func performPlayIndex(_ index: Int) {
        lastKnownCurrentIndex = index
        if isLocalPlaybackNode {
            nodeClient?.playIndexLocal(index)
        }
        client?.playIndex(index)
        invalidateMediaSnapshotAndRefresh()
    }

    func performReplaceAndPlay(tracks: [Track], index: Int) {
        lastKnownQueue = tracks
        lastKnownCurrentIndex = index
        if isLocalPlaybackNode {
            nodeClient?.replaceAndPlayLocal(tracks: tracks, index: index)
        }
        client?.replaceAndPlay(tracks: tracks, index: index)
        invalidateMediaSnapshotAndRefresh()
    }

    func performAddToQueue(_ track: Track) {
        performAddTracksToQueue([track])
    }

    func performAddTracksToQueue(_ tracks: [Track]) {
        if isLocalPlaybackNode {
            lastKnownQueue.append(contentsOf: tracks)
            nodeClient?.addLocal(tracks)
        }
        client?.addTracksToQueue(tracks)
        invalidateMediaSnapshotAndRefresh()
    }

    func performRemoveFromQueue(_ index: Int) {
        if lastKnownQueue.indices.contains(index) {
            lastKnownQueue.remove(at: index)
            if let lastKnownCurrentIndex {
                if lastKnownQueue.isEmpty {
                    self.lastKnownCurrentIndex = nil
                } else if index < lastKnownCurrentIndex {
                    self.lastKnownCurrentIndex = lastKnownCurrentIndex - 1
                } else if index == lastKnownCurrentIndex {
                    self.lastKnownCurrentIndex = min(lastKnownCurrentIndex, lastKnownQueue.count - 1)
                }
            }
        }
        if isLocalPlaybackNode {
            nodeClient?.removeLocal(at: index)
        }
        client?.removeFromQueue(index)
        invalidateMediaSnapshotAndRefresh()
    }

    func performMoveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        if lastKnownQueue.indices.contains(sourceIndex) {
            let boundedDestination = min(max(destinationIndex, 0), lastKnownQueue.count)
            var updatedQueue = lastKnownQueue
            let track = updatedQueue.remove(at: sourceIndex)
            let adjustedDestination = sourceIndex < boundedDestination ? boundedDestination - 1 : boundedDestination
            updatedQueue.insert(track, at: min(max(adjustedDestination, 0), updatedQueue.count))
            lastKnownQueue = updatedQueue

            if let lastKnownCurrentIndex {
                if lastKnownCurrentIndex == sourceIndex {
                    self.lastKnownCurrentIndex = min(max(adjustedDestination, 0), updatedQueue.count - 1)
                } else if sourceIndex < lastKnownCurrentIndex && adjustedDestination >= lastKnownCurrentIndex {
                    self.lastKnownCurrentIndex = lastKnownCurrentIndex - 1
                } else if sourceIndex > lastKnownCurrentIndex && adjustedDestination <= lastKnownCurrentIndex {
                    self.lastKnownCurrentIndex = lastKnownCurrentIndex + 1
                }
            }
        }

        if isLocalPlaybackNode {
            nodeClient?.moveLocal(from: sourceIndex, to: destinationIndex)
        }
        client?.moveInQueue(from: sourceIndex, to: destinationIndex)
        invalidateMediaSnapshotAndRefresh()
    }

    func performClearQueue() {
        lastKnownQueue = []
        lastKnownCurrentIndex = nil
        if isLocalPlaybackNode {
            nodeClient?.clearQueueLocal()
        }
        client?.clearQueue()
        invalidateMediaSnapshotAndRefresh()
    }

    func performSelectNode(_ nodeId: String) {
        lastKnownSelectedNodeId = nodeId
        client?.selectNode(nodeId)
        invalidateMediaSnapshotAndRefresh()
    }

    func startNode() {
        stopNode()
        guard nodeEnabled else { return }

        let wsURL = URL(string: "ws://\(serverAddress):\(wsPort)")!
        let nodeName = self.nodeName
        let client = NodeClient(url: wsURL) {
            nodeName
        }
        client.connectionChanged = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.isNodeConnected = connected
                self?.updateIOSMediaSession()
            }
        }
        client.localSnapshotDidChange = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.localSnapshot = snapshot
                self?.lastLocalSnapshotAt = ContinuousClock().now
                self?.updateIOSMediaSession()
            }
        }
        client.errorHandler = { _ in }
        client.connect()
        nodeClient = client
    }

    func stopNode() {
        nodeClient?.stopAndDisconnect()
        nodeClient = nil
        isNodeConnected = false
        localSnapshot = nil
        lastLocalSnapshotAt = nil
    }

    private func persistConnectionSettings() {
        defaults.set(serverAddress, forKey: Self.serverAddressKey)
        defaults.set(wsPort, forKey: Self.wsPortKey)
        defaults.set(httpPort, forKey: Self.httpPortKey)
        defaults.set(autoConnectOnLaunch, forKey: Self.autoConnectKey)
        defaults.set(nodeEnabled, forKey: Self.nodeEnabledKey)
        defaults.set(nodeName, forKey: Self.nodeNameKey)
    }

    private func restartNodeIfNeeded() {
        guard nodeEnabled else { return }
        startNode()
    }

    private func updateIOSMediaSession() {
        #if os(iOS) || os(macOS)
        guard let mediaSessionManager else { return }
        mediaSessionManager.performPlay = { [weak self] in
            Task { @MainActor in self?.performPlay() }
        }
        mediaSessionManager.performPause = { [weak self] in
            Task { @MainActor in self?.performPause() }
        }
        mediaSessionManager.performSeek = { [weak self] positionSecs in
            Task { @MainActor in self?.performSeek(to: positionSecs) }
        }
        mediaSessionManager.performSetVolume = { [weak self] volume in
            Task { @MainActor in self?.performSetVolume(volume) }
        }
        mediaSessionManager.performNext = { [weak self] in
            Task { @MainActor in self?.performNext() }
        }
        mediaSessionManager.performPrevious = { [weak self] in
            Task { @MainActor in self?.performPrevious() }
        }
        mediaSessionManager.update(
            client: client,
            mediaClient: mediaClient,
            state: mediaSessionPlaybackState,
            effectiveCurrentTrack: effectiveCurrentTrack,
            effectiveTransportState: effectiveTransportState,
            isLocalPlaybackNode: isLocalPlaybackNode
        )
        #endif
    }

    private var selectedPlaybackNode: Node? {
        guard let state = client?.state else { return nil }

        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = state.nodes.first(where: { $0.id == selectedNodeId }) {
            return selectedNode
        }

        return state.nodes.first(where: \.connected) ?? state.nodes.first
    }

    private var hasFreshLocalSnapshot: Bool {
        guard localSnapshot != nil,
              let lastLocalSnapshotAt,
              nodeClient?.nodeID != nil else {
            return false
        }
        return lastLocalSnapshotAt.duration(to: ContinuousClock().now) < .seconds(5)
    }

    private var effectiveLocalSnapshot: NodeAudioPlayer.Snapshot? {
        guard nodeClient?.nodeID != nil else { return nil }
        return localSnapshot
    }

    private func invalidateMediaSnapshotAndRefresh() {
        mediaSessionManager?.invalidateSnapshotCache()
        updateIOSMediaSession()
    }

    private var mediaSessionPlaybackState: PlaybackState? {
        if let state = client?.state {
            return PlaybackState(
                nodes: state.nodes,
                selectedNodeId: state.selectedNodeId,
                queue: state.queue,
                currentIndex: effectiveCurrentIndex,
                shuffle: effectiveShuffleEnabled,
                repeatMode: effectiveRepeatMode
            )
        }

        guard !lastKnownQueue.isEmpty || effectiveCurrentIndex != nil else {
            return nil
        }

        return PlaybackState(
            nodes: [],
            selectedNodeId: lastKnownSelectedNodeId ?? nodeClient?.nodeID,
            queue: lastKnownQueue,
            currentIndex: effectiveCurrentIndex,
            shuffle: effectiveShuffleEnabled,
            repeatMode: effectiveRepeatMode
        )
    }

    private func repeatMode(for localRepeatMode: NodeAudioPlayer.LocalRepeatMode) -> RepeatMode {
        switch localRepeatMode {
        case .off:
            return .off
        case .one:
            return .one
        case .all:
            return .all
        }
    }

    private func localRepeatMode(for repeatMode: RepeatMode) -> NodeAudioPlayer.LocalRepeatMode {
        switch repeatMode {
        case .off:
            return .off
        case .one:
            return .one
        case .all:
            return .all
        }
    }

    private func nodePlaybackStatus(for playbackStatus: PlaybackStatus) -> NodePlaybackStatus {
        switch playbackStatus {
        case .stopped:
            return .stopped
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .loading:
            return .loading
        }
    }

    private static var defaultNodeName: String {
        #if os(iOS)
        UIDevice.current.name
        #elseif os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}

extension AppState: KanadeClientDelegate {
    nonisolated func clientDidConnect(_ client: KanadeClient) {
        Task { @MainActor [weak self] in
            self?.updateIOSMediaSession()
        }
    }

    nonisolated func clientDidDisconnect(_ client: KanadeClient, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.updateIOSMediaSession()
        }
    }

    nonisolated func client(_ client: KanadeClient, didUpdateState state: PlaybackState) {
        Task { @MainActor [weak self] in
            self?.lastKnownQueue = state.queue
            self?.lastKnownCurrentIndex = state.currentIndex
            self?.lastKnownRepeatMode = state.repeatMode
            self?.lastKnownShuffleEnabled = state.shuffle
            self?.lastKnownSelectedNodeId = state.selectedNodeId
            self?.updateIOSMediaSession()
        }
    }
}
