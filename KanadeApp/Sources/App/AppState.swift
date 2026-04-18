import SwiftUI
import KanadeKit
import Security

enum ControlTarget: String, Codable {
    case local
    case remote
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
    @ObservationIgnored private static let serverPortKey = "kanade.serverPort"
    @ObservationIgnored private static let autoConnectKey = "kanade.autoConnect"
    @ObservationIgnored private static let controlTargetKey = "kanade.controlTarget"
    @ObservationIgnored private static let lastRemoteNodeIdKey = "kanade.lastRemoteNodeId"
    @ObservationIgnored private static let deviceIdKey = "kanade.deviceId"
    @ObservationIgnored private static let localQueueKey = "kanade.localQueue"
    @ObservationIgnored private static let localPositionKey = "kanade.localPosition"
    @ObservationIgnored private static let localRepeatKey = "kanade.localRepeat"
    @ObservationIgnored private static let localShuffleKey = "kanade.localShuffle"
    @ObservationIgnored private static let localIndexKey = "kanade.localIndex"
    @ObservationIgnored private static let useTLSKey = "kanade.useTLS"
    @ObservationIgnored private static let allowSelfSignedKey = "kanade.allowSelfSigned"
    @ObservationIgnored private static let trustedCADataKey = "kanade.trustedCAData"

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var didAttemptStartupConnect = false
    @ObservationIgnored private var isResolvingControlledNodeId = false

    var showRemoteUnavailablePrompt = false
    var serverDiscovery = ServerDiscovery()

    var client: KanadeClient?
    var mediaClient: MediaClient?
    var controlTarget: ControlTarget {
        didSet {
            persistControlTarget()
            if controlTarget == .local {
                setResolvedControlledNodeId(localNodeId)
            }
        }
    }
    var lastRemoteNodeId: String? {
        didSet { persistLastRemoteNodeId() }
    }
    var controlledNodeId: String? {
        didSet {
            guard !isResolvingControlledNodeId, oldValue != controlledNodeId else { return }
            guard let controlledNodeId else { return }

            if controlledNodeId == localNodeId {
                controlTarget = .local
            } else {
                controlTarget = .remote
                lastRemoteNodeId = controlledNodeId
            }
        }
    }
    var localPlayback: LocalPlaybackController?
    var localNodeId: String?
    var lastKnownQueue: [Track] = []
    var lastKnownCurrentIndex: Int?
    var lastKnownRepeatMode: RepeatMode = .off
    var lastKnownShuffleEnabled = false

    var serverAddress: String {
        didSet { persistConnectionSettings() }
    }

    var serverPort: Int {
        didSet { persistConnectionSettings() }
    }

    var autoConnectOnLaunch: Bool {
        didSet { persistConnectionSettings() }
    }

    var useTLS: Bool {
        didSet { persistConnectionSettings() }
    }

    var allowSelfSignedServer: Bool {
        didSet { persistConnectionSettings() }
    }

    var clientCertificatePassword: String {
        didSet { saveToKeychain(key: "kanade.p12password", data: Data(clientCertificatePassword.utf8)) }
    }

    var hasClientCertificate: Bool {
        loadFromKeychain(key: "kanade.p12") != nil
    }

    var trustedCAData: Data? {
        didSet { persistConnectionSettings() }
    }

