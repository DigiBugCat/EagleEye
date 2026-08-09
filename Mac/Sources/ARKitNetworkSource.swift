import Foundation
import GazeCore
import Network

public enum GazeSourceIngestRejection: Error, Equatable, Sendable {
    case oversized(actual: Int, maximum: Int)
    case rateLimited
    case secureSessionRequired
    case invalidSecureEnvelope(String)
    case replayOrOutOfOrder(String)
    case invalidCanonicalPayload
    case plaintextNotAllowed
    case invalidLegacySample(String)
}

public enum GazeSourceIngestResult: Equatable, Sendable {
    case accepted(CanonicalGazeFrame)
    case rejected(GazeSourceIngestRejection)
}

/// The authenticated ARKit-over-network adapter.  Network and wire details
/// stop here; downstream code sees only CanonicalGazeFrame values.
@MainActor
public final class ARKitNetworkSource: GazeSource {
    nonisolated public static let receiverFingerprintTXTKey = "receiverFingerprint"
    nonisolated public static let maximumReceiverFingerprintBytes = 128

    #if DEBUG
    nonisolated public static let debugReceiverFingerprint = "debug-eagle-gaze"
    #else
    /// Production composition must provide the stable fingerprint from the
    /// paired-device record; an empty default intentionally cannot advertise.
    nonisolated public static let debugReceiverFingerprint = ""
    #endif

    public struct SecureSession: Sendable, Equatable {
        public let pairID: UUID
        public let sessionID: UUID
        public let sessionKey: Data
        public let noncePrefix: Data

        public init(pairID: UUID, sessionID: UUID, sessionKey: Data, noncePrefix: Data) {
            self.pairID = pairID
            self.sessionID = sessionID
            self.sessionKey = sessionKey
            self.noncePrefix = noncePrefix
        }
    }

    public struct Configuration: Sendable {
        public var port: NWEndpoint.Port
        public var maximumDatagramSize: Int
        public var maximumPacketsPerSecond: Int
        public var freshnessTimeout: TimeInterval
        public var secureSession: SecureSession?
        public var receiverFingerprint: String

        public init(
            port: NWEndpoint.Port = .any,
            maximumDatagramSize: Int = 16 * 1024,
            maximumPacketsPerSecond: Int = 240,
            freshnessTimeout: TimeInterval = 0.6,
            secureSession: SecureSession? = nil,
            receiverFingerprint: String = ARKitNetworkSource.debugReceiverFingerprint
        ) {
            self.port = port
            self.maximumDatagramSize = max(1, maximumDatagramSize)
            self.maximumPacketsPerSecond = max(1, maximumPacketsPerSecond)
            self.freshnessTimeout = min(60, max(0.05, freshnessTimeout))
            self.secureSession = secureSession
            self.receiverFingerprint = receiverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public let descriptor: GazeSourceDescriptor
    public private(set) var isRunning = false
    public private(set) var isFresh = false
    public private(set) var latestFrame: CanonicalGazeFrame?
    public private(set) var listeningPort: NWEndpoint.Port?
    public var advertisedReceiverFingerprint: String { configuration.receiverFingerprint }
    public private(set) var acceptedPacketCount = 0
    public private(set) var rejectedPacketCount = 0
    public private(set) var lastRejection: GazeSourceIngestRejection?

    /// Set only by the compatibility façade.  It is never part of the source
    /// event contract and is compiled out of release packet acceptance.
    #if DEBUG
    public var compatibilitySampleHandler: (@MainActor (GazeSample) -> Void)?
    #endif

    private var configuration: Configuration
    private var eventHandler: GazeSourceEventHandler?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "app.eaglegaze.mac.arkit-source", qos: .userInteractive)
    private var secureReceiver: SecureGazeEnvelopeReceiver?
    private var sampleGate = GazeSampleGate(maximumTransitAge: nil)
    private var freshnessTask: Task<Void, Never>?
    private var rateWindowStart: TimeInterval?
    private var packetsInRateWindow = 0

    public init(
        // Matches PhoneGazePipeline's migration default. Production pairing
        // should always pass the durable paired source ID explicitly; source
        // identity is validated on every authenticated frame.
        sourceID: GazeSourceID = "iphone-arkit",
        displayName: String = "iPhone TrueDepth",
        configuration: Configuration = Configuration()
    ) {
        descriptor = GazeSourceDescriptor(
            sourceID: sourceID,
            kind: .arkitRemote,
            displayName: displayName,
            capabilities: [.eyeTracking, .blinkDetection, .sourceCoordinates, .faceTracking]
        )
        self.configuration = configuration
        secureReceiver = Self.makeReceiver(configuration.secureSession)
    }

    public func update(secureSession: SecureSession?) {
        configuration.secureSession = secureSession
        secureReceiver = Self.makeReceiver(secureSession)
        resetTransientState()
    }

