import Foundation

/// Versioned acknowledgement that the Mac may display face-derived gaze
/// information received from a paired phone.  This state is intentionally
/// coarse: it contains no gaze samples, face data, device addresses, or user
/// identity.
public struct MacPrivacyDisclosure: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let acknowledgedAt: Date

    public init(version: Int = Self.currentVersion, acknowledgedAt: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw MacPrivacyDisclosureError.unsupportedVersion(
                received: version,
                supported: Self.currentVersion
            )
        }
        guard acknowledgedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MacPrivacyDisclosureError.invalidDate
        }
        self.version = version
        self.acknowledgedAt = acknowledgedAt
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw MacPrivacyDisclosureError.unsupportedVersion(
                received: version,
                supported: Self.currentVersion
            )
        }
        guard acknowledgedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MacPrivacyDisclosureError.invalidDate
        }
    }
}

public enum MacPrivacyDisclosureState: Codable, Equatable, Sendable {
    case undisclosed
    case acknowledged(MacPrivacyDisclosure)

    public var isAcknowledged: Bool {
        if case .acknowledged = self { return true }
        return false
    }
}

public enum MacPrivacyDisclosureError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case invalidDate
}
