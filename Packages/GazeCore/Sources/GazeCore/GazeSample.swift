import Foundation

/// A three-dimensional value expressed in the sender's coordinate system.
public struct Vector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// A column-major 4x4 matrix, matching the flattened layout of `simd_float4x4`.
public struct Matrix4x4: Codable, Equatable, Sendable {
    public static let elementCount = 16

    public let elements: [Double]

    public init(elements: [Double]) throws {
        guard elements.count == Self.elementCount else {
            throw GazeSampleError.invalidMatrixElementCount(elements.count)
        }
        guard elements.allSatisfy(\.isFinite) else {
            throw GazeSampleError.nonFiniteValue
        }
        self.elements = elements
    }

    private enum CodingKeys: String, CodingKey {
        case elements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(elements: container.decode([Double].self, forKey: .elements))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(elements, forKey: .elements)
    }

    public static let identity = try! Matrix4x4(elements: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])
}

public enum GazeSampleError: Error, Equatable, Sendable {
    case invalidMatrixElementCount(Int)
    case nonFiniteValue
}

/// One versioned eye-tracking observation suitable for a network datagram.
public struct GazeSample: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sessionID: UUID
    public var sequence: UInt64
    public var captureUptime: TimeInterval
    public var sentUptime: TimeInterval
    public var isTracked: Bool
    public var lookAt: Vector3
    public var faceTransform: Matrix4x4
    public var leftEyeTransform: Matrix4x4
    public var rightEyeTransform: Matrix4x4
    public var leftBlink: Double
    public var rightBlink: Double

    public init(
        version: Int = Self.currentVersion,
        sessionID: UUID,
        sequence: UInt64,
        captureUptime: TimeInterval,
        sentUptime: TimeInterval,
        isTracked: Bool,
        lookAt: Vector3,
        faceTransform: Matrix4x4,
        leftEyeTransform: Matrix4x4,
        rightEyeTransform: Matrix4x4,
        leftBlink: Double,
        rightBlink: Double
    ) {
        self.version = version
        self.sessionID = sessionID
        self.sequence = sequence
        self.captureUptime = captureUptime
        self.sentUptime = sentUptime
        self.isTracked = isTracked
        self.lookAt = lookAt
        self.faceTransform = faceTransform
        self.leftEyeTransform = leftEyeTransform
        self.rightEyeTransform = rightEyeTransform
        self.leftBlink = leftBlink
        self.rightBlink = rightBlink
    }
}
