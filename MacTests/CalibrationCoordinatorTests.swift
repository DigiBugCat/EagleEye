import Foundation
import Testing
import GazeCore
@testable import EagleGazeMac

private let testSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

private final class TestClock: @unchecked Sendable {
    var uptime: TimeInterval

    init(_ uptime: TimeInterval = 0) {
        self.uptime = uptime
    }
}

private func frame(
    sourceID: GazeSourceID,
    point: Point2D,
    uptime: TimeInterval,
    sequence: UInt64
) -> CanonicalGazeFrame {
    CanonicalGazeFrame(
        sourceID: sourceID,
        sourceSessionID: testSessionID,
        sequence: sequence,
        captureUptime: uptime,
        validity: .valid,
        confidence: 1,
        point: point,
        coordinateSpace: .source,
        blink: .open
    )
}

private func testPlan() throws -> CalibrationPlan {
    let timing = try CalibrationTimingConfiguration(
        settleDuration: 0,
        collectDuration: 1,
        minimumSamplesPerTarget: 1
    )
    return try CalibrationPlan(
        targets: [
            Point2D(x: 0, y: 0),
            Point2D(x: 1, y: 0),
            Point2D(x: 0, y: 1),
        ],
        evaluationTargets: [Point2D(x: 0.5, y: 0.5)],
        timing: timing,
        evaluationHitRadius: 0.05
    )
}

@Test func coordinatorUsesInjectedClockAndPersistsCompletedProfile() throws {
    let testClock = TestClock(10)
    let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let coordinator = CalibrationCoordinator(
        plan: try testPlan(),
        clock: { testClock.uptime },
        wallClock: { expectedDate }
    )
    let source: GazeSourceID = "phone-a"
    try coordinator.setContext(sourceID: source, displayID: "main", setupID: "mount-a")

    try coordinator.startCalibration()
    testClock.uptime = 11
    try coordinator.consume(frame(sourceID: source, point: Point2D(x: 0, y: 0), uptime: testClock.uptime, sequence: 1))
    testClock.uptime = 12
    try coordinator.consume(frame(sourceID: source, point: Point2D(x: 1, y: 0), uptime: testClock.uptime, sequence: 2))
    testClock.uptime = 13
    try coordinator.consume(frame(sourceID: source, point: Point2D(x: 0, y: 1), uptime: testClock.uptime, sequence: 3))

    #expect(coordinator.snapshot.phase == .calibrated)
    #expect(coordinator.activeProfile?.createdAt == expectedDate)
    #expect(coordinator.profileStore.profile(for: coordinator.activeProfile!.key) == coordinator.activeProfile)
}

@Test func contextChangeResetsAndPausesTheCurrentSession() throws {
    let coordinator = CalibrationCoordinator(plan: try testPlan())
    try coordinator.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    try coordinator.startCalibration(at: 0)
    #expect(coordinator.snapshot.phase == .calibrating)

    try coordinator.setContext(sourceID: "phone-b", displayID: "main", setupID: "mount-a")
    #expect(coordinator.snapshot.phase == .idle)
    #expect(coordinator.snapshot.isPaused)
    #expect(coordinator.activeProfile == nil)
    #expect(throws: CalibrationCoordinatorError.paused) {
        try coordinator.consume(frame(sourceID: "phone-b", point: Point2D(x: 0, y: 0), uptime: 1, sequence: 1))
    }

    try coordinator.resume()
    #expect(!coordinator.snapshot.isPaused)
}

@Test func fineAdjustmentIsAppliedAndResetWithoutChangingBaseMapping() throws {
    let coordinator = CalibrationCoordinator(plan: try testPlan())
    try coordinator.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    try coordinator.startCalibration(at: 0)
    try coordinator.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 0), uptime: 1, sequence: 1))
    try coordinator.consume(frame(sourceID: "phone-a", point: Point2D(x: 1, y: 0), uptime: 2, sequence: 2))
    try coordinator.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 1), uptime: 3, sequence: 3))

    let base = coordinator.activeProfile?.baseTransform
    try coordinator.applyFineAdjustment(FineAdjustment(scaleX: 1.1, scaleY: 0.9, offsetX: 0.02, offsetY: -0.01))
    #expect(coordinator.activeProfile?.baseTransform == base)
    #expect(coordinator.activeProfile?.fineAdjustment.scaleX == 1.1)

    try coordinator.resetFineAdjustment()
    #expect(coordinator.activeProfile?.baseTransform == base)
    #expect(coordinator.activeProfile?.fineAdjustment == .identity)
}

@Test func profileStoreRestoresProfileForEvaluation() throws {
    let store = InMemoryCalibrationProfileStore()
    let first = CalibrationCoordinator(plan: try testPlan(), profileStore: store)
    try first.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    try first.startCalibration(at: 0)
    try first.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 0), uptime: 1, sequence: 1))
    try first.consume(frame(sourceID: "phone-a", point: Point2D(x: 1, y: 0), uptime: 2, sequence: 2))
    try first.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 1), uptime: 3, sequence: 3))

    let second = CalibrationCoordinator(plan: try testPlan(), profileStore: store)
    try second.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    #expect(second.snapshot.profile != nil)
    #expect(second.snapshot.phase == .calibrated)
    try second.startEvaluation(at: 4)
    try second.consume(frame(sourceID: "phone-a", point: Point2D(x: 0.5, y: 0.5), uptime: 5, sequence: 1))
    #expect(second.snapshot.phase == .complete)
    #expect(second.snapshot.evaluationHits == 1)
}
