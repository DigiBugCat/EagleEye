import Foundation

public enum CalibrationEngineError: Error, Equatable, Sendable {
    case nonFiniteTimestamp
    case timeMovedBackward(lastObserved: TimeInterval, received: TimeInterval)
    case nonFinitePoint
    case cannotEvaluateBeforeCalibration
    case notEvaluating
    case cannotFitCalibration(AffineCalibrationError)
    case cannotFitMapping(String)
    case validationFailed(rms: Double, worst: Double)
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
    case validating
    case recentering
    case calibrated
    case evaluating
    case complete
    case failed
}

public enum CalibrationHoldReason: String, Codable, Equatable, Sendable {
    case settling
    case waitingForFrame
    case eyesUnavailable
    case blink
    case headMoving
    case unstableGaze
    case collecting
    case streamRestarted
}

public enum CalibrationSampleRejectionReason: String, Codable, Equatable, Sendable {
    case invalidTracking
    case blink
    case lowConfidence
    case eyesUnavailable
    case headMoving
    case invalidMetrics
    case staleTargetEpoch
    case streamChanged
}

public enum CalibrationEngineEvent: Equatable, Sendable {
    case targetStarted(mode: CalibrationEngineMode, index: Int, target: Point2D)
    case sampleAccepted(mode: CalibrationEngineMode, index: Int, count: Int)
    case sampleRejected(mode: CalibrationEngineMode, index: Int, reason: CalibrationSampleRejectionReason)
    case targetRetried(mode: CalibrationEngineMode, index: Int, retry: Int, reason: CalibrationHoldReason)
    case candidateFitted(CalibrationReport)
    case rayPlaneCandidateFitted(RayScreenCalibrationReport)
    case rayPlaneCandidateUnavailable(String)
    case modelComparisonCompleted(
        legacyRMS: Double?,
        legacyWorst: Double?,
        rayPlaneRMS: Double?,
        rayPlaneWorst: Double?,
        selected: CalibrationModelSelection?
    )
    case calibrationCompleted(CalibrationProfile)
    case validationTrialCompleted(index: Int, target: Point2D, estimate: Point2D, error: Double)
    case validationCompleted(rms: Double, worst: Double, accepted: Bool)
    case recenterCompleted(CalibrationProfile, correction: Point2D)
    case evaluationTrialCompleted(index: Int, target: Point2D, estimate: Point2D, hit: Bool)
    case evaluationCompleted(hits: Int, total: Int)
}

public enum CalibrationEngineMode: String, Codable, Equatable, Sendable {
    case calibration
    case validation
    case recenter
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
    public fileprivate(set) var rejectedSampleCount: Int
    public fileprivate(set) var trialIndex: Int
    public fileprivate(set) var trialCount: Int
    public fileprivate(set) var evaluationHits: Int
    public fileprivate(set) var targetProgress: Double
    public fileprivate(set) var targetDispersion: Double?
    public fileprivate(set) var targetRetryCount: Int
    public fileprivate(set) var holdReason: CalibrationHoldReason?
    public fileprivate(set) var calibrationRunID: UUID?
    public fileprivate(set) var targetEpoch: UInt64
    public fileprivate(set) var profile: CalibrationProfile?
    public fileprivate(set) var error: CalibrationEngineError?

    fileprivate init(plan: CalibrationPlan) {
        phase = .idle
        mode = nil
        target = nil
        targetIndex = 0
        targetCount = plan.targets.count
        sampleCount = 0
        rejectedSampleCount = 0
        trialIndex = 0
        trialCount = plan.evaluationTargets.count
        evaluationHits = 0
        targetProgress = 0
        targetDispersion = nil
        targetRetryCount = 0
        holdReason = nil
        calibrationRunID = nil
        targetEpoch = 0
        profile = nil
        error = nil
    }
}

/// Deterministic calibration/evaluation coordinator. The active persisted
/// profile remains in `state.profile` while a replacement is being fitted and
/// validated; only an accepted candidate is committed.
public struct CalibrationEngine: Sendable {
    public let plan: CalibrationPlan
    public let profileKey: CalibrationProfileKey
    public let coordinateSpace: CalibrationCoordinateSpace
    public let screenSizeMeters: PhysicalSize2D?
    public let minimumConfidence: Double
    public private(set) var state: CalibrationEngineState

    private let wallClock: @Sendable () -> Date
    private var targetStartedAt: TimeInterval?
    private var lastTimestamp: TimeInterval?
    private var samples: [Point2D] = []
    private var targetRays: [GazeRay3D] = []
    private var targetGeometries: [GazeGeometrySample] = []
    private var allCalibrationGeometries: [GazeGeometrySample] = []
    private var observationsByIndex: [Int: AffineObservation] = [:]
    private var raySamplesByIndex: [Int: [GazeRay3D]] = [:]
    private var dispersionsByIndex: [Int: Double] = [:]
    private var totalCalibrationSamples = 0
    private var totalRejectedSamples = 0
    private var candidateReport: CalibrationReport?
    private var candidateProfile: CalibrationProfile?
    private var validationErrors: [Double] = []
    private var candidateProfiles: [CalibrationModelSelection: CalibrationProfile] = [:]
    private var validationErrorsByModel: [CalibrationModelSelection: [Double]] = [:]
    private var selectiveRetriesUsed = 0
    private var isSelectiveRetry = false
    private var expectedSourceSessionID: UUID?
    private var expectedTrackingRunID: UInt64?
    private var lastFrameSequence: UInt64?
    private var minimumSequenceForTarget: UInt64?

