import Foundation
import GazeCore
#if canImport(Security)
import Security
#endif

public struct PairingControlCandidate: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    /// When Bonjour exposes a service name, this is the identity advertised by
    /// the Mac. A nil value means the transport must establish identity from
    /// the authenticated response rather than selecting by result order.
    public let serviceIdentity: String?

    public init(id: String, serviceIdentity: String? = nil) {
        self.id = id
        self.serviceIdentity = serviceIdentity
    }
}

public protocol PairingControlChannel: AnyObject {
    func send(_ frame: Data) async throws
    func receive(timeout: Duration) async throws -> Data
    func close()
}

public protocol PairingControlTransport: AnyObject {
    func browse(timeout: Duration) async throws -> [PairingControlCandidate]
    func connect(to candidate: PairingControlCandidate, timeout: Duration) async throws -> PairingControlChannel
}

public enum PairingControlClientError: Error, Equatable, Sendable {
    case noMatchingReceiver
    case ambiguousReceiver
    case timeout
    case rejected(String?)
    case invalidResponse
    case identityMismatch
    case invalidProof
    case offerExpired
    case transport(String)
}

public struct PhoneGazeSessionMaterial: Equatable, Sendable {
    public let sessionID: UUID
    public let streamKey: Data
    public let noncePrefix: Data

    public init(_ material: ReconnectSessionMaterial) {
        sessionID = material.sessionID
        streamKey = material.streamKey
        noncePrefix = material.noncePrefix
    }
}

/// Phone initiator for the authenticated TCP control plane. No pairing record
/// is persisted until the Mac's approval HMAC verifies with locally-derived
/// pairing material and all advertised identities match the scanned offer.
public final class PairingControlClient: @unchecked Sendable {
    public static let serviceType = "_eagle-gaze-pair._tcp"

    private let identityStore: PhoneDeviceIdentityStore
    private let receiverStore: PairedReceiverStore
    private let transport: PairingControlTransport
    private let clock: @Sendable () -> Date
    private let keyPairFactory: @Sendable () -> P256EphemeralKeyPair
    private let browseTimeout: Duration
    private let connectTimeout: Duration
    private let responseTimeout: Duration

    public init(
        identityStore: PhoneDeviceIdentityStore,
        receiverStore: PairedReceiverStore,
        transport: PairingControlTransport,
        clock: @escaping @Sendable () -> Date = Date.init,
        keyPairFactory: @escaping @Sendable () -> P256EphemeralKeyPair = P256EphemeralKeyPair.init,
        browseTimeout: Duration = .seconds(5),
        connectTimeout: Duration = .seconds(3),
        responseTimeout: Duration = .seconds(30)
    ) {
        self.identityStore = identityStore
        self.receiverStore = receiverStore
        self.transport = transport
        self.clock = clock
        self.keyPairFactory = keyPairFactory
        self.browseTimeout = browseTimeout
        self.connectTimeout = connectTimeout
        self.responseTimeout = responseTimeout
    }

    public func pair(qrPayload: String, displayName: String) async throws -> PairedReceiver {
        let offer = try PairingOfferParser(clock: clock).parse(qrPayload)
        return try await pair(offer: offer, displayName: displayName)
    }