    public func start(handler: @escaping GazeSourceEventHandler) {
        eventHandler = handler
        guard listener == nil else { return }
        guard Self.isValidReceiverFingerprint(configuration.receiverFingerprint) else {
            handler(.failed("A paired receiver fingerprint is required"))
            return
        }
        isRunning = true

        do {
            let parameters = NWParameters.udp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters, on: configuration.port)
            var txtRecord = NWTXTRecord()
            txtRecord[Self.receiverFingerprintTXTKey] = configuration.receiverFingerprint
            listener.service = NWListener.Service(type: "_eagle-gaze._udp", txtRecord: txtRecord)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.handle(listenerState: state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            isRunning = false
            handler(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        let hadLifecycle = isRunning || listener != nil
        freshnessTask?.cancel()
        freshnessTask = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        listeningPort = nil
        isRunning = false
        resetTransientState()
        if hadLifecycle { eventHandler?(.stopped) }
    }

    public func resetTransientState() {
        freshnessTask?.cancel()
        freshnessTask = nil
        latestFrame = nil
        isFresh = false
        lastRejection = nil
        secureReceiver?.reset()
        sampleGate.reset()
        rateWindowStart = nil
        packetsInRateWindow = 0
    }

    /// Synchronous edge entry point used by Network.framework and pure tests.
    /// It enforces size and rate limits before attempting any JSON or crypto.
    @discardableResult
    public func ingest(
        _ datagram: Data,
        receivedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> GazeSourceIngestResult {
        guard datagram.count <= configuration.maximumDatagramSize else {
            return reject(.oversized(actual: datagram.count, maximum: configuration.maximumDatagramSize))
        }
        guard allowPacket(at: receivedAtUptime) else { return reject(.rateLimited) }

        if let session = configuration.secureSession {
            guard var receiver = secureReceiver else {
                return reject(.secureSessionRequired)
            }
            do {
                let envelope = try SecureGazeEnvelope.decode(datagram)
                let payload = try receiver.openData(envelope)
                guard let frame = try? JSONDecoder().decode(CanonicalGazeFrame.self, from: payload),
                      frame.sourceID == descriptor.sourceID,
                      frame.sourceSessionID == session.sessionID,
                      frame.sequence == envelope.sequence,
                      frame.sourceSessionID == envelope.sessionID
                else { return reject(.invalidCanonicalPayload) }
                secureReceiver = receiver
                return accept(frame)
            } catch let error as SecureGazeEnvelopeError {
                if case .replayOrOutOfOrder = error {
                    return reject(.replayOrOutOfOrder(String(describing: error)))
                }
                return reject(.invalidSecureEnvelope(String(describing: error)))
            } catch {
                return reject(.invalidSecureEnvelope(error.localizedDescription))
            }
        }

        #if DEBUG
        // Migration-only path: old GazeSample packets are decoded and
        // immediately converted to canonical data at this boundary.
        do {
            let sample = try GazeDatagramCodec.decode(datagram)
            guard let frame = ARKitGazeFeatureExtractor.extract(from: sample, sourceID: descriptor.sourceID),
                  case .success = sampleGate.accept(sample, receivedAtUptime: receivedAtUptime)
            else { return reject(.invalidLegacySample("stale, replayed, or unprojectable sample")) }
            compatibilitySampleHandler?(sample)
            return accept(frame)
        } catch {
            return reject(.invalidLegacySample(error.localizedDescription))
        }
        #else
        return reject(.plaintextNotAllowed)
        #endif
    }

    private func accept(_ frame: CanonicalGazeFrame) -> GazeSourceIngestResult {
        acceptedPacketCount += 1
        latestFrame = frame
        isFresh = true
        freshnessTask?.cancel()
        let sequence = frame.sequence
        let sessionID = frame.sourceSessionID
        freshnessTask = Task { [weak self] in
            let ns = UInt64((self?.configuration.freshnessTimeout ?? 0.6) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.latestFrame?.sequence == sequence,
                      self.latestFrame?.sourceSessionID == sessionID
                else { return }
                self.isFresh = false
                self.eventHandler?(.freshnessChanged(false))
            }
        }
        eventHandler?(.frame(frame))
        eventHandler?(.freshnessChanged(true))
        return .accepted(frame)
    }

    private func reject(_ rejection: GazeSourceIngestRejection) -> GazeSourceIngestResult {
        rejectedPacketCount += 1
        lastRejection = rejection
        eventHandler?(.rejected(String(describing: rejection)))
        return .rejected(rejection)
    }

    private func allowPacket(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        guard let start = rateWindowStart, now >= start, now - start < 1 else {
            rateWindowStart = now
            packetsInRateWindow = 1
            return true
        }
        guard packetsInRateWindow < configuration.maximumPacketsPerSecond else { return false }
        packetsInRateWindow += 1
        return true
    }

    private static func makeReceiver(_ session: SecureSession?) -> SecureGazeEnvelopeReceiver? {
        guard let session else { return nil }
        return try? SecureGazeEnvelopeReceiver(
            pairID: session.pairID,
            sessionID: session.sessionID,
            sessionKey: session.sessionKey,
            noncePrefix: session.noncePrefix
        )
    }

    private static func isValidReceiverFingerprint(_ fingerprint: String) -> Bool {
        let value = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumReceiverFingerprintBytes else { return false }
        // DNS-SD TXT values are UTF-8, but control bytes would make matching
        // ambiguous and are not valid durable pairing identity material.
        return value.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
    }

    private func handle(listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            listeningPort = listener?.port
            eventHandler?(.started)
        case .failed(let error):
            isRunning = false
            listener?.cancel()
            listener = nil
            eventHandler?(.failed(error.localizedDescription))
        case .waiting(let error):
            eventHandler?(.waiting(error.localizedDescription))
        case .cancelled:
            if isRunning { isRunning = false; eventHandler?(.stopped) }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard isRunning else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .failed = state { Task { @MainActor in self?.remove(connection) } }
            if case .cancelled = state { Task { @MainActor in self?.remove(connection) } }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            Task { @MainActor in
                if let data, !data.isEmpty { _ = self.ingest(data) }
                if error == nil { self.receive(on: connection) }
                else { self.remove(connection); connection.cancel() }
            }
        }
    }
}
