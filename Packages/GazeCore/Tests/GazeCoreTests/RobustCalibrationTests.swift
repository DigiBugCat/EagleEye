import Foundation
import Testing
@testable import GazeCore

private func robustTestPlan(maximumSelectiveRetries: Int = 0) throws -> CalibrationPlan {
    let timing = try CalibrationTimingConfiguration(
        settleDuration: 0,
        collectDuration: 0.1,
        minimumSamplesPerTarget: 3
    )
    let quality = try CalibrationQualityConfiguration(
        maximumTargetDuration: 2,
        maximumHeadAngularVelocity: 1,
        maximumHeadLinearVelocity: 0.25,
        maximumDispersion: 0.1,
        dispersionWindowSize: 3,
        maximumRetriesPerTarget: 1
    )
    let validation = try CalibrationValidationPolicy(
        maximumRMSError: 0.05,
        maximumWorstError: 0.06,
        maximumSelectiveRetries: maximumSelectiveRetries
    )
    return try CalibrationPlan(
        targets: [
            Point2D(x: 0.2, y: 0.2),
            Point2D(x: 0.8, y: 0.2),
            Point2D(x: 0.2, y: 0.8),
        ],
        evaluationTargets: [Point2D(x: 0.65, y: 0.65)],
        timing: timing,
        quality: quality,
        validation: validation
    )
}

private func identityProfile(key: CalibrationProfileKey) -> CalibrationProfile {
    CalibrationProfile(
        key: key,
        baseTransform: AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0),
        mapping: .affine(AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0))
    )
}

private func feedTarget(
    _ point: Point2D,
    engine: inout CalibrationEngine,
    timestamp: TimeInterval
) throws {
    _ = try engine.consume(point, at: timestamp)
    _ = try engine.consume(point, at: timestamp)
    _ = try engine.consume(point, at: timestamp)
}

@Test func candidateKeepsLastKnownGoodUntilIndependentValidationPasses() throws {
    let key = CalibrationProfileKey(sourceID: "phone", displayID: "main", setupID: "mount")
    let oldProfile = identityProfile(key: key)
    var engine = try CalibrationEngine(plan: robustTestPlan(), profile: oldProfile)

    _ = try engine.startCalibration(at: 0)
    #expect(engine.profile == oldProfile)
    try feedTarget(Point2D(x: 0.2, y: 0.2), engine: &engine, timestamp: 0.11)
    try feedTarget(Point2D(x: 0.8, y: 0.2), engine: &engine, timestamp: 0.22)
    try feedTarget(Point2D(x: 0.2, y: 0.8), engine: &engine, timestamp: 0.33)

    #expect(engine.phase == .validating)
    #expect(engine.profile == oldProfile)
    try feedTarget(Point2D(x: 0.65, y: 0.65), engine: &engine, timestamp: 0.44)

    #expect(engine.phase == .calibrated)
    #expect(engine.profile?.quality.validationRMSError == 0)
    #expect(engine.profile?.quality.modelName == "affine")
}

@Test func failedCandidateLeavesLastKnownGoodProfileActive() throws {
    let key = CalibrationProfileKey(sourceID: "phone", displayID: "main", setupID: "mount")
    let oldProfile = identityProfile(key: key)
    var engine = try CalibrationEngine(plan: robustTestPlan(), profile: oldProfile)

    _ = try engine.startCalibration(at: 0)
    try feedTarget(Point2D(x: 0.2, y: 0.2), engine: &engine, timestamp: 0.11)
    try feedTarget(Point2D(x: 0.8, y: 0.2), engine: &engine, timestamp: 0.22)
    try feedTarget(Point2D(x: 0.2, y: 0.8), engine: &engine, timestamp: 0.33)
    try feedTarget(Point2D(x: 0.05, y: 0.05), engine: &engine, timestamp: 0.44)

    #expect(engine.phase == .failed)
    #expect(engine.profile == oldProfile)
}

@Test func qualityGateRejectsHeadMotionWithoutAdvancingTarget() throws {
    let key = CalibrationProfileKey(sourceID: "phone", displayID: "main", setupID: "mount")
    var engine = CalibrationEngine(plan: try robustTestPlan(), profileKey: key)
    _ = try engine.startCalibration(at: 0)
    let frame = CanonicalGazeFrame(
        sourceID: "phone",
        sourceSessionID: UUID(),
        sequence: 1,
        captureUptime: 0.1,
        validity: .valid,
        confidence: 1,
        point: Point2D(x: 0.2, y: 0.2),
        coordinateSpace: .source,
        blink: .open,
        trackingRunID: 1,
        trackingMetrics: GazeTrackingMetrics(
            bothEyesUsable: true,
            headAngularVelocity: 3,
            headLinearVelocity: 0,
            geometry: nil
        )
    )
    let events = try engine.consume(frame, at: 0.1)
    #expect(engine.state.sampleCount == 0)
    #expect(engine.state.holdReason == .headMoving)
    #expect(events.contains(.sampleRejected(mode: .calibration, index: 0, reason: .headMoving)))
}

@Test func onePointRecenterUpdatesOnlyFineAdjustment() throws {
    let key = CalibrationProfileKey(sourceID: "phone", displayID: "main", setupID: "mount")
    let oldProfile = identityProfile(key: key)
    var engine = try CalibrationEngine(plan: robustTestPlan(), profile: oldProfile)
    _ = try engine.startRecenter(at: 0)
    try feedTarget(Point2D(x: 0.4, y: 0.5), engine: &engine, timestamp: 0.11)

    #expect(engine.phase == .calibrated)
    #expect(abs((engine.profile?.fineAdjustment.offsetX ?? 0) - 0.1) < 1e-12)
    #expect(engine.profile?.mapping == oldProfile.mapping)
}

@Test func geometryMonitorRequiresSustainedShiftBeforePrompting() {
    let baseline = GazeGeometrySample(
        facePosition: Vector3(x: 0, y: 0, z: 0.6),
        faceForward: Vector3(x: 0, y: 0, z: 1),
        eyeSeparation: 0.063
    )
    let shifted = GazeGeometrySample(
        facePosition: Vector3(x: 0.10, y: 0, z: 0.6),
        faceForward: Vector3(x: 0, y: 0, z: 1),
        eyeSeparation: 0.063
    )
    var monitor = CalibrationGeometryMonitor(requiredConsecutiveFrames: 3)
    #expect(monitor.update(current: shifted, baseline: baseline)?.status == .stable)
    #expect(monitor.update(current: shifted, baseline: baseline)?.status == .stable)
    #expect(monitor.update(current: shifted, baseline: baseline)?.status == .recalibrationRequired)
}
