import Combine
import Foundation
import GazeCore
import Network

@MainActor
final class GazeReceiver: ObservableObject {
    enum State: Equatable {
        case starting
        case advertising(port: UInt16)
        case waiting(String)
        case failed(String)
        case stopped

        var label: String {
            switch self {
            case .starting: return "Starting receiver…"
            case .advertising(let port): return "Listening on UDP \(port)"
            case .waiting(let detail): return "Waiting: \(detail)"
            case .failed(let detail): return "Receiver error: \(detail)"
            case .stopped: return "Receiver stopped"
            }
        }

        var isReady: Bool {
            if case .advertising = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var latestSample: GazeSample?
    @Published private(set) var isFresh = false
    @Published private(set) var acceptedPacketCount = 0
    @Published private(set) var rejectedPacketCount = 0
    @Published private(set) var decodeErrorCount = 0
    @Published private(set) var lastRejection: String?

    private let queue = DispatchQueue(label: "app.eaglegaze.mac.receiver", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var gate = GazeSampleGate(maximumTransitAge: nil)
    private var freshnessTask: Task<Void, Never>?

    init() {
        start()
    }

    func start() {
        guard listener == nil else { return }
        state = .starting

        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: .any)
            listener.service = NWListener.Service(type: "_eagle-gaze._udp")
            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    self?.handleListenerState(newState)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        freshnessTask?.cancel()
        freshnessTask = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        gate.reset()
        latestSample = nil
        isFresh = false
        state = .stopped
    }

    func restart() {
        stop()
        start()
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .setup:
            state = .starting
        case .waiting(let error):
            state = .waiting(error.localizedDescription)
        case .ready:
            state = .advertising(port: listener?.port?.rawValue ?? 0)
        case .failed(let error):
            state = .failed(error.localizedDescription)
            listener?.cancel()
            listener = nil
        case .cancelled:
            if state != .stopped { state = .stopped }
        @unknown default:
            state = .waiting("unknown Network.framework state")
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let connection else { return }
            if case .failed = connectionState {
                Task { @MainActor in self?.remove(connection) }
            } else if case .cancelled = connectionState {
                Task { @MainActor in self?.remove(connection) }
            }
        }
        connection.start(queue: queue)
        receiveMessage(on: connection)
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    self.consume(data)
                }

                if error == nil {
                    self.receiveMessage(on: connection)
                } else {
                    self.remove(connection)
                    connection.cancel()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        do {
            let sample = try GazeDatagramCodec.decode(data)
            switch gate.accept(sample, receivedAtUptime: ProcessInfo.processInfo.systemUptime) {
            case .success:
                acceptedPacketCount += 1
                latestSample = sample
                markFresh(sequence: sample.sequence, sessionID: sample.sessionID)
            case .failure(let rejection):
                rejectedPacketCount += 1
                lastRejection = String(describing: rejection)
            }
        } catch {
            decodeErrorCount += 1
            lastRejection = error.localizedDescription
        }
    }

    private func markFresh(sequence: UInt64, sessionID: UUID) {
        isFresh = true
        freshnessTask?.cancel()
        freshnessTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.latestSample?.sequence == sequence,
                      self?.latestSample?.sessionID == sessionID
                else { return }
                self?.isFresh = false
            }
        }
    }
}