    public init(
        plan: CalibrationPlan = .standard,
        profileKey: CalibrationProfileKey = CalibrationProfileKey(sourceID: "", displayID: "", setupID: ""),
        coordinateSpace: CalibrationCoordinateSpace = .source,
        screenSizeMeters: PhysicalSize2D? = nil,
        minimumConfidence: Double = 0.5,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.plan = plan
        self.profileKey = profileKey
        self.coordinateSpace = coordinateSpace
        self.screenSizeMeters = screenSizeMeters?.isValid == true ? screenSizeMeters : nil
        self.minimumConfidence = minimumConfidence.isFinite ? min(1, max(0, minimumConfidence)) : 0.5
        self.wallClock = wallClock
        self.state = CalibrationEngineState(plan: plan)
    }

    public init(
        plan: CalibrationPlan = .standard,
        profile: CalibrationProfile,
        screenSizeMeters: PhysicalSize2D? = nil,
        minimumConfidence: Double = 0.5,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.init(
            plan: plan,
            profileKey: profile.key,
            coordinateSpace: profile.coordinateSpace,
            screenSizeMeters: screenSizeMeters,
            minimumConfidence: minimumConfidence,
            wallClock: wallClock
        )
        try restore(profile)
    }

    public var phase: CalibrationEnginePhase { state.phase }
    public var currentTarget: Point2D? { state.target }
    public var profile: CalibrationProfile? { state.profile }

    public mutating func restore(_ profile: CalibrationProfile) throws {
        do {
            try profile.validate(expectedKey: profileKey, expectedCoordinateSpace: coordinateSpace)
        } catch let error as CalibrationProfileValidationError {
            throw CalibrationEngineError.invalidProfile(error)
        }
        clearRunData()
        state.phase = .calibrated
        state.mode = nil
        state.target = nil
        state.targetIndex = 0
        state.targetCount = plan.targets.count
        state.trialIndex = 0
        state.trialCount = plan.evaluationTargets.count
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
        let lastKnownGood = state.profile
        clearRunData()
        state.profile = lastKnownGood
        state.phase = .calibrating
        state.mode = .calibration
        state.targetCount = plan.targets.count
        state.trialCount = plan.evaluationTargets.count
        state.calibrationRunID = UUID()
        state.error = nil
        return [startTarget(mode: .calibration, index: 0, at: timestamp, resetRetry: true)]
    }

    @discardableResult
    public mutating func beginCalibration(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try startCalibration(at: timestamp)
    }

    @discardableResult
    public mutating func startRecenter(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        guard state.profile != nil else { throw CalibrationEngineError.cannotEvaluateBeforeCalibration }
        samples.removeAll(keepingCapacity: true)
        targetGeometries.removeAll(keepingCapacity: true)
        state.phase = .recentering
        state.mode = .recenter
        state.targetCount = 1
        state.calibrationRunID = UUID()
        state.error = nil
        return [startTarget(mode: .recenter, index: 0, at: timestamp, resetRetry: true)]
    }

    @discardableResult
    public mutating func startEvaluation(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        guard state.profile != nil else { throw CalibrationEngineError.cannotEvaluateBeforeCalibration }
        samples.removeAll(keepingCapacity: true)
        state.phase = .evaluating
        state.mode = .evaluation
        state.targetCount = plan.evaluationTargets.count
        state.trialCount = plan.evaluationTargets.count
        state.trialIndex = 0
        state.evaluationHits = 0
        state.error = nil
        return [startTarget(mode: .evaluation, index: 0, at: timestamp, resetRetry: true)]
    }

    @discardableResult
    public mutating func beginEvaluation(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try startEvaluation(at: timestamp)
    }

    @discardableResult
    public mutating func consume(_ point: Point2D, at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try consumeAccepted(point, gazeRay: nil, geometry: nil, at: timestamp)
    }

    @discardableResult
    public mutating func ingest(_ point: Point2D, at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try consume(point, at: timestamp)
    }

    @discardableResult
    public mutating func consume(_ frame: CanonicalGazeFrame) throws -> [CalibrationEngineEvent] {
        try consume(frame, at: frame.captureUptime)
    }

