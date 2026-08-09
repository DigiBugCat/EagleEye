import Foundation

public enum CalibrationEngineError: Error, Equatable, Sendable {
    case nonFiniteTimestamp
    case timeMovedBackward(lastObserved: TimeInterval, received: TimeInterval)
    case nonFinitePoint
    case cannotEvaluateBeforeCalibration
    case notEvaluating
    case cannotFitCalibration(AffineCalibrationError)
    case invalidFrameValidity(GazeValidity)
    case closedBlink
    case nonFiniteConfidence
    case insufficientConfidence(received: Double, minimum: Double)
    case sourceMismatch(expected: GazeSourceID, received: GazeSourceID)
    case coordinateSpaceMismatch(expected: GazeCoordinateSpace, received: GazeCoordinateSpace)
    case invalidProfile(CalibrationProfileValidationError)
}

public enum CalibrationEnginePhase: String, Codable, Equatable, Sendable {
    case idle
    case calibrating
    case calibrated
    case evaluating
    case complete
    case failed
}

public enum CalibrationEngineEvent: Equatable, Sendable {
    case targetStarted(mode: CalibrationEngineMode, index: Int, target: Point2D)
    case sampleAccepted(mode: CalibrationEngineMode, index: Int, count: Int)
    case calibrationCompleted(CalibrationProfile)
    case evaluationTrialCompleted(index: Int, target: Point2D, estimate: Point2D, hit: Bool)
    case evaluationCompleted(hits: Int, total: Int)
}

public enum CalibrationEngineMode: String, Codable, Equatable, Sendable {
    case calibration
    case evaluation
}

/// UI-facing state that can be observed without exposing mutable engine data.
public struct CalibrationEngineState: Equatable, Sendable {
    public fileprivate(set) var phase: CalibrationEnginePhase
    public fileprivate(set) var mode: CalibrationEngineMode?
    public fileprivate(set) var target: Point2D?
    public fileprivate(set) var targetIndex: Int
    public fileprivate(set) var targetCount: Int
    public fileprivate(set) var sampleCount: Int
    public fileprivate(set) var trialIndex: Int
    public fileprivate(set) var trialCount: Int
    public fileprivate(set) var evaluationHits: Int
    public fileprivate(set) var profile: CalibrationProfile?
    public fileprivate(set) var error: CalibrationEngineError?

    fileprivate init(plan: CalibrationPlan) {
        phase = .idle
        mode = nil
        target = nil
        targetIndex = 0
        targetCount = plan.targets.count
        sampleCount = 0
        trialIndex = 0
        trialCount = plan.evaluationTargets.count
        evaluationHits = 0
        profile = nil
        error = nil
    }
}

/// Deterministic calibration/evaluation coordinator. It owns no UI and uses
/// caller-supplied monotonic timestamps for every transition.
public struct CalibrationEngine: Sendable {
    public let plan: CalibrationPlan
    public let profileKey: CalibrationProfileKey
    public let coordinateSpace: CalibrationCoordinateSpace
    /// Minimum canonical-frame confidence accepted by `consume(_ frame:)`.
    /// A 0.5 threshold avoids admitting weak ARKit/vendor estimates while
    /// keeping confidence policy outside the UI. Raw point fixtures bypass
    /// this gate because they have no confidence metadata.
    public let minimumConfidence: Double
    public private(set) var state: CalibrationEngineState

    /// Wall-clock provider used only for profile metadata. Calibration
    /// transitions continue to use the injected monotonic timestamps passed to
    /// `start*`, `consume`, and `advance`.
    private let wallClock: @Sendable () -> Date
    private var targetStartedAt: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var samples: [Point2D] = []
    private var observations: [AffineObservation] = []
    private var totalCalibrationSamples = 0

    public init(
        plan: CalibrationPlan = .standard,
        profileKey: CalibrationProfileKey = CalibrationProfileKey(sourceID: "", displayID: "", setupID: ""),
        coordinateSpace: CalibrationCoordinateSpace = .source,
        minimumConfidence: Double = 0.5,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.plan = plan
        self.profileKey = profileKey
        self.coordinateSpace = coordinateSpace
        self.minimumConfidence = minimumConfidence.isFinite
            ? min(1, max(0, minimumConfidence))
            : 0.5
        self.wallClock = wallClock
        self.state = CalibrationEngineState(plan: plan)
        self.targetStartedAt = nil
        self.lastTimestamp = nil
    }

    /// Creates an engine already calibrated from a persisted profile. The
    /// profile is validated against this engine's source/setup and coordinate
    /// space. No monotonic timestamp is inferred from profile wall-clock dates;
    /// the first evaluation must still provide its current monotonic time.
    public init(
        plan: CalibrationPlan = .standard,
        profile: CalibrationProfile,
        minimumConfidence: Double = 0.5,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.init(
            plan: plan,
            profileKey: profile.key,
            coordinateSpace: profile.coordinateSpace,
            minimumConfidence: minimumConfidence,
            wallClock: wallClock
        )
        try restore(profile)
    }

