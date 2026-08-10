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
        profileStore: InMemoryCalibrationProfileStore(),
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
    let coordinator = CalibrationCoordinator(plan: try testPlan(), profileStore: InMemoryCalibrationProfileStore())
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
    let testClock = TestClock(0)
    let coordinator = CalibrationCoordinator(
        plan: try testPlan(),
        profileStore: InMemoryCalibrationProfileStore(),
        clock: { testClock.uptime }
    )
    try coordinator.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    try coordinator.startCalibration(at: 0)
    testClock.uptime = 1
    try coordinator.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 0), uptime: 1, sequence: 1))
    testClock.uptime = 2
    try coordinator.consume(frame(sourceID: "phone-a", point: Point2D(x: 1, y: 0), uptime: 2, sequence: 2))
    testClock.uptime = 3
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
    let firstClock = TestClock(0)
    let first = CalibrationCoordinator(plan: try testPlan(), profileStore: store, clock: { firstClock.uptime })
    try first.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    try first.startCalibration(at: 0)
    firstClock.uptime = 1
    try first.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 0), uptime: 1, sequence: 1))
    firstClock.uptime = 2
    try first.consume(frame(sourceID: "phone-a", point: Point2D(x: 1, y: 0), uptime: 2, sequence: 2))
    firstClock.uptime = 3
    try first.consume(frame(sourceID: "phone-a", point: Point2D(x: 0, y: 1), uptime: 3, sequence: 3))

    let secondClock = TestClock(4)
    let second = CalibrationCoordinator(plan: try testPlan(), profileStore: store, clock: { secondClock.uptime })
    try second.setContext(sourceID: "phone-a", displayID: "main", setupID: "mount-a")
    #expect(second.snapshot.profile != nil)
    #expect(second.snapshot.phase == .calibrated)
    try second.startEvaluation(at: 4)
    secondClock.uptime = 5
    try second.consume(frame(sourceID: "phone-a", point: Point2D(x: 0.5, y: 0.5), uptime: 5, sequence: 1))
    #expect(second.snapshot.phase == .complete)
    #expect(second.snapshot.evaluationHits == 1)
}

@Test func recalibrationStartsFreshAndCancelRestoresLastSavedProfile() throws {
    let store = InMemoryCalibrationProfileStore()
    let testClock = TestClock(0)
    let coordinator = CalibrationCoordinator(
        plan: try testPlan(),
        profileStore: store,
        clock: { testClock.uptime }
    )
    let source: GazeSourceID = "phone-a"
    try coordinator.setContext(sourceID: source, displayID: "main", setupID: "mount-a")
    try coordinator.startCalibration()
    testClock.uptime = 1
    try coordinator.consume(frame(sourceID: source, point: Point2D(x: 0, y: 0), uptime: 1, sequence: 1))
    testClock.uptime = 2
    try coordinator.consume(frame(sourceID: source, point: Point2D(x: 1, y: 0), uptime: 2, sequence: 2))
    testClock.uptime = 3
    try coordinator.consume(frame(sourceID: source, point: Point2D(x: 0, y: 1), uptime: 3, sequence: 3))

    let savedProfile = try #require(coordinator.activeProfile)
    #expect(store.profile(for: savedProfile.key) == savedProfile)

    testClock.uptime = 4
    try coordinator.startCalibration()
    #expect(coordinator.snapshot.phase == .calibrating)
    #expect(coordinator.snapshot.targetIndex == 0)
    #expect(coordinator.snapshot.sampleCount == 0)
    // Recalibration is transactional: the last accepted profile remains active
    // until the replacement candidate passes independent validation.
    #expect(coordinator.snapshot.profile == savedProfile)
    #expect(store.profile(for: savedProfile.key) == savedProfile)

    try coordinator.reset()
    #expect(coordinator.snapshot.phase == .calibrated)
    #expect(coordinator.snapshot.profile == savedProfile)
}

@Test func menuBarStatusPrioritizesConnectionAndActiveWork() {
    #expect(EagleGazeMenuBarStatus.resolve(hasSource: false, isFresh: false, phase: .idle, hasProfile: false) == .needsPhone)
    #expect(EagleGazeMenuBarStatus.resolve(hasSource: true, isFresh: false, phase: .calibrating, hasProfile: false) == .waiting)
    #expect(EagleGazeMenuBarStatus.resolve(hasSource: true, isFresh: true, phase: .idle, hasProfile: false) == .connected)
    #expect(EagleGazeMenuBarStatus.resolve(hasSource: true, isFresh: true, phase: .calibrating, hasProfile: false) == .calibrating)
    #expect(EagleGazeMenuBarStatus.resolve(hasSource: true, isFresh: true, phase: .evaluating, hasProfile: true) == .evaluating)
    #expect(EagleGazeMenuBarStatus.resolve(hasSource: true, isFresh: true, phase: .complete, hasProfile: true) == .ready)
}