    @discardableResult
    public mutating func consume(
        _ frame: CanonicalGazeFrame,
        at timestamp: TimeInterval
    ) throws -> [CalibrationEngineEvent] {
        guard frame.sourceID == profileKey.sourceID else {
            throw CalibrationEngineError.sourceMismatch(expected: profileKey.sourceID, received: frame.sourceID)
        }
        guard frame.coordinateSpace == coordinateSpace else {
            throw CalibrationEngineError.coordinateSpaceMismatch(expected: coordinateSpace, received: frame.coordinateSpace)
        }
        try setTimestamp(timestamp)
        guard isCollecting else { return [] }

        if let minimumSequenceForTarget, frame.sequence < minimumSequenceForTarget {
            return reject(.staleTargetEpoch, hold: .settling)
        }

        if let expectedSourceSessionID, expectedSourceSessionID != frame.sourceSessionID {
            self.expectedSourceSessionID = frame.sourceSessionID
            self.expectedTrackingRunID = frame.trackingRunID
            lastFrameSequence = frame.sequence
            return restartCurrentTarget(at: timestamp, reason: .streamRestarted, rejection: .streamChanged)
        }
        if expectedSourceSessionID == nil { expectedSourceSessionID = frame.sourceSessionID }

        if let run = frame.trackingRunID,
           let expectedTrackingRunID,
           run != expectedTrackingRunID {
            self.expectedTrackingRunID = run
            lastFrameSequence = frame.sequence
            return restartCurrentTarget(at: timestamp, reason: .streamRestarted, rejection: .streamChanged)
        }
        if expectedTrackingRunID == nil { expectedTrackingRunID = frame.trackingRunID }
        lastFrameSequence = frame.sequence

        guard frame.validity == .valid else {
            return try rejectOrThrow(.invalidTracking, hold: .eyesUnavailable, legacyError: .invalidFrameValidity(frame.validity))
        }
        guard frame.blink != .closed else {
            return try rejectOrThrow(.blink, hold: .blink, legacyError: .closedBlink)
        }
        guard frame.confidence.isFinite else { throw CalibrationEngineError.nonFiniteConfidence }
        guard frame.confidence >= minimumConfidence else {
            return try rejectOrThrow(
                .lowConfidence,
                hold: .eyesUnavailable,
                legacyError: .insufficientConfidence(received: frame.confidence, minimum: minimumConfidence)
            )
        }

        if let metrics = frame.trackingMetrics, let quality = plan.quality {
            guard metrics.isFinite else { return reject(.invalidMetrics, hold: .eyesUnavailable) }
            guard metrics.bothEyesUsable else { return reject(.eyesUnavailable, hold: .eyesUnavailable) }
            guard metrics.headAngularVelocity <= quality.maximumHeadAngularVelocity,
                  metrics.headLinearVelocity <= quality.maximumHeadLinearVelocity else {
                return reject(.headMoving, hold: .headMoving)
            }
        }

        return try consumeAccepted(
            frame.point,
            gazeRay: frame.gazeRay,
            geometry: frame.trackingMetrics?.geometry,
            at: timestamp,
            timestampAlreadySet: true
        )
    }

    @discardableResult
    public mutating func advance(to timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        try setTimestamp(timestamp)
        guard isCollecting, let target = state.target, let started = targetStartedAt else { return [] }
        updateProgress(at: timestamp)
        if canFinishTarget(at: timestamp) {
            return try finishTarget(target: target, at: timestamp)
        }
        if let quality = plan.quality,
           timestamp - started >= quality.maximumTargetDuration,
           state.targetRetryCount < quality.maximumRetriesPerTarget {
            let reason: CalibrationHoldReason = samples.count < plan.timing.minimumSamplesPerTarget ? .waitingForFrame : .unstableGaze
            return retryCurrentTarget(at: timestamp, reason: reason)
        }
        return []
    }

    public mutating func reset() {
        state = CalibrationEngineState(plan: plan)
        targetStartedAt = nil
        lastTimestamp = nil
        clearRunData()
    }

    private var isCollecting: Bool {
        switch state.phase {
        case .calibrating, .validating, .recentering, .evaluating: return true
        case .idle, .calibrated, .complete, .failed: return false
        }
    }

    private var isQualityManaged: Bool { plan.quality != nil && isCollecting }

