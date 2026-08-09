import Foundation

public enum CalibrationPlanError: Error, Equatable, Sendable {
    case noCalibrationTargets
    case noEvaluationTargets
    case invalidTarget
    case invalidTiming
    case invalidSampleRequirement
    case invalidEvaluationRadius
}

/// Monotonic-time controls for target settling and sample collection.
public struct CalibrationTimingConfiguration: Codable, Equatable, Sendable {
    public var settleDuration: TimeInterval
    public var collectDuration: TimeInterval
    public var minimumSamplesPerTarget: Int

    public init(
        settleDuration: TimeInterval = 0.65,
        collectDuration: TimeInterval = 0.75,
        minimumSamplesPerTarget: Int = 12
    ) throws {
        guard settleDuration.isFinite, settleDuration >= 0,
              collectDuration.isFinite, collectDuration > 0 else {
            throw CalibrationPlanError.invalidTiming
        }
        guard minimumSamplesPerTarget > 0 else {
            throw CalibrationPlanError.invalidSampleRequirement
        }
        self.settleDuration = settleDuration
        self.collectDuration = collectDuration
        self.minimumSamplesPerTarget = minimumSamplesPerTarget
    }

    public static let standard = try! CalibrationTimingConfiguration()
    public var totalTargetDuration: TimeInterval { settleDuration + collectDuration }
    public var collectionDuration: TimeInterval {
        get { collectDuration }
        set { collectDuration = newValue }
    }
    public var sampleDuration: TimeInterval {
        get { collectDuration }
        set { collectDuration = newValue }
    }
    public var minimumSamples: Int {
        get { minimumSamplesPerTarget }
        set { minimumSamplesPerTarget = newValue }
    }
}

public typealias CalibrationTiming = CalibrationTimingConfiguration

/// A deterministic target sequence. UI can render these points in any way;
/// the engine never creates or randomizes targets itself.
public struct CalibrationPlan: Codable, Equatable, Sendable {
    public var targets: [Point2D]
    public var evaluationTargets: [Point2D]
    public var timing: CalibrationTimingConfiguration
    public var evaluationHitRadius: Double

    public init(
        targets: [Point2D],
        evaluationTargets: [Point2D]? = nil,
        timing: CalibrationTimingConfiguration = .standard,
        evaluationHitRadius: Double = 0.12
    ) throws {
        guard !targets.isEmpty else { throw CalibrationPlanError.noCalibrationTargets }
        guard targets.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw CalibrationPlanError.invalidTarget
        }
        let evaluationTargets = evaluationTargets ?? targets
        guard !evaluationTargets.isEmpty else { throw CalibrationPlanError.noEvaluationTargets }
        guard evaluationTargets.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw CalibrationPlanError.invalidTarget
        }
        guard evaluationHitRadius.isFinite, evaluationHitRadius >= 0 else {
            throw CalibrationPlanError.invalidEvaluationRadius
        }
        self.targets = targets
        self.evaluationTargets = evaluationTargets
        self.timing = timing
        self.evaluationHitRadius = evaluationHitRadius
    }

    public static let standard: CalibrationPlan = {
        let grid = [0.16, 0.50, 0.84].flatMap { y in
            [0.16, 0.50, 0.84].map { x in Point2D(x: x, y: y) }
        }
        return try! CalibrationPlan(targets: grid, evaluationTargets: grid)
    }()
}