    var deviceId: String {
        if let existing = defaults.string(forKey: Self.deviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        defaults.set(newId, forKey: Self.deviceIdKey)
        return newId
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
        controlTarget == .local
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
        serverPort = defaults.object(forKey: Self.serverPortKey) as? Int ?? 8080
        autoConnectOnLaunch = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? true
        useTLS = defaults.object(forKey: Self.useTLSKey) as? Bool ?? false
        allowSelfSignedServer = defaults.object(forKey: Self.allowSelfSignedKey) as? Bool ?? false
        clientCertificatePassword = Self.loadFromKeychainStatic(key: "kanade.p12password").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        trustedCAData = defaults.object(forKey: Self.trustedCADataKey) as? Data
        controlTarget = defaults.string(forKey: Self.controlTargetKey).flatMap(ControlTarget.init(rawValue:)) ?? .remote
        lastRemoteNodeId = defaults.string(forKey: Self.lastRemoteNodeIdKey)
        controlledNodeId = nil

        if defaults.object(forKey: "kanade.wsPort") != nil {
            if defaults.object(forKey: Self.serverPortKey) == nil,
               let oldPort = defaults.object(forKey: "kanade.wsPort") as? Int {
                defaults.set(oldPort, forKey: Self.serverPortKey)
                serverPort = oldPort
            }
            defaults.removeObject(forKey: "kanade.wsPort")
            defaults.removeObject(forKey: "kanade.httpPort")
        }

        defaults.removeObject(forKey: "kanade.controlledNodeId")
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

        let tlsConfig: TLSConfiguration? = useTLS ? buildTLSConfiguration() : nil

        let newClient = KanadeClient(
            host: serverAddress,
            port: serverPort,
            useTLS: useTLS,
            reconnectPolicy: ReconnectPolicy(initialDelay: 2.0, maxDelay: 10.0, base: 2.0),
            tlsConfiguration: tlsConfig
        )

        newClient.delegate = self
        client = newClient
        mediaClient = MediaClient(host: serverAddress, port: serverPort, useTLS: useTLS)

        newClient.connect()
    }

    func retryConnection() {
        connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        mediaClient = nil
        localNodeId = nil
        if controlTarget == .local {
            setResolvedControlledNodeId(nil)
        }
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
        controlTarget = .remote
        lastRemoteNodeId = nodeId
        controlledNodeId = nodeId
        client?.selectNode(nodeId)
    }

    func startLocalPlayback() {
        if localPlayback == nil {
            let localPlayback = LocalPlaybackController(mediaClient: mediaClient)
            localPlayback.onStateUpdate = { [weak self] queue, index, position, status, volume, repeatMode, shuffle in
                guard let self else { return }
                self.sendLocalSessionUpdate(
                    queue: queue,
                    currentIndex: index,
                    positionSecs: position,
                    status: status,
                    volume: volume,
                    repeatMode: repeatMode,
                    shuffle: shuffle
                )
                self.saveLocalPlaybackState()
            }
            self.localPlayback = localPlayback
        }

        registerLocalSession()
    }

    func stopLocalPlayback() {
        localPlayback?.stop()
        localPlayback = nil
        client?.localSessionStop()
        localNodeId = nil
        controlTarget = .remote

        defaults.removeObject(forKey: Self.localQueueKey)
        defaults.removeObject(forKey: Self.localIndexKey)
        defaults.removeObject(forKey: Self.localPositionKey)
        defaults.removeObject(forKey: Self.localRepeatKey)
        defaults.removeObject(forKey: Self.localShuffleKey)
    }

    func switchToLocal(tracks: [Track], index: Int, positionSecs: Double?) {
        let wasPlaying = effectiveTransportState?.isPlayingLike == true
        startLocalPlayback()
        localPlayback?.importFromServer(tracks: tracks, index: index, positionSecs: positionSecs)
        controlTarget = .local
        if wasPlaying {
            localPlayback?.play()
        }
    }

    func switchToRemote(nodeId: String) {
        if let from = controlledNodeId, from != nodeId {
            client?.handoff(fromNodeId: from, toNodeId: nodeId)
        }
        controlTarget = .remote
        lastRemoteNodeId = nodeId
        controlledNodeId = nodeId
        client?.selectNode(nodeId)
    }

    func registerLocalSession() {
        guard let client, client.connected else { return }
        client.localSessionStart(deviceName: currentDeviceName, deviceId: deviceId)
    }

    func sendLocalSessionUpdate() {
        guard let localPlayback else { return }
        sendLocalSessionUpdate(
            queue: localPlayback.queue.tracks,
            currentIndex: localPlayback.queue.currentIndex,
            positionSecs: localPlayback.positionSecs,
            status: localPlayback.renderer.state.status,
            volume: localPlayback.volume,
            repeatMode: localPlayback.queue.repeatMode,
            shuffle: localPlayback.queue.shuffleEnabled
        )
    }

    func sendLocalSessionUpdate(
        queue: [Track],
        currentIndex: Int?,
        positionSecs: Double,
        status: PlaybackStatus,
        volume: Int,
        repeatMode: RepeatMode,
        shuffle: Bool
    ) {
        guard let client else { return }
        client.localSessionUpdate(
            queue: queue,
            currentIndex: currentIndex,
            positionSecs: positionSecs,
            status: status,
            volume: volume,
            repeatMode: repeatMode,
            shuffle: shuffle
        )
    }

    private func persistConnectionSettings() {
        defaults.set(serverAddress, forKey: Self.serverAddressKey)
        defaults.set(serverPort, forKey: Self.serverPortKey)
        defaults.set(autoConnectOnLaunch, forKey: Self.autoConnectKey)
        defaults.set(useTLS, forKey: Self.useTLSKey)
        defaults.set(allowSelfSignedServer, forKey: Self.allowSelfSignedKey)
        defaults.set(trustedCAData, forKey: Self.trustedCADataKey)
    }

    private func persistControlTarget() {
        defaults.set(controlTarget.rawValue, forKey: Self.controlTargetKey)
    }

    private func persistLastRemoteNodeId() {
        defaults.set(lastRemoteNodeId, forKey: Self.lastRemoteNodeIdKey)
    }

    func saveLocalPlaybackState() {
        guard let localPlayback else { return }
        let tracks = localPlayback.queue.tracks
        guard !tracks.isEmpty else { return }

        if let encoded = try? JSONEncoder().encode(tracks) {
            defaults.set(encoded, forKey: Self.localQueueKey)
        }
        defaults.set(localPlayback.queue.currentIndex, forKey: Self.localIndexKey)
        defaults.set(localPlayback.positionSecs, forKey: Self.localPositionKey)
        defaults.set(localPlayback.queue.repeatMode.rawValue, forKey: Self.localRepeatKey)
        defaults.set(localPlayback.queue.shuffleEnabled, forKey: Self.localShuffleKey)
    }

    func restoreLocalPlaybackIfNeeded() {
        guard controlTarget == .local,
              localPlayback == nil,
              mediaClient != nil,
              let data = defaults.data(forKey: Self.localQueueKey),
              let tracks = try? JSONDecoder().decode([Track].self, from: data),
              !tracks.isEmpty
        else { return }

        startLocalPlayback()

        let index = defaults.object(forKey: Self.localIndexKey) as? Int
        let position = defaults.double(forKey: Self.localPositionKey)
        localPlayback?.importFromServer(
            tracks: tracks,
            index: index ?? 0,
            positionSecs: position > 0 ? position : nil
        )

        let repeatMode = defaults.string(forKey: Self.localRepeatKey).flatMap(RepeatMode.init(rawValue:)) ?? .off
        localPlayback?.setRepeat(repeatMode)
        localPlayback?.setShuffle(defaults.bool(forKey: Self.localShuffleKey))
    }

    private var currentDeviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "This Mac"
        #endif
    }

