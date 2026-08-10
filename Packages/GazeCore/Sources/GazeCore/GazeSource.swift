import Foundation

/// A stable identifier for a gaze-producing device or tracker.
///
/// The identifier is intentionally an opaque string.  Pairing and persistence
/// layers choose its value; consumers must not infer a network address, model,
/// or user identity from it.
public struct GazeSourceID: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: String) {
        self.init(rawValue: value)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    /// Source IDs are opaque, but an empty or whitespace-only value cannot be
    /// a useful stable identity.  Adapters can use this before persisting a
    /// descriptor; the initializer remains non-throwing for Codable use.
    public var isValid: Bool {
        !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The implementation family at the edge of the source pipeline.
public enum GazeSourceKind: Codable, Equatable, Hashable, Sendable {
    case arkitRemote
    case tobii
    case custom(String)

    /// Short spelling for callers that do not need to distinguish a remote
    /// ARKit adapter from the on-device SDK boundary.
    public static var arkit: Self { .arkitRemote }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum BuiltIn: String, Codable {
        case arkitRemote
        case tobii
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case BuiltIn.arkitRemote.rawValue:
            self = .arkitRemote
        case BuiltIn.tobii.rawValue:
            self = .tobii
        case "custom":
            self = .custom(try container.decode(String.self, forKey: .name))
        default:
            // Forward-compatible decoding: unknown source families remain
            // identifiable instead of being silently treated as ARKit.
            self = .custom(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .arkitRemote:
            try container.encode(BuiltIn.arkitRemote.rawValue, forKey: .kind)
        case .tobii:
            try container.encode(BuiltIn.tobii.rawValue, forKey: .kind)
        case let .custom(name):
            try container.encode("custom", forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Capabilities advertised by a source adapter.
public struct GazeSourceCapabilities: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let eyeTracking = Self(rawValue: 1 << 0)
    public static let blinkDetection = Self(rawValue: 1 << 1)
    public static let displayNormalizedCoordinates = Self(rawValue: 1 << 2)
    public static let sourceCoordinates = Self(rawValue: 1 << 3)
    public static let faceTracking = Self(rawValue: 1 << 4)

    // Short names make adapter declarations readable while retaining one
    // canonical bit for serialization and capability comparisons.
    public static let gaze = eyeTracking
    public static let blink = blinkDetection
    public static let displayNormalized = displayNormalizedCoordinates
    public static let source = sourceCoordinates
    public static let supportsBlink = blinkDetection
    public static let supportsDisplayMapping = displayNormalizedCoordinates
    public static let displayMapping = displayNormalizedCoordinates
}

/// A source's user-facing metadata and capabilities.
public struct GazeSourceDescriptor: Codable, Equatable, Sendable {
    public let sourceID: GazeSourceID
    public let kind: GazeSourceKind
    public let displayName: String
    public let capabilities: GazeSourceCapabilities

    /// Short spelling retained for source-list UIs and older adapters.
    public var id: GazeSourceID { sourceID }

    public init(
        id: GazeSourceID,
        kind: GazeSourceKind,
        displayName: String,
        capabilities: GazeSourceCapabilities
    ) {
        self.sourceID = id
        self.kind = kind
        self.displayName = displayName
        self.capabilities = capabilities
    }

    public init(
        sourceID: GazeSourceID,
        kind: GazeSourceKind,
        displayName: String,
        capabilities: GazeSourceCapabilities
    ) {
        self.init(id: sourceID, kind: kind, displayName: displayName, capabilities: capabilities)
    }
}

/// The coordinate contract of a canonical gaze point.
public enum GazeCoordinateSpace: String, Codable, Equatable, Sendable {
    /// Coordinates in the source's stable, calibration input space.
    case source
    /// Coordinates normalized to the active display, in the range defined by
    /// the source adapter (normally 0...1 on each axis).
    case displayNormalized
}

/// Why a canonical gaze point may or may not be usable by consumers.
public enum GazeValidity: String, Codable, Equatable, Sendable {
    case valid
    case invalid
    case lowConfidence
    case untracked
    case stale
}

/// Blink state associated with a canonical gaze frame.
public enum BlinkState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case unknown
}

/// Source-independent pose evidence used to recognize when the physical
/// phone/face geometry has changed enough that a saved calibration is no
/// longer trustworthy. Values are expressed in the source camera's metric
/// coordinate system; consumers compare relative deltas rather than assuming
/// that a particular mount is above or below the display.
public struct GazeGeometrySample: Codable, Equatable, Sendable {
    public let facePosition: Vector3
    public let faceForward: Vector3
    public let eyeSeparation: Double

    public init(facePosition: Vector3, faceForward: Vector3, eyeSeparation: Double) {
        self.facePosition = facePosition
        self.faceForward = faceForward
        self.eyeSeparation = eyeSeparation
    }

    public var isFinite: Bool {
        [facePosition.x, facePosition.y, facePosition.z,
         faceForward.x, faceForward.y, faceForward.z,
         eyeSeparation].allSatisfy(\.isFinite)
            && eyeSeparation > 0
    }
}

/// Per-frame tracking evidence. `confidence` on the canonical frame remains a
/// validity/reliability signal; these metrics let calibration make explicit,
/// explainable decisions about blinks, eye availability, and head motion.
public struct GazeTrackingMetrics: Codable, Equatable, Sendable {
    public let bothEyesUsable: Bool
    public let headAngularVelocity: Double
    public let headLinearVelocity: Double
    public let geometry: GazeGeometrySample?

    public init(
        bothEyesUsable: Bool,
        headAngularVelocity: Double,
        headLinearVelocity: Double,
        geometry: GazeGeometrySample? = nil
    ) {
        self.bothEyesUsable = bothEyesUsable
        self.headAngularVelocity = headAngularVelocity
        self.headLinearVelocity = headLinearVelocity
        self.geometry = geometry
    }

    public var isFinite: Bool {
        headAngularVelocity.isFinite
            && headLinearVelocity.isFinite
            && (geometry?.isFinite ?? true)
    }
}

/// The complete metric gaze ray emitted by the tracker. The origin and
/// direction share the same session coordinate system. Keeping this evidence
/// alongside the legacy projected point lets calibration compare a
/// direction-only mapping with a physical screen-plane model without changing
/// the authenticated transport envelope.
public struct GazeRay3D: Codable, Equatable, Sendable {
    public let origin: Vector3
    public let direction: Vector3

    public init(origin: Vector3, direction: Vector3) {
        self.origin = origin
        self.direction = direction
    }

    public var isFinite: Bool {
        [origin.x, origin.y, origin.z,
         direction.x, direction.y, direction.z].allSatisfy(\.isFinite)
    }

    public var normalized: GazeRay3D? {
        guard isFinite else { return nil }
        let magnitude = (
            direction.x * direction.x
                + direction.y * direction.y
                + direction.z * direction.z
        ).squareRoot()
        guard magnitude.isFinite, magnitude > 1e-9 else { return nil }
        return GazeRay3D(
            origin: origin,
            direction: Vector3(
                x: direction.x / magnitude,
                y: direction.y / magnitude,
                z: direction.z / magnitude
            )
        )
    }
}

/// Source-independent gaze observation consumed by calibration, smoothing, and
/// presentation.  Raw ARKit transforms never cross this boundary.
public struct CanonicalGazeFrame: Codable, Equatable, Sendable {
    public let sourceID: GazeSourceID
    public let sourceSessionID: UUID
    public let sequence: UInt64
    public let captureUptime: TimeInterval
    public let validity: GazeValidity
    public let confidence: Double
    public let point: Point2D
    public let coordinateSpace: GazeCoordinateSpace
    public let blink: BlinkState?
    public let blinkConfidence: Double?
    /// AR session generation, used to prevent delayed frames from an earlier
    /// tracking run from leaking into a new calibration target epoch.
    public let trackingRunID: UInt64?
    public let trackingMetrics: GazeTrackingMetrics?
    /// Optional for backward wire/profile compatibility. New ARKit senders
    /// populate it; older senders continue to drive the 2D candidate.
    public let gazeRay: GazeRay3D?

    /// Convenience spelling used by consumers that call the source session
    /// simply `sessionID` (the wire model uses that spelling).
    public var sessionID: UUID { sourceSessionID }

    public init(
        sourceID: GazeSourceID,
        sourceSessionID: UUID,
        sequence: UInt64,
        captureUptime: TimeInterval,
        validity: GazeValidity,
        confidence: Double,
        point: Point2D,
        coordinateSpace: GazeCoordinateSpace,
        blink: BlinkState? = nil,
        blinkConfidence: Double? = nil,
        trackingRunID: UInt64? = nil,
        trackingMetrics: GazeTrackingMetrics? = nil,
        gazeRay: GazeRay3D? = nil
    ) {
        self.sourceID = sourceID
        self.sourceSessionID = sourceSessionID
        self.sequence = sequence
        self.captureUptime = captureUptime
        self.validity = validity
        self.confidence = confidence
        self.point = point
        self.coordinateSpace = coordinateSpace
        self.blink = blink
        self.blinkConfidence = blinkConfidence
        self.trackingRunID = trackingRunID
        self.trackingMetrics = trackingMetrics
        self.gazeRay = gazeRay
    }

    public init(
        sourceID: GazeSourceID,
        sessionID: UUID,
        sequence: UInt64,
        captureUptime: TimeInterval,
        validity: GazeValidity,
        confidence: Double,
        point: Point2D,
        coordinateSpace: GazeCoordinateSpace,
        blink: BlinkState? = nil,
        blinkConfidence: Double? = nil,
        trackingRunID: UInt64? = nil,
        trackingMetrics: GazeTrackingMetrics? = nil,
        gazeRay: GazeRay3D? = nil
    ) {
        self.init(
            sourceID: sourceID,
            sourceSessionID: sessionID,
            sequence: sequence,
            captureUptime: captureUptime,
            validity: validity,
            confidence: confidence,
            point: point,
            coordinateSpace: coordinateSpace,
            blink: blink,
            blinkConfidence: blinkConfidence,
            trackingRunID: trackingRunID,
            trackingMetrics: trackingMetrics,
            gazeRay: gazeRay
        )
    }
}