    private mutating func consumeAccepted(
        _ point: Point2D,
        gazeRay: GazeRay3D?,
        geometry: GazeGeometrySample?,
        at timestamp: TimeInterval,
        timestampAlreadySet: Bool = false
    ) throws -> [CalibrationEngineEvent] {
        if !timestampAlreadySet { try setTimestamp(timestamp) }
        guard point.x.isFinite, point.y.isFinite else { throw CalibrationEngineError.nonFinitePoint }
        guard isCollecting, let started = targetStartedAt, let target = state.target else { return [] }

        let elapsed = timestamp - started
        guard elapsed >= plan.timing.settleDuration else {
            state.holdReason = .settling
            updateProgress(at: timestamp)
            return []
        }

        let collectedPoint: Point2D
        switch state.mode {
        case .validation:
            // Keep the raw 2D evidence here. Both candidate families are
            // scored from this same target window in `finishTarget`.
            collectedPoint = point
        case .evaluation:
            guard let profile = state.profile else { return [] }
            guard let mapped = profile.apply(to: point, gazeRay: gazeRay) else { return [] }
            collectedPoint = mapped
        case .calibration, .recenter, .none:
            collectedPoint = point
        }

        samples.append(collectedPoint)
        if let gazeRay = gazeRay?.normalized { targetRays.append(gazeRay) }
        if let geometry, geometry.isFinite {
            targetGeometries.append(geometry)
            if state.mode == .calibration { allCalibrationGeometries.append(geometry) }
        }
        if state.mode == .calibration {
            totalCalibrationSamples += 1
        }
        state.sampleCount = samples.count
        state.targetDispersion = currentDispersion()
        state.holdReason = .collecting
        updateProgress(at: timestamp)

        var events: [CalibrationEngineEvent] = [
            .sampleAccepted(mode: state.mode ?? .calibration, index: state.targetIndex, count: samples.count)
        ]
        if canFinishTarget(at: timestamp) {
            events.append(contentsOf: try finishTarget(target: target, at: timestamp))
        } else if let quality = plan.quality,
                  elapsed >= quality.maximumTargetDuration,
                  state.targetRetryCount < quality.maximumRetriesPerTarget {
            let reason: CalibrationHoldReason = samples.count < plan.timing.minimumSamplesPerTarget ? .waitingForFrame : .unstableGaze
            events.append(contentsOf: retryCurrentTarget(at: timestamp, reason: reason))
        } else if samples.count >= plan.timing.minimumSamplesPerTarget,
                  let dispersion = state.targetDispersion,
                  let quality = plan.quality,
                  dispersion > quality.maximumDispersion {
            state.holdReason = .unstableGaze
        }
        return events
    }

    private mutating func finishTarget(target: Point2D, at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        guard let mode = state.mode else { return [] }
        let capturedPoints = samples
        let capturedRays = targetRays
        let representative = median(of: capturedPoints)
        let representativeRay = medianRay(capturedRays)
        let dispersion = currentDispersion() ?? 0
        samples.removeAll(keepingCapacity: true)
        targetRays.removeAll(keepingCapacity: true)
        targetGeometries.removeAll(keepingCapacity: true)
        state.sampleCount = 0
        state.targetProgress = 0
        state.targetDispersion = nil
        state.holdReason = nil

        switch mode {
        case .calibration:
            observationsByIndex[state.targetIndex] = AffineObservation(input: representative, output: target)
            if !capturedRays.isEmpty { raySamplesByIndex[state.targetIndex] = capturedRays }
            dispersionsByIndex[state.targetIndex] = dispersion

            if !isSelectiveRetry, state.targetIndex + 1 < plan.targets.count {
                return [startTarget(mode: .calibration, index: state.targetIndex + 1, at: timestamp, resetRetry: true)]
            }
            isSelectiveRetry = false
            return try fitCandidateAndContinue(at: timestamp)

        case .validation:
            guard !candidateProfiles.isEmpty else { return [] }
            let completedIndex = state.trialIndex
            var trialResults: [(CalibrationModelSelection, Point2D, Double)] = []
            for (model, profile) in candidateProfiles {
                let mapped: [Point2D]
                switch model {
                case .legacy2D:
                    mapped = capturedPoints.compactMap { profile.apply(to: $0, gazeRay: nil) }
                case .rayPlane3D:
                    mapped = capturedRays.compactMap { profile.apply(to: representative, gazeRay: $0) }
                }
                guard mapped.count >= max(3, plan.timing.minimumSamplesPerTarget / 2) else { continue }
                let estimate = median(of: mapped)
                let error = pointDistance(estimate, target)
                validationErrorsByModel[model, default: []].append(error)
                trialResults.append((model, estimate, error))
            }
            guard let displayed = trialResults.min(by: { $0.2 < $1.2 }) else { return [] }
            state.trialIndex += 1
            var events: [CalibrationEngineEvent] = [
                .validationTrialCompleted(
                    index: completedIndex,
                    target: target,
                    estimate: displayed.1,
                    error: displayed.2
                )
            ]
            if state.trialIndex < plan.evaluationTargets.count {
                events.append(startTarget(mode: .validation, index: state.trialIndex, at: timestamp, resetRetry: true))
                return events
            }

            let policy = plan.validation!
            let legacy = validationMetrics(for: .legacy2D)
            let rayPlane = validationMetrics(for: .rayPlane3D)
            let selected = preferredAcceptedModel(policy: policy)
            let bestAvailable = selected ?? bestAvailableModel(policy: policy)
            events.append(.modelComparisonCompleted(
                legacyRMS: legacy?.rms,
                legacyWorst: legacy?.worst,
                rayPlaneRMS: rayPlane?.rms,
                rayPlaneWorst: rayPlane?.worst,
                selected: bestAvailable
            ))

            if let selected,
               var selectedProfile = candidateProfiles[selected],
               let selectedMetrics = validationMetrics(for: selected) {
                selectedProfile.quality.legacyValidationRMSError = legacy?.rms
                selectedProfile.quality.legacyValidationMaxError = legacy?.worst
                selectedProfile.quality.rayPlaneValidationRMSError = rayPlane?.rms
                selectedProfile.quality.rayPlaneValidationMaxError = rayPlane?.worst
                events.append(.validationCompleted(
                    rms: selectedMetrics.rms,
                    worst: selectedMetrics.worst,
                    accepted: true
                ))
                events.append(contentsOf: commitCandidate(
                    selectedProfile,
                    validationRMS: selectedMetrics.rms,
                    validationWorst: selectedMetrics.worst
                ))
                return events
            }

            let bestMetrics = bestAvailable.flatMap { validationMetrics(for: $0) }
                ?? (rms: Double.infinity, worst: Double.infinity)
            events.append(.validationCompleted(
                rms: bestMetrics.rms,
                worst: bestMetrics.worst,
                accepted: false
            ))

            if selectiveRetriesUsed < policy.maximumSelectiveRetries,
               let bestAvailable,
               let errors = validationErrorsByModel[bestAvailable],
               let worstIndex = errors.indices.max(by: { errors[$0] < errors[$1] }) {
                let failedTarget = plan.evaluationTargets[worstIndex]
                let nearest = plan.targets.indices.min(by: {
                    pointDistance(plan.targets[$0], failedTarget) < pointDistance(plan.targets[$1], failedTarget)
                }) ?? 0
                selectiveRetriesUsed += 1
                isSelectiveRetry = true
                observationsByIndex.removeValue(forKey: nearest)
                raySamplesByIndex.removeValue(forKey: nearest)
                state.phase = .calibrating
                state.mode = .calibration
                state.targetCount = plan.targets.count
                events.append(startTarget(mode: .calibration, index: nearest, at: timestamp, resetRetry: true))
                return events
            }

            state.phase = .failed
            state.mode = nil
            state.target = nil
            state.error = .validationFailed(rms: bestMetrics.rms, worst: bestMetrics.worst)
            targetStartedAt = nil
            return events

        case .recenter:
            guard var profile = state.profile else { return [] }
            guard let mapped = profile.apply(to: representative, gazeRay: representativeRay) else { return [] }
            let correction = Point2D(x: target.x - mapped.x, y: target.y - mapped.y)
            profile.fineAdjustment.offsetX += correction.x
            profile.fineAdjustment.offsetY += correction.y
            profile.updatedAt = wallClock()
            state.profile = profile
            state.phase = .calibrated
            state.mode = nil
            state.target = nil
            targetStartedAt = nil
            return [.recenterCompleted(profile, correction: correction)]

        case .evaluation:
            let dx = representative.x - target.x
            let dy = representative.y - target.y
            let hit = (dx * dx + dy * dy).squareRoot() <= plan.evaluationHitRadius
            let completedIndex = state.trialIndex
            state.trialIndex += 1
            state.evaluationHits += hit ? 1 : 0
            var events: [CalibrationEngineEvent] = [
                .evaluationTrialCompleted(index: completedIndex, target: target, estimate: representative, hit: hit)
            ]
            if state.trialIndex < plan.evaluationTargets.count {
                events.append(startTarget(mode: .evaluation, index: state.trialIndex, at: timestamp, resetRetry: true))
            } else {
                state.phase = .complete
                state.mode = nil
                state.target = nil
                targetStartedAt = nil
                events.append(.evaluationCompleted(hits: state.evaluationHits, total: state.trialCount))
            }
            return events
        }
    }

