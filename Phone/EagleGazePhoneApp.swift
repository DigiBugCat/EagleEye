import SwiftUI
import GazeCore
import OSLog
import UIKit

private let phoneLifecycleLog = Logger(subsystem: "com.aviary.EagleGazePhone", category: "lifecycle")

@main
struct EagleGazePhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhoneAppModel()

    var body: some Scene {
        WindowGroup {
            PhonePresentationRootView(model: model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleScenePhase(phase)
        }
    }
}

/// Small dependency seam so lifecycle behavior can be tested without a real
/// UIApplication. The timer remains disabled only while the phone stream is
/// active, keeping the camera capture alive during a foreground session.
@MainActor
protocol PhoneIdleTimerControlling: AnyObject {
    func setIdleTimerDisabled(_ disabled: Bool)
}

@MainActor
private final class UIApplicationIdleTimerController: PhoneIdleTimerControlling {
    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

/// Main-actor composition root for the phone.  It owns no ARKit or network
/// details: those are injected through the tracker, pipeline, sender, and the
/// pairing-session boundary. A saved pairing is the user's durable choice of
/// destination; every foreground launch derives a fresh encrypted session.
@MainActor
final class PhoneAppModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var streamSessionID: UUID?
    @Published private(set) var pairedReceivers: [PairedReceiver] = []
    @Published private(set) var selectedReceiver: PairedReceiver?
    @Published private(set) var streamStatus = "Pair a Mac to begin"
    @Published private(set) var pairingStatus = ""
    @Published private(set) var nearbyMacs: [PairingControlCandidate] = []
    @Published private(set) var pairingVerificationCode: String?
    @Published private(set) var isDiscoveringNearbyMacs = false
    @Published private(set) var isPairingNearbyMac = false
    @Published private(set) var authenticationNeedsRepair = false
    @Published var isNearbyPairingPresented = false

    let faceTracking: FaceTrackingService
    let sender: GazeSender
    let pipeline: PhoneGazePipeline
    let catalog: PairedReceiverCatalog
    let pairingSessionClient: PhonePairingSessionClient

    private let pairedStore: PairedReceiverStore
    private let identityStore: PhoneDeviceIdentityStore
    private let hasStableIdentity: Bool
    private let lifecycle: PhoneLifecycleCoordinator
    private var activeSession: GazeSessionMaterial?
    private var foregroundRequested = false
    private var sessionTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var pairingTask: Task<Void, Never>?
    private var receiverBeingRepaired: PairedReceiver?

    var isRepairingConnection: Bool { receiverBeingRepaired != nil }

    init(
        faceTracking: FaceTrackingService = FaceTrackingService(),
        sender: GazeSender = GazeSender(),
        pipeline: PhoneGazePipeline? = nil,
        idleTimer: PhoneIdleTimerControlling = UIApplicationIdleTimerController(),
        pairedStore: PairedReceiverStore? = nil,
        identityStore: PhoneDeviceIdentityStore? = nil,
        pairingSessionClient: PhonePairingSessionClient? = nil
    ) {
        self.faceTracking = faceTracking
        self.sender = sender
        let resolvedPairedStore = pairedStore ?? Self.makeDefaultPairedReceiverStore()
        self.pairedStore = resolvedPairedStore
        let resolvedIdentityStore = identityStore ?? Self.makeDefaultIdentityStore()
        self.identityStore = resolvedIdentityStore
        let identity = try? resolvedIdentityStore.loadOrCreate(displayName: "Eagle Gaze iPhone")
        self.hasStableIdentity = identity != nil
        let resolvedPipeline = pipeline ?? PhoneGazePipeline(
            sourceID: GazeSourceID(identity?.deviceID.uuidString.lowercased() ?? "identity-unavailable")
        )
        self.pipeline = resolvedPipeline
        self.catalog = PairedReceiverCatalog(store: resolvedPairedStore)
        self.pairingSessionClient = pairingSessionClient ?? Self.makeDefaultPairingSessionClient(
            identityStore: resolvedIdentityStore,
            receiverStore: resolvedPairedStore
        )

        // The event callback carries the ARSession generation. The pipeline
        // checks it again against its own stream generation before sequencing,
        // extracting, or forwarding a frame.
        faceTracking.onCaptureEvent = { [weak resolvedPipeline] event in
            resolvedPipeline?.ingest(event)
        }
        // The transport consumes only the canonical contract. Raw ARKit
        // matrices remain private to the pipeline's edge conversion.
        resolvedPipeline.onFrame = { [weak sender] frame in
            sender?.sendLatest(frame)
        }
        self.lifecycle = PhoneLifecycleCoordinator(
            tracker: faceTracking,
            sender: sender,
            pipeline: resolvedPipeline,
            idleTimer: idleTimer
        )

        sender.onRecoveryNeeded = { [weak self] detail in
            self?.scheduleAutomaticRecovery(reason: detail)
        }
        refreshCatalog()
    }