    public func pair(offer: PairingOffer, displayName: String) async throws -> PairedReceiver {
        do {
            try offer.validate(at: clock())
        } catch PairingOfferError.expired {
            throw PairingControlClientError.offerExpired
        } catch {
            throw PairingControlClientError.invalidResponse
        }

        let identity = try identityStore.loadOrCreate(displayName: displayName)
        let ephemeral = keyPairFactory()
        let transcript = try PairingTranscript(
            offerID: offer.offerID,
            receiverFingerprint: offer.receiverFingerprint,
            serviceIdentity: offer.serviceIdentity,
            receiverEphemeralPublicKey: offer.ephemeralPublicKey,
            initiatorEphemeralPublicKey: ephemeral.publicKey,
            oneTimeSecret: offer.oneTimeSecret
        )
        let material = try PairingKeyAgreement.derivePairingMaterial(
            localKeyPair: ephemeral,
            peerPublicKey: offer.ephemeralPublicKey,
            transcript: transcript
        )
        let request = try PairingQRRequest(
            offer: offer,
            initiatorDeviceID: identity.deviceID,
            initiatorDisplayName: identity.displayName,
            initiatorEphemeralPublicKey: ephemeral.publicKey,
            material: material
        )
        let frame = try PairingWireProtocol.encode(PairingControlMessage.qrRequest(request))

        let candidates = try await transport.browse(timeout: browseTimeout)
            .sorted { $0.id < $1.id }
        guard !candidates.isEmpty else { throw PairingControlClientError.noMatchingReceiver }

        var approvals: [(PairingControlCandidate, PairingMacResponse)] = []
        for candidate in candidates {
            if let advertised = candidate.serviceIdentity, advertised != offer.serviceIdentity { continue }
            guard let channel = try? await transport.connect(to: candidate, timeout: connectTimeout) else { continue }
            defer { channel.close() }
            do {
                try await channel.send(frame)
                if let response = try await receiveApproval(
                    channel,
                    offerID: offer.offerID,
                    expectedVerificationCode: material.verificationCode,
                    reader: PairingControlMessageReader(channel: channel, timeout: responseTimeout)
                ) {
                    guard response.receiverFingerprint == offer.receiverFingerprint,
                          response.serviceIdentity == offer.serviceIdentity else { continue }
                    try response.verifyApproval(pairingKey: material.pairingKey)
                    approvals.append((candidate, response))
                }
            } catch PairingControlClientError.rejected {
                continue
            } catch {
                continue
            }
        }

        guard approvals.count == 1 else {
            if approvals.count > 1 { throw PairingControlClientError.ambiguousReceiver }
            throw PairingControlClientError.noMatchingReceiver
        }
        let response = approvals[0].1
        guard let pairID = response.pairID,
              let deviceID = response.deviceID,
              let receiverName = response.displayName,
              let fingerprint = response.receiverFingerprint,
              let serviceIdentity = response.serviceIdentity,
              let createdAt = response.createdAt,
              response.verificationCode == material.verificationCode,
              response.transcriptMAC == material.transcriptMAC else {
            throw PairingControlClientError.invalidResponse
        }
        let receiver = try PairedReceiver(
            pairID: pairID,
            deviceID: deviceID,
            displayName: receiverName,
            receiverFingerprint: fingerprint,
            pairingKey: material.pairingKey,
            createdAt: createdAt,
            serviceIdentity: serviceIdentity
        )
        try receiverStore.save(receiver)
        return receiver
    }

    /// Reconnects an existing pair using the caller's lifecycle session ID.
    /// The returned stream key is fresh for every call and is never persisted.
    public func reconnect(receiver: PairedReceiver, sessionID: UUID) async throws -> PhoneGazeSessionMaterial {
        let initiatorNonce = try randomNonce()
        let challenge = try ReconnectChallenge(
            pairID: receiver.pairID,
            sessionID: sessionID,
            initiatorNonce: initiatorNonce
        )
        let candidates = try await transport.browse(timeout: browseTimeout)
            .filter { candidate in
                candidate.serviceIdentity == nil || candidate.serviceIdentity == receiver.serviceIdentity
            }
            .sorted { $0.id < $1.id }
        guard !candidates.isEmpty else { throw PairingControlClientError.noMatchingReceiver }
        var successes: [ReconnectSessionMaterial] = []
        for candidate in candidates {
            guard let channel = try? await transport.connect(to: candidate, timeout: connectTimeout) else { continue }
            defer { channel.close() }
            do {
                try await channel.send(try PairingWireProtocol.encode(PairingControlMessage.reconnectChallenge(challenge)))
                let response = try await receiveReconnectResponse(
                    channel,
                    challenge: challenge,
                    reader: PairingControlMessageReader(channel: channel, timeout: responseTimeout)
                )
                try response.verify(pairingKey: receiver.pairingKey)
                let material = try ReconnectSessionDerivation.derive(
                    pairingKey: receiver.pairingKey,
                    pairID: receiver.pairID,
                    sessionID: sessionID,
                    initiatorNonce: initiatorNonce,
                    responderNonce: response.responderNonce
                )
                let confirmation = try ReconnectConfirmation(response: response, pairingKey: receiver.pairingKey)
                try await channel.send(try PairingWireProtocol.encode(PairingControlMessage.reconnectConfirmation(confirmation)))
                successes.append(material)
            } catch { continue }
        }
        guard successes.count == 1 else {
            if successes.count > 1 { throw PairingControlClientError.ambiguousReceiver }
            throw PairingControlClientError.noMatchingReceiver
        }
        return PhoneGazeSessionMaterial(successes[0])
    }

    public func establishSession(
        receiver: PairedReceiver,
        sessionID: UUID
    ) async throws -> PhoneGazeSessionMaterial {
        try await reconnect(receiver: receiver, sessionID: sessionID)
    }

