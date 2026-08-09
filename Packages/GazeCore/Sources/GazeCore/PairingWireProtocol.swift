import CryptoKit
import Foundation

/// Constants and errors shared by the pairing control-plane wire messages.
public enum PairingWireProtocol {
    public static let currentVersion = PairingProtocol.currentVersion
    /// The maximum number of bytes in a JSON payload (the four-byte length
    /// prefix is not included).  Keeping this limit small bounds work before
    /// a message has been authenticated or decoded.
    public static let maxEncodedFrameSize = 64 * 1024
    public static let maxFrameSize = maxEncodedFrameSize
    public static let maximumEncodedFrameSize = maxEncodedFrameSize
    public static let lengthPrefixSize = 4
    public static let nonceLength = 32
    public static let proofLength = 32
    public static let maxStringUTF8Length = 512

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        guard !payload.isEmpty, payload.count <= maxEncodedFrameSize else {
            throw PairingWireError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(capacity: lengthPrefixSize + payload.count)
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }

    public static func decode<T: Decodable>(_ type: T.Type, payload: Data) throws -> T {
        guard !payload.isEmpty, payload.count <= maxEncodedFrameSize else {
            throw PairingWireError.frameTooLarge(payload.count)
        }
        do { return try JSONDecoder().decode(type, from: payload) }
        catch let error as PairingWireError { throw error }
        catch { throw PairingWireError.invalidMessage }
    }
}

public enum PairingWireError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case invalidID
    case invalidOffer
    case invalidDisplayName
    case invalidFingerprint
    case invalidServiceIdentity
    case expired
    case invalidPublicKey
    case invalidNonce
    case invalidProof
    case invalidDate
    case invalidResponse
    case invalidMessage
    case frameTooLarge(Int)
    case invalidLengthPrefix
}

private func nonZero(_ value: UUID) -> Bool {
    withUnsafeBytes(of: value.uuid) { bytes in bytes.contains { $0 != 0 } }
}

private func validText(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        value.utf8.count <= PairingWireProtocol.maxStringUTF8Length
}

private func validP256(_ data: Data) -> Bool {
    data.count == 64 || (data.count == 65 && data.first == 4)
}

private func validDate(_ date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite
}

private func requireVersion(_ version: Int) throws {
    guard version == PairingWireProtocol.currentVersion else {
        throw PairingWireError.unsupportedVersion(
            received: version, supported: PairingWireProtocol.currentVersion
        )
    }
}

private func validateVerificationCode(_ value: String) throws {
    guard value.utf8.count == 6,
          value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
        throw PairingWireError.invalidProof
    }
}

