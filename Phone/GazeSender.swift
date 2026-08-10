import Combine
import Foundation
import GazeCore
import OSLog

private let gazeSenderLog = Logger(subsystem: "com.aviary.EagleGazePhone", category: "gaze-transport")

@MainActor
final class GazeSender: ObservableObject {
    @Published private(set) var status = "Select a paired Mac receiver"
    @Published private(set) var isConnected = false
    @Published private(set) var discoveredReceivers: [GazeReceiverID: DiscoveredGazeReceiver] = [:]
    @Published private(set) var selectedReceiverID: GazeReceiverID?
    var onRecoveryNeeded: (@MainActor @Sendable (String) -> Void)?

    private let transport: GazeTransportCoordinator

    init(
        browser: GazeReceiverBrowser? = nil,
        factory: GazeDatagramConnectionFactory? = nil
    ) {
        let browser = browser ?? NetworkGazeReceiverBrowser()
        let factory = factory ?? NetworkGazeDatagramConnectionFactory()
        let transport = GazeTransportCoordinator(browser: browser, factory: factory)
        self.transport = transport

        transport.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.isConnected = state == .ready
            switch state {
            case .ready:
                gazeSenderLog.notice("Authenticated gaze transport ready")
                self.status = "Streaming gaze to selected Mac"
            case .starting:
                self.status = self.selectedReceiverID == nil
                    ? "Select a paired Mac receiver"
                    : "Connecting to selected Mac receiver…"
            case .waiting(let detail):
                self.status = "Waiting for selected Mac: \(detail)"
                if self.selectedReceiverID != nil { self.onRecoveryNeeded?(detail) }
            case .failed(let detail):
                gazeSenderLog.error("Gaze transport failed detail=\(detail, privacy: .public)")
                self.status = "Mac connection failed: \(detail)"
                if self.selectedReceiverID != nil { self.onRecoveryNeeded?(detail) }
            case .cancelled:
                self.status = "Network streaming is paused"
            }
        }
        transport.onReceiversChanged = { [weak self] receivers in
            guard let self else { return }
            self.discoveredReceivers = receivers
            gazeSenderLog.debug("Gaze receiver discovery changed count=\(receivers.count, privacy: .public)")
        }
    }

    func start() {
        gazeSenderLog.info("Gaze receiver browser starting")
        transport.start()
        refreshSelectionState()
        if selectedReceiverID == nil {
            status = "Select a paired Mac receiver"
        }
    }

    func stop() {
        gazeSenderLog.info("Gaze transport stopping")
        transport.stop()
        isConnected = false
        status = "Network streaming is paused"
    }

    /// Re-browse after the Mac authenticates so a UDP service cached from an
    /// earlier Mac process cannot be selected merely because UDP reported a
    /// locally ready connection.
    func restartDiscovery() {
        gazeSenderLog.info("Gaze receiver discovery restarting after authentication")
        transport.restartDiscovery()
        refreshSelectionState()
    }

    /// Pairing composition must call this with the selected receiver and fresh
    /// session material. A discovered receiver is never chosen implicitly.
    func selectReceiver(
        id: GazeReceiverID,
        receiverFingerprint: String,
        session: GazeSessionMaterial
    ) throws {
        try transport.selectReceiver(
            id: id,
            receiverFingerprint: receiverFingerprint,
            session: session
        )
        selectedReceiverID = id
        gazeSenderLog.notice("Authenticated gaze receiver selected session=\(session.sessionID.uuidString.prefix(8), privacy: .public)")
        status = "Connecting to selected Mac receiver…"
    }

    /// Use when pairing has already retained a resolved endpoint.
    func selectReceiver(_ receiver: PairedGazeReceiver) {
        guard transport.selectReceiver(receiver) else {
            isConnected = false
            status = transport.lastError?.localizedDescription ?? "Receiver identity could not be verified"
            return
        }
        selectedReceiverID = receiver.receiverID
        status = "Connecting to selected Mac receiver…"
    }

    func clearReceiverSelection() {
        gazeSenderLog.info("Gaze receiver selection cleared")
        transport.clearSelection()
        selectedReceiverID = nil
        isConnected = false
        status = "Select a paired Mac receiver"
    }

    func sendLatest(_ frame: CanonicalGazeFrame) {
        transport.sendLatest(frame)
        if let error = transport.lastError {
            status = error.localizedDescription
        }
    }

    /// Existing ARKit code still produces the legacy GazeSample. This bridge
    /// is intentionally non-authenticated and only available as a DEBUG
    /// migration hook; release builds make the migration requirement explicit
    /// at compile time.
    #if DEBUG
    func sendLatest(_ sample: GazeSample) {
        guard transport.selectedReceiver != nil else {
            status = "Select a paired Mac receiver before debug streaming"
            return
        }
        do {
            transport.sendDebugLatest(try GazeDatagramCodec.encode(sample))
        } catch {
            status = "Could not encode a gaze sample: \(error.localizedDescription)"
        }
    }
    #else
    @available(*, unavailable, message: "Release transport accepts CanonicalGazeFrame with paired session material")
    func sendLatest(_ sample: GazeSample) { fatalError("legacy gaze samples are DEBUG-only") }
    #endif

    private func refreshSelectionState() {
        discoveredReceivers = transport.discoveredReceivers
        selectedReceiverID = transport.selectedReceiver?.receiverID
    }
}
