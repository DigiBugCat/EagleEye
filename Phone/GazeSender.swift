import Foundation
import GazeCore
import Network

@MainActor
final class GazeSender: ObservableObject {
    @Published private(set) var status = "Looking for a Mac receiver…"
    @Published private(set) var isConnected = false

    private let networkQueue = DispatchQueue(label: "com.eaglegaze.phone.network")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var latestEndpoint: NWEndpoint?
    private var reconnectTask: Task<Void, Never>?

    // Main-actor state. At most one datagram is in flight and one
    // newer datagram is retained, so slow networking cannot build a gaze queue.
    private var pendingLatest: Data?
    private var sendInFlight = false

    func start() {
        guard browser == nil else { return }

        status = "Looking for a Mac receiver…"
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: "_eagle-gaze._udp", domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = self.connection == nil
                        ? "Looking for a Mac receiver…"
                        : self.status
                case .failed(let error):
                    self.status = "Receiver discovery failed: \(error.localizedDescription)"
                    self.browser?.cancel()
                    self.browser = nil
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.latestEndpoint = results.first?.endpoint
                if let endpoint = self.latestEndpoint {
                    self.connectIfNeeded(to: endpoint)
                }
            }
        }
        browser.start(queue: networkQueue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        latestEndpoint = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isConnected = false
        status = "Network streaming is paused"
        pendingLatest = nil
        sendInFlight = false
    }

    func sendLatest(_ sample: GazeSample) {
        guard let data = try? GazeDatagramCodec.encode(sample) else {
            status = "Could not encode a gaze sample"
            return
        }

        pendingLatest = data
        drainLatest()
    }

    private func connectIfNeeded(to endpoint: NWEndpoint) {
        guard connection == nil else { return }

        status = "Connecting to the Mac receiver…"
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.isConnected = true
                    self.status = "Streaming gaze to Mac"
                case .waiting(let error):
                    self.isConnected = false
                    self.status = "Waiting for Mac: \(error.localizedDescription)"
                case .failed(let error):
                    self.isConnected = false
                    self.status = "Mac connection failed: \(error.localizedDescription)"
                    self.connection = nil
                    connection.cancel()
                    self.scheduleReconnect()
                case .cancelled:
                    self.isConnected = false
                    if self.connection === connection {
                        self.connection = nil
                        self.status = "Looking for a Mac receiver…"
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: networkQueue)
    }

    private func scheduleReconnect() {
        guard browser != nil, latestEndpoint != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let endpoint = self.latestEndpoint else { return }
            self.connectIfNeeded(to: endpoint)
        }
    }

    private func drainLatest() {
        guard !sendInFlight,
              isConnected,
              let connection,
              let data = pendingLatest else { return }
        pendingLatest = nil
        sendInFlight = true

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.sendInFlight = false
                if let error {
                    self.status = "Gaze send failed: \(error.localizedDescription)"
                }
                self.drainLatest()
            }
        })
    }
}
