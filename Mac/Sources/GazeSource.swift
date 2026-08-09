import Foundation
import GazeCore

/// Events emitted by a source at the edge of the Mac gaze pipeline.
///
/// Consumers receive canonical frames only.  Transport-specific packets and
/// vendor SDK values are decoded before an event crosses this boundary.
public enum GazeSourceEvent: Equatable, Sendable {
    case started
    case stopped
    case frame(CanonicalGazeFrame)
    case freshnessChanged(Bool)
    case waiting(String)
    case rejected(String)
    case failed(String)
}

public typealias GazeSourceEventHandler = @MainActor @Sendable (GazeSourceEvent) -> Void

/// A source adapter owns its transport and emits source-independent frames.
/// The protocol is main-actor isolated deliberately: source selection and
/// callbacks are serialized with application state, while Network.framework
/// callbacks hop to the main actor at the edge.
@MainActor
public protocol GazeSource: AnyObject {
    var descriptor: GazeSourceDescriptor { get }
    var isRunning: Bool { get }
    func start(handler: @escaping GazeSourceEventHandler)
    func stop()
    func resetTransientState()
}

/// Type erasure used by the manager's source inventory.
@MainActor
public final class AnyGazeSource: GazeSource {
    public let descriptor: GazeSourceDescriptor

    private let startImpl: (@escaping GazeSourceEventHandler) -> Void
    private let stopImpl: () -> Void
    private let resetImpl: () -> Void
    private let runningImpl: () -> Bool

    public init<S: GazeSource>(_ source: S) {
        descriptor = source.descriptor
        startImpl = { handler in source.start(handler: handler) }
        stopImpl = { source.stop() }
        resetImpl = { source.resetTransientState() }
        runningImpl = { source.isRunning }
    }

    public var isRunning: Bool { runningImpl() }
    public func start(handler: @escaping GazeSourceEventHandler) { startImpl(handler) }
    public func stop() { stopImpl() }
    public func resetTransientState() { resetImpl() }
}

public enum GazeSourceManagerError: Error, Equatable, Sendable {
    case duplicateSource(GazeSourceID)
    case sourceNotFound(GazeSourceID)
}

/// Owns the one-active-source invariant.  Registering a source never starts
/// it; selecting one is always an explicit caller action.  The manager stops
/// the old source and clears frame/freshness state before starting the new one,
/// and ignores late events from a source that is no longer active.
@MainActor
public final class GazeSourceManager {
    public private(set) var sources: [GazeSourceDescriptor] = []
    public private(set) var activeSourceID: GazeSourceID?
    public private(set) var latestFrame: CanonicalGazeFrame?
    public private(set) var isFresh = false
    public private(set) var lastError: String?
    public var eventHandler: (@MainActor @Sendable (GazeSourceEvent) -> Void)?

    private var sourceByID: [GazeSourceID: AnyGazeSource] = [:]

    public var activeSource: GazeSourceDescriptor? {
        guard let activeSourceID else { return nil }
        return sourceByID[activeSourceID]?.descriptor
    }

    public init() {}

    public func register<S: GazeSource>(_ source: S) throws {
        let erased = AnyGazeSource(source)
        let id = erased.descriptor.sourceID
        guard id.isValid, sourceByID[id] == nil else {
            throw GazeSourceManagerError.duplicateSource(id)
        }
        sourceByID[id] = erased
        sources = sourceByID.values.map(\.descriptor).sorted { $0.sourceID.rawValue < $1.sourceID.rawValue }
    }

    public func registerSource<S: GazeSource>(_ source: S) throws {
        try register(source)
    }

    public func unregister(sourceID: GazeSourceID) throws {
        guard let source = sourceByID.removeValue(forKey: sourceID) else {
            throw GazeSourceManagerError.sourceNotFound(sourceID)
        }
        if activeSourceID == sourceID {
            source.stop()
            source.resetTransientState()
            activeSourceID = nil
            clearTransientState()
        }
        sources = sourceByID.values.map(\.descriptor).sorted { $0.sourceID.rawValue < $1.sourceID.rawValue }
    }

