import CryptoKit
import Foundation
import GazeCore

public enum PairingServiceError: Error, Equatable, Sendable {
    case invalidOfferLifetime
    case noActiveOffer
    case offerExpired
    case offerAlreadyAwaitingConfirmation
    case offerMismatch
    case invalidRequest
    case authenticationFailed
    case verificationCodeMismatch
    case pendingPairingNotFound
    case pairNotFound
    case revokedPair
    case sessionAlreadyActive
    case advertisementFailed
    case reconnectNotFound
    case reconnectMismatch
}

/// The value encoded in a QR code.  It contains only the short-lived
/// `GazeCore.PairingOffer`; no address, stream key, or gaze data is encoded.
public enum PairingQRCodec {
    public static let prefix = "eagle-gaze-pair:v1:"

    public static func encode(_ offer: PairingOffer) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(offer)
        return prefix + payload.base64URLEncodedString()
    }

    public static func decode(_ value: String, now: Date = Date()) throws -> PairingOffer {
        guard value.hasPrefix(prefix) else { throw PairingServiceError.offerMismatch }
        let encoded = String(value.dropFirst(prefix.count))
        guard encoded.count <= 16_384, let data = Data(base64URLString: encoded) else {
            throw PairingServiceError.offerMismatch
        }
        do {
            let offer = try JSONDecoder().decode(PairingOffer.self, from: data)
            try offer.validate(at: now)
            return offer
        } catch let error as PairingOfferError {
            throw error
        } catch {
            throw PairingServiceError.offerMismatch
        }
    }
}

public struct PairingOfferPresentation: Equatable, Sendable {
    public let offer: PairingOffer
    public let qrString: String

    public init(offer: PairingOffer, qrString: String) {
        self.offer = offer
        self.qrString = qrString
    }
}

/// Data sent by the phone after scanning the QR and completing its side of
/// the P-256 transcript.  The Mac still requires explicit user confirmation
/// before this request becomes durable.
public struct PairingRequest: Equatable, Sendable {
    public let offerID: UUID
    public let deviceID: UUID
    public let displayName: String
    public let initiatorEphemeralPublicKey: Data
    public let verificationCode: String
    public let transcriptMAC: Data

    public init(
        offerID: UUID,
        deviceID: UUID,
        displayName: String,
        initiatorEphemeralPublicKey: Data,
        verificationCode: String,
        transcriptMAC: Data
    ) {
        self.offerID = offerID
        self.deviceID = deviceID
        self.displayName = displayName
        self.initiatorEphemeralPublicKey = initiatorEphemeralPublicKey
        self.verificationCode = verificationCode
        self.transcriptMAC = transcriptMAC
    }
}

/// A reconnect context is intentionally internal: it keeps the pairing key
/// inside the Mac module while the control server performs the wire exchange.
struct PairingReconnectContext: Sendable {
    let record: PairedDeviceRecord
    let challenge: ReconnectChallenge
    let response: ReconnectResponse
}

public typealias PairingHandshake = PairingRequest

/// Safe-to-display pending state.  Pairing keys and ephemeral private keys are
/// intentionally not exposed through this value.
public struct PendingPairingConfirmation: Equatable, Sendable {
    public let confirmationID: UUID
    public let pairID: UUID
    public let offerID: UUID
    public let deviceID: UUID
    public let displayName: String
    public let verificationCode: String
    public let createdAt: Date
    public let expiresAt: Date
}

public enum PairingServiceState: Equatable, Sendable {
    case idle
    case offerVisible(PairingOfferPresentation)
    case awaitingConfirmation(PendingPairingConfirmation)
    case paired(PairedDeviceRecord)
}

/// Mac-side pairing boundary.  This class is main-actor isolated so UI can
/// render explicit approval state without exposing cryptographic material.
@MainActor
public final class PairingService {
    public typealias StateChangeHandler = @MainActor @Sendable (PairingServiceState) -> Void
    public private(set) var state: PairingServiceState = .idle
    private var stateChangeHandler: StateChangeHandler?

    /// Stable, nonsecret identity used to match a scanned offer to this Mac.
    public var receiverFingerprintValue: String { receiverFingerprint }

    public var currentOffer: PairingOfferPresentation? {
        guard case .offerVisible(let presentation) = state else { return nil }
        return presentation
    }

    public var pendingConfirmation: PendingPairingConfirmation? {
        guard case .awaitingConfirmation(let confirmation) = state else { return nil }
        return confirmation
    }

    private let receiverFingerprint: String
    private let serviceIdentity: String
    private let store: any PairedDeviceStore
    private let advertisement: (any PairingAdvertisementService)?
    private let now: @Sendable () -> Date
    private var activeOffer: PairingOffer?
    private var receiverEphemeralKey: P256EphemeralKeyPair?
    private var pending: PendingMaterial?
    private var activeSessions: [UUID: Set<UUID>] = [:]

