import Foundation
import Testing
@testable import GazeCore

private func canonicalFrame(
    sourceID: GazeSourceID = "phone",
    validity: GazeValidity = .valid,
    confidence: Double = 0.8,
    point: Point2D = Point2D(x: 0.2, y: 0.2),
    coordinateSpace: GazeCoordinateSpace = .source,
    blink: BlinkState? = .open,
    captureUptime: TimeInterval = 0
) -> CanonicalGazeFrame {
    CanonicalGazeFrame(
        sourceID: sourceID,
        sourceSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        sequence: 1,
        captureUptime: captureUptime,
        validity: validity,
        confidence: confidence,
        point: point,
        coordinateSpace: coordinateSpace,
        blink: blink
    )
}

@Test func fineAdjustmentScalesAroundDisplayCenterThenOffsets() {
    let adjustment = FineAdjustment(scaleX: 2, scaleY: 0.5, offsetX: 0.1, offsetY: -0.05)
    let result = adjustment.apply(to: Point2D(x: 0.75, y: 0.25))
    #expect(result == Point2D(x: 1.1, y: 0.325))
    #expect(FineAdjustment.identity.apply(to: Point2D(x: 0.2, y: 0.8)) == Point2D(x: 0.2, y: 0.8))
}

@Test func qualitySummaryReportsAffineResiduals() throws {
    let transform = AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    let observations = [
        AffineObservation(input: Point2D(x: 0, y: 0), output: Point2D(x: 0, y: 0)),
        AffineObservation(input: Point2D(x: 1, y: 0), output: Point2D(x: 1.1, y: 0)),
        AffineObservation(input: Point2D(x: 0, y: 1), output: Point2D(x: 0, y: 1.2)),
    ]
    let quality = CalibrationQualitySummary.from(observations: observations, transform: transform)
    #expect(quality.sampleCount == 3)
    #expect(quality.targetCount == 3)
    #expect(abs(quality.maxError - 0.2) < 1e-12)
    #expect(quality.rmsError > quality.meanError)
}

@Test func calibrationEngineUsesInjectedMonotonicTimestamps() throws {
    let source = GazeSourceID("phone-1")
    let targets = [
        Point2D(x: 0.2, y: 0.2), Point2D(x: 0.8, y: 0.2), Point2D(x: 0.2, y: 0.8),
    ]
    let timing = try CalibrationTimingConfiguration(
        settleDuration: 1,
        collectDuration: 1,
        minimumSamplesPerTarget: 2
    )
    let plan = try CalibrationPlan(targets: targets, timing: timing)
    var engine = CalibrationEngine(
        plan: plan,
        profileKey: CalibrationProfileKey(sourceID: source, displayID: "main", setupID: "mount-a")
    )

    _ = try engine.startCalibration(at: 10)
    _ = try engine.consume(Point2D(x: 0, y: 0), at: 10.5)
    #expect(engine.state.sampleCount == 0)
    _ = try engine.consume(Point2D(x: 0, y: 0), at: 11)
    _ = try engine.consume(Point2D(x: 0, y: 0), at: 12)
    _ = try engine.consume(Point2D(x: 0.6, y: 0), at: 14)
    _ = try engine.consume(Point2D(x: 0.6, y: 0), at: 15)
    _ = try engine.consume(Point2D(x: 0, y: 0.6), at: 17)
    _ = try engine.consume(Point2D(x: 0, y: 0.6), at: 18)

    #expect(engine.phase == .calibrated)
    #expect(engine.profile?.key.sourceID == source)
    #expect(engine.profile?.quality.targetCount == 3)
    #expect(engine.profile?.quality.sampleCount == 6)

    #expect(throws: CalibrationEngineError.timeMovedBackward(lastObserved: 18, received: 17.5)) {
        try engine.startEvaluation(at: 17.5)
    }
}

@Test func calibrationProfileDatesUseWallClockInjectionNotMonotonicTime() throws {
    let timing = try CalibrationTimingConfiguration(settleDuration: 0, collectDuration: 1, minimumSamplesPerTarget: 1)
    let plan = try CalibrationPlan(
        targets: [Point2D(x: 0, y: 0), Point2D(x: 1, y: 0), Point2D(x: 0, y: 1)],
        timing: timing
    )
    let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
    var engine = CalibrationEngine(plan: plan, wallClock: { expectedDate })
    _ = try engine.startCalibration(at: 50_000)
    _ = try engine.consume(Point2D(x: 0, y: 0), at: 51_000)
    _ = try engine.consume(Point2D(x: 1, y: 0), at: 52_000)
    _ = try engine.consume(Point2D(x: 0, y: 1), at: 53_000)
    #expect(engine.profile?.createdAt == expectedDate)
    #expect(engine.profile?.updatedAt == expectedDate)
}

