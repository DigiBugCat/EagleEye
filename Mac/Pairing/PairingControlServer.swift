import Foundation
import GazeCore
import Network

/// Authenticated reconnect result handed to the Mac source composition root.
/// The source identifier is stable for a paired phone across reconnect
/// sessions and does not contain an IP address or any raw gaze data.  Session
/// identity belongs in `sessionID`/`sourceSessionID` on each gaze frame.
public struct PairingAuthenticatedSession: Sendable {
    public let pairID: UUID
    public let deviceID: UUID
    public let sessionID: UUID
    public let sourceID: GazeSourceID
    public let displayName: String
    public let receiverFingerprint: String
    public let material: ReconnectSessionMaterial

    public var descriptor: GazeSourceDescriptor {
        GazeSourceDescriptor(
            sourceID: sourceID,
            kind: .arkitRemote,
            displayName: displayName,
            capabilities: [.eyeTracking, .blinkDetection, .sourceCoordinates, .faceTracking]
        )
    }
}

public enum PairingControlServerError: Error, Equatable, Sendable {
    case notAttached
    case alreadyAdvertising
    case notAdvertising
    case connectionTimedOut
    case pendingConfirmationNotFound
    case reconnectNotFound
    case activeSessionExists
    case protocolViolation
}

/// Small transport harness for MacTests and previews.  It exercises the same
/// length-framed/tagged codec as Network.framework without opening a socket.
public struct PairingControlFrameHarness: Sendable {
    private var decoder = PairingWireFrameDecoder()
    public private(set) var sentFrames: [Data] = []

    public init() {}

    @discardableResult
    public mutating func encode(_ message: PairingControlMessage) throws -> Data {
        let frame = try PairingWireProtocol.encode(message)
        sentFrames.append(frame)
        return frame
    }

    public mutating func receive(_ bytes: Data) throws -> [PairingControlMessage] {
        try decoder.append(bytes).map {
            try PairingWireProtocol.decode(PairingControlMessage.self, payload: $0)
        }
    }

    /// Encodes several messages into one coalesced TCP read and decodes them
    /// in wire order.  This is used by MacTests to exercise challenge then
    /// confirmation sequencing without Network.framework.
    public static func coalescedRoundTrip(_ messages: [PairingControlMessage]) throws -> [PairingControlMessage] {
        var harness = Self()
        var bytes = Data()
        for message in messages { bytes.append(try harness.encode(message)) }
        return try harness.receive(bytes)
    }

    public mutating func reset() {
        decoder.reset()
        sentFrames.removeAll(keepingCapacity: false)
    }
}

/// A bounded Network.framework control plane for pairing and authenticated
/// reconnect.  The server never accepts gaze payloads: after reconnect proofs
/// succeed it emits a session callback, and the composition root may then
/// attach the returned stream material to its UDP source.
public final class PairingControlServer: PairingAdvertisementService, @unchecked Sendable {
    public static let serviceType = "_eagle-gaze-pair._tcp"
    public static let defaultTimeout: TimeInterval = 15

    public typealias SessionReadyHandler = @Sendable (PairingAuthenticatedSession) -> Void
    public typealias SessionEndedHandler = @Sendable (UUID) -> Void

    public static func sourceID(for deviceID: UUID) -> GazeSourceID {
        GazeSourceID(deviceID.uuidString.lowercased())
    }

    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let serviceIdentity: String
    private let lock = NSLock()
    private weak var pairingService: PairingService?
    private let sessionReady: SessionReadyHandler?
    private let sessionEnded: SessionEndedHandler?
    private var listener: NWListener?
    private var advertising = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var decoders: [ObjectIdentifier: PairingWireFrameDecoder] = [:]
    private var timers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var timerGenerations: [ObjectIdentifier: UInt64] = [:]
    private var messageTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var pairings: [UUID: PendingPairingConnection] = [:]
    private var reconnects: [ObjectIdentifier: PairingReconnectContext] = [:]
    private var sessionByConnection: [ObjectIdentifier: UUID] = [:]
    private var activeSessionID: UUID?
    private var activePairID: UUID?
    private var activeDeviceID: UUID?

