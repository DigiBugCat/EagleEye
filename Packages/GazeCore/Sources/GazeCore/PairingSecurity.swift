import CryptoKit
import Foundation

public enum PairingSecurityError: Error, Equatable, Sendable {
    case invalidPrivateKey
    case invalidPeerPublicKey
    case invalidSharedSecret
    case invalidKeyLength
    case invalidNonce
    case invalidTranscript
    case invalidAuthenticationCode
}

/// A P-256 key agreement key intended to live only for one pairing attempt.
public struct P256EphemeralKeyPair: Sendable {
    private let privateKeyData: Data
    public let publicKey: Data

    public init() {
        let key = P256.KeyAgreement.PrivateKey()
        privateKeyData = key.rawRepresentation
        publicKey = key.publicKey.rawRepresentation
    }

    public init(privateKey: Data) throws {
        do {
            let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            privateKeyData = key.rawRepresentation
            publicKey = key.publicKey.rawRepresentation
        } catch {
            throw PairingSecurityError.invalidPrivateKey
        }
    }

    public var privateKeyRawRepresentation: Data { privateKeyData }

    public func sharedSecret(with peerPublicKey: Data) throws -> Data {
        do {
            let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            // CryptoKit currently exposes X||Y as 64 bytes on Apple
            // platforms. Accept the standard uncompressed 65-byte form too,
            // converting it to CryptoKit's raw representation at the edge.
            let normalizedPeer = peerPublicKey.count == 65 && peerPublicKey.first == 4
                ? Data(peerPublicKey.dropFirst())
                : peerPublicKey
            let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: normalizedPeer)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let result: Data = shared.withUnsafeBytes { Data($0) }
            return result
        } catch {
            throw PairingSecurityError.invalidPeerPublicKey
        }
    }
}

/// All values that identify the pairing transcript are serialized in a fixed
/// order.  This prevents one side from deriving a valid key for a different
/// offer or for a swapped initiator/receiver key.
public struct PairingTranscript: Equatable, Sendable, Codable {
    public let version: Int
    public let offerID: UUID
    public let receiverFingerprint: String
    public let serviceIdentity: String
    public let receiverEphemeralPublicKey: Data
    public let initiatorEphemeralPublicKey: Data
    public let oneTimeSecret: Data

    public init(
        version: Int = PairingProtocol.currentVersion,
        offerID: UUID,
        receiverFingerprint: String,
        serviceIdentity: String,
        receiverEphemeralPublicKey: Data,
        initiatorEphemeralPublicKey: Data,
        oneTimeSecret: Data
    ) throws {
        guard version == PairingProtocol.currentVersion else {
            throw PairingSecurityError.invalidTranscript
        }
        guard isValidP256PublicKey(receiverEphemeralPublicKey),
              isValidP256PublicKey(initiatorEphemeralPublicKey),
              oneTimeSecret.count >= 16,
              !receiverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !serviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairingSecurityError.invalidTranscript
        }
        self.version = version
        self.offerID = offerID
        self.receiverFingerprint = receiverFingerprint
        self.serviceIdentity = serviceIdentity
        self.receiverEphemeralPublicKey = receiverEphemeralPublicKey
        self.initiatorEphemeralPublicKey = initiatorEphemeralPublicKey
        self.oneTimeSecret = oneTimeSecret
    }

    public var serialized: Data {
        var result = Data()
        appendUInt32(UInt32(version), to: &result)
        result.append(contentsOf: uuidData(offerID))
        appendString(receiverFingerprint, to: &result)
        appendString(serviceIdentity, to: &result)
        appendBytes(receiverEphemeralPublicKey, to: &result)
        appendBytes(initiatorEphemeralPublicKey, to: &result)
        appendBytes(oneTimeSecret, to: &result)
        return result
    }
}

public struct PairingMaterial: Equatable, Sendable {
    public let pairingKey: Data
    public let verificationCode: String
    public let transcriptMAC: Data

    public var symmetricKey: SymmetricKey { SymmetricKey(data: pairingKey) }
}

public enum PairingKeyAgreement {
    private static let codeLabel = Data("eagle-gaze/pairing-code/v1".utf8)
    private static let macLabel = Data("eagle-gaze/pairing-proof/v1".utf8)
    private static let keyInfo = Data("eagle-gaze/pairing-key/v1".utf8)

