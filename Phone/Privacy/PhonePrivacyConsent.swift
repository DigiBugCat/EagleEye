import Foundation

/// The only face-derived values covered by the phone's off-device consent.
///
/// A consent record contains these category names, never a camera image, face
/// mesh, eye transform, or gaze sample.  The values are a disclosure contract
/// for the transport boundary, not a data buffer.
public enum PhoneConsentDataCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case gazeDirection
    case eyeBlinkEstimate
    case trackingState
    case timingMetadata
}

public enum PhoneConsentProcessing: String, Codable, Sendable {
    case onDeviceARKit
}

public enum PhoneConsentTransmission: String, Codable, Sendable {
    case localNetworkToPairedMac
}

public enum PhonePrivacyConsentError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case invalidConsentID
    case invalidDestinationID
    case emptyDataCategories
    case invalidDate
}

/// Versioned permission to send face-derived gaze metadata to one paired Mac.
///
/// The destination is an opaque paired-device identifier.  It must not be an
/// IP address, hostname, or durable stream key.  A consent is scoped to the
/// destination so choosing another Mac requires a new explicit grant.
public struct PhoneOffDeviceGazeConsent: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let consentID: UUID
    public let destinationID: String
    public let dataCategories: Set<PhoneConsentDataCategory>
    public let processing: PhoneConsentProcessing
    public let transmission: PhoneConsentTransmission
    public let grantedAt: Date

    public init(
        version: Int = Self.currentVersion,
        consentID: UUID = UUID(),
        destinationID: String,
        dataCategories: Set<PhoneConsentDataCategory> = Set(PhoneConsentDataCategory.allCases),
        processing: PhoneConsentProcessing = .onDeviceARKit,
        transmission: PhoneConsentTransmission = .localNetworkToPairedMac,
        grantedAt: Date = Date()
    ) throws {
        guard version == Self.currentVersion else {
            throw PhonePrivacyConsentError.unsupportedVersion(
                received: version,
                supported: Self.currentVersion
            )
        }
        guard !consentID.isZero else { throw PhonePrivacyConsentError.invalidConsentID }
        guard !destinationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhonePrivacyConsentError.invalidDestinationID
        }
        guard !dataCategories.isEmpty else { throw PhonePrivacyConsentError.emptyDataCategories }
        guard grantedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PhonePrivacyConsentError.invalidDate
        }

        self.version = version
        self.consentID = consentID
        self.destinationID = destinationID
        self.dataCategories = dataCategories
        self.processing = processing
        self.transmission = transmission
        self.grantedAt = grantedAt
    }

    /// Codable decoding bypasses the throwing initializer, so stores must
    /// call this before treating decoded data as an active consent.
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw PhonePrivacyConsentError.unsupportedVersion(
                received: version,
                supported: Self.currentVersion
            )
        }
        guard !consentID.isZero else { throw PhonePrivacyConsentError.invalidConsentID }
        guard !destinationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhonePrivacyConsentError.invalidDestinationID
        }
        guard !dataCategories.isEmpty else { throw PhonePrivacyConsentError.emptyDataCategories }
        guard grantedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PhonePrivacyConsentError.invalidDate
        }
    }
}

/// Short name for app composition and disclosure UI code.
public typealias PhonePrivacyConsent = PhoneOffDeviceGazeConsent

/// An ephemeral capability handed to the transport after consent succeeds.
/// It contains no gaze data and is invalidated by `PhonePrivacyConsentCoordinator.revoke()`.
public struct PhoneStreamingAuthorization: Equatable, Sendable {
    public let consentID: UUID
    public let consentVersion: Int
    public let destinationID: String

    init(consent: PhoneOffDeviceGazeConsent) {
        consentID = consent.consentID
        consentVersion = consent.version
        destinationID = consent.destinationID
    }
}

private extension UUID {
    var isZero: Bool {
        withUnsafeBytes(of: uuid) { bytes in bytes.allSatisfy { $0 == 0 } }
    }
}
