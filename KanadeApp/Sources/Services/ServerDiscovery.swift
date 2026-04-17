import Foundation
import Network

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let httpPort: Int?
    let persistent: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
        lhs.id == rhs.id
    }
}

@Observable
@MainActor
final class ServerDiscovery {
    var servers: [DiscoveredServer] = []
    var isBrowsing = false

    private var browser: NWBrowser?

    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_kanade._tcp", domain: "local."),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready, .setup:
                    break
                case .failed, .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.servers = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }

                    var port = 8080
                    var httpPort: Int?
                    var advertisedHost: String?

                    if case .bonjour(let record) = result.metadata {
                        if let portStr = record["ws_port"], let p = Int(portStr) {
                            port = p
                        }
                        if let portStr = record["http_port"], let p = Int(portStr) {
                            httpPort = p
                        }
                        advertisedHost = record["host"]
                    }

                    let resolvedHost: String
                    if let advertisedHost {
                        resolvedHost = advertisedHost
                    } else {
                        resolvedHost = "\(name).local."
                    }

                    return DiscoveredServer(
                        id: name,
                        name: name,
                        host: resolvedHost,
                        port: port,
                        httpPort: httpPort,
                        persistent: advertisedHost != nil
                    )
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        servers = []
    }
}