private func appendWireString(_ value: String?, to data: inout Data) {
    let bytes = value.map { Data($0.utf8) } ?? Data()
    var length = UInt32(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(bytes)
}

private func appendWireData(_ value: Data?, to data: inout Data) {
    var length = UInt32(value?.count ?? 0).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    if let value { data.append(value) }
}

/// A request sent after a phone has scanned the Mac's QR offer.  The offer
/// fields are carried explicitly so the Mac can reject a request for a
/// different/stale offer before doing key agreement.  This DTO contains no
/// durable key material.
public struct PairingQRRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let offerID: UUID
    public let receiverFingerprint: String
    public let serviceIdentity: String
    public let expiresAt: Date
    public let receiverEphemeralPublicKey: Data
    public let oneTimeSecret: Data
    public let initiatorDeviceID: UUID
    public let initiatorDisplayName: String
    public let initiatorEphemeralPublicKey: Data
    /// Human-verifiable transcript output.  This is not secret; it lets the
    /// Mac reject a request before presenting its explicit approval UI.
    public let verificationCode: String
    /// HMAC over the pairing transcript, never the pairing key itself.
    public let transcriptMAC: Data

    public init(
        version: Int = PairingWireProtocol.currentVersion,
        offerID: UUID,
        receiverFingerprint: String,
        serviceIdentity: String,
        expiresAt: Date,
        receiverEphemeralPublicKey: Data,
        oneTimeSecret: Data,
        initiatorDeviceID: UUID,
        initiatorDisplayName: String,
        initiatorEphemeralPublicKey: Data,
        verificationCode: String,
        transcriptMAC: Data
    ) throws {
        try requireVersion(version)
        guard nonZero(offerID), nonZero(initiatorDeviceID) else { throw PairingWireError.invalidID }
        guard validText(receiverFingerprint) else { throw PairingWireError.invalidFingerprint }
        guard validText(serviceIdentity) else { throw PairingWireError.invalidServiceIdentity }
        guard validDate(expiresAt) else { throw PairingWireError.invalidDate }
        guard validP256(receiverEphemeralPublicKey) else { throw PairingWireError.invalidPublicKey }
        guard oneTimeSecret.count >= 16, oneTimeSecret.count <= 256 else { throw PairingWireError.invalidOffer }
        guard validText(initiatorDisplayName) else { throw PairingWireError.invalidDisplayName }
        guard validP256(initiatorEphemeralPublicKey) else { throw PairingWireError.invalidPublicKey }
        guard verificationCode.utf8.count == 6,
              verificationCode.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
            throw PairingWireError.invalidProof
        }
        guard transcriptMAC.count == PairingWireProtocol.proofLength else { throw PairingWireError.invalidProof }
        self.version = version
        self.offerID = offerID
        self.receiverFingerprint = receiverFingerprint
        self.serviceIdentity = serviceIdentity
        self.expiresAt = expiresAt
        self.receiverEphemeralPublicKey = receiverEphemeralPublicKey
        self.oneTimeSecret = oneTimeSecret
        self.initiatorDeviceID = initiatorDeviceID
        self.initiatorDisplayName = initiatorDisplayName
        self.initiatorEphemeralPublicKey = initiatorEphemeralPublicKey
        self.verificationCode = verificationCode
        self.transcriptMAC = transcriptMAC
    }

    /// Convenience initializer from the shared QR offer model.
    public init(
        offer: PairingOffer,
        initiatorDeviceID: UUID,
        initiatorDisplayName: String,
        initiatorEphemeralPublicKey: Data,
        material: PairingMaterial
    ) throws {
        try self.init(
            offerID: offer.offerID,
            receiverFingerprint: offer.receiverFingerprint,
            serviceIdentity: offer.serviceIdentity,
            expiresAt: offer.expiresAt,
            receiverEphemeralPublicKey: offer.ephemeralPublicKey,
            oneTimeSecret: offer.oneTimeSecret,
            initiatorDeviceID: initiatorDeviceID,
            initiatorDisplayName: initiatorDisplayName,
            initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
            verificationCode: material.verificationCode,
            transcriptMAC: material.transcriptMAC
        )
    }

    public func validate(at now: Date? = nil) throws {
        try requireVersion(version)
        guard nonZero(offerID), nonZero(initiatorDeviceID) else { throw PairingWireError.invalidID }
        guard validText(receiverFingerprint) else { throw PairingWireError.invalidFingerprint }
        guard validText(serviceIdentity) else { throw PairingWireError.invalidServiceIdentity }
        guard validDate(expiresAt) else { throw PairingWireError.invalidDate }
        guard validP256(receiverEphemeralPublicKey) else { throw PairingWireError.invalidPublicKey }
        guard oneTimeSecret.count >= 16, oneTimeSecret.count <= 256 else { throw PairingWireError.invalidOffer }
        guard validText(initiatorDisplayName) else { throw PairingWireError.invalidDisplayName }
        guard validP256(initiatorEphemeralPublicKey) else { throw PairingWireError.invalidPublicKey }
        guard verificationCode.utf8.count == 6,
              verificationCode.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              transcriptMAC.count == PairingWireProtocol.proofLength else { throw PairingWireError.invalidProof }
        if let now, now >= expiresAt { throw PairingWireError.expired }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(Int.self, forKey: .version),
            offerID: c.decode(UUID.self, forKey: .offerID),
            receiverFingerprint: c.decode(String.self, forKey: .receiverFingerprint),
            serviceIdentity: c.decode(String.self, forKey: .serviceIdentity),
            expiresAt: c.decode(Date.self, forKey: .expiresAt),
            receiverEphemeralPublicKey: c.decode(Data.self, forKey: .receiverEphemeralPublicKey),
            oneTimeSecret: c.decode(Data.self, forKey: .oneTimeSecret),
            initiatorDeviceID: c.decode(UUID.self, forKey: .initiatorDeviceID),
            initiatorDisplayName: c.decode(String.self, forKey: .initiatorDisplayName),
            initiatorEphemeralPublicKey: c.decode(Data.self, forKey: .initiatorEphemeralPublicKey),
            verificationCode: c.decode(String.self, forKey: .verificationCode),
            transcriptMAC: c.decode(Data.self, forKey: .transcriptMAC)
        )
    }
}

