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
        guard let state = client?.state,
              let currentIndex = state.currentIndex,
              state.queue.indices.contains(currentIndex),
              !state.queue.isEmpty else {
            return false
        }

        return true
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
            }
        }
        client.errorHandler = { _ in }
        client.connect()
        nodeClient = client
    }

    func stopNode() {
        nodeClient?.disconnect()
        nodeClient = nil
        isNodeConnected = false
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
        let client = client
        let mediaClient = mediaClient
        let state = client?.state
        Task { @MainActor [weak self] in
            self?.mediaSessionManager?.update(client: client, mediaClient: mediaClient, state: state)
        }
        #endif
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
            self?.updateIOSMediaSession()
        }
    }
}