    private var controlledRemoteNode: Node? {
        guard controlTarget == .remote, let id = controlledNodeId else { return nil }
        return client?.state?.nodes.first(where: { $0.id == id })
    }

    private var fallbackRemoteNodeId: String? {
        let excludeId = localNodeId

        if let selected = client?.state?.selectedNodeId, selected != excludeId {
            return selected
        }

        return client?.state?.nodes.first(where: { $0.id != excludeId && $0.connected })?.id
            ?? client?.state?.nodes.first(where: { $0.id != excludeId })?.id
    }

    private func setResolvedControlledNodeId(_ nodeId: String?) {
        guard controlledNodeId != nodeId else { return }
        isResolvingControlledNodeId = true
        controlledNodeId = nodeId
        isResolvingControlledNodeId = false
    }

    private func syncRemoteSelectionIfNeeded() {
        guard controlTarget == .remote,
              let controlledNodeId,
              controlledNodeId != localNodeId,
              client?.state?.nodes.contains(where: { $0.id == controlledNodeId }) == true,
              controlledNodeId != client?.state?.selectedNodeId
        else { return }

        client?.selectNode(controlledNodeId)
    }

    private func refreshEffectiveFallbacks(from state: PlaybackState) {
        lastKnownQueue = state.queue
        lastKnownCurrentIndex = state.currentIndex
        lastKnownRepeatMode = state.repeatMode
        lastKnownShuffleEnabled = state.shuffle

        if let controlledNodeId,
           let controlledNode = state.nodes.first(where: { $0.id == controlledNodeId }) {
            if let queue = controlledNode.queue {
                lastKnownQueue = queue
            }
            if let currentIndex = controlledNode.currentIndex {
                lastKnownCurrentIndex = currentIndex
            }
            if let repeatMode = controlledNode.repeatMode {
                lastKnownRepeatMode = repeatMode
            }
            if let shuffle = controlledNode.shuffle {
                lastKnownShuffleEnabled = shuffle
            }
            return
        }

        if let selectedNodeId = state.selectedNodeId,
           let selectedNode = state.nodes.first(where: { $0.id == selectedNodeId }) {
            if let queue = selectedNode.queue {
                lastKnownQueue = queue
            }
            if let currentIndex = selectedNode.currentIndex {
                lastKnownCurrentIndex = currentIndex
            }
            if let repeatMode = selectedNode.repeatMode {
                lastKnownRepeatMode = repeatMode
            }
            if let shuffle = selectedNode.shuffle {
                lastKnownShuffleEnabled = shuffle
            }
        }
    }
}

