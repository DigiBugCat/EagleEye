import Foundation
import GazeCore

/// The physical source/display arrangement used by a calibration session.
public struct CalibrationContext: Equatable, Sendable {
    public let profileKey: CalibrationProfileKey
    public let coordinateSpace: CalibrationCoordinateSpace

    public init(
        sourceID: GazeSourceID,
        displayID: String,
        setupID: String,
        coordinateSpace: CalibrationCoordinateSpace = .source
    ) {
        self.profileKey = CalibrationProfileKey(
            sourceID: sourceID,
            displayID: displayID,
            setupID: setupID
        )
        self.coordinateSpace = coordinateSpace
    }

    public init(profileKey: CalibrationProfileKey, coordinateSpace: CalibrationCoordinateSpace = .source) {
        self.profileKey = profileKey
        self.coordinateSpace = coordinateSpace
    }

    public var sourceID: GazeSourceID { profileKey.sourceID }
    public var displayID: String { profileKey.displayID }
    public var setupID: String { profileKey.setupID }

    public var isValid: Bool { profileKey.isValid }
}

public enum CalibrationPauseReason: Equatable, Sendable {
    case user
    case contextChanged
}

public enum CalibrationCoordinatorError: Error, Equatable, Sendable {
    case contextNotConfigured
    case invalidContext
    case noProfile
    case invalidAdjustment
    case paused
    case invalidStoredProfile(CalibrationEngineError)
    case engine(CalibrationEngineError)
}

/// An immutable projection suitable for SwiftUI, AppKit, or a source manager.
/// No engine or persistence implementation details are exposed.
public struct CalibrationCoordinatorSnapshot: Equatable, Sendable {
    public let context: CalibrationContext?
    public let phase: CalibrationEnginePhase
    public let mode: CalibrationEngineMode?
    public let target: Point2D?
    public let targetIndex: Int
    public let targetCount: Int
    public let sampleCount: Int
    public let trialIndex: Int
    public let trialCount: Int
    public let evaluationHits: Int
    public let profile: CalibrationProfile?
    public let mappedPoint: Point2D?
    public let isPaused: Bool
    public let error: CalibrationCoordinatorError?

    public init(
        context: CalibrationContext?,
        phase: CalibrationEnginePhase = .idle,
        mode: CalibrationEngineMode? = nil,
        target: Point2D? = nil,
        targetIndex: Int = 0,
        targetCount: Int = 0,
        sampleCount: Int = 0,
        trialIndex: Int = 0,
        trialCount: Int = 0,
        evaluationHits: Int = 0,
        profile: CalibrationProfile? = nil,
        mappedPoint: Point2D? = nil,
        isPaused: Bool = false,
        error: CalibrationCoordinatorError? = nil
    ) {
        self.context = context
        self.phase = phase
        self.mode = mode
        self.target = target
        self.targetIndex = targetIndex
        self.targetCount = targetCount
        self.sampleCount = sampleCount
        self.trialIndex = trialIndex
        self.trialCount = trialCount
        self.evaluationHits = evaluationHits
        self.profile = profile
        self.mappedPoint = mappedPoint
        self.isPaused = isPaused
        self.error = error
    }
}

public enum CalibrationCoordinatorEvent: Equatable, Sendable {
    case contextChanged(previous: CalibrationContext?, current: CalibrationContext)
    case paused(reason: CalibrationPauseReason)
    case resumed
    case profileLoaded(CalibrationProfile)
    case profileSaved(CalibrationProfile)
    case profileRemoved(CalibrationProfileKey)
    case engine(CalibrationEngineEvent)
    case snapshotChanged(CalibrationCoordinatorSnapshot)
    case error(CalibrationCoordinatorError)
}

/// UI-independent application layer around `CalibrationEngine`.
///
/// Calls are synchronous and deterministic.  `clock` is monotonic and is
/// used for lifecycle transitions and silent advancement; frame timestamps
/// remain the canonical source timeline consumed by `CalibrationEngine`.
public final class CalibrationCoordinator: @unchecked Sendable {
    public typealias MonotonicClock = @Sendable () -> TimeInterval
    public typealias EventStream = AsyncStream<CalibrationCoordinatorEvent>

    public let plan: CalibrationPlan
    public let profileStore: CalibrationProfileStore

    public private(set) var snapshot: CalibrationCoordinatorSnapshot
    public private(set) var lastEvents: [CalibrationCoordinatorEvent] = []

    private let clock: MonotonicClock
    private let wallClock: @Sendable () -> Date
    private var context: CalibrationContext?
    private var profile: CalibrationProfile?
    private var engine: CalibrationEngine?
    private var continuations: [UUID: EventStream.Continuation] = [:]

    public init(
        plan: CalibrationPlan = .standard,
        profileStore: CalibrationProfileStore = InMemoryCalibrationProfileStore(),
        clock: @escaping MonotonicClock = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.plan = plan
        self.profileStore = profileStore
        self.clock = clock
        self.wallClock = wallClock
        self.snapshot = CalibrationCoordinatorSnapshot(context: nil)
    }