    private struct PendingMaterial {
        let confirmation: PendingPairingConfirmation
        let material: PairingMaterial
        let receiverEphemeralKey: P256EphemeralKeyPair
    }

    public init(
        receiverFingerprint: String,
        serviceIdentity: String = "EagleGaze Mac",
        store: any PairedDeviceStore,
        advertisement: (any PairingAdvertisementService)? = nil,
        onStateChanged: StateChangeHandler? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.receiverFingerprint = receiverFingerprint
        self.serviceIdentity = serviceIdentity
        self.store = store
        self.advertisement = advertisement
        self.stateChangeHandler = onStateChanged
        self.now = now
    }

    /// Convenience for previews and legacy composition.  It still loads a
    /// device-only identity rather than using a shared constant; production
    /// composition should inject `MacReceiverIdentityStore` explicitly.
    @available(*, deprecated, message: "Inject MacReceiverIdentityStore for explicit identity composition")
    public convenience init(
        store: any PairedDeviceStore,
        advertisement: (any PairingAdvertisementService)? = nil,
        onStateChanged: StateChangeHandler? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let fingerprint = (try? KeychainMacReceiverIdentityStore().loadOrCreate().fingerprint)
            ?? MacReceiverIdentity.random().fingerprint
        self.init(
            receiverFingerprint: fingerprint,
            store: store,
            advertisement: advertisement,
            onStateChanged: onStateChanged,
            now: now
        )
    }

    /// Production composition entry point: load the per-install opaque Mac
    /// identity before creating offers.  Tests can inject the in-memory store.
    public convenience init(
        identityStore: any MacReceiverIdentityStore,
        serviceIdentity: String = "EagleGaze Mac",
        store: any PairedDeviceStore,
        advertisement: (any PairingAdvertisementService)? = nil,
        onStateChanged: StateChangeHandler? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let identity = try identityStore.loadOrCreate()
        self.init(
            receiverFingerprint: identity.fingerprint,
            serviceIdentity: serviceIdentity,
            store: store,
            advertisement: advertisement,
            onStateChanged: onStateChanged,
            now: now
        )
    }

    public func setStateChangeHandler(_ handler: StateChangeHandler?) {
        stateChangeHandler = handler
    }

    public func pairedDevices() throws -> [PairedDeviceRecord] {
        try store.list()
    }

    public func pairedDevice(pairID: UUID) throws -> PairedDeviceRecord? {
        try store.record(pairID: pairID)
    }

    /// Creates an expiring offer and starts Bonjour advertisement.  A new offer
    /// replaces an old visible offer, but never replaces a pending approval.
    @discardableResult
    public func makeOffer(lifetime: TimeInterval = 120) throws -> PairingOfferPresentation {
        guard lifetime.isFinite, lifetime > 0, lifetime <= 15 * 60 else {
            throw PairingServiceError.invalidOfferLifetime
        }
        expireOfferIfNeeded()
        guard pending == nil else { throw PairingServiceError.offerAlreadyAwaitingConfirmation }
        // A visible offer is one-time and its advertisement is scoped to that
        // offer.  Stop it before replacing the QR with a fresh offer.
        if activeOffer != nil { clearOffer() }

        let keyPair = P256EphemeralKeyPair()
        let offer = try PairingOffer(
            offerID: UUID(),
            receiverFingerprint: receiverFingerprint,
            ephemeralPublicKey: keyPair.publicKey,
            oneTimeSecret: randomBytes(count: 32),
            serviceIdentity: serviceIdentity,
            expiresAt: now().addingTimeInterval(lifetime)
        )
        let qrString = try PairingQRCodec.encode(offer)

        do {
            try advertisement?.start(offer: offer)
        } catch {
            transition(to: .idle)
            throw PairingServiceError.advertisementFailed
        }

        activeOffer = offer
        receiverEphemeralKey = keyPair
        let presentation = PairingOfferPresentation(offer: offer, qrString: qrString)
        transition(to: .offerVisible(presentation))
        return presentation
    }

    public func expireOfferIfNeeded() {
        guard let offer = activeOffer else { return }
        guard now() >= offer.expiresAt else { return }
        clearOffer()
    }

    public func cancelOffer() {
        guard pending == nil else { return }
        clearOffer()
    }