    public static func derivePairingMaterial(
        localKeyPair: P256EphemeralKeyPair,
        peerPublicKey: Data,
        transcript: PairingTranscript
    ) throws -> PairingMaterial {
        let sharedSecret = try localKeyPair.sharedSecret(with: peerPublicKey)
        guard !sharedSecret.isEmpty else { throw PairingSecurityError.invalidSharedSecret }
        return derivePairingMaterial(sharedSecret: sharedSecret, transcript: transcript)
    }

    public static func derivePairingMaterial(
        sharedSecret: Data,
        transcript: PairingTranscript
    ) -> PairingMaterial {
        let transcriptHash = Data(SHA256.hash(data: transcript.serialized))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: transcriptHash,
            info: keyInfo,
            outputByteCount: PairingProtocol.keyLength
        )
        let pairingKey: Data = key.withUnsafeBytes { Data($0) }
        let codeMAC = Data(HMAC<SHA256>.authenticationCode(
            for: codeLabel + transcript.serialized,
            using: key
        ))
        let codeValue = (UInt32(codeMAC[0]) << 24)
            | (UInt32(codeMAC[1]) << 16)
            | (UInt32(codeMAC[2]) << 8)
            | UInt32(codeMAC[3])
        let verificationCode = String(format: "%06u", codeValue % 1_000_000)
        let transcriptMAC = Data(HMAC<SHA256>.authenticationCode(
            for: macLabel + transcript.serialized,
            using: key
        ))
        return PairingMaterial(pairingKey: pairingKey, verificationCode: verificationCode, transcriptMAC: transcriptMAC)
    }

    public static func verifyTranscriptMAC(
        _ mac: Data,
        material: PairingMaterial,
        transcript: PairingTranscript
    ) -> Bool {
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: macLabel + transcript.serialized,
            using: material.symmetricKey
        ))
        return expected.count == mac.count && HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: macLabel + transcript.serialized, using: material.symmetricKey)
    }
}

public struct ReconnectSessionMaterial: Equatable, Sendable {
    public let sessionID: UUID
    public let streamKey: Data
    /// Four bytes are combined with an eight-byte big-endian sequence to make
    /// ChaChaPoly's 12-byte nonce.
    public let noncePrefix: Data

    public var symmetricKey: SymmetricKey { SymmetricKey(data: streamKey) }
}

public enum ReconnectSessionDerivation {
    public static func derive(
        pairingKey: Data,
        pairID: UUID,
        sessionID: UUID,
        initiatorNonce: Data,
        responderNonce: Data
    ) throws -> ReconnectSessionMaterial {
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairingSecurityError.invalidKeyLength }
        guard initiatorNonce.count >= 16, responderNonce.count >= 16 else { throw PairingSecurityError.invalidNonce }
        var context = Data("eagle-gaze/reconnect/v1".utf8)
        context.append(contentsOf: uuidData(pairID))
        context.append(contentsOf: uuidData(sessionID))
        appendBytes(initiatorNonce, to: &context)
        appendBytes(responderNonce, to: &context)
        let salt = Data(SHA256.hash(data: context))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingKey),
            salt: salt,
            info: context,
            outputByteCount: PairingProtocol.keyLength + PairingProtocol.noncePrefixLength
        )
        let bytes: Data = derived.withUnsafeBytes { Data($0) }
        return ReconnectSessionMaterial(
            sessionID: sessionID,
            streamKey: Data(bytes.prefix(PairingProtocol.keyLength)),
            noncePrefix: Data(bytes.suffix(PairingProtocol.noncePrefixLength))
        )
    }

    public static func deriveSessionKey(
        pairingKey: Data,
        pairID: UUID,
        sessionID: UUID,
        initiatorNonce: Data,
        responderNonce: Data
    ) throws -> Data {
        try derive(pairingKey: pairingKey, pairID: pairID, sessionID: sessionID, initiatorNonce: initiatorNonce, responderNonce: responderNonce).streamKey
    }
}

private func uuidData(_ uuid: UUID) -> Data {
    withUnsafeBytes(of: uuid.uuid) { Data($0) }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func appendString(_ value: String, to data: inout Data) {
    appendBytes(Data(value.utf8), to: &data)
}

private func appendBytes(_ value: Data, to data: inout Data) {
    appendUInt32(UInt32(value.count), to: &data)
    data.append(value)
}

private func isValidP256PublicKey(_ data: Data) -> Bool {
    data.count == 64 || (data.count == 65 && data.first == 4)
}