    private mutating func fitCandidateAndContinue(at timestamp: TimeInterval) throws -> [CalibrationEngineEvent] {
        let indexed = observationsByIndex.sorted(by: { $0.key < $1.key })
        guard indexed.count == plan.targets.count else {
            let missing = plan.targets.indices.first(where: { observationsByIndex[$0] == nil }) ?? 0
            isSelectiveRetry = true
            return [startTarget(mode: .calibration, index: missing, at: timestamp, resetRetry: true)]
        }
        let observations = indexed.map(\.value)
        let report: CalibrationReport
        do {
            report = try GazeMapping.robustFit(
                observations: observations,
                maxDrops: min(2, max(0, observations.count - 8)),
                minimumRetained: min(8, observations.count)
            )
        } catch {
            do {
                _ = try AffineCalibration.fit(observations: observations)
                throw CalibrationEngineError.cannotFitMapping(String(describing: error))
            } catch let affineError as AffineCalibrationError {
                state.phase = .failed
                state.mode = nil
                state.target = nil
                state.error = .cannotFitCalibration(affineError)
                targetStartedAt = nil
                throw CalibrationEngineError.cannotFitCalibration(affineError)
            }
        }

        candidateReport = report
        if let relativeDrop = report.droppedObservationIndices.first,
           relativeDrop < indexed.count,
           selectiveRetriesUsed < (plan.validation?.maximumSelectiveRetries ?? 0) {
            let originalIndex = indexed[relativeDrop].key
            selectiveRetriesUsed += 1
            isSelectiveRetry = true
            observationsByIndex.removeValue(forKey: originalIndex)
            raySamplesByIndex.removeValue(forKey: originalIndex)
            state.phase = .calibrating
            state.mode = .calibration
            return [
                .candidateFitted(report),
                startTarget(mode: .calibration, index: originalIndex, at: timestamp, resetRetry: true),
            ]
        }

        let date = wallClock()
        let residualMagnitudes = report.residuals.map(\.magnitude)
        let meanError = residualMagnitudes.isEmpty ? .infinity : residualMagnitudes.reduce(0, +) / Double(residualMagnitudes.count)
        let mapping = report.mapping
        let affine: AffineTransform2D?
        if case .affine(let transform) = mapping { affine = transform } else { affine = nil }
        let oldProfile = state.profile
        let legacyProfile = CalibrationProfile(
            key: profileKey,
            baseTransform: affine,
            mapping: mapping,
            selectedModel: .legacy2D,
            coordinateSpace: coordinateSpace,
            quality: CalibrationQualitySummary(
                sampleCount: totalCalibrationSamples,
                targetCount: observations.count,
                meanError: meanError,
                rmsError: report.rms,
                maxError: report.worstMagnitude,
                meanTargetDispersion: dispersionsByIndex.isEmpty
                    ? nil
                    : dispersionsByIndex.values.reduce(0, +) / Double(dispersionsByIndex.count),
                rejectedSampleCount: totalRejectedSamples,
                modelName: report.mapping.modelName
            ),
            createdAt: oldProfile?.createdAt ?? date,
            updatedAt: date,
            geometryBaseline: medianGeometry(allCalibrationGeometries)
        )
        candidateProfile = legacyProfile
        candidateProfiles = [.legacy2D: legacyProfile]

        var events: [CalibrationEngineEvent] = [.candidateFitted(report)]
        if let screenSizeMeters {
            let rayObservations = indexed.compactMap { index, _ -> RayScreenTargetObservation? in
                guard let rays = raySamplesByIndex[index], !rays.isEmpty else { return nil }
                return RayScreenTargetObservation(target: plan.targets[index], rays: rays)
            }
            do {
                let rayReport = try RayScreenCalibrator.fit(
                    observations: rayObservations,
                    screenSize: screenSizeMeters
                )
                let rayMagnitudes = rayReport.residuals.map(\.magnitude)
                let rayMean = rayMagnitudes.isEmpty
                    ? .infinity
                    : rayMagnitudes.reduce(0, +) / Double(rayMagnitudes.count)
                let rayProfile = CalibrationProfile(
                    key: profileKey,
                    baseTransform: affine,
                    mapping: mapping,
                    rayScreenMapping: rayReport.mapping,
                    selectedModel: .rayPlane3D,
                    coordinateSpace: coordinateSpace,
                    quality: CalibrationQualitySummary(
                        sampleCount: totalCalibrationSamples,
                        targetCount: rayReport.residuals.count,
                        meanError: rayMean,
                        rmsError: rayReport.rms,
                        maxError: rayReport.worstMagnitude,
                        meanTargetDispersion: dispersionsByIndex.isEmpty
                            ? nil
                            : dispersionsByIndex.values.reduce(0, +) / Double(dispersionsByIndex.count),
                        rejectedSampleCount: totalRejectedSamples,
                        modelName: "ray-plane-3D"
                    ),
                    createdAt: oldProfile?.createdAt ?? date,
                    updatedAt: date,
                    geometryBaseline: medianGeometry(allCalibrationGeometries)
                )
                candidateProfiles[.rayPlane3D] = rayProfile
                events.append(.rayPlaneCandidateFitted(rayReport))
            } catch {
                events.append(.rayPlaneCandidateUnavailable(String(describing: error)))
            }
        } else {
            events.append(.rayPlaneCandidateUnavailable("selected display did not report physical dimensions"))
        }

        guard plan.validation != nil else {
            events.append(contentsOf: commitCandidate(legacyProfile, validationRMS: nil, validationWorst: nil))
            return events
        }

        validationErrors.removeAll(keepingCapacity: true)
        validationErrorsByModel.removeAll(keepingCapacity: true)
        for model in candidateProfiles.keys { validationErrorsByModel[model] = [] }
        state.phase = .validating
        state.mode = .validation
        state.targetCount = plan.evaluationTargets.count
        state.trialCount = plan.evaluationTargets.count
        state.trialIndex = 0
        state.evaluationHits = 0
        events.append(startTarget(mode: .validation, index: 0, at: timestamp, resetRetry: true))
        return events
    }