public enum PairingResponseStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case rejected
}

/// Mac response to a QR request.  Approved metadata is sufficient to create
/// a `PairedDeviceRecord` after both sides derive pairingKey independently;
/// pairingKey is intentionally not a field of this type.
public struct PairingMacResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let offerID: UUID
    public let status: PairingResponseStatus
    public let pairID: UUID?
    public let deviceID: UUID?
    public let displayName: String?
    public let receiverFingerprint: String?
    public let serviceIdentity: String?
    public let createdAt: Date?
    public let rejectionReason: String?
    public let verificationCode: String?
    public let transcriptMAC: Data?
    /// Mac proof of approval, HMACed with pairingKey over all response fields.
    public let approvalProof: Data?

    public init(
        version: Int = PairingWireProtocol.currentVersion,
        offerID: UUID,
        status: PairingResponseStatus,
        pairID: UUID? = nil,
        deviceID: UUID? = nil,
        displayName: String? = nil,
        receiverFingerprint: String? = nil,
        serviceIdentity: String? = nil,
        createdAt: Date? = nil,
        rejectionReason: String? = nil,
        verificationCode: String? = nil,
        transcriptMAC: Data? = nil,
        approvalProof: Data? = nil
    ) throws {
        try requireVersion(version)
        guard nonZero(offerID) else { throw PairingWireError.invalidID }
        switch status {
        case .pending:
            guard pairID == nil, deviceID == nil, displayName == nil, receiverFingerprint == nil,
                  serviceIdentity == nil, createdAt == nil, transcriptMAC == nil, approvalProof == nil else { throw PairingWireError.invalidResponse }
            guard rejectionReason == nil else { throw PairingWireError.invalidResponse }
            if let verificationCode { try validateVerificationCode(verificationCode) }
        case .approved:
            guard let pairID, nonZero(pairID), let deviceID, nonZero(deviceID),
                  let displayName, validText(displayName),
                  let receiverFingerprint, validText(receiverFingerprint),
                  let serviceIdentity, validText(serviceIdentity),
                  let createdAt, validDate(createdAt), rejectionReason == nil,
                  let verificationCode, let transcriptMAC, transcriptMAC.count == PairingWireProtocol.proofLength,
                  let approvalProof, approvalProof.count == PairingWireProtocol.proofLength else {
                throw PairingWireError.invalidResponse
            }
            try validateVerificationCode(verificationCode)
        case .rejected:
            guard pairID == nil, deviceID == nil, displayName == nil, receiverFingerprint == nil,
                  serviceIdentity == nil, createdAt == nil, verificationCode == nil,
                  transcriptMAC == nil, approvalProof == nil else { throw PairingWireError.invalidResponse }
            if let rejectionReason, !validText(rejectionReason) { throw PairingWireError.invalidResponse }
        }
        self.version = version
        self.offerID = offerID
        self.status = status
        self.pairID = pairID
        self.deviceID = deviceID
        self.displayName = displayName
        self.receiverFingerprint = receiverFingerprint
        self.serviceIdentity = serviceIdentity
        self.createdAt = createdAt
        self.rejectionReason = rejectionReason
        self.verificationCode = verificationCode
        self.transcriptMAC = transcriptMAC
        self.approvalProof = approvalProof
    }

    public static func pending(offerID: UUID, verificationCode: String? = nil) throws -> Self {
        try Self(offerID: offerID, status: .pending, verificationCode: verificationCode)
    }

    public static func rejected(offerID: UUID, reason: String? = nil) throws -> Self {
        try Self(offerID: offerID, status: .rejected, rejectionReason: reason)
    }

    public static func approved(
        offerID: UUID,
        pairID: UUID,
        deviceID: UUID,
        displayName: String,
        receiverFingerprint: String,
        serviceIdentity: String,
        createdAt: Date,
        verificationCode: String,
        transcriptMAC: Data,
        pairingKey: Data
    ) throws -> Self {
        let unsigned = try Self(offerID: offerID, status: .approved, pairID: pairID, deviceID: deviceID,
                                displayName: displayName, receiverFingerprint: receiverFingerprint,
                                serviceIdentity: serviceIdentity, createdAt: createdAt,
                                verificationCode: verificationCode, transcriptMAC: transcriptMAC,
                                approvalProof: Data(repeating: 0, count: PairingWireProtocol.proofLength))
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairingWireError.invalidProof }
        let mac = PairingMacResponse.approvalMAC(for: unsigned, pairingKey: pairingKey)
        return try Self(offerID: offerID, status: .approved, pairID: pairID, deviceID: deviceID,
                         displayName: displayName, receiverFingerprint: receiverFingerprint,
                         serviceIdentity: serviceIdentity, createdAt: createdAt,
                         verificationCode: verificationCode, transcriptMAC: transcriptMAC, approvalProof: mac)
    }

    public func verifyApproval(pairingKey: Data) throws {
        guard let approvalProof, pairingKey.count == PairingProtocol.keyLength,
              HMAC<SHA256>.isValidAuthenticationCode(approvalProof,
                  authenticating: Self.approvalTranscript(self), using: SymmetricKey(data: pairingKey)) else {
            throw PairingWireError.invalidProof
        }
    }

    private static func approvalMAC(for response: Self, pairingKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: approvalTranscript(response), using: SymmetricKey(data: pairingKey)))
    }

    private static func approvalTranscript(_ response: Self) -> Data {
        var data = Data("eagle-gaze/pairing-approval/v1".utf8)
        var version = UInt32(response.version).bigEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        data.append(contentsOf: withUnsafeBytes(of: response.offerID.uuid) { Data($0) })
        if let pairID = response.pairID { data.append(contentsOf: withUnsafeBytes(of: pairID.uuid) { Data($0) }) }
        if let deviceID = response.deviceID { data.append(contentsOf: withUnsafeBytes(of: deviceID.uuid) { Data($0) }) }
        appendWireString(response.displayName, to: &data)
        appendWireString(response.receiverFingerprint, to: &data)
        appendWireString(response.serviceIdentity, to: &data)
        var date = response.createdAt?.timeIntervalSinceReferenceDate.bitPattern.bigEndian ?? 0
        withUnsafeBytes(of: &date) { data.append(contentsOf: $0) }
        appendWireString(response.verificationCode, to: &data)
        appendWireData(response.transcriptMAC, to: &data)
        return data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(Int.self, forKey: .version), offerID: c.decode(UUID.self, forKey: .offerID),
            status: c.decode(PairingResponseStatus.self, forKey: .status), pairID: c.decodeIfPresent(UUID.self, forKey: .pairID),
            deviceID: c.decodeIfPresent(UUID.self, forKey: .deviceID), displayName: c.decodeIfPresent(String.self, forKey: .displayName),
            receiverFingerprint: c.decodeIfPresent(String.self, forKey: .receiverFingerprint),
            serviceIdentity: c.decodeIfPresent(String.self, forKey: .serviceIdentity), createdAt: c.decodeIfPresent(Date.self, forKey: .createdAt),
            rejectionReason: c.decodeIfPresent(String.self, forKey: .rejectionReason),
            verificationCode: c.decodeIfPresent(String.self, forKey: .verificationCode),
            transcriptMAC: c.decodeIfPresent(Data.self, forKey: .transcriptMAC),
            approvalProof: c.decodeIfPresent(Data.self, forKey: .approvalProof)
        )
    }
}