    /// Validates the phone's transcript and moves into a user-confirmation
    /// state.  No record is written until `confirmPairing` is called.
    @discardableResult
    public func beginPairing(_ request: PairingRequest) throws -> PendingPairingConfirmation {
        guard let offer = activeOffer, let receiverKey = receiverEphemeralKey else {
            throw PairingServiceError.noActiveOffer
        }
        guard now() < offer.expiresAt else {
            clearOffer()
            throw PairingServiceError.offerExpired
        }
        guard pending == nil else { throw PairingServiceError.offerAlreadyAwaitingConfirmation }
        guard request.offerID == offer.offerID else { throw PairingServiceError.offerMismatch }
        guard !request.deviceID.isZero,
              !request.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw PairingServiceError.invalidRequest }

        do {
            let transcript = try PairingTranscript(
                offerID: offer.offerID,
                receiverFingerprint: offer.receiverFingerprint,
                serviceIdentity: offer.serviceIdentity,
                receiverEphemeralPublicKey: offer.ephemeralPublicKey,
                initiatorEphemeralPublicKey: request.initiatorEphemeralPublicKey,
                oneTimeSecret: offer.oneTimeSecret
            )
            let material = try PairingKeyAgreement.derivePairingMaterial(
                localKeyPair: receiverKey,
                peerPublicKey: request.initiatorEphemeralPublicKey,
                transcript: transcript
            )
            guard request.verificationCode == material.verificationCode else {
                throw PairingServiceError.verificationCodeMismatch
            }
            guard PairingKeyAgreement.verifyTranscriptMAC(
                request.transcriptMAC,
                material: material,
                transcript: transcript
            ) else {
                throw PairingServiceError.authenticationFailed
            }

            let confirmation = PendingPairingConfirmation(
                confirmationID: UUID(),
                pairID: UUID(),
                offerID: offer.offerID,
                deviceID: request.deviceID,
                displayName: request.displayName,
                verificationCode: material.verificationCode,
                createdAt: now(),
                expiresAt: offer.expiresAt
            )
            pending = PendingMaterial(
                confirmation: confirmation,
                material: material,
                receiverEphemeralKey: receiverKey
            )
            transition(to: .awaitingConfirmation(confirmation))
            return confirmation
        } catch let error as PairingServiceError {
            throw error
        } catch {
            throw PairingServiceError.authenticationFailed
        }
    }

    /// Converts a wire request only after every offer field has matched the
    /// currently visible QR.  This prevents a valid transcript for another
    /// receiver/offer from reaching the approval UI.
    @discardableResult
    public func beginPairing(_ request: PairingQRRequest) throws -> PendingPairingConfirmation {
        try request.validate(at: now())
        guard let offer = activeOffer else { throw PairingServiceError.noActiveOffer }
        guard request.offerID == offer.offerID,
              request.receiverFingerprint == offer.receiverFingerprint,
              request.serviceIdentity == offer.serviceIdentity,
              request.expiresAt == offer.expiresAt,
              request.receiverEphemeralPublicKey == offer.ephemeralPublicKey,
              request.oneTimeSecret == offer.oneTimeSecret else {
            throw PairingServiceError.offerMismatch
        }
        return try beginPairing(PairingRequest(
            offerID: request.offerID,
            deviceID: request.initiatorDeviceID,
            displayName: request.initiatorDisplayName,
            initiatorEphemeralPublicKey: request.initiatorEphemeralPublicKey,
            verificationCode: request.verificationCode,
            transcriptMAC: request.transcriptMAC
        ))
    }

    /// Builds the responder proof without exposing the pairing key to the
    /// control-plane transport.  The context is retained by the Mac module
    /// until the initiator's confirmation proof arrives.
    func prepareReconnect(_ challenge: ReconnectChallenge) throws -> PairingReconnectContext {
        guard let record = try store.record(pairID: challenge.pairID) else {
            throw PairingServiceError.reconnectNotFound
        }
        do {
            let response = try ReconnectResponse(
                challenge: challenge,
                responderNonce: randomBytes(count: PairingWireProtocol.nonceLength),
                pairingKey: record.pairingKey
            )
            return PairingReconnectContext(record: record, challenge: challenge, response: response)
        } catch {
            throw PairingServiceError.reconnectMismatch
        }
    }

    /// Verifies both reconnect fields and the initiator's confirmation HMAC,
    /// then derives fresh stream material.  The caller must not activate a UDP
    /// source until this method succeeds.
    @discardableResult
    func completeReconnect(_ context: PairingReconnectContext, confirmation: ReconnectConfirmation) throws -> ReconnectSessionMaterial {
        guard confirmation.pairID == context.response.pairID,
              confirmation.sessionID == context.response.sessionID,
              confirmation.initiatorNonce == context.response.initiatorNonce,
              confirmation.responderNonce == context.response.responderNonce else {
            throw PairingServiceError.reconnectMismatch
        }
        do {
            try context.response.verify(pairingKey: context.record.pairingKey)
            try confirmation.verify(pairingKey: context.record.pairingKey)
            return try sessionMaterial(
                for: context.record.pairID,
                sessionID: context.response.sessionID,
                initiatorNonce: context.response.initiatorNonce,
                responderNonce: context.response.responderNonce
            )
        } catch {
            throw PairingServiceError.reconnectMismatch
        }
    }

    /// Stores a durable record only after the Mac user has explicitly approved
    /// the displayed verification code/device name.
    @discardableResult
    public func confirmPairing(confirmationID: UUID) throws -> PairedDeviceRecord {
        guard let pending else { throw PairingServiceError.pendingPairingNotFound }
        guard pending.confirmation.confirmationID == confirmationID else {
            throw PairingServiceError.pendingPairingNotFound
        }
        guard now() < pending.confirmation.expiresAt else {
            self.pending = nil
            clearOffer()
            throw PairingServiceError.offerExpired
        }

        let record = try PairedDeviceRecord(
            pairID: pending.confirmation.pairID,
            deviceID: pending.confirmation.deviceID,
            displayName: pending.confirmation.displayName,
            receiverFingerprint: receiverFingerprint,
            pairingKey: pending.material.pairingKey,
            createdAt: pending.confirmation.createdAt
        )
        do {
            try store.save(record)
        } catch {
            throw error
        }

        self.pending = nil
        clearOffer()
        transition(to: .paired(record))
        return record
    }

    public func rejectPairing(confirmationID: UUID) throws {
        guard pending?.confirmation.confirmationID == confirmationID else {
            throw PairingServiceError.pendingPairingNotFound
        }
        pending = nil
        clearOffer()
        transition(to: .idle)
    }

    /// Revocation deletes durable material and invalidates any sessions derived
    /// through this service.  Calibration history is intentionally untouched.
    public func revoke(pairID: UUID) throws {
        guard try store.record(pairID: pairID) != nil else {
            throw PairingServiceError.pairNotFound
        }
        try store.delete(pairID: pairID)
        activeSessions.removeValue(forKey: pairID)
        if pending?.confirmation.pairID == pairID {
            pending = nil
            clearOffer()
        }
        transition(to: .idle)
    }

    public func revokeDevice(pairID: UUID) throws {
        try revoke(pairID: pairID)
    }

    /// Derives fresh reconnect material only for a currently stored pair.
    /// Calling this after revocation fails, so an old session cannot be
    /// resurrected from a cached record.
    @discardableResult
    public func sessionMaterial(
        for pairID: UUID,
        sessionID: UUID = UUID(),
        initiatorNonce: Data,
        responderNonce: Data
    ) throws -> ReconnectSessionMaterial {
        guard let record = try store.record(pairID: pairID) else {
            throw PairingServiceError.pairNotFound
        }
        guard !activeSessions[pairID, default: []].contains(sessionID) else {
            throw PairingServiceError.sessionAlreadyActive
        }
        let material = try ReconnectSessionDerivation.derive(
            pairingKey: record.pairingKey,
            pairID: pairID,
            sessionID: sessionID,
            initiatorNonce: initiatorNonce,
            responderNonce: responderNonce
        )
        activeSessions[pairID, default: []].insert(sessionID)
        return material
    }

    public func deriveSessionMaterial(
        for pairID: UUID,
        sessionID: UUID = UUID(),
        initiatorNonce: Data,
        responderNonce: Data
    ) throws -> ReconnectSessionMaterial {
        try sessionMaterial(
            for: pairID,
            sessionID: sessionID,
            initiatorNonce: initiatorNonce,
            responderNonce: responderNonce
        )
    }

    public func endSession(pairID: UUID, sessionID: UUID) {
        activeSessions[pairID]?.remove(sessionID)
        if activeSessions[pairID]?.isEmpty == true { activeSessions.removeValue(forKey: pairID) }
    }

    public func isSessionActive(pairID: UUID, sessionID: UUID) -> Bool {
        activeSessions[pairID]?.contains(sessionID) == true
    }

    private func clearOffer() {
        advertisement?.stopOffer()
        activeOffer = nil
        receiverEphemeralKey = nil
        if pending == nil { transition(to: .idle) }
    }

    private func transition(to newState: PairingServiceState) {
        state = newState
        stateChangeHandler?(newState)
    }
}

public typealias MacPairingService = PairingService

private func randomBytes(count: Int) -> Data {
    let key = SymmetricKey(size: .bits256)
    return key.withUnsafeBytes { Data($0.prefix(count)) }
}

private extension UUID {
    var isZero: Bool {
        withUnsafeBytes(of: uuid) { rawBuffer in
            rawBuffer.allSatisfy { $0 == 0 }
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString value: String) {
        var value = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: value)
    }
}