    private func validationMetrics(
        for model: CalibrationModelSelection
    ) -> (rms: Double, worst: Double)? {
        guard let errors = validationErrorsByModel[model],
              errors.count == plan.evaluationTargets.count else { return nil }
        return (rootMeanSquare(errors), errors.max() ?? .infinity)
    }

    /// Prefer the physical model only when it improves generalization or the
    /// perimeter/worst point by a meaningful margin. This prevents a more
    /// complex fit from winning on an insignificant average-only difference.
    private func preferredAcceptedModel(
        policy: CalibrationValidationPolicy
    ) -> CalibrationModelSelection? {
        let legacy = validationMetrics(for: .legacy2D)
        let ray = validationMetrics(for: .rayPlane3D)
        let legacyPasses = legacy.map {
            $0.rms <= policy.maximumRMSError && $0.worst <= policy.maximumWorstError
        } ?? false
        let rayPasses = ray.map {
            $0.rms <= policy.maximumRMSError && $0.worst <= policy.maximumWorstError
        } ?? false

        switch (legacyPasses, rayPasses) {
        case (false, false): return nil
        case (true, false): return .legacy2D
        case (false, true): return .rayPlane3D
        case (true, true):
            guard let legacy, let ray else { return .legacy2D }
            let meaningfullyBetterAverage = ray.rms <= legacy.rms * 0.95
                && ray.worst <= legacy.worst
            let meaningfullyBetterPerimeter = ray.worst <= legacy.worst * 0.90
                && ray.rms <= legacy.rms * 1.02
            return meaningfullyBetterAverage || meaningfullyBetterPerimeter
                ? .rayPlane3D
                : .legacy2D
        }
    }

