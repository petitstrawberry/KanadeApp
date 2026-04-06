import Foundation
import KanadeKit
import Observation
@preconcurrency import Starscream

final class NodeClient: @unchecked Sendable {
    var connectionChanged: (@Sendable (Bool) -> Void)?
    var errorHandler: (@Sendable (any Error) -> Void)?

    private let url: URL
    private let reconnectPolicy: ReconnectPolicy
    private let nodeNameProvider: @Sendable () -> String
    private let queue = DispatchQueue(label: "com.petitstrawberry.KanadeApp.node-client", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let audioPlayer: NodeAudioPlayer

    private var socket: WebSocket?
    private var reconnectTask: Task<Void, Never>?
    private var stateTimer: DispatchSourceTimer?
    private var retryCount: Int = 0
    private var isActive = false
    private var isRegistered = false
    private var mediaBaseURL: URL?
    private var nodeID: String?

    init(
        url: URL,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(initialDelay: 2.0, maxDelay: 10.0, base: 2.0),
        nodeNameProvider: @escaping @Sendable () -> String
    ) {
        self.url = url
        self.reconnectPolicy = reconnectPolicy
        self.nodeNameProvider = nodeNameProvider
        self.audioPlayer = NodeAudioPlayer()
        queue.setSpecific(key: queueKey, value: 1)
        audioPlayer.stateDidChange = { [weak self] in
            self?.queue.async {
                self?.sendStateUpdateIfPossible()
            }
        }
        audioPlayer.errorHandler = { [weak self] error in
            self?.errorHandler?(error)
        }
    }

    deinit {
        disconnect()
    }

    func connect() {
        queue.async { [weak self] in
            guard let self, !self.isActive else { return }
            self.isActive = true
            self.startStateTimerLocked()
            self.startConnectionLocked()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isActive = false
            self.isRegistered = false
            self.mediaBaseURL = nil
            self.retryCount = 0
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.stopStateTimerLocked()
            let socket = self.socket
            self.socket = nil
            socket?.disconnect()
            self.connectionChanged?(false)
            self.audioPlayer.stop()
        }
    }

    private func startConnectionLocked() {
        guard isActive else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let socket = WebSocket(request: request)
        socket.onEvent = { [weak self] event in
            self?.queue.async {
                self?.handleEventLocked(event)
            }
        }

        self.socket?.disconnect()
        self.socket = socket
        socket.connect()
    }

    private func handleEventLocked(_ event: WebSocketEvent) {
        switch event {
        case .connected:
            retryCount = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            isRegistered = false
            sendRegistrationLocked()

        case .text(let string):
            handleMessageDataLocked(Data(string.utf8))

        case .binary(let data):
            handleMessageDataLocked(data)

        case .disconnected:
            handleDisconnectLocked(error: nil)

        case .peerClosed:
            handleDisconnectLocked(error: nil)

        case .error(let error):
            if let error {
                errorHandler?(error)
                handleDisconnectLocked(error: error)
            }

        case .cancelled:
            handleDisconnectLocked(error: nil)

        case .pong, .ping, .viabilityChanged, .reconnectSuggested:
            break
        }
    }

    private func handleMessageDataLocked(_ data: Data) {
        do {
            if !isRegistered, let ack = try? decoder.decode(NodeRegistrationAck.self, from: data) {
                try handleRegistrationAckLocked(ack)
                return
            }

            let command = try decoder.decode(NodeCommand.self, from: data)
            handleCommandLocked(command)
        } catch {
            errorHandler?(error)
        }
    }

    private func handleRegistrationAckLocked(_ ack: NodeRegistrationAck) throws {
        nodeID = ack.nodeID
        mediaBaseURL = URL(string: ack.mediaBaseURL)
        isRegistered = true
        connectionChanged?(true)
        sendStateUpdateIfPossible()
    }

    private func handleCommandLocked(_ command: NodeCommand) {
        guard let mediaBaseURL else { return }

        switch command {
        case .play:
            audioPlayer.play()
        case .pause:
            audioPlayer.pause()
        case .stop:
            audioPlayer.stop()
        case .seek(let positionSecs):
            audioPlayer.seek(to: positionSecs)
        case .setVolume(let volume):
            audioPlayer.setVolume(volume)
        case .setQueue(let filePaths, let projectionGeneration):
            audioPlayer.setQueue(makeQueueItems(filePaths: filePaths, mediaBaseURL: mediaBaseURL), projectionGeneration: projectionGeneration)
        case .add(let filePaths):
            audioPlayer.add(makeQueueItems(filePaths: filePaths, mediaBaseURL: mediaBaseURL))
        case .remove(let index):
            audioPlayer.remove(at: index)
        case .moveTrack(let from, let to):
            audioPlayer.move(from: from, to: to)
        }
    }

    private func makeQueueItems(filePaths: [String], mediaBaseURL: URL) -> [NodeAudioPlayer.QueueItem] {
        filePaths.map { filePath in
            NodeAudioPlayer.QueueItem(trackID: filePath, url: mediaBaseURL.appending(path: "media/tracks").appending(path: filePath))
        }
    }

    private func sendRegistrationLocked() {
        let trimmedName = nodeNameProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        let registration = NodeRegistration(
            nodeID: nodeID,
            displayName: trimmedName.isEmpty ? nil : trimmedName,
            name: trimmedName.isEmpty ? nil : trimmedName
        )
        sendLocked(registration)
    }

    private func sendStateUpdateIfPossible() {
        guard isRegistered else { return }
        let snapshot = audioPlayer.snapshot()
        let update = NodeStateUpdate(
            status: snapshot.status,
            positionSecs: snapshot.positionSecs,
            volume: snapshot.volume,
            mpdSongIndex: snapshot.mpdSongIndex,
            projectionGeneration: snapshot.projectionGeneration
        )
        sendLocked(update)
    }

    private func sendLocked<T: Encodable>(_ payload: T) {
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        socket?.write(string: string)
    }

    private func handleDisconnectLocked(error: (any Error)?) {
        let hadConnection = socket != nil || isRegistered
        socket = nil
        isRegistered = false
        mediaBaseURL = nil
        if hadConnection {
            connectionChanged?(false)
        }
        guard isActive else { return }
        if let error {
            errorHandler?(error)
        }
        scheduleReconnectLocked()
    }

    private func scheduleReconnectLocked() {
        guard isActive else { return }
        let delay = reconnectPolicy.nextDelay(retryCount: retryCount)
        retryCount += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.queue.async {
                self?.startConnectionLocked()
            }
        }
    }

    private func startStateTimerLocked() {
        guard stateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.sendStateUpdateIfPossible()
        }
        stateTimer = timer
        timer.resume()
    }

    private func stopStateTimerLocked() {
        stateTimer?.cancel()
        stateTimer = nil
    }
}
