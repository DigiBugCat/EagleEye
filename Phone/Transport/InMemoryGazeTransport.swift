import Foundation

/// Deterministic fakes used by PhoneTests. These intentionally expose no
/// Network.framework types, making selection, reconnect, and latest-only
/// behavior testable on a host without a network interface.
public final class InMemoryGazeReceiverBrowser: GazeReceiverBrowser, @unchecked Sendable {
    public var stateChanged: (@Sendable (GazeBrowserState) -> Void)?
    public var receiversChanged: (@Sendable ([DiscoveredGazeReceiver]) -> Void)?
    public private(set) var isRunning = false

    public init() {}

    public func start() {
        isRunning = true
        stateChanged?(.ready)
    }

    public func stop() {
        isRunning = false
        stateChanged?(.stopped)
        receiversChanged?([])
    }

    public func emit(_ receivers: [DiscoveredGazeReceiver]) {
        receiversChanged?(receivers)
    }

    public func fail(_ detail: String) {
        stateChanged?(.failed(detail))
    }
}

public final class InMemoryGazeDatagramConnection: GazeDatagramConnection, @unchecked Sendable {
    public var stateChanged: (@Sendable (GazeConnectionState) -> Void)?
    public private(set) var sent: [Data] = []
    public private(set) var isCancelled = false
    private var completions: [(@Sendable (Error?) -> Void)] = []
    public var holdCompletions = true

    public init() {}

    public func start() {
        stateChanged?(.starting)
    }

    public func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        sent.append(data)
        completions.append(completion)
        if !holdCompletions { completeNext() }
    }

    public func completeNext(with error: Error? = nil) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(error)
    }

    public func emit(_ state: GazeConnectionState) {
        stateChanged?(state)
    }

    public func cancel() {
        isCancelled = true
        stateChanged?(.cancelled)
    }
}

public final class InMemoryGazeDatagramConnectionFactory: GazeDatagramConnectionFactory, @unchecked Sendable {
    public private(set) var endpoints: [GazeTransportEndpoint] = []
    public private(set) var connections: [InMemoryGazeDatagramConnection] = []

    public init() {}

    public func makeConnection(to endpoint: GazeTransportEndpoint) -> GazeDatagramConnection {
        endpoints.append(endpoint)
        let connection = InMemoryGazeDatagramConnection()
        connections.append(connection)
        return connection
    }
}
