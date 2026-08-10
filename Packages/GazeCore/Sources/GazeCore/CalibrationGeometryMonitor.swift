import Foundation

public enum CalibrationGeometryStatus: String, Codable, Equatable, Sendable {
    case stable
    case recenterRecommended
    case recalibrationRequired
}

public struct CalibrationGeometryAssessment: Codable, Equatable, Sendable {
    public let status: CalibrationGeometryStatus
    public let positionDeltaMeters: Double
    public let angleDeltaDegrees: Double

    public init(status: CalibrationGeometryStatus, positionDeltaMeters: Double, angleDeltaDegrees: Double) {
        self.status = status
        self.positionDeltaMeters = positionDeltaMeters
        self.angleDeltaDegrees = angleDeltaDegrees
    }
}

/// Debounces relative camera/face geometry changes. ARKit cannot tell whether
/// the phone or the user moved, so the result deliberately describes a setup
/// shift rather than claiming a particular object moved.
public struct CalibrationGeometryMonitor: Sendable {
    public var recenterPositionThreshold: Double
    public var recalibratePositionThreshold: Double
    public var recenterAngleThresholdDegrees: Double
    public var recalibrateAngleThresholdDegrees: Double
    public var requiredConsecutiveFrames: Int

    private var pendingStatus: CalibrationGeometryStatus = .stable
    private var consecutiveFrames = 0
    public private(set) var status: CalibrationGeometryStatus = .stable

    public init(
        recenterPositionThreshold: Double = 0.035,
        recalibratePositionThreshold: Double = 0.085,
        recenterAngleThresholdDegrees: Double = 5,
        recalibrateAngleThresholdDegrees: Double = 12,
        requiredConsecutiveFrames: Int = 30
    ) {
        self.recenterPositionThreshold = recenterPositionThreshold
        self.recalibratePositionThreshold = recalibratePositionThreshold
        self.recenterAngleThresholdDegrees = recenterAngleThresholdDegrees
        self.recalibrateAngleThresholdDegrees = recalibrateAngleThresholdDegrees
        self.requiredConsecutiveFrames = max(1, requiredConsecutiveFrames)
    }

    public mutating func update(
        current: GazeGeometrySample,
        baseline: GazeGeometrySample
    ) -> CalibrationGeometryAssessment? {
        guard current.isFinite, baseline.isFinite else { return nil }
        let positionDelta = distance(current.facePosition, baseline.facePosition)
        let angleDelta = angleDegrees(current.faceForward, baseline.faceForward)
        let measured: CalibrationGeometryStatus
        if positionDelta >= recalibratePositionThreshold || angleDelta >= recalibrateAngleThresholdDegrees {
            measured = .recalibrationRequired
        } else if positionDelta >= recenterPositionThreshold || angleDelta >= recenterAngleThresholdDegrees {
            measured = .recenterRecommended
        } else {
            measured = .stable
        }

        if measured == pendingStatus {
            consecutiveFrames += 1
        } else {
            pendingStatus = measured
            consecutiveFrames = 1
        }
        if consecutiveFrames >= requiredConsecutiveFrames { status = measured }
        return CalibrationGeometryAssessment(
            status: status,
            positionDeltaMeters: positionDelta,
            angleDeltaDegrees: angleDelta
        )
    }

    public mutating func reset() {
        pendingStatus = .stable
        consecutiveFrames = 0
        status = .stable
    }

    private func distance(_ a: Vector3, _ b: Vector3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func angleDegrees(_ a: Vector3, _ b: Vector3) -> Double {
        let am = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let bm = (b.x * b.x + b.y * b.y + b.z * b.z).squareRoot()
        guard am > 1e-9, bm > 1e-9 else { return 0 }
        let dot = max(-1, min(1, (a.x * b.x + a.y * b.y + a.z * b.z) / (am * bm)))
        return acos(dot) * 180 / .pi
    }
}