    public var phase: CalibrationEnginePhase { state.phase }
    public var currentTarget: Point2D? { state.target }
    public var profile: CalibrationProfile? { state.profile }

    /// Loads a persisted profile while preserving the engine's monotonic clock
    /// watermark. Callers can subsequently invoke `startEvaluation(at:)` with
    /// the current monotonic timestamp.
    public mutating func restore(_ profile: CalibrationProfile) throws {
        do {
            try profile.validate(
                expectedKey: profileKey,
                expectedCoordinateSpace: coordinateSpace
            )
        } catch let error as CalibrationProfileValidationError {
            throw CalibrationEngineError.invalidProfile(error)
        }
        samples.removeAll(keepingCapacity: true)
        observations.removeAll(keepingCapacity: true)
        totalCalibrationSamples = 0
        state.phase = .calibrated
        state.mode = nil
        state.target = nil
        state.targetIndex = 0
        state.targetCount = plan.targets.count
        state.sampleCount = 0
        state.trialIndex = 0
        state.trialCount = plan.evaluationTargets.count
        state.evaluationHits = 0
        state.profile = profile
        state.error = nil
        targetStartedAt = nil
    }

    @discardableResult
    public mutating func load(profile: CalibrationProfile) throws -> CalibrationProfile {
        try restore(profile)
        return profile
    }

    @discardableResult
    public mutating func startCalibration(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        samples.removeAll(keepingCapacity: true)
        observations.removeAll(keepingCapacity: true)
        totalCalibrationSamples = 0
        state.phase = .calibrating
        state.mode = .calibration
        state.targetIndex = 0
        state.targetCount = plan.targets.count
        state.sampleCount = 0
        state.trialIndex = 0
        state.evaluationHits = 0
        state.profile = nil
        state.error = nil
        targetStartedAt = timestamp
        state.target = plan.targets[0]
        return [.targetStarted(mode: .calibration, index: 0, target: plan.targets[0])]
    }

    @discardableResult
    public mutating func beginCalibration(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try startCalibration(at: timestamp)
    }

    @discardableResult
    public mutating func startEvaluation(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        guard state.profile != nil else {
            throw CalibrationEngineError.cannotEvaluateBeforeCalibration
        }
        samples.removeAll(keepingCapacity: true)
        state.phase = .evaluating
        state.mode = .evaluation
        state.targetCount = plan.evaluationTargets.count
        state.trialCount = plan.evaluationTargets.count
        state.targetIndex = 0
        state.trialIndex = 0
        state.sampleCount = 0
        state.evaluationHits = 0
        targetStartedAt = timestamp
        state.target = plan.evaluationTargets[0]
        return [.targetStarted(mode: .evaluation, index: 0, target: plan.evaluationTargets[0])]
    }

    @discardableResult
    public mutating func beginEvaluation(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try startEvaluation(at: timestamp)
    }

    /// Consumes one source-space gaze point. A point is eligible only after the
    /// settle interval, and a target advances once both timing and sample-count
    /// requirements are satisfied.
    @discardableResult
    public mutating func consume(_ point: Point2D, at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        guard point.x.isFinite, point.y.isFinite else {
            throw CalibrationEngineError.nonFinitePoint
        }
        guard state.phase == .calibrating || state.phase == .evaluating,
              let started = targetStartedAt,
              let target = state.target else { return [] }

        let elapsed = timestamp - started
        guard elapsed >= plan.timing.settleDuration else { return [] }

        let mappedPoint: Point2D
        if state.phase == .evaluating, let profile = state.profile {
            mappedPoint = profile.apply(to: point)
        } else {
            mappedPoint = point
        }
        samples.append(mappedPoint)
        if state.phase == .calibrating {
            totalCalibrationSamples += 1
        }
        state.sampleCount = samples.count
        var events: [CalibrationEngineEvent] = [
            .sampleAccepted(mode: state.mode ?? .calibration, index: state.targetIndex, count: samples.count)
        ]
        if elapsed >= plan.timing.totalTargetDuration,
           samples.count >= plan.timing.minimumSamplesPerTarget {
            events.append(contentsOf: try finishTarget(target: target, at: timestamp))
        }
        return events
    }

    @discardableResult
    public mutating func ingest(_ point: Point2D, at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try consume(point, at: timestamp)
    }