public typealias PairingPendingResponse = PairingMacResponse
public typealias PairingApprovedResponse = PairingMacResponse
public typealias PairingRejectedResponse = PairingMacResponse

/// Tagged control-plane envelope.  A stream receiver can dispatch by `type`
/// before decoding the payload; each nested DTO still performs its own strict
/// validation.  The payload is an object (not base64 bytes) on the wire.
public enum PairingControlMessage: Codable, Equatable, Sendable {
    case qrRequest(PairingQRRequest)
    case macResponse(PairingMacResponse)
    case reconnectChallenge(ReconnectChallenge)
    case reconnectResponse(ReconnectResponse)
    case reconnectConfirmation(ReconnectConfirmation)

    private enum CodingKeys: String, CodingKey { case version, type, payload }
    private enum Kind: String, Codable {
        case qrRequest, macResponse, reconnectChallenge, reconnectResponse, reconnectConfirmation
    }

    public var version: Int { PairingWireProtocol.currentVersion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        try requireVersion(version)
        switch try container.decode(Kind.self, forKey: .type) {
        case .qrRequest: self = .qrRequest(try container.decode(PairingQRRequest.self, forKey: .payload))
        case .macResponse: self = .macResponse(try container.decode(PairingMacResponse.self, forKey: .payload))
        case .reconnectChallenge: self = .reconnectChallenge(try container.decode(ReconnectChallenge.self, forKey: .payload))
        case .reconnectResponse: self = .reconnectResponse(try container.decode(ReconnectResponse.self, forKey: .payload))
        case .reconnectConfirmation: self = .reconnectConfirmation(try container.decode(ReconnectConfirmation.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        switch self {
        case .qrRequest(let value):
            try container.encode(Kind.qrRequest, forKey: .type); try container.encode(value, forKey: .payload)
        case .macResponse(let value):
            try container.encode(Kind.macResponse, forKey: .type); try container.encode(value, forKey: .payload)
        case .reconnectChallenge(let value):
            try container.encode(Kind.reconnectChallenge, forKey: .type); try container.encode(value, forKey: .payload)
        case .reconnectResponse(let value):
            try container.encode(Kind.reconnectResponse, forKey: .type); try container.encode(value, forKey: .payload)
        case .reconnectConfirmation(let value):
            try container.encode(Kind.reconnectConfirmation, forKey: .type); try container.encode(value, forKey: .payload)
        }
    }
}

public typealias PairingWireMessage = PairingControlMessage
public typealias PairingReconnectChallenge = ReconnectChallenge
public typealias PairingReconnectResponse = ReconnectResponse
public typealias PairingReconnectConfirmation = ReconnectConfirmation

private enum ReconnectProofKind {
    case response
    case confirmation
    var label: Data {
        Data((self == .response ? "eagle-gaze/reconnect-response/v1" : "eagle-gaze/reconnect-confirmation/v1").utf8)
    }
}

private func reconnectTranscript(
    kind: ReconnectProofKind, version: Int, pairID: UUID, sessionID: UUID,
    initiatorNonce: Data, responderNonce: Data
) -> Data {
    var data = kind.label
    var value = UInt32(version).bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    data.append(contentsOf: withUnsafeBytes(of: pairID.uuid) { Data($0) })
    data.append(contentsOf: withUnsafeBytes(of: sessionID.uuid) { Data($0) })
    data.append(initiatorNonce)
    data.append(responderNonce)
    return data
}

private func proof(_ kind: ReconnectProofKind, version: Int, pairID: UUID, sessionID: UUID,
                   initiatorNonce: Data, responderNonce: Data, pairingKey: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(
        for: reconnectTranscript(kind: kind, version: version, pairID: pairID, sessionID: sessionID,
                                 initiatorNonce: initiatorNonce, responderNonce: responderNonce),
        using: SymmetricKey(data: pairingKey)
    ))
}

/// Initial reconnect message.  The nonce is echoed in both subsequent proofs.
public struct ReconnectChallenge: Codable, Equatable, Sendable {
    public let version: Int
    public let pairID: UUID
    public let sessionID: UUID
    public let initiatorNonce: Data

    public init(version: Int = PairingWireProtocol.currentVersion, pairID: UUID, sessionID: UUID, initiatorNonce: Data) throws {
        try requireVersion(version)
        guard nonZero(pairID), nonZero(sessionID) else { throw PairingWireError.invalidID }
        guard initiatorNonce.count == PairingWireProtocol.nonceLength else { throw PairingWireError.invalidNonce }
        self.version = version; self.pairID = pairID; self.sessionID = sessionID; self.initiatorNonce = initiatorNonce
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(Int.self, forKey: .version), pairID: c.decode(UUID.self, forKey: .pairID),
                      sessionID: c.decode(UUID.self, forKey: .sessionID), initiatorNonce: c.decode(Data.self, forKey: .initiatorNonce))
    }
}

public struct ReconnectResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let pairID: UUID
    public let sessionID: UUID
    public let initiatorNonce: Data
    public let responderNonce: Data
    public let proof: Data