    /// Explicitly selects and starts one source.  There is intentionally no
    /// fallback or automatic selection when a source stops or fails.
    @discardableResult
    public func select(sourceID: GazeSourceID) throws -> Bool {
        guard let source = sourceByID[sourceID] else {
            throw GazeSourceManagerError.sourceNotFound(sourceID)
        }
        if activeSourceID == sourceID {
            return false
        }

        if let oldID = activeSourceID, let old = sourceByID[oldID] {
            old.stop()
            old.resetTransientState()
        }
        clearTransientState()
        activeSourceID = sourceID
        source.start { [weak self, weak source] event in
            guard let self, let source, self.activeSourceID == source.descriptor.sourceID else { return }
            self.handle(event)
        }
        return true
    }

    @discardableResult
    public func selectSource(sourceID: GazeSourceID) throws -> Bool {
        try select(sourceID: sourceID)
    }

    public func stopActive() {
        guard let id = activeSourceID, let source = sourceByID[id] else { return }
        source.stop()
        source.resetTransientState()
        activeSourceID = nil
        clearTransientState()
    }

    public func source(sourceID: GazeSourceID) -> AnyGazeSource? { sourceByID[sourceID] }

    private func clearTransientState() {
        latestFrame = nil
        isFresh = false
        lastError = nil
    }

    private func handle(_ event: GazeSourceEvent) {
        eventHandler?(event)
        switch event {
        case .frame(let frame):
            latestFrame = frame
            isFresh = true
        case .freshnessChanged(let fresh):
            isFresh = fresh
        case .failed(let error), .rejected(let error):
            lastError = error
        case .started, .stopped, .waiting:
            break
        }
    }
}

/// Deterministic in-memory source for tests and local integration previews.
@MainActor
public final class FakeGazeSource: GazeSource {
    public let descriptor: GazeSourceDescriptor
    public private(set) var isRunning = false
    private var handler: GazeSourceEventHandler?

    public init(
        sourceID: GazeSourceID = "fake-gaze",
        displayName: String = "Fake gaze source",
        capabilities: GazeSourceCapabilities = [.eyeTracking, .sourceCoordinates]
    ) {
        descriptor = GazeSourceDescriptor(
            sourceID: sourceID,
            kind: .custom("fake"),
            displayName: displayName,
            capabilities: capabilities
        )
    }

    public func start(handler: @escaping GazeSourceEventHandler) {
        self.handler = handler
        guard !isRunning else { return }
        isRunning = true
        handler(.started)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        handler?(.stopped)
    }

    public func resetTransientState() {}

    public func emit(_ frame: CanonicalGazeFrame) {
        guard isRunning else { return }
        handler?(.frame(frame))
    }

    public func emit(_ event: GazeSourceEvent) {
        guard isRunning else { return }
        handler?(event)
    }
}

/// Narrow provider seam for a future Tobii SDK integration.  The default
/// loader is deliberately unavailable and carries no SDK or entitlements.
public protocol TobiiProviderLoader: AnyObject, Sendable {
    @MainActor func makeProvider() -> (any TobiiProvider)?
}

public protocol TobiiProvider: AnyObject, Sendable {
    @MainActor func start(handler: @escaping GazeSourceEventHandler)
    @MainActor func stop()
}

public final class UnavailableTobiiProviderLoader: TobiiProviderLoader, @unchecked Sendable {
    public init() {}
    @MainActor public func makeProvider() -> (any TobiiProvider)? { nil }
}

@MainActor
public final class TobiiSource: GazeSource {
    public let descriptor: GazeSourceDescriptor
    public private(set) var isRunning = false

    private let loader: any TobiiProviderLoader
    private var provider: (any TobiiProvider)?
    private var handler: GazeSourceEventHandler?

    public init(
        sourceID: GazeSourceID = "tobii",
        displayName: String = "Tobii eye tracker",
        loader: any TobiiProviderLoader = UnavailableTobiiProviderLoader()
    ) {
        descriptor = GazeSourceDescriptor(
            sourceID: sourceID,
            kind: .tobii,
            displayName: displayName,
            capabilities: [.eyeTracking, .displayNormalizedCoordinates, .blinkDetection]
        )
        self.loader = loader
    }

    public func start(handler: @escaping GazeSourceEventHandler) {
        self.handler = handler
        guard !isRunning else { return }
        guard let provider = loader.makeProvider() else {
            handler(.failed("Tobii provider unavailable"))
            return
        }
        self.provider = provider
        isRunning = true
        handler(.started)
        provider.start(handler: handler)
    }

    public func stop() {
        provider?.stop()
        provider = nil
        if isRunning { handler?(.stopped) }
        isRunning = false
    }

    public func resetTransientState() {}
}