    /// Convenience edge for the canonical source contract. The frame's
    /// capture uptime is already monotonic, so callers that do not maintain a
    /// separate receipt clock can pass it directly to the state machine.
    @discardableResult
    public mutating func consume(_ frame: CanonicalGazeFrame) throws -> [CalibrationEngineEvent] {
        guard frame.validity == .valid else {
            throw CalibrationEngineError.invalidFrameValidity(frame.validity)
        }
        guard frame.blink != .closed else {
            throw CalibrationEngineError.closedBlink
        }
        guard frame.confidence.isFinite else {
            throw CalibrationEngineError.nonFiniteConfidence
        }
        guard frame.confidence >= minimumConfidence else {
            throw CalibrationEngineError.insufficientConfidence(
                received: frame.confidence,
                minimum: minimumConfidence
            )
        }
        guard frame.sourceID == profileKey.sourceID else {
            throw CalibrationEngineError.sourceMismatch(
                expected: profileKey.sourceID,
                received: frame.sourceID
            )
        }
        guard frame.coordinateSpace == coordinateSpace else {
            throw CalibrationEngineError.coordinateSpaceMismatch(
                expected: coordinateSpace,
                received: frame.coordinateSpace
            )
        }
        return try consume(frame.point, at: frame.captureUptime)
    }

    /// Advances a silent session. This is useful when the last sample arrived
    /// exactly at the collection boundary; it never fabricates samples.
    @discardableResult
    public mutating func advance(to timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        guard let started = targetStartedAt,
              let target = state.target,
              state.phase == .calibrating || state.phase == .evaluating,
              timestamp - started >= plan.timing.totalTargetDuration,
              samples.count >= plan.timing.minimumSamplesPerTarget else { return [] }
        return try finishTarget(target: target, at: timestamp)
    }

    public mutating func reset() {
        state = CalibrationEngineState(plan: plan)
        targetStartedAt = nil
        lastTimestamp = nil
        samples.removeAll(keepingCapacity: true)
        observations.removeAll(keepingCapacity: true)
        totalCalibrationSamples = 0
    }

    private mutating func finishTarget(target: Point2D, at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        guard let mode = state.mode else { return [] }
        let representative = median(of: samples)
        samples.removeAll(keepingCapacity: true)
        state.sampleCount = 0

        switch mode {
        case .calibration:
            observations.append(AffineObservation(input: representative, output: target))
            if state.targetIndex + 1 < plan.targets.count {
                state.targetIndex += 1
                state.target = plan.targets[state.targetIndex]
                targetStartedAt = timestamp
                return [.targetStarted(mode: .calibration, index: state.targetIndex, target: plan.targets[state.targetIndex])]
            }

            do {
                let transform = try AffineCalibration.fit(observations: observations)
                var quality = CalibrationQualitySummary.from(observations: observations, transform: transform)
                quality.sampleCount = totalCalibrationSamples
                let date = wallClock()
                let profile = CalibrationProfile(
                    key: profileKey,
                    baseTransform: transform,
                    coordinateSpace: coordinateSpace,
                    quality: quality,
                    createdAt: date,
                    updatedAt: date
                )
                state.profile = profile
                state.phase = .calibrated
                state.mode = nil
                state.target = nil
                targetStartedAt = nil
                return [.calibrationCompleted(profile)]
            } catch let error as AffineCalibrationError {
                state.phase = .failed
                state.mode = nil
                state.target = nil
                state.error = .cannotFitCalibration(error)
                targetStartedAt = nil
                throw CalibrationEngineError.cannotFitCalibration(error)
            }

        case .evaluation:
            let dx = representative.x - target.x
            let dy = representative.y - target.y
            let hit = (dx * dx + dy * dy).squareRoot() <= plan.evaluationHitRadius
            let completedIndex = state.trialIndex
            state.trialIndex += 1
            state.evaluationHits += hit ? 1 : 0
            if state.trialIndex < plan.evaluationTargets.count {
                state.targetIndex = state.trialIndex
                state.target = plan.evaluationTargets[state.trialIndex]
                targetStartedAt = timestamp
            } else {
                state.phase = .complete
                state.mode = nil
                state.target = nil
                targetStartedAt = nil
            }
            var events: [CalibrationEngineEvent] = [
                .evaluationTrialCompleted(index: completedIndex, target: target, estimate: representative, hit: hit)
            ]
            if state.phase == .complete {
                events.append(.evaluationCompleted(hits: state.evaluationHits, total: state.trialCount))
            } else {
                events.append(.targetStarted(mode: .evaluation, index: state.targetIndex, target: state.target!))
            }
            return events
        }
    }

    private mutating func setTimestamp(_ timestamp: TimeInterval) throws {
        guard timestamp.isFinite else { throw CalibrationEngineError.nonFiniteTimestamp }
        if let lastTimestamp, timestamp < lastTimestamp {
            throw CalibrationEngineError.timeMovedBackward(lastObserved: lastTimestamp, received: timestamp)
        }
        lastTimestamp = timestamp
    }

    private func median(of points: [Point2D]) -> Point2D {
        let x = points.map(\.x).sorted()
        let y = points.map(\.y).sorted()
        func median(_ values: [Double]) -> Double {
            let middle = values.count / 2
            if values.count.isMultiple(of: 2) {
                return values[middle - 1] / 2 + values[middle] / 2
            }
            return values[middle]
        }
        return Point2D(x: median(x), y: median(y))
    }
}