@Test func calibrationEngineEvaluationIsDeterministic() throws {
    let point = Point2D(x: 0.5, y: 0.5)
    let timing = try CalibrationTimingConfiguration(settleDuration: 0, collectDuration: 1, minimumSamplesPerTarget: 1)
    let plan = try CalibrationPlan(
        targets: [Point2D(x: 0.2, y: 0.2), Point2D(x: 0.8, y: 0.2), Point2D(x: 0.2, y: 0.8)],
        evaluationTargets: [point, Point2D(x: 0.8, y: 0.8)],
        timing: timing,
        evaluationHitRadius: 0.05
    )
    var engine = CalibrationEngine(plan: plan)
    _ = try engine.startCalibration(at: 0)
    _ = try engine.consume(Point2D(x: 0, y: 0), at: 1)
    _ = try engine.consume(Point2D(x: 1, y: 0), at: 2)
    _ = try engine.consume(Point2D(x: 0, y: 1), at: 3)
    #expect(engine.phase == .calibrated)

    _ = try engine.startEvaluation(at: 5)
    _ = try engine.consume(point, at: 6)
    _ = try engine.consume(Point2D(x: 1, y: 1), at: 7)
    #expect(engine.phase == .complete)
    #expect(engine.state.evaluationHits == 2)
}

@Test func canonicalFrameIngestionAppliesValidityConfidenceAndIdentityGates() throws {
    let timing = try CalibrationTimingConfiguration(settleDuration: 0, collectDuration: 1, minimumSamplesPerTarget: 1)
    let plan = try CalibrationPlan(
        targets: [Point2D(x: 0, y: 0), Point2D(x: 1, y: 0), Point2D(x: 0, y: 1)],
        timing: timing
    )
    let key = CalibrationProfileKey(sourceID: GazeSourceID("phone"), displayID: "main", setupID: "mount")
    var engine = CalibrationEngine(plan: plan, profileKey: key)
    _ = try engine.startCalibration(at: 0)

    #expect(throws: CalibrationEngineError.invalidFrameValidity(.lowConfidence)) {
        try engine.consume(canonicalFrame(validity: .lowConfidence))
    }
    #expect(throws: CalibrationEngineError.closedBlink) {
        try engine.consume(canonicalFrame(blink: .closed))
    }
    #expect(throws: CalibrationEngineError.insufficientConfidence(received: 0.49, minimum: 0.5)) {
        try engine.consume(canonicalFrame(confidence: 0.49))
    }
    #expect(throws: CalibrationEngineError.nonFiniteConfidence) {
        try engine.consume(canonicalFrame(confidence: .nan))
    }
    #expect(throws: CalibrationEngineError.sourceMismatch(expected: "phone", received: "other")) {
        try engine.consume(canonicalFrame(sourceID: "other"))
    }
    #expect(throws: CalibrationEngineError.coordinateSpaceMismatch(expected: .source, received: .displayNormalized)) {
        try engine.consume(canonicalFrame(coordinateSpace: .displayNormalized))
    }
    #expect(throws: CalibrationEngineError.nonFinitePoint) {
        try engine.consume(canonicalFrame(point: Point2D(x: .infinity, y: 0)))
    }

    _ = try engine.consume(canonicalFrame())
    #expect(engine.state.sampleCount == 1)
}

@Test func calibrationEngineRestoresValidatedProfileWithoutDerivingMonotonicTime() throws {
    let timing = try CalibrationTimingConfiguration(settleDuration: 0, collectDuration: 1, minimumSamplesPerTarget: 1)
    let plan = try CalibrationPlan(
        targets: [Point2D(x: 0, y: 0), Point2D(x: 1, y: 0), Point2D(x: 0, y: 1)],
        evaluationTargets: [Point2D(x: 0.5, y: 0.5)],
        timing: timing
    )
    let key = CalibrationProfileKey(sourceID: "phone", displayID: "main", setupID: "mount")
    var original = CalibrationEngine(plan: plan, profileKey: key)
    _ = try original.startCalibration(at: 100)
    _ = try original.consume(Point2D(x: 0, y: 0), at: 101)
    _ = try original.consume(Point2D(x: 1, y: 0), at: 102)
    _ = try original.consume(Point2D(x: 0, y: 1), at: 103)
    let profile = try #require(original.profile)

    var restored = try CalibrationEngine(plan: plan, profile: profile)
    #expect(restored.phase == .calibrated)
    #expect(restored.profile == profile)
    _ = try restored.startEvaluation(at: 1)
    #expect(restored.phase == .evaluating)

    var futureVersion = profile
    futureVersion.version = 99
    #expect(throws: CalibrationEngineError.invalidProfile(
        .unsupportedVersion(received: 99, supported: CalibrationProfile.currentVersion)
    )) {
        try restored.restore(futureVersion)
    }

    var alteredKey = profile
    alteredKey.key = CalibrationProfileKey(sourceID: "other", displayID: "main", setupID: "mount")
    #expect(throws: CalibrationEngineError.invalidProfile(.keyMismatch)) {
        try restored.restore(alteredKey)
    }

    var nonFinite = profile
    nonFinite.baseTransform = AffineTransform2D(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    #expect(throws: CalibrationEngineError.invalidProfile(.nonFiniteMapping)) {
        try restored.restore(nonFinite)
    }
}