    public init(version: Int = PairingWireProtocol.currentVersion, pairID: UUID, sessionID: UUID,
                initiatorNonce: Data, responderNonce: Data, proof: Data) throws {
        try requireVersion(version)
        guard nonZero(pairID), nonZero(sessionID) else { throw PairingWireError.invalidID }
        guard initiatorNonce.count == PairingWireProtocol.nonceLength,
              responderNonce.count == PairingWireProtocol.nonceLength else { throw PairingWireError.invalidNonce }
        guard proof.count == PairingWireProtocol.proofLength else { throw PairingWireError.invalidProof }
        self.version = version; self.pairID = pairID; self.sessionID = sessionID
        self.initiatorNonce = initiatorNonce; self.responderNonce = responderNonce; self.proof = proof
    }

    public init(challenge: ReconnectChallenge, responderNonce: Data, pairingKey: Data) throws {
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairingWireError.invalidProof }
        try self.init(version: challenge.version, pairID: challenge.pairID, sessionID: challenge.sessionID,
                      initiatorNonce: challenge.initiatorNonce, responderNonce: responderNonce,
                      proof: GazeReconnectProof.response(pairID: challenge.pairID, sessionID: challenge.sessionID,
                                                         initiatorNonce: challenge.initiatorNonce, responderNonce: responderNonce,
                                                         pairingKey: pairingKey))
    }

    public func verify(pairingKey: Data) throws {
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairingWireError.invalidProof }
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: reconnectTranscript(
            kind: .response, version: version, pairID: pairID, sessionID: sessionID,
            initiatorNonce: initiatorNonce, responderNonce: responderNonce), using: SymmetricKey(data: pairingKey)) else {
            throw PairingWireError.invalidProof
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(Int.self, forKey: .version), pairID: c.decode(UUID.self, forKey: .pairID), sessionID: c.decode(UUID.self, forKey: .sessionID),
                      initiatorNonce: c.decode(Data.self, forKey: .initiatorNonce), responderNonce: c.decode(Data.self, forKey: .responderNonce), proof: c.decode(Data.self, forKey: .proof))
    }
}

