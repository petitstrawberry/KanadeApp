import SwiftUI
import KanadeKit

@Observable
final class AppState {
    var client: KanadeClient?
    var mediaClient: MediaClient?

    var serverAddress = "127.0.0.1"
    var wsPort: Int = 8080
    var httpPort: Int = 8081

    var isConnected: Bool { client?.connected ?? false }

    func connect() {
        disconnect()
        let wsURL = URL(string: "ws://\(serverAddress):\(wsPort)")!
        let httpURL = URL(string: "http://\(serverAddress):\(httpPort)")!
        let newClient = KanadeClient(url: wsURL)
        newClient.connect()
        client = newClient
        mediaClient = MediaClient(baseURL: httpURL)
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        mediaClient = nil
    }
}