    private func receiveApproval(
        _ channel: PairingControlChannel,
        offerID: UUID,
        expectedVerificationCode: String,
        reader: PairingControlMessageReader
    ) async throws -> PairingMacResponse? {
        while true {
            let message = try await reader.next()
            guard case let .macResponse(response) = message, response.offerID == offerID else {
                throw PairingControlClientError.invalidResponse
            }
            switch response.status {
            case .pending:
                if let code = response.verificationCode, code != expectedVerificationCode {
                    throw PairingControlClientError.invalidProof
                }
                continue
            case .rejected: throw PairingControlClientError.rejected(response.rejectionReason)
            case .approved: return response
            }
        }
    }

    private func receiveReconnectResponse(
        _ channel: PairingControlChannel,
        challenge: ReconnectChallenge,
        reader: PairingControlMessageReader
    ) async throws -> ReconnectResponse {
        let message = try await reader.next()
        guard case let .reconnectResponse(response) = message,
              response.pairID == challenge.pairID,
              response.sessionID == challenge.sessionID,
              response.initiatorNonce == challenge.initiatorNonce else {
            throw PairingControlClientError.invalidResponse
        }
        return response
    }

    private func randomNonce() throws -> Data {
        var nonce = Data(count: PairingWireProtocol.nonceLength)
        #if canImport(Security)
        let result = nonce.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw PairingControlClientError.invalidProof }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in nonce.indices { nonce[index] = UInt8.random(in: .min ... .max, using: &generator) }
        #endif
        return nonce
    }
}

/// Keeps framing and decoded-message leftovers for one TCP channel. A single
/// receive may contain pending + approved (or several fragmented messages),
/// so the decoder and queue must outlive each individual `next` call.
private final class PairingControlMessageReader: @unchecked Sendable {
    private let channel: PairingControlChannel
    private let timeout: Duration
    private var decoder = PairingWireFrameDecoder()
    private var pending: [PairingControlMessage] = []

    init(channel: PairingControlChannel, timeout: Duration) {
        self.channel = channel
        self.timeout = timeout
    }

    func next() async throws -> PairingControlMessage {
        if !pending.isEmpty { return pending.removeFirst() }
        while true {
            let chunk = try await channel.receive(timeout: timeout)
            for payload in try decoder.append(chunk) {
                pending.append(try PairingWireProtocol.decode(PairingControlMessage.self, payload: payload))
            }
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }
}

/// A deterministic transport fake. Tests can enqueue framed control messages
/// and inspect exactly what the client sent without a Network.framework path.
public final class InMemoryPairingControlChannel: PairingControlChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [Data] = []
    private var closed = false
    public private(set) var sent: [Data] = []
    public var onSend: (@Sendable (Data) -> Void)?

    public init() {}

    public func send(_ frame: Data) async throws {
        let hook = try recordSend(frame)
        hook?(frame)
    }

    private func recordSend(_ frame: Data) throws -> (@Sendable (Data) -> Void)? {
        lock.lock()
        if closed {
            lock.unlock()
            throw PairingControlClientError.transport("channel closed")
        }
        sent.append(frame)
        let hook = onSend
        lock.unlock()
        return hook
    }

    public func receive(timeout: Duration) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let frame = popInbound() {
                return frame
            }
            if isClosed() { throw PairingControlClientError.transport("channel closed") }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw PairingControlClientError.timeout
    }

    public func enqueue(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        inbound.append(frame)
    }

    /// Enqueues one arbitrary TCP chunk, useful for testing coalesced frames
    /// and split length-prefix/payload boundaries.
    public func enqueueRaw(_ bytes: Data) {
        enqueue(bytes)
    }

    public func enqueue<T: Encodable>(_ message: T) throws {
        enqueue(try PairingWireProtocol.encode(message))
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }

    private func popInbound() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !inbound.isEmpty else { return nil }
        return inbound.removeFirst()
    }

    private func isClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }
}

public final class InMemoryPairingControlTransport: PairingControlTransport, @unchecked Sendable {
    public var candidates: [PairingControlCandidate]
    private var channels: [String: PairingControlChannel]

    public init(candidates: [PairingControlCandidate] = [], channels: [String: PairingControlChannel] = [:]) {
        self.candidates = candidates
        self.channels = channels
    }

    public func browse(timeout: Duration) async throws -> [PairingControlCandidate] { candidates }

    public func connect(to candidate: PairingControlCandidate, timeout: Duration) async throws -> PairingControlChannel {
        guard let channel = channels[candidate.id] else {
            throw PairingControlClientError.noMatchingReceiver
        }
        return channel
    }

    public func setChannel(_ channel: PairingControlChannel, for candidate: PairingControlCandidate) {
        channels[candidate.id] = channel
    }
}
