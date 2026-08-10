import Foundation

public enum CalibrationPlanError: Error, Equatable, Sendable {
    case noCalibrationTargets
    case noEvaluationTargets
    case invalidTarget
    case invalidTiming
    case invalidSampleRequirement
    case invalidEvaluationRadius
    case invalidQualityConfiguration
    case invalidValidationPolicy
}

/// Conditions a target must satisfy before it contributes to a fit. A time
/// window alone is not evidence of fixation: the tracker must see both eyes,
/// the head must be sufficiently still, and the recent raw estimates must form
/// a compact cluster.
public struct CalibrationQualityConfiguration: Codable, Equatable, Sendable {
    public var maximumTargetDuration: TimeInterval
    public var maximumHeadAngularVelocity: Double
    public var maximumHeadLinearVelocity: Double
    public var maximumDispersion: Double
    public var dispersionWindowSize: Int
    public var maximumRetriesPerTarget: Int

    public init(
        maximumTargetDuration: TimeInterval = 5,
        maximumHeadAngularVelocity: Double = 1.2,
        maximumHeadLinearVelocity: Double = 0.30,
        maximumDispersion: Double = 0.045,
        dispersionWindowSize: Int = 18,
        maximumRetriesPerTarget: Int = 2
    ) throws {
        guard maximumTargetDuration.isFinite, maximumTargetDuration > 0,
              maximumHeadAngularVelocity.isFinite, maximumHeadAngularVelocity > 0,
              maximumHeadLinearVelocity.isFinite, maximumHeadLinearVelocity > 0,
              maximumDispersion.isFinite, maximumDispersion > 0,
              dispersionWindowSize >= 3,
              maximumRetriesPerTarget >= 0 else {
            throw CalibrationPlanError.invalidQualityConfiguration
        }
        self.maximumTargetDuration = maximumTargetDuration
        self.maximumHeadAngularVelocity = maximumHeadAngularVelocity
        self.maximumHeadLinearVelocity = maximumHeadLinearVelocity
        self.maximumDispersion = maximumDispersion
        self.dispersionWindowSize = dispersionWindowSize
        self.maximumRetriesPerTarget = maximumRetriesPerTarget
    }

    public static let standard = try! CalibrationQualityConfiguration()
}

/// Acceptance gate for a newly fitted candidate. These targets are collected
/// after fitting and must be spatially independent from the training grid.
/// The previous profile stays active until the candidate passes this gate.
public struct CalibrationValidationPolicy: Codable, Equatable, Sendable {
    public var maximumRMSError: Double
    public var maximumWorstError: Double
    public var maximumSelectiveRetries: Int

    public init(
        maximumRMSError: Double = 0.13,
        maximumWorstError: Double = 0.22,
        maximumSelectiveRetries: Int = 2
    ) throws {
        guard maximumRMSError.isFinite, maximumRMSError > 0,
              maximumWorstError.isFinite, maximumWorstError >= maximumRMSError,
              maximumSelectiveRetries >= 0 else {
            throw CalibrationPlanError.invalidValidationPolicy
        }
        self.maximumRMSError = maximumRMSError
        self.maximumWorstError = maximumWorstError
        self.maximumSelectiveRetries = maximumSelectiveRetries
    }

    public static let standard = try! CalibrationValidationPolicy()
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
    public var quality: CalibrationQualityConfiguration?
    public var validation: CalibrationValidationPolicy?

    public init(
        targets: [Point2D],
        evaluationTargets: [Point2D]? = nil,
        timing: CalibrationTimingConfiguration = .standard,
        evaluationHitRadius: Double = 0.12,
        quality: CalibrationQualityConfiguration? = nil,
        validation: CalibrationValidationPolicy? = nil
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
        self.quality = quality
        self.validation = validation
    }

    public static let standard: CalibrationPlan = {
        let grid = [0.16, 0.50, 0.84].flatMap { y in
            [0.16, 0.50, 0.84].map { x in Point2D(x: x, y: y) }
        }
        let validationTargets = [
            Point2D(x: 0.50, y: 0.24),
            Point2D(x: 0.72, y: 0.42),
            Point2D(x: 0.62, y: 0.72),
            Point2D(x: 0.38, y: 0.72),
            Point2D(x: 0.28, y: 0.42),
        ]
        let timing = try! CalibrationTimingConfiguration(
            settleDuration: 0.70,
            collectDuration: 1.15,
            minimumSamplesPerTarget: 24
        )
        return try! CalibrationPlan(
            targets: grid,
            evaluationTargets: validationTargets,
            timing: timing,
            quality: .standard,
            validation: .standard
        )
    }()
}