public struct ReconnectConfirmation: Codable, Equatable, Sendable {
    public let version: Int
    public let pairID: UUID
    public let sessionID: UUID
    public let initiatorNonce: Data
    public let responderNonce: Data
    public let proof: Data

    public init(version: Int = PairingWireProtocol.currentVersion, pairID: UUID, sessionID: UUID,
                initiatorNonce: Data, responderNonce: Data, proof: Data) throws {
        try requireVersion(version)
        guard nonZero(pairID), nonZero(sessionID) else { throw PairingWireError.invalidID }
        guard initiatorNonce.count == PairingWireProtocol.nonceLength,
              responderNonce.count == PairingWireProtocol.nonceLength else { throw PairingWireError.invalidNonce }
        guard proof.count == PairingWireProtocol.proofLength else { throw PairingWireError.invalidProof }
        self.version = version; self.pairID = pairID; self.sessionID = sessionID
        self.initiatorNonce = initiatorNonce; self.responderNonce = responderNonce; self.proof = proof
    }

    public init(response: ReconnectResponse, pairingKey: Data) throws {
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairingWireError.invalidProof }
        try self.init(version: response.version, pairID: response.pairID, sessionID: response.sessionID,
                      initiatorNonce: response.initiatorNonce, responderNonce: response.responderNonce,
                      proof: GazeReconnectProof.confirmation(pairID: response.pairID, sessionID: response.sessionID,
                                                             initiatorNonce: response.initiatorNonce, responderNonce: response.responderNonce,
                                                             pairingKey: pairingKey))
    }

    public func verify(pairingKey: Data) throws {
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairingWireError.invalidProof }
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: reconnectTranscript(
            kind: .confirmation, version: version, pairID: pairID, sessionID: sessionID,
            initiatorNonce: initiatorNonce, responderNonce: responderNonce), using: SymmetricKey(data: pairingKey)) else {
            throw PairingWireError.invalidProof
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: c.decode(Int.self, forKey: .version), pairID: c.decode(UUID.self, forKey: .pairID), sessionID: c.decode(UUID.self, forKey: .sessionID),
                      initiatorNonce: c.decode(Data.self, forKey: .initiatorNonce), responderNonce: c.decode(Data.self, forKey: .responderNonce), proof: c.decode(Data.self, forKey: .proof))
    }
}