extension AppState: KanadeClientDelegate {
    nonisolated func clientDidConnect(_ client: KanadeClient) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.controlTarget == .local {
                self.restoreLocalPlaybackIfNeeded()
            }
            if self.localPlayback != nil {
                self.registerLocalSession()
            }
        }
    }

    nonisolated func clientDidDisconnect(_ client: KanadeClient, error: (any Error)?) {}

    nonisolated func client(_ client: KanadeClient, didUpdateState state: PlaybackState) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let matchedLocalNode = state.nodes.first(where: { $0.deviceId == self.deviceId })
                ?? state.nodes.first(where: { $0.nodeType == .local && $0.name == self.currentDeviceName })

            if let matchedLocalNode {
                self.localNodeId = matchedLocalNode.id
            } else if let localNodeId = self.localNodeId,
                      !state.nodes.contains(where: { $0.id == localNodeId }) {
                self.localNodeId = nil
            }

            if self.localPlayback != nil && self.localNodeId == nil {
                self.registerLocalSession()
            }

            switch self.controlTarget {
            case .local:
                if let localNodeId = self.localNodeId {
                    self.setResolvedControlledNodeId(localNodeId)
                } else {
                    self.setResolvedControlledNodeId(nil)
                }
            case .remote:
                let preferred = self.lastRemoteNodeId ?? state.selectedNodeId

                if let preferred,
                   state.nodes.contains(where: { $0.id == preferred && $0.nodeType != .local }) {
                    self.setResolvedControlledNodeId(preferred)
                    self.showRemoteUnavailablePrompt = false
                } else {
                    self.setResolvedControlledNodeId(nil)
                    self.showRemoteUnavailablePrompt = true
                }
            }

            if let controlledNodeId = self.controlledNodeId,
               controlledNodeId != self.localNodeId,
               state.nodes.contains(where: { $0.id == controlledNodeId }),
               state.selectedNodeId != controlledNodeId {
                client.selectNode(controlledNodeId)
            }

            self.refreshEffectiveFallbacks(from: state)
        }
    }

    func importClientCertificate(data: Data) {
        saveToKeychain(key: "kanade.p12", data: data)
    }

    func removeClientCertificate() {
        deleteFromKeychain(key: "kanade.p12")
        deleteFromKeychain(key: "kanade.p12password")
        clientCertificatePassword = ""
    }

    func loadClientCertificate() -> Data? {
        loadFromKeychain(key: "kanade.p12")
    }

    private static func loadFromKeychainStatic(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func saveToKeychain(key: String, data: Data) {
        deleteFromKeychain(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func buildTLSConfiguration() -> TLSConfiguration {
        var identity: SecIdentity?
        if let p12Data = loadClientCertificate() {
            identity = try? TLSConfiguration.identityFromPKCS12(data: p12Data, password: clientCertificatePassword)
        }

        var caCerts: [SecCertificate]?
        if let caData = trustedCAData, let pem = String(data: caData, encoding: .utf8) {
            caCerts = TLSConfiguration.certificatesFromPEM(pem)
        }

        return TLSConfiguration(
            clientIdentity: identity,
            trustedCACertificates: caCerts,
            allowSelfSignedServer: allowSelfSignedServer
        )
    }
}
