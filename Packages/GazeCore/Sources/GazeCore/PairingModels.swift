import Foundation

/// The version of the QR pairing offer and pairing transcript understood by
/// this package.  Versioning is deliberately explicit so an offer from a
/// newer application is never silently interpreted as this one.
public enum PairingProtocol {
    public static let currentVersion = 1
    public static let noncePrefixLength = 4
    public static let keyLength = 32
}

public enum PairingOfferError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case invalidOfferID
    case invalidReceiverFingerprint
    case invalidEphemeralPublicKey
    case invalidOneTimeSecret
    case invalidServiceIdentity
    case invalidExpiry
    case expired
}

/// The short-lived object represented by the pairing QR code.
public struct PairingOffer: Codable, Equatable, Sendable {
    public static let currentVersion = PairingProtocol.currentVersion

    public let version: Int
    public let offerID: UUID
    public let receiverFingerprint: String
    /// P-256 public key in CryptoKit's raw 64-byte X||Y representation (the
    /// standard 65-byte 0x04||X||Y form is also accepted and normalized).
    public let ephemeralPublicKey: Data
    /// A random, one-time value supplied by the receiver.
    public let oneTimeSecret: Data
    public let serviceIdentity: String
    public let expiresAt: Date

    public init(
        version: Int = Self.currentVersion,
        offerID: UUID,
        receiverFingerprint: String,
        ephemeralPublicKey: Data,
        oneTimeSecret: Data,
        serviceIdentity: String,
        expiresAt: Date
    ) throws {
        guard version == Self.currentVersion else {
            throw PairingOfferError.unsupportedVersion(received: version, supported: Self.currentVersion)
        }
        guard !offerID.isZero else { throw PairingOfferError.invalidOfferID }
        guard !receiverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairingOfferError.invalidReceiverFingerprint
        }
        guard isValidP256PublicKey(ephemeralPublicKey) else {
            throw PairingOfferError.invalidEphemeralPublicKey
        }
        guard oneTimeSecret.count >= 16 else { throw PairingOfferError.invalidOneTimeSecret }
        guard !serviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairingOfferError.invalidServiceIdentity
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PairingOfferError.invalidExpiry
        }
        self.version = version
        self.offerID = offerID
        self.receiverFingerprint = receiverFingerprint
        self.ephemeralPublicKey = ephemeralPublicKey
        self.oneTimeSecret = oneTimeSecret
        self.serviceIdentity = serviceIdentity
        self.expiresAt = expiresAt
    }

    /// Validates an offer at an injected clock instant.  Equality with the
    /// expiry is treated as expired, avoiding a boundary race at the receiver.
    public func validate(at now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw PairingOfferError.unsupportedVersion(received: version, supported: Self.currentVersion)
        }
        guard now < expiresAt else { throw PairingOfferError.expired }
        // Codable decoding can bypass the throwing initializer, so validate
        // every field again when an offer arrives from QR/JSON data.
        guard !offerID.isZero else { throw PairingOfferError.invalidOfferID }
        guard !receiverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairingOfferError.invalidReceiverFingerprint
        }
        guard isValidP256PublicKey(ephemeralPublicKey) else {
            throw PairingOfferError.invalidEphemeralPublicKey
        }
        guard oneTimeSecret.count >= 16 else { throw PairingOfferError.invalidOneTimeSecret }
        guard !serviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairingOfferError.invalidServiceIdentity
        }
        guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PairingOfferError.invalidExpiry
        }
    }

    public func isValid(at now: Date = Date()) -> Bool {
        (try? validate(at: now)) != nil
    }
}

/// Durable pairing metadata.  Persistence belongs to Phone/Mac Keychain
/// layers; GazeCore only defines the data contract those layers store.
public struct PairedDeviceRecord: Codable, Equatable, Sendable {
    public let pairID: UUID
    public let deviceID: UUID
    public let displayName: String
    public let receiverFingerprint: String
    /// The long-lived symmetric material retained by a platform Keychain.
    public let pairingKey: Data
    public let createdAt: Date
    public let lastConnectedAt: Date?

    public init(
        pairID: UUID,
        deviceID: UUID,
        displayName: String,
        receiverFingerprint: String,
        pairingKey: Data,
        createdAt: Date,
        lastConnectedAt: Date? = nil
    ) throws {
        guard !pairID.isZero, !deviceID.isZero else { throw PairedDeviceRecordError.invalidID }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairedDeviceRecordError.invalidDisplayName
        }
        guard !receiverFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairedDeviceRecordError.invalidFingerprint
        }
        guard pairingKey.count == PairingProtocol.keyLength else { throw PairedDeviceRecordError.invalidKey }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              lastConnectedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw PairedDeviceRecordError.invalidDate
        }
        self.pairID = pairID
        self.deviceID = deviceID
        self.displayName = displayName
        self.receiverFingerprint = receiverFingerprint
        self.pairingKey = pairingKey
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}

public enum PairedDeviceRecordError: Error, Equatable, Sendable {
    case invalidID
    case invalidDisplayName
    case invalidFingerprint
    case invalidKey
    case invalidDate
}

private extension UUID {
    var isZero: Bool {
        let bytes = withUnsafeBytes(of: uuid) { Array($0) }
        return bytes.allSatisfy { $0 == 0 }
    }
}

private func isValidP256PublicKey(_ data: Data) -> Bool {
    data.count == 64 || (data.count == 65 && data.first == 4)
}