    /// Used to choose the failed target to recollect. The max normalized ratio
    /// makes a bad corner count just as strongly as a bad overall average.
    private func bestAvailableModel(
        policy: CalibrationValidationPolicy
    ) -> CalibrationModelSelection? {
        candidateProfiles.keys.compactMap { model -> (CalibrationModelSelection, Double)? in
            guard let metrics = validationMetrics(for: model) else { return nil }
            let score = max(
                metrics.rms / policy.maximumRMSError,
                metrics.worst / policy.maximumWorstError
            )
            return (model, score)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private mutating func commitCandidate(
        _ candidate: CalibrationProfile,
        validationRMS: Double?,
        validationWorst: Double?
    ) -> [CalibrationEngineEvent] {
        var accepted = candidate
        accepted.quality.validationRMSError = validationRMS
        accepted.quality.validationMaxError = validationWorst
        accepted.updatedAt = wallClock()
        candidateProfile = nil
        candidateProfiles.removeAll(keepingCapacity: true)
        validationErrorsByModel.removeAll(keepingCapacity: true)
        state.profile = accepted
        state.phase = .calibrated
        state.mode = nil
        state.target = nil
        state.targetCount = plan.targets.count
        state.error = nil
        targetStartedAt = nil
        return [.calibrationCompleted(accepted)]
    }

    private mutating func startTarget(
        mode: CalibrationEngineMode,
        index: Int,
        at timestamp: TimeInterval,
        resetRetry: Bool
    ) -> CalibrationEngineEvent {
        samples.removeAll(keepingCapacity: true)
        targetRays.removeAll(keepingCapacity: true)
        targetGeometries.removeAll(keepingCapacity: true)
        state.mode = mode
        state.targetIndex = index
        state.sampleCount = 0
        state.targetProgress = 0
        state.targetDispersion = nil
        state.holdReason = .settling
        if resetRetry { state.targetRetryCount = 0 }
        state.targetEpoch &+= 1
        targetStartedAt = timestamp
        minimumSequenceForTarget = lastFrameSequence.map { $0 == UInt64.max ? $0 : $0 + 1 }

        let target: Point2D
        switch mode {
        case .calibration: target = plan.targets[index]
        case .validation, .evaluation: target = plan.evaluationTargets[index]
        case .recenter: target = Point2D(x: 0.5, y: 0.5)
        }
        state.target = target
        return .targetStarted(mode: mode, index: index, target: target)
    }

    private mutating func retryCurrentTarget(
        at timestamp: TimeInterval,
        reason: CalibrationHoldReason
    ) -> [CalibrationEngineEvent] {
        let mode = state.mode ?? .calibration
        let index = state.targetIndex
        state.targetRetryCount += 1
        let retry = state.targetRetryCount
        let event = startTarget(mode: mode, index: index, at: timestamp, resetRetry: false)
        state.holdReason = reason
        return [.targetRetried(mode: mode, index: index, retry: retry, reason: reason), event]
    }

    private mutating func restartCurrentTarget(
        at timestamp: TimeInterval,
        reason: CalibrationHoldReason,
        rejection: CalibrationSampleRejectionReason
    ) -> [CalibrationEngineEvent] {
        let rejected = reject(rejection, hold: reason)
        return rejected + retryCurrentTarget(at: timestamp, reason: reason)
    }

    private mutating func reject(
        _ reason: CalibrationSampleRejectionReason,
        hold: CalibrationHoldReason
    ) -> [CalibrationEngineEvent] {
        totalRejectedSamples += 1
        state.rejectedSampleCount = totalRejectedSamples
        state.holdReason = hold
        return [.sampleRejected(mode: state.mode ?? .calibration, index: state.targetIndex, reason: reason)]
    }

    private mutating func rejectOrThrow(
        _ reason: CalibrationSampleRejectionReason,
        hold: CalibrationHoldReason,
        legacyError: CalibrationEngineError
    ) throws -> [CalibrationEngineEvent] {
        if isQualityManaged { return reject(reason, hold: hold) }
        throw legacyError
    }

    private func canFinishTarget(at timestamp: TimeInterval) -> Bool {
        guard let started = targetStartedAt,
              timestamp - started >= plan.timing.totalTargetDuration,
              samples.count >= plan.timing.minimumSamplesPerTarget else { return false }
        guard let quality = plan.quality else { return true }
        guard let dispersion = currentDispersion() else { return false }
        return dispersion <= quality.maximumDispersion
    }

    private mutating func updateProgress(at timestamp: TimeInterval) {
        guard let started = targetStartedAt else { state.targetProgress = 0; return }
        let elapsed = max(0, timestamp - started)
        if elapsed < plan.timing.settleDuration {
            state.targetProgress = min(0.18, elapsed / max(plan.timing.settleDuration, 0.001) * 0.18)
            return
        }
        let timeProgress = min(1, (elapsed - plan.timing.settleDuration) / max(plan.timing.collectDuration, 0.001))
        let sampleProgress = min(1, Double(samples.count) / Double(plan.timing.minimumSamplesPerTarget))
        var progress = 0.18 + 0.82 * min(timeProgress, sampleProgress)
        if let quality = plan.quality,
           let dispersion = currentDispersion(),
           dispersion > quality.maximumDispersion {
            progress = min(progress, 0.82)
        }
        state.targetProgress = min(1, max(0, progress))
    }

    private func currentDispersion() -> Double? {
        guard samples.count >= 3 else { return nil }
        let windowCount = min(samples.count, plan.quality?.dispersionWindowSize ?? samples.count)
        let window = Array(samples.suffix(windowCount))
        let center = median(of: window)
        let squared = window.reduce(0.0) { partial, point in
            let d = pointDistance(point, center)
            return partial + d * d
        }
        return (squared / Double(window.count)).squareRoot()
    }

    private mutating func clearRunData() {
        samples.removeAll(keepingCapacity: true)
        targetRays.removeAll(keepingCapacity: true)
        targetGeometries.removeAll(keepingCapacity: true)
        allCalibrationGeometries.removeAll(keepingCapacity: true)
        observationsByIndex.removeAll(keepingCapacity: true)
        raySamplesByIndex.removeAll(keepingCapacity: true)
        dispersionsByIndex.removeAll(keepingCapacity: true)
        validationErrors.removeAll(keepingCapacity: true)
        totalCalibrationSamples = 0
        totalRejectedSamples = 0
        candidateReport = nil
        candidateProfile = nil
        candidateProfiles.removeAll(keepingCapacity: true)
        validationErrorsByModel.removeAll(keepingCapacity: true)
        selectiveRetriesUsed = 0
        isSelectiveRetry = false
        expectedSourceSessionID = nil
        expectedTrackingRunID = nil
        minimumSequenceForTarget = nil
        state.sampleCount = 0
        state.rejectedSampleCount = 0
        state.targetProgress = 0
        state.targetDispersion = nil
        state.targetRetryCount = 0
        state.holdReason = nil
        state.calibrationRunID = nil
        state.targetEpoch = 0
    }

    private mutating func setTimestamp(_ timestamp: TimeInterval) throws {
        guard timestamp.isFinite else { throw CalibrationEngineError.nonFiniteTimestamp }
        if let lastTimestamp, timestamp < lastTimestamp {
            throw CalibrationEngineError.timeMovedBackward(lastObserved: lastTimestamp, received: timestamp)
        }
        lastTimestamp = timestamp
    }

    private func median(of points: [Point2D]) -> Point2D {
        Point2D(x: scalarMedian(points.map(\.x)), y: scalarMedian(points.map(\.y)))
    }

    private func medianRay(_ rays: [GazeRay3D]) -> GazeRay3D? {
        guard !rays.isEmpty else { return nil }
        return GazeRay3D(
            origin: Vector3(
                x: scalarMedian(rays.map(\.origin.x)),
                y: scalarMedian(rays.map(\.origin.y)),
                z: scalarMedian(rays.map(\.origin.z))
            ),
            direction: Vector3(
                x: scalarMedian(rays.map(\.direction.x)),
                y: scalarMedian(rays.map(\.direction.y)),
                z: scalarMedian(rays.map(\.direction.z))
            )
        ).normalized
    }

    private func medianGeometry(_ values: [GazeGeometrySample]) -> GazeGeometrySample? {
        guard !values.isEmpty else { return nil }
        return GazeGeometrySample(
            facePosition: Vector3(
                x: scalarMedian(values.map(\.facePosition.x)),
                y: scalarMedian(values.map(\.facePosition.y)),
                z: scalarMedian(values.map(\.facePosition.z))
            ),
            faceForward: Vector3(
                x: scalarMedian(values.map(\.faceForward.x)),
                y: scalarMedian(values.map(\.faceForward.y)),
                z: scalarMedian(values.map(\.faceForward.z))
            ),
            eyeSeparation: scalarMedian(values.map(\.eyeSeparation))
        )
    }

    private func scalarMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }

    private func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    private func pointDistance(_ a: Point2D, _ b: Point2D) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