    private struct PendingPairingConnection {
        let connection: NWConnection
        let request: PairingQRRequest
        let confirmation: PendingPairingConfirmation
    }

    public init(
        pairingService: PairingService? = nil,
        serviceIdentity: String = "EagleGaze Mac",
        queue: DispatchQueue = DispatchQueue(label: "app.eaglegaze.mac.pairing-control"),
        timeout: TimeInterval = PairingControlServer.defaultTimeout,
        onSessionReady: SessionReadyHandler? = nil,
        onSessionEnded: SessionEndedHandler? = nil
    ) {
        self.pairingService = pairingService
        self.serviceIdentity = serviceIdentity
        self.queue = queue
        self.timeout = max(1, timeout)
        self.sessionReady = onSessionReady
        self.sessionEnded = onSessionEnded
    }

    public func attach(_ pairingService: PairingService) {
        lock.lock()
        self.pairingService = pairingService
        lock.unlock()
    }

    public var isAdvertising: Bool {
        lock.lock()
        defer { lock.unlock() }
        return advertising
    }

    public var currentActiveSessionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return activeSessionID
    }

    public func start(offer: PairingOffer) throws {
        try startListener(serviceName: offer.serviceIdentity)
    }

    /// Starts the long-lived control listener before a QR offer is shown.
    /// PairingService can then call `start(offer:)` repeatedly without tearing
    /// down reconnect availability after an offer is approved or expires.
    public func start() throws {
        try startListener(serviceName: serviceIdentity)
    }

    private func startListener(serviceName: String) throws {
        lock.lock()
        if advertising {
            let boundedName = String(serviceName.prefix(63))
            listener?.service = NWListener.Service(name: boundedName, type: Self.serviceType, domain: nil, txtRecord: nil)
            lock.unlock()
            return
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: .any)
        } catch {
            throw PairingControlServerError.notAdvertising
        }
        // Keep the Bonjour instance name equal to serviceIdentity: the phone
        // browser uses this stable nonsecret value to select the endpoint.
        // Receiver fingerprint and all offer material remain QR/transcript
        // fields, never TXT metadata.
        let boundedName = String(serviceName.prefix(63))
        newListener.service = NWListener.Service(name: boundedName, type: Self.serviceType, domain: nil, txtRecord: nil)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { self.stop() }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        lock.lock()
        listener = newListener
        advertising = true
        lock.unlock()
        newListener.start(queue: queue)
    }

    /// A QR offer is no longer visible, but the control listener remains
    /// advertised so already-paired phones can reconnect.
    public func stopOffer() {}

    public func stop() {
        lock.lock()
        let oldListener = listener
        listener = nil
        advertising = false
        let oldConnections = Array(connections.values)
        connections.removeAll()
        decoders.removeAll()
        messageTasks.values.forEach { $0.cancel() }
        messageTasks.removeAll()
        timerGenerations.removeAll()
        pairings.removeAll()
        reconnects.removeAll()
        sessionByConnection.removeAll()
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        let oldActive = activeSessionID
        activeSessionID = nil
        activePairID = nil
        activeDeviceID = nil
        lock.unlock()

        oldListener?.cancel()
        oldConnections.forEach { $0.cancel() }
        if let oldActive { sessionEnded?(oldActive) }
    }

    /// Explicitly ends the one active source/session, allowing a different
    /// remembered phone to reconnect and become active.
    public func deactivateActiveSession() {
        lock.lock()
        let old = activeSessionID
        activeSessionID = nil
        activePairID = nil
        activeDeviceID = nil
        lock.unlock()
        if let old { sessionEnded?(old) }
    }

    /// Approves a pending request after the UI has shown the verification code.
    /// The pairing key is used only to MAC the response and is never encoded.
    public func approve(confirmationID: UUID) async throws -> PairedDeviceRecord {
        guard let service = pairingService else { throw PairingControlServerError.notAttached }
        guard let pending = pendingConnection(confirmationID: confirmationID) else {
            throw PairingControlServerError.pendingConfirmationNotFound
        }

        let record = try await service.confirmPairing(confirmationID: confirmationID)
        let response = try PairingMacResponse.approved(
            offerID: pending.request.offerID,
            pairID: record.pairID,
            deviceID: record.deviceID,
            // This response is consumed by the phone, so its peer label is
            // the Mac's configured identity.  The Mac record keeps the
            // phone's initiator display name separately.
            displayName: serviceIdentity,
            receiverFingerprint: record.receiverFingerprint,
            serviceIdentity: pending.request.serviceIdentity,
            createdAt: record.createdAt,
            verificationCode: pending.request.verificationCode,
            transcriptMAC: pending.request.transcriptMAC,
            pairingKey: record.pairingKey
        )
        try send(.macResponse(response), on: pending.connection)
        removeConnection(pending.connection)
        return record
    }

    public func reject(confirmationID: UUID, reason: String? = nil) async throws {
        guard let service = pairingService else { throw PairingControlServerError.notAttached }
        guard let pending = pendingConnection(confirmationID: confirmationID) else {
            throw PairingControlServerError.pendingConfirmationNotFound
        }
        try await service.rejectPairing(confirmationID: confirmationID)
        let response = try PairingMacResponse.rejected(offerID: pending.request.offerID, reason: reason)
        try send(.macResponse(response), on: pending.connection)
        removeConnection(pending.connection)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        connections[id] = connection
        decoders[id] = PairingWireFrameDecoder()
        lock.unlock()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.removeConnection(connection) }
            if case .cancelled = state { self.removeConnection(connection) }
        }
        connection.start(queue: queue)
        receive(on: connection)
        scheduleTimeout(for: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: PairingWireProtocol.maxEncodedFrameSize + PairingWireProtocol.lengthPrefixSize
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                self.handle(data: data, on: connection)
            }
            if error == nil && !isComplete {
                self.receive(on: connection)
            } else {
                self.removeConnection(connection)
            }
        }
    }

    private func handle(data: Data, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        var decoder = decoders[id] ?? PairingWireFrameDecoder()
        let frames: [Data]
        do {
            frames = try decoder.append(data)
            decoders[id] = decoder
            timers[id]?.cancel()
            timers[id] = nil
        } catch {
            lock.unlock()
            removeConnection(connection)
            return
        }
        lock.unlock()

        guard !frames.isEmpty else {
            scheduleTimeout(for: connection)
            return
        }
        // A single TCP read may contain challenge + confirmation.  Chain one
        // MainActor task per connection so coalesced frames and successive
        // receive callbacks cannot race or reorder protocol state.
        lock.lock()
        let previous = messageTasks[id]
        let next = Task { @MainActor [weak self, weak connection] in
            if let previous { await previous.value }
            guard let self, let connection else { return }
            for payload in frames {
                guard !Task.isCancelled else { return }
                self.handle(payload: payload, on: connection)
            }
        }
        messageTasks[id] = next
        lock.unlock()
    }

    @MainActor
    private func handle(payload: Data, on connection: NWConnection) {
        do {
            let message = try PairingWireProtocol.decode(PairingControlMessage.self, payload: payload)
            switch message {
            case .qrRequest(let request): try handle(request: request, on: connection)
            case .reconnectChallenge(let challenge): try handle(challenge: challenge, on: connection)
            case .reconnectConfirmation(let confirmation): try handle(confirmation: confirmation, on: connection)
            case .macResponse, .reconnectResponse:
                throw PairingControlServerError.protocolViolation
            }
        } catch {
            removeConnection(connection)
        }
    }

    @MainActor
    private func handle(request: PairingQRRequest, on connection: NWConnection) throws {
        guard let service = pairingService else { throw PairingControlServerError.notAttached }
        let confirmation = try service.beginPairing(request)
        let response = try PairingMacResponse.pending(
            offerID: request.offerID,
            verificationCode: confirmation.verificationCode
        )
        lock.lock()
        pairings[confirmation.confirmationID] = PendingPairingConnection(
            connection: connection,
            request: request,
            confirmation: confirmation
        )
        lock.unlock()
        try send(.macResponse(response), on: connection)
        scheduleTimeout(for: connection, interval: confirmation.expiresAt.timeIntervalSinceNow)
    }

    @MainActor
    private func handle(challenge: ReconnectChallenge, on connection: NWConnection) throws {
        guard let service = pairingService else { throw PairingControlServerError.notAttached }
        let context = try service.prepareReconnect(challenge)
        lock.lock()
        guard activePairID == nil || activePairID == context.record.pairID else {
            lock.unlock()
            throw PairingControlServerError.activeSessionExists
        }
        reconnects[ObjectIdentifier(connection)] = context
        lock.unlock()
        try send(.reconnectResponse(context.response), on: connection)
        scheduleTimeout(for: connection)
    }

    @MainActor
    private func handle(confirmation: ReconnectConfirmation, on connection: NWConnection) throws {
        let id = ObjectIdentifier(connection)
        lock.lock()
        guard let context = reconnects[id] else {
            lock.unlock()
            throw PairingControlServerError.reconnectNotFound
        }
        guard activePairID == nil || activePairID == context.record.pairID else {
            lock.unlock()
            throw PairingControlServerError.activeSessionExists
        }
        lock.unlock()
        guard let service = pairingService else { throw PairingControlServerError.notAttached }
        let material = try service.completeReconnect(context, confirmation: confirmation)
        let sourceID = Self.sourceID(for: context.record.deviceID)
        let authenticated = PairingAuthenticatedSession(
            pairID: context.record.pairID,
            deviceID: context.record.deviceID,
            sessionID: confirmation.sessionID,
            sourceID: sourceID,
            displayName: context.record.displayName,
            receiverFingerprint: context.record.receiverFingerprint,
            material: material
        )
        lock.lock()
        let previousSession = activeSessionID
        activeSessionID = confirmation.sessionID
        activePairID = context.record.pairID
        activeDeviceID = context.record.deviceID
        sessionByConnection[id] = confirmation.sessionID
        reconnects.removeValue(forKey: id)
        lock.unlock()
        if let previousSession, previousSession != confirmation.sessionID {
            sessionEnded?(previousSession)
        }
        sessionReady?(authenticated)
        // Control TCP is complete; the authenticated UDP session remains
        // active until composition explicitly deactivates it.
        lock.lock()
        sessionByConnection.removeValue(forKey: id)
        lock.unlock()
        removeConnection(connection)
    }

    private func send(_ message: PairingControlMessage, on connection: NWConnection) throws {
        let frame = try PairingWireProtocol.encode(message)
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            if error != nil, let self, let connection { self.removeConnection(connection) }
        })
    }

    private func scheduleTimeout(for connection: NWConnection, interval: TimeInterval? = nil) {
        let id = ObjectIdentifier(connection)
        let duration = max(1, interval ?? timeout)
        lock.lock()
        let generation = (timerGenerations[id] ?? 0) &+ 1
        timerGenerations[id] = generation
        timers[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.lock()
            let isCurrent = self.timerGenerations[id] == generation
            self.lock.unlock()
            guard isCurrent else { return }
            self.removeConnection(connection)
        }
        timers[id] = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func pendingConnection(confirmationID: UUID) -> PendingPairingConnection? {
        lock.lock()
        defer { lock.unlock() }
        return pairings[confirmationID]
    }

    private func removeConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        let endedSession = sessionByConnection[id]
        let wasActive = endedSession != nil && endedSession == activeSessionID
        connections.removeValue(forKey: id)
        decoders.removeValue(forKey: id)
        messageTasks.removeValue(forKey: id)?.cancel()
        reconnects.removeValue(forKey: id)
        sessionByConnection.removeValue(forKey: id)
        pairings = pairings.filter { $0.value.connection !== connection }
        timers.removeValue(forKey: id)?.cancel()
        timerGenerations.removeValue(forKey: id)
        if wasActive {
            activeSessionID = nil
            activePairID = nil
            activeDeviceID = nil
        }
        lock.unlock()
        connection.cancel()
        if let endedSession { sessionEnded?(endedSession) }
    }
}