    /// Scene lifecycle entry point. `.inactive` intentionally does nothing;
    /// backgrounding invalidates the camera and authenticated stream.
    func handleScenePhase(_ phase: ScenePhase) {
        phoneLifecycleLog.info("Scene phase changed phase=\(String(describing: phase), privacy: .public)")
        switch phase {
        case .active:
            foregroundRequested = true
            recoveryAttempt = 0
            start()
        case .inactive:
            break
        case .background:
            foregroundRequested = false
            stop()
        @unknown default:
            foregroundRequested = false
            stop()
        }
    }

    /// Requests a foreground stream. A saved receiver is authenticated with a
    /// fresh session before TrueDepth frame production begins.
    func start() {
        guard foregroundRequested || !isRunning else { return }
        foregroundRequested = true
        guard let receiver = selectedReceiver else {
            phoneLifecycleLog.info("Stream start gated reason=no-selected-receiver")
            streamStatus = pairedReceivers.count > 1
                ? "Choose which paired Mac should receive gaze"
                : "Pair a Mac to begin"
            return
        }
        guard hasStableIdentity else {
            phoneLifecycleLog.error("Stream start gated reason=identity-unavailable")
            streamStatus = "Waiting for a protected phone identity before streaming"
            return
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        sessionTask?.cancel()
        activeSession = nil
        authenticationNeedsRepair = false
        lifecycle.prepareForSessionReplacement()
        sender.clearReceiverSelection()
        isRunning = lifecycle.isRunning
        streamSessionID = lifecycle.streamSessionID
        streamStatus = "Waiting for a fresh authenticated session…"
        phoneLifecycleLog.info("Stream authentication requested receiver=\(receiver.displayName, privacy: .public)")
        // Bonjour discovery may run while the control handshake is pending,
        // but no gaze frames are accepted until sender selection succeeds.
        sender.start()
        sessionTask = Task { @MainActor [weak self, receiver] in
            guard let self else { return }
            do {
                let requestedSessionID = UUID()
                // The client owns nonce exchange and authentication. No
                // random or cached values are accepted at this boundary.
                let session = try await self.pairingSessionClient.establishSession(
                    for: receiver,
                    sessionID: requestedSessionID
                )
                guard self.foregroundRequested,
                      self.selectedReceiver?.pairID == receiver.pairID,
                      session.sessionID == requestedSessionID
                else { return }
                // The authenticated control exchange proves which Mac is
                // trusted. Refresh the separate UDP Bonjour browse now so an
                // endpoint cached from a previous Mac process cannot win.
                self.sender.restartDiscovery()
                var discovered: DiscoveredGazeReceiver?
                for _ in 0..<50 {
                    let candidates = self.sender.discoveredReceivers.values.filter {
                        $0.receiverFingerprint == receiver.receiverFingerprint
                    }
                    if candidates.count == 1 {
                        discovered = candidates[0]
                        break
                    }
                    if candidates.count > 1 {
                        phoneLifecycleLog.warning("Waiting for stale duplicate gaze receivers to expire count=\(candidates.count, privacy: .public)")
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let discovered else {
                    throw PhonePairingSessionError.noAuthenticatedSession
                }
                try self.sender.selectReceiver(
                    id: discovered.id,
                    receiverFingerprint: receiver.receiverFingerprint,
                    session: session
                )
                self.activeSession = session
                self.lifecycle.start(sessionID: requestedSessionID)
                self.isRunning = self.lifecycle.isRunning
                self.streamSessionID = self.lifecycle.streamSessionID
                self.streamStatus = "Ready — sending canonical gaze status to \(receiver.displayName)"
                self.authenticationNeedsRepair = false
                self.recoveryAttempt = 0
                self.recoveryTask?.cancel()
                self.recoveryTask = nil
                phoneLifecycleLog.notice("Authenticated gaze session active receiver=\(receiver.displayName, privacy: .public) session=\(requestedSessionID.uuidString.prefix(8), privacy: .public)")
            } catch {
                self.activeSession = nil
                self.isRunning = false
                self.streamSessionID = nil
                self.authenticationNeedsRepair = false
                self.streamStatus = "Reconnecting securely to \(receiver.displayName)…"
                phoneLifecycleLog.error("Gaze session authentication failed receiver=\(receiver.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.scheduleAutomaticRecovery(reason: error.localizedDescription)
            }
        }
    }

    /// Stops camera and network work and invalidates queued frames. Calling
    /// this more than once is safe and still leaves the idle timer enabled.
    func stop() {
        phoneLifecycleLog.info("Stream stopping")
        sessionTask?.cancel()
        sessionTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempt = 0
        pairingTask?.cancel()
        activeSession = nil
        lifecycle.stop()
        isRunning = lifecycle.isRunning
        streamSessionID = lifecycle.streamSessionID
        sender.clearReceiverSelection()
        streamStatus = "Stream paused until a fresh authenticated session is available"
    }

    func refreshCatalog() {
        do {
            pairedReceivers = try catalog.receivers()
            if let selectedReceiver,
               pairedReceivers.contains(where: { $0.pairID == selectedReceiver.pairID }) {
                return
            }
            switch try catalog.selection() {
            case .selected(let receiver): select(receiver: receiver)
            case .none, .requiresChoice: break
            }
        } catch {
            pairingStatus = "Could not read paired Macs"
        }
    }

    func select(receiver: PairedReceiver) {
        guard pairedReceivers.contains(where: { $0.pairID == receiver.pairID }) else { return }
        if selectedReceiver?.pairID != receiver.pairID {
            sessionTask?.cancel()
            activeSession = nil
            sender.clearReceiverSelection()
            if isRunning { lifecycle.stop() }
            isRunning = lifecycle.isRunning
            streamSessionID = lifecycle.streamSessionID
        }
        selectedReceiver = receiver
        authenticationNeedsRepair = false
        phoneLifecycleLog.info("Receiver selected name=\(receiver.displayName, privacy: .public)")
        if foregroundRequested { start() }
    }

    func revoke(receiver: PairedReceiver) {
        stop()
        do {
            try catalog.revoke(pairID: receiver.pairID)
            if selectedReceiver?.pairID == receiver.pairID { selectedReceiver = nil }
            refreshCatalog()
            pairingStatus = "Revoked \(receiver.displayName)"
        } catch {
            pairingStatus = "Could not revoke \(receiver.displayName)"
        }
    }

    func refreshNearbyMacs() {
        guard !isDiscoveringNearbyMacs, !isPairingNearbyMac else { return }
        isDiscoveringNearbyMacs = true
        pairingStatus = "Looking for nearby Macs…"
        phoneLifecycleLog.info("User requested nearby Mac discovery")
        pairingTask?.cancel()
        pairingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                nearbyMacs = try await pairingSessionClient.discoverNearbyMacs()
                pairingStatus = nearbyMacs.isEmpty
                    ? "No EagleGaze Macs found on the nearby network"
                    : "Choose a Mac to pair"
            } catch {
                nearbyMacs = []
                pairingStatus = "Could not discover nearby Macs: \(error.localizedDescription)"
            }
            isDiscoveringNearbyMacs = false
        }
    }

    func pair(with candidate: PairingControlCandidate) {
        guard !isPairingNearbyMac else { return }
        isPairingNearbyMac = true
        pairingVerificationCode = nil
        pairingStatus = "Connecting to \(candidate.displayName)…"
        pairingTask?.cancel()
        pairingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receiver = try await pairingSessionClient.pair(
                    candidate: candidate,
                    displayName: "Eagle Gaze iPhone",
                    onVerificationCode: { [weak self] code in
                        self?.pairingVerificationCode = code
                        self?.pairingStatus = "Confirm this code on the Mac, then approve"
                    }
                )
                let replacedReceiver = receiverBeingRepaired
                if let replacedReceiver, replacedReceiver.pairID != receiver.pairID {
                    try catalog.revoke(pairID: replacedReceiver.pairID)
                    phoneLifecycleLog.notice("Saved pairing repaired old=\(replacedReceiver.displayName, privacy: .public) new=\(receiver.displayName, privacy: .public)")
                }
                receiverBeingRepaired = nil
                refreshCatalog()
                select(receiver: receiver)
                pairingStatus = "Paired \(receiver.displayName)"
                pairingVerificationCode = nil
                isNearbyPairingPresented = false
            } catch {
                pairingVerificationCode = nil
                pairingStatus = "Pairing failed: \(error.localizedDescription)"
                phoneLifecycleLog.error("Pairing failed candidate=\(candidate.displayName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
            isPairingNearbyMac = false
        }
    }

    func retryAuthentication() {
        phoneLifecycleLog.info("User requested authentication retry")
        recoveryAttempt = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        start()
    }

    func beginPairingRepair() {
        receiverBeingRepaired = selectedReceiver
        isNearbyPairingPresented = true
        pairingStatus = "Choose this Mac again to replace the saved connection"
        phoneLifecycleLog.notice("User began saved-pairing repair")
        refreshNearbyMacs()
    }

    func cancelNearbyPairing() {
        receiverBeingRepaired = nil
        isNearbyPairingPresented = false
        pairingVerificationCode = nil
        phoneLifecycleLog.info("Nearby pairing sheet dismissed")
    }

    private func scheduleAutomaticRecovery(reason: String) {
        guard foregroundRequested, selectedReceiver != nil, recoveryTask == nil else { return }
        guard recoveryAttempt < 5 else {
            authenticationNeedsRepair = true
            streamStatus = "Couldn’t reconnect automatically. Retry, or repair the saved Mac if its identity changed."
            phoneLifecycleLog.error("Automatic recovery exhausted reason=\(reason, privacy: .public)")
            return
        }
        let delayMilliseconds = min(8_000, 500 * (1 << recoveryAttempt))
        recoveryAttempt += 1
        phoneLifecycleLog.info("Automatic recovery scheduled attempt=\(self.recoveryAttempt, privacy: .public) delayMs=\(delayMilliseconds, privacy: .public) reason=\(reason, privacy: .public)")
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self, self.foregroundRequested else { return }
            self.recoveryTask = nil
            self.start()
        }
    }

    private static func makeDefaultPairedReceiverStore() -> PairedReceiverStore {
        #if canImport(Security)
        return KeychainPairedReceiverStore()
        #else
        return InMemoryPairedReceiverStore()
        #endif
    }

    private static func makeDefaultIdentityStore() -> PhoneDeviceIdentityStore {
        #if canImport(Security)
        return KeychainPhoneDeviceIdentityStore()
        #else
        return InMemoryPhoneDeviceIdentityStore()
        #endif
    }

    private static func makeDefaultPairingSessionClient(
        identityStore: PhoneDeviceIdentityStore,
        receiverStore: PairedReceiverStore
    ) -> PhonePairingSessionClient {
        #if canImport(Network)
        return PairingControlClient(
            identityStore: identityStore,
            receiverStore: receiverStore,
            transport: NetworkPairingControlTransport()
        )
        #else
        return UnavailablePhonePairingSessionClient()
        #endif
    }
}
