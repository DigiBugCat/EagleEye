import Combine
import Foundation
import GazeCore

/// Compatibility façade for the original Mac UI.  New code should depend on
/// GazeSourceManager and consume CanonicalGazeFrame values; this façade keeps
/// the published counters and DEBUG-only GazeSample bridge while the UI is
/// migrated.
@MainActor
final class GazeReceiver: ObservableObject {
    enum ActivationError: Error, Equatable {
        case invalidSourceID
    }

    enum State: Equatable {
        case starting
        case advertising(port: UInt16)
        case waiting(String)
        case failed(String)
        case stopped

        var label: String {
            switch self {
            case .starting: return "Starting receiver…"
            case .advertising(let port): return "Listening on UDP \(port)"
            case .waiting(let detail): return "Waiting: \(detail)"
            case .failed(let detail): return "Receiver error: \(detail)"
            case .stopped: return "Receiver stopped"
            }
        }

        var isReady: Bool {
            if case .advertising = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var latestSample: GazeSample?
    @Published private(set) var latestFrame: CanonicalGazeFrame?
    @Published private(set) var isFresh = false
    @Published private(set) var acceptedPacketCount = 0
    @Published private(set) var rejectedPacketCount = 0
    @Published private(set) var decodeErrorCount = 0
    @Published private(set) var lastRejection: String?

    private(set) var source: ARKitNetworkSource
    let sourceManager: GazeSourceManager

    /// The source inventory is intentionally read-only here. Pairing or
    /// presentation code must call `activatePairedSource` to select one; a
    /// newly discovered packet can never replace the active adapter.
    var availableSources: [GazeSourceDescriptor] { sourceManager.sources }
    var selectedSourceID: GazeSourceID? { sourceManager.activeSourceID }
    var selectedSourceDescriptor: GazeSourceDescriptor? { sourceManager.activeSource }

    init() {
        source = ARKitNetworkSource()
        sourceManager = GazeSourceManager()
        #if DEBUG
        source.compatibilitySampleHandler = { [weak self] sample in
            self?.latestSample = sample
        }
        #endif
        sourceManager.eventHandler = { [weak self] event in self?.consume(event) }
        do {
            try sourceManager.register(source)
            // This is the one explicit source selection performed by the
            // application composition root. The manager never auto-switches.
            try sourceManager.select(sourceID: source.descriptor.sourceID)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func start() {
        guard !source.isRunning else { return }
        do {
            if sourceManager.activeSourceID == nil {
                try sourceManager.select(sourceID: source.descriptor.sourceID)
            } else {
                sourceManager.stopActive()
                try sourceManager.select(sourceID: source.descriptor.sourceID)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        sourceManager.stopActive()
        latestSample = nil
        latestFrame = nil
        isFresh = false
        state = .stopped
    }

    func restart() {
        stop()
        start()
    }

    /// Replaces the current ARKit adapter with one bound to an explicitly
    /// paired device/session. The old listener is stopped and unregistered
    /// before the new listener is started, so two adapters cannot overlap.
    /// Passing `nil` for the session is retained for DEBUG migration only;
    /// Release ingestion still rejects plaintext packets.
    func activatePairedSource(
        sourceID: GazeSourceID,
        displayName: String,
        secureSession: ARKitNetworkSource.SecureSession? = nil,
        receiverFingerprint: String? = nil
    ) throws {
        guard sourceID.isValid else { throw ActivationError.invalidSourceID }

        let oldID = source.descriptor.sourceID
        sourceManager.stopActive()
        if sourceManager.source(sourceID: oldID) != nil {
            try sourceManager.unregister(sourceID: oldID)
        }

        let replacement = ARKitNetworkSource(
            sourceID: sourceID,
            displayName: displayName,
            configuration: .init(
                secureSession: secureSession,
                receiverFingerprint: receiverFingerprint ?? ARKitNetworkSource.debugReceiverFingerprint
            )
        )
        #if DEBUG
        replacement.compatibilitySampleHandler = { [weak self] sample in
            self?.latestSample = sample
        }
        #endif
        source = replacement
        clearPublishedGazeState()
        try sourceManager.register(replacement)
        try sourceManager.select(sourceID: sourceID)
    }

    private func consume(_ event: GazeSourceEvent) {
        acceptedPacketCount = source.acceptedPacketCount
        rejectedPacketCount = source.rejectedPacketCount
        switch event {
        case .started:
            state = .advertising(port: source.listeningPort?.rawValue ?? 0)
        case .frame(let frame):
            latestFrame = frame
            isFresh = true
        case .freshnessChanged(let fresh):
            isFresh = fresh
        case .waiting(let detail):
            state = .waiting(detail)
        case .rejected(let reason):
            lastRejection = reason
            decodeErrorCount = source.rejectedPacketCount
        case .failed(let detail):
            state = .failed(detail)
        case .stopped:
            if state != .stopped { state = .stopped }
        }
    }

    private func clearPublishedGazeState() {
        latestSample = nil
        latestFrame = nil
        isFresh = false
        acceptedPacketCount = 0
        rejectedPacketCount = 0
        decodeErrorCount = 0
        lastRejection = nil
        state = .starting
    }
}
