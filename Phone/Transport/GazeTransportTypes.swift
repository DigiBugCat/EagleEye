import Foundation
import GazeCore

/// A stable identifier for a receiver discovered by Bonjour.  Pairing owns
/// the mapping between this identifier and a durable pair record; transport
/// never guesses which receiver should be active.
public struct GazeReceiverID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Network endpoints are value types so discovery and transport can be faked
/// in unit tests without importing Network.framework.
public enum GazeTransportEndpoint: Hashable, Codable, Sendable {
    case bonjour(name: String, type: String, domain: String)
    case host(name: String, port: UInt16)
}

public struct DiscoveredGazeReceiver: Identifiable, Hashable, Codable, Sendable {
    public let id: GazeReceiverID
    public let displayName: String
    public let endpoint: GazeTransportEndpoint
    /// Stable receiver identity from the Bonjour TXT record. This is not the
    /// endpoint-derived ID, which is intentionally ephemeral.
    public let receiverFingerprint: String

    public init(
        id: GazeReceiverID,
        displayName: String,
        endpoint: GazeTransportEndpoint,
        receiverFingerprint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.receiverFingerprint = receiverFingerprint
    }

    public var hasValidReceiverIdentity: Bool {
        Self.isValidReceiverFingerprint(receiverFingerprint)
    }

    public static func isValidReceiverFingerprint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7E
        }
    }
}

public enum GazeSessionMaterialError: Error, Equatable, Sendable {
    case invalidPairID
    case invalidSessionID
    case invalidSessionKey
    case invalidNoncePrefix
}

/// Fresh material for one authenticated stream.  A pairing key is not a
/// session key and must never be passed to the sender by accident.
public struct GazeSessionMaterial: Equatable, Sendable {
    public let pairID: UUID
    public let sessionID: UUID
    public let sessionKey: Data
    public let noncePrefix: Data

    public init(
        pairID: UUID,
        sessionID: UUID,
        sessionKey: Data,
        noncePrefix: Data
    ) throws {
        guard !pairID.isZero else { throw GazeSessionMaterialError.invalidPairID }
        guard !sessionID.isZero else { throw GazeSessionMaterialError.invalidSessionID }
        guard sessionKey.count == PairingProtocol.keyLength else {
            throw GazeSessionMaterialError.invalidSessionKey
        }
        guard noncePrefix.count == PairingProtocol.noncePrefixLength else {
            throw GazeSessionMaterialError.invalidNoncePrefix
        }
        self.pairID = pairID
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        self.noncePrefix = noncePrefix
    }
}

public struct PairedGazeReceiver: Equatable, Sendable {
    public let receiverID: GazeReceiverID
    public let receiverFingerprint: String
    public let endpoint: GazeTransportEndpoint
    public let session: GazeSessionMaterial

    public init(
        receiverID: GazeReceiverID,
        receiverFingerprint: String,
        endpoint: GazeTransportEndpoint,
        session: GazeSessionMaterial
    ) {
        self.receiverID = receiverID
        self.receiverFingerprint = receiverFingerprint
        self.endpoint = endpoint
        self.session = session
    }
}

public enum GazeTransportError: Error, Equatable, Sendable {
    case noSelectedReceiver
    case receiverNotDiscovered(GazeReceiverID)
    case receiverIdentityRequired
    case receiverIdentityMismatch
    case sessionMaterialRequired
    case receiverChangedWhileSelected
    case payloadTooLarge(actual: Int, maximum: Int)
    case connectionUnavailable
}

public enum GazeBrowserState: Equatable, Sendable {
    case starting
    case ready
    case failed(String)
    case stopped
}

public enum GazeConnectionState: Equatable, Sendable {
    case starting
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
}

public protocol GazeReceiverBrowser: AnyObject {
    var stateChanged: (@Sendable (GazeBrowserState) -> Void)? { get set }
    var receiversChanged: (@Sendable ([DiscoveredGazeReceiver]) -> Void)? { get set }
    func start()
    func stop()
}

public protocol GazeDatagramConnection: AnyObject {
    var stateChanged: (@Sendable (GazeConnectionState) -> Void)? { get set }
    func start()
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    func cancel()
}

public protocol GazeDatagramConnectionFactory: AnyObject {
    func makeConnection(to endpoint: GazeTransportEndpoint) -> GazeDatagramConnection
}

private extension UUID {
    var isZero: Bool {
        withUnsafeBytes(of: uuid) { $0.allSatisfy { $0 == 0 } }
    }
}
