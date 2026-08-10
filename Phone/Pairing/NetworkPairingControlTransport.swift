#if canImport(Network)
@preconcurrency import Network
import Foundation
import GazeCore
import OSLog

private final class PairingContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed(_ value: sending Value) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func fail<E: Error & Sendable>(_ error: E) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// Network.framework adapter for the pairing control plane. Endpoint values
/// remain private to this adapter; callers select by the stable candidate ID
/// and authenticated receiver identity, never by browser result order.
public final class NetworkPairingControlTransport: PairingControlTransport, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.aviary.EagleGazePhone", category: "pairing-network")
    private let queue = DispatchQueue(label: "com.aviary.eaglegaze.phone.pairing-control")
    private let lock = NSLock()
    private var endpoints: [String: NWEndpoint] = [:]

    public init() {}

    public func browse(timeout: Duration) async throws -> [PairingControlCandidate] {
        Self.logger.debug("Bonjour browse starting")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: PairingControlClient.serviceType, domain: nil),
            using: parameters
        )
        return try await withThrowingTaskGroup(of: [PairingControlCandidate].self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[PairingControlCandidate], Error>) in
                    let gate = PairingContinuationGate<[PairingControlCandidate]>()
                    gate.install(continuation)
                    browser.browseResultsChangedHandler = { [weak self] results, _ in
                        var values: [PairingControlCandidate] = []
                        self?.lock.lock()
                        for result in results {
                            let id = Self.candidateID(for: result.endpoint)
                            self?.endpoints[id] = result.endpoint
                            let name: String
                            if case let .service(serviceName, _, _, _) = result.endpoint {
                                name = serviceName
                            } else {
                                name = "Nearby Mac"
                            }
                            // Bonjour names are only user-facing routing
                            // labels. The transcript code authenticates the
                            // selected endpoint after connection.
                            values.append(PairingControlCandidate(id: id, displayName: name))
                        }
                        self?.lock.unlock()
                        browser.cancel()
                        Self.logger.debug("Bonjour browse returned count=\(values.count, privacy: .public)")
                        gate.succeed(values)
                    }
                    browser.stateUpdateHandler = { state in
                        switch state {
                        case .failed(let error):
                            Self.logger.error("Bonjour browse failed error=\(error.localizedDescription, privacy: .public)")
                            gate.fail(PairingControlClientError.transport(error.localizedDescription))
                        case .cancelled:
                            gate.fail(CancellationError())
                        default:
                            break
                        }
                    }
                    browser.start(queue: self?.queue ?? .main)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PairingControlClientError.timeout
            }
            defer { browser.cancel(); group.cancelAll() }
            return try await group.next()!
        }
    }

    public func connect(to candidate: PairingControlCandidate, timeout: Duration) async throws -> PairingControlChannel {
        Self.logger.debug("Control connection starting candidate=\(candidate.displayName, privacy: .public)")
        let endpoint = endpoint(for: candidate.id)
        guard let endpoint else { throw PairingControlClientError.noMatchingReceiver }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let gate = PairingContinuationGate<Void>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    gate.install(continuation)
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            Self.logger.debug("Control connection ready candidate=\(candidate.displayName, privacy: .public)")
                            gate.succeed(())
                        case .failed(let error):
                            Self.logger.error("Control connection failed candidate=\(candidate.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                            gate.fail(PairingControlClientError.transport(error.localizedDescription))
                        case .cancelled: gate.fail(PairingControlClientError.transport("connection cancelled"))
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PairingControlClientError.timeout
            }
            defer {
                group.cancelAll()
                gate.fail(CancellationError())
            }
            _ = try await group.next()!
        }
        return NetworkPairingControlChannel(connection: connection)
    }

    private func endpoint(for id: String) -> NWEndpoint? {
        lock.lock(); defer { lock.unlock() }
        return endpoints[id]
    }

    private static func candidateID(for endpoint: NWEndpoint) -> String {
        if case let .service(name, type, domain, _) = endpoint {
            return "\(name).\(type).\(domain)"
        }
        return String(describing: endpoint)
    }

}

public final class NetworkPairingControlChannel: PairingControlChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.aviary.eaglegaze.phone.pairing-read")

    init(connection: NWConnection) { self.connection = connection }

    public func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: PairingControlClientError.transport(error.localizedDescription)) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    public func receive(timeout: Duration) async throws -> Data {
        let gate = PairingContinuationGate<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                gate.install(continuation)
                self.connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: PairingWireProtocol.maxEncodedFrameSize + PairingWireProtocol.lengthPrefixSize,
                    completion: { data, _, isComplete, error in
                        if let error {
                            gate.fail(PairingControlClientError.transport(error.localizedDescription))
                        } else if let data, !data.isEmpty {
                            gate.succeed(data)
                        } else if isComplete {
                            gate.fail(PairingControlClientError.transport("connection closed"))
                        }
                    }
                )
                Task {
                    try? await Task.sleep(for: timeout)
                    gate.fail(PairingControlClientError.timeout)
                }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }

    public func close() { connection.cancel() }
}
#endif