    public var activeContext: CalibrationContext? { context }
    public var activeProfile: CalibrationProfile? { profile }

    /// Creates a stream of all subsequent coordinator events.
    public func events() -> EventStream {
        let id = UUID()
        return EventStream { [weak self] continuation in
            self?.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    public func makeEventStream() -> EventStream { events() }

    @discardableResult
    public func setContext(_ newContext: CalibrationContext) throws -> [CalibrationCoordinatorEvent] {
        guard newContext.isValid else {
            let error = CalibrationCoordinatorError.invalidContext
            _ = publish([.error(error)], error: error)
            throw error
        }

        let previous = context
        let changed = previous != newContext
        if !changed {
            return publish([.snapshotChanged(snapshot)])
        }
        context = newContext
        do {
            try rebuildEngine()
        } catch let error as CalibrationCoordinatorError {
            context = previous
            throw error
        }

        var events: [CalibrationCoordinatorEvent] = []
        if changed {
            events.append(.contextChanged(previous: previous, current: newContext))
            if previous != nil {
                events.append(.paused(reason: .contextChanged))
            }
        }
        if let profile {
            events.append(.profileLoaded(profile))
        }
        snapshot = makeSnapshot(paused: changed && previous != nil)
        events.append(.snapshotChanged(snapshot))
        return publish(events)
    }

    @discardableResult
    public func setContext(
        sourceID: GazeSourceID,
        displayID: String,
        setupID: String,
        coordinateSpace: CalibrationCoordinateSpace = .source
    ) throws -> [CalibrationCoordinatorEvent] {
        try setContext(CalibrationContext(
            sourceID: sourceID,
            displayID: displayID,
            setupID: setupID,
            coordinateSpace: coordinateSpace
        ))
    }

    @discardableResult
    public func startCalibration() throws -> [CalibrationCoordinatorEvent] {
        try startCalibration(at: clock())
    }

    @discardableResult
    public func startCalibration(at timestamp: TimeInterval) throws -> [CalibrationCoordinatorEvent] {
        guard context != nil, var engine else { throw CalibrationCoordinatorError.contextNotConfigured }
        do {
            let events = try engine.startCalibration(at: timestamp)
            self.engine = engine
            profile = nil
            snapshot = makeSnapshot(paused: false)
            return publish(engineEvents(events))
        } catch let error as CalibrationEngineError {
            return try fail(error)
        }
    }

    @discardableResult
    public func startEvaluation() throws -> [CalibrationCoordinatorEvent] {
        try startEvaluation(at: clock())
    }

    @discardableResult
    public func startEvaluation(at timestamp: TimeInterval) throws -> [CalibrationCoordinatorEvent] {
        guard context != nil, var engine else { throw CalibrationCoordinatorError.contextNotConfigured }
        guard profile != nil else { throw CalibrationCoordinatorError.noProfile }
        do {
            let events = try engine.startEvaluation(at: timestamp)
            self.engine = engine
            snapshot = makeSnapshot(paused: false)
            return publish(engineEvents(events))
        } catch let error as CalibrationEngineError {
            return try fail(error)
        }
    }

    @discardableResult
    public func consume(_ frame: CanonicalGazeFrame) throws -> [CalibrationCoordinatorEvent] {
        guard context != nil, var engine else { throw CalibrationCoordinatorError.contextNotConfigured }
        guard !snapshot.isPaused else { throw CalibrationCoordinatorError.paused }
        do {
            let events = try engine.consume(frame)
            self.engine = engine
            let mapped = profile?.apply(to: frame.point)
            return publish(engineEvents(events, mappedPoint: mapped))
        } catch let error as CalibrationEngineError {
            return try fail(error)
        }
    }

    @discardableResult
    public func advance() throws -> [CalibrationCoordinatorEvent] {
        try advance(to: clock())
    }

    @discardableResult
    public func advance(to timestamp: TimeInterval) throws -> [CalibrationCoordinatorEvent] {
        guard context != nil, var engine else { throw CalibrationCoordinatorError.contextNotConfigured }
        guard !snapshot.isPaused else { throw CalibrationCoordinatorError.paused }
        do {
            let events = try engine.advance(to: timestamp)
            self.engine = engine
            return publish(engineEvents(events))
        } catch let error as CalibrationEngineError {
            return try fail(error)
        }
    }

    @discardableResult
    public func pause() throws -> [CalibrationCoordinatorEvent] {
        guard context != nil else { throw CalibrationCoordinatorError.contextNotConfigured }
        try rebuildEngine()
        let events: [CalibrationCoordinatorEvent] = [.paused(reason: .user), .snapshotChanged(makeSnapshot(paused: true))]
        return publish(events, paused: true)
    }

    @discardableResult
    public func resume() throws -> [CalibrationCoordinatorEvent] {
        guard context != nil else { throw CalibrationCoordinatorError.contextNotConfigured }
        snapshot = makeSnapshot(paused: false)
        return publish([.resumed, .snapshotChanged(snapshot)])
    }

    /// Resets the current session while retaining the stored profile.
    @discardableResult
    public func reset() throws -> [CalibrationCoordinatorEvent] {
        guard context != nil else { throw CalibrationCoordinatorError.contextNotConfigured }
        try rebuildEngine()
        snapshot = makeSnapshot(paused: false)
        return publish([.snapshotChanged(snapshot)])
    }

    @discardableResult
    public func removeCalibrationProfile() throws -> [CalibrationCoordinatorEvent] {
        guard let context else { throw CalibrationCoordinatorError.contextNotConfigured }
        profileStore.removeProfile(for: context.profileKey)
        profile = nil
        try rebuildEngine()
        let events: [CalibrationCoordinatorEvent] = [
            .profileRemoved(context.profileKey),
            .snapshotChanged(makeSnapshot()),
        ]
        return publish(events)
    }

    @discardableResult
    public func applyFineAdjustment(_ adjustment: FineAdjustment) throws -> [CalibrationCoordinatorEvent] {
        guard adjustment.isValid else { throw CalibrationCoordinatorError.invalidAdjustment }
        guard var profile else { throw CalibrationCoordinatorError.noProfile }
        profile.fineAdjustment = adjustment
        profile.updatedAt = wallClock()
        self.profile = profile
        profileStore.save(profile)
        return publish([.profileSaved(profile), .snapshotChanged(makeSnapshot())])
    }

    @discardableResult
    public func resetFineAdjustment() throws -> [CalibrationCoordinatorEvent] {
        try applyFineAdjustment(.identity)
    }

    private func rebuildEngine() throws {
        guard let context else {
            engine = nil
            profile = nil
            return
        }
        if let stored = profileStore.profile(for: context.profileKey) {
            do {
                engine = try CalibrationEngine(
                    plan: plan,
                    profile: stored,
                    wallClock: wallClock
                )
                profile = stored
            } catch let error as CalibrationEngineError {
                throw CalibrationCoordinatorError.invalidStoredProfile(error)
            }
        } else {
            engine = CalibrationEngine(
                plan: plan,
                profileKey: context.profileKey,
                coordinateSpace: context.coordinateSpace,
                wallClock: wallClock
            )
            profile = nil
        }
        snapshot = makeSnapshot(paused: false)
    }

    private func makeSnapshot(
        paused: Bool? = nil,
        mappedPoint: Point2D? = nil,
        errorOverride: CalibrationCoordinatorError? = nil
    ) -> CalibrationCoordinatorSnapshot {
        guard let engine else {
            return CalibrationCoordinatorSnapshot(
                context: context,
                profile: profile,
                isPaused: paused ?? false,
                error: errorOverride
            )
        }
        let state = engine.state
        return CalibrationCoordinatorSnapshot(
            context: context,
            phase: state.phase,
            mode: state.mode,
            target: state.target,
            targetIndex: state.targetIndex,
            targetCount: state.targetCount,
            sampleCount: state.sampleCount,
            trialIndex: state.trialIndex,
            trialCount: state.trialCount,
            evaluationHits: state.evaluationHits,
            profile: profile,
            mappedPoint: mappedPoint,
            isPaused: paused ?? snapshot.isPaused,
            error: errorOverride ?? snapshot.error
        )
    }

    private func engineEvents(
        _ engineEvents: [CalibrationEngineEvent],
        mappedPoint: Point2D? = nil
    ) -> [CalibrationCoordinatorEvent] {
        var result = engineEvents.map(CalibrationCoordinatorEvent.engine)
        for event in engineEvents {
            if case let .calibrationCompleted(completedProfile) = event {
                profile = completedProfile
                profileStore.save(completedProfile)
                result.append(.profileSaved(completedProfile))
            }
        }
        snapshot = makeSnapshot(mappedPoint: mappedPoint)
        result.append(.snapshotChanged(snapshot))
        return result
    }

    private func fail(_ error: CalibrationEngineError) throws -> [CalibrationCoordinatorEvent] {
        let coordinatorError = CalibrationCoordinatorError.engine(error)
        snapshot = makeSnapshot(errorOverride: coordinatorError)
        _ = publish([.error(coordinatorError), .snapshotChanged(snapshot)])
        throw coordinatorError
    }

    @discardableResult
    private func publish(
        _ events: [CalibrationCoordinatorEvent],
        error: CalibrationCoordinatorError? = nil,
        paused: Bool? = nil
    ) -> [CalibrationCoordinatorEvent] {
        if let error {
            snapshot = makeSnapshot(paused: paused, errorOverride: error)
        } else if paused != nil {
            snapshot = makeSnapshot(paused: paused)
        }
        if !events.isEmpty { lastEvents = events }
        for event in events {
            continuations.values.forEach { _ = $0.yield(event) }
        }
        return events
    }
}