/// Public proof helpers are useful when a transport implementation needs to
/// construct a DTO in stages (e.g. after generating a responder nonce).
public enum GazeReconnectProof {
    public static func response(pairID: UUID, sessionID: UUID, initiatorNonce: Data,
                                responderNonce: Data, pairingKey: Data) -> Data {
        proof(.response, version: PairingWireProtocol.currentVersion, pairID: pairID, sessionID: sessionID,
              initiatorNonce: initiatorNonce, responderNonce: responderNonce, pairingKey: pairingKey)
    }
    public static func confirmation(pairID: UUID, sessionID: UUID, initiatorNonce: Data,
                                    responderNonce: Data, pairingKey: Data) -> Data {
        proof(.confirmation, version: PairingWireProtocol.currentVersion, pairID: pairID, sessionID: sessionID,
              initiatorNonce: initiatorNonce, responderNonce: responderNonce, pairingKey: pairingKey)
    }
}

/// Incremental parser for a TCP byte stream.  `append` may receive arbitrary
/// fragments and returns each complete JSON payload in order.
public struct PairingWireFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !bytes.isEmpty else { return [] }
        buffer.append(bytes)
        var frames: [Data] = []
        while true {
            guard buffer.count >= PairingWireProtocol.lengthPrefixSize else { break }
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0 else { throw PairingWireError.invalidLengthPrefix }
            guard length <= PairingWireProtocol.maxEncodedFrameSize else { throw PairingWireError.frameTooLarge(Int(length)) }
            let total = PairingWireProtocol.lengthPrefixSize + Int(length)
            guard buffer.count >= total else { break }
            frames.append(Data(buffer[4..<total]))
            buffer.removeSubrange(0..<total)
        }
        return frames
}

/// Naming aliases kept intentionally small so transport adapters can refer to
/// the codec/parser without depending on a particular implementation name.
public typealias PairingWireCodec = PairingWireProtocol
public typealias PairingWireStreamDecoder = PairingWireFrameDecoder

    public var bufferedByteCount: Int { buffer.count }
    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}
