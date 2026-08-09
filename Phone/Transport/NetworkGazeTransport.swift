import Foundation
import Network

public final class NetworkGazeReceiverBrowser: GazeReceiverBrowser, @unchecked Sendable {
    public var stateChanged: (@Sendable (GazeBrowserState) -> Void)?
    public var receiversChanged: (@Sendable ([DiscoveredGazeReceiver]) -> Void)?

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public init(queue: DispatchQueue = DispatchQueue(label: "com.eaglegaze.phone.discovery")) {
        self.queue = queue
    }

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_eagle-gaze._udp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup: self.stateChanged?(.starting)
            case .ready: self.stateChanged?(.ready)
            case .failed(let error): self.stateChanged?(.failed(error.localizedDescription))
            case .cancelled: self.stateChanged?(.stopped)
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let receivers = results.compactMap(Self.receiver(from:))
            self.receiversChanged?(receivers)
        }
        self.browser = browser
        stateChanged?(.starting)
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        stateChanged?(.stopped)
        receiversChanged?([])
    }

    private static func receiver(from result: NWBrowser.Result) -> DiscoveredGazeReceiver? {
        let endpoint: GazeTransportEndpoint
        let displayName: String
        switch result.endpoint {
        case .service(let name, let type, let domain, _):
            endpoint = .bonjour(name: name, type: type, domain: domain)
            displayName = name
        case .hostPort(let host, let port):
            let hostName = String(describing: host)
            endpoint = .host(name: hostName, port: port.rawValue)
            displayName = hostName
        default:
            return nil
        }
        guard let receiverFingerprint = Self.receiverFingerprint(from: result.metadata) else {
            #if DEBUG
            // DEBUG may inspect an unverified service while bring-up is in
            // progress, but it remains unselectable by the coordinator.
            let id = GazeReceiverID(rawValue: Self.identity(for: endpoint))
            return DiscoveredGazeReceiver(
                id: id,
                displayName: displayName,
                endpoint: endpoint,
                receiverFingerprint: ""
            )
            #else
            // A service name is not an authenticated receiver identity.
            return nil
            #endif
        }
        let id = GazeReceiverID(rawValue: Self.identity(for: endpoint))
        return DiscoveredGazeReceiver(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            receiverFingerprint: receiverFingerprint
        )
    }

    private static func receiverFingerprint(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let record) = metadata,
              let value = record["receiverFingerprint"] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscoveredGazeReceiver.isValidReceiverFingerprint(trimmed) else { return nil }
        return trimmed
    }

    private static func identity(for endpoint: GazeTransportEndpoint) -> String {
        switch endpoint {
        case .bonjour(let name, let type, let domain):
            return "bonjour:\(name)|\(type)|\(domain)"
        case .host(let name, let port):
            return "host:\(name):\(port)"
        }
    }
}

public final class NetworkGazeDatagramConnection: GazeDatagramConnection, @unchecked Sendable {
    public var stateChanged: (@Sendable (GazeConnectionState) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup: self.stateChanged?(.starting)
            case .ready: self.stateChanged?(.ready)
            case .waiting(let error): self.stateChanged?(.waiting(error.localizedDescription))
            case .failed(let error): self.stateChanged?(.failed(error.localizedDescription))
            case .cancelled: self.stateChanged?(.cancelled)
            default: break
            }
        }
    }

    public func start() { connection.start(queue: queue) }

    public func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    public func cancel() { connection.cancel() }
}

public final class NetworkGazeDatagramConnectionFactory: GazeDatagramConnectionFactory, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "com.eaglegaze.phone.transport")) {
        self.queue = queue
    }

    public func makeConnection(to endpoint: GazeTransportEndpoint) -> GazeDatagramConnection {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let networkEndpoint: NWEndpoint
        switch endpoint {
        case .bonjour(let name, let type, let domain):
            networkEndpoint = .service(name: name, type: type, domain: domain, interface: nil)
        case .host(let name, let port):
            networkEndpoint = .hostPort(host: NWEndpoint.Host(name), port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        return NetworkGazeDatagramConnection(
            connection: NWConnection(to: networkEndpoint, using: parameters),
            queue: queue
        )
    }
}
