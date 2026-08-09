import SwiftUI
import GazeCore
import UIKit

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
/// pairing-session boundary.  In particular, a foreground transition never
/// starts ARKit until consent and a fresh authenticated session are present.
@MainActor
final class PhoneAppModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var streamSessionID: UUID?
    @Published private(set) var pairedReceivers: [PairedReceiver] = []
    @Published private(set) var selectedReceiver: PairedReceiver?
    @Published private(set) var consent: PhoneOffDeviceGazeConsent?
    @Published private(set) var streamStatus = "Pair a Mac to begin"
    @Published private(set) var pairingStatus = ""
    @Published var isPairingScannerPresented = false

    var hasConsentForSelectedReceiver: Bool {
        guard let receiver = selectedReceiver,
              consent?.destinationID == receiver.pairID.uuidString
        else { return false }
        return consentCoordinator.currentAuthorization?.destinationID == receiver.pairID.uuidString
    }

    let faceTracking: FaceTrackingService
    let sender: GazeSender
    let pipeline: PhoneGazePipeline
    let consentCoordinator: PhonePrivacyConsentCoordinator
    let catalog: PairedReceiverCatalog
    let pairingSessionClient: PhonePairingSessionClient
    private(set) var qrScanner: QRScannerCoordinator?

    private let pairedStore: PairedReceiverStore
    private let consentStore: PhonePrivacyConsentStore
    private let identityStore: PhoneDeviceIdentityStore
    private let hasStableIdentity: Bool
    private let lifecycle: PhoneLifecycleCoordinator
    private let offerParser = PairingOfferParser()
    private var activeSession: GazeSessionMaterial?
    private var foregroundRequested = false
    private var sessionTask: Task<Void, Never>?
    private var scannerPausedRunning = false

    init(
        faceTracking: FaceTrackingService = FaceTrackingService(),
        sender: GazeSender = GazeSender(),
        pipeline: PhoneGazePipeline? = nil,
        idleTimer: PhoneIdleTimerControlling = UIApplicationIdleTimerController(),
        pairedStore: PairedReceiverStore? = nil,
        consentStore: PhonePrivacyConsentStore = KeychainPhonePrivacyConsentStore(),
        identityStore: PhoneDeviceIdentityStore? = nil,
        pairingSessionClient: PhonePairingSessionClient? = nil,
        qrScannerBoundary: QRScannerBoundary? = nil
    ) {
        self.faceTracking = faceTracking
        self.sender = sender
        let resolvedPairedStore = pairedStore ?? Self.makeDefaultPairedReceiverStore()
        self.pairedStore = resolvedPairedStore
        self.consentStore = consentStore
        let resolvedIdentityStore = identityStore ?? Self.makeDefaultIdentityStore()
        self.identityStore = resolvedIdentityStore
        let identity = try? resolvedIdentityStore.loadOrCreate(displayName: "Eagle Gaze iPhone")
        self.hasStableIdentity = identity != nil
        let resolvedPipeline = pipeline ?? PhoneGazePipeline(
            sourceID: GazeSourceID(identity?.deviceID.uuidString.lowercased() ?? "identity-unavailable")
        )
        self.pipeline = resolvedPipeline
        self.catalog = PairedReceiverCatalog(store: resolvedPairedStore)
        self.consentCoordinator = PhonePrivacyConsentCoordinator(store: consentStore)
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

        if let scanner = qrScannerBoundary ?? Self.makeDefaultQRScanner() {
            let coordinator = QRScannerCoordinator(
                scanner: scanner,
                pauseARKit: { [weak self] in self?.pauseForPairingScanner() },
                resumeARKit: { [weak self] in self?.resumeAfterPairingScanner() }
            )
            self.qrScanner = coordinator
            coordinator.onPayload = { [weak self] payload in
                self?.handlePairingPayload(payload)
            }
        } else {
            self.qrScanner = nil
        }

        consentCoordinator.setRevocationHandler { [weak self] in
            Task { @MainActor in self?.stopForConsentRevocation() }
        }
        refreshCatalog()
        restoreConsent()
    }

    /// Scene lifecycle entry point. `.inactive` intentionally does nothing;
    /// backgrounding invalidates the camera and authenticated stream.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            foregroundRequested = true
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

    /// Requests a foreground stream. It is a no-op until a selected receiver,
    /// matching consent, and a fresh session material have all been obtained.
    func start() {
        guard foregroundRequested || !isRunning else { return }
        foregroundRequested = true
        guard let receiver = selectedReceiver else {
            streamStatus = pairedReceivers.count > 1
                ? "Choose which paired Mac should receive gaze"
                : "Pair a Mac to begin"
            return
        }
        guard hasStableIdentity else {
            streamStatus = "Waiting for a protected phone identity before streaming"
            return
        }
        guard (try? consentCoordinator.authorizeStreaming(to: receiver.pairID.uuidString)) != nil else {
            streamStatus = "Consent is required before gaze can leave this iPhone"
            return
        }

        sessionTask?.cancel()
        activeSession = nil
        streamStatus = "Waiting for a fresh authenticated session…"
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
                      self.consentCoordinator.currentAuthorization?.destinationID == receiver.pairID.uuidString,
                      session.sessionID == requestedSessionID
                else { return }
                var discovered: DiscoveredGazeReceiver?
                for _ in 0..<20 {
                    if let candidate = self.sender.discoveredReceivers.values.first(where: {
                        $0.receiverFingerprint == receiver.receiverFingerprint
                    }) {
                        discovered = candidate
                        break
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
            } catch {
                self.activeSession = nil
                self.isRunning = false
                self.streamSessionID = nil
                self.streamStatus = "Waiting for Mac authentication: \(error.localizedDescription)"
            }
        }
    }

    /// Stops camera and network work and invalidates queued frames. Calling
    /// this more than once is safe and still leaves the idle timer enabled.
    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        if qrScanner?.isScanning == true {
            qrScanner?.stop()
            isPairingScannerPresented = false
        }
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
        if (try? consentCoordinator.authorizeStreaming(to: receiver.pairID.uuidString)) == nil {
            streamStatus = "Consent is required before gaze can leave this iPhone"
        }
        if foregroundRequested { start() }
    }

    func grantConsentForSelectedReceiver() {
        guard let receiver = selectedReceiver else { return }
        do {
            let value = try PhoneOffDeviceGazeConsent(destinationID: receiver.pairID.uuidString)
            _ = try consentCoordinator.grant(value)
            consent = value
            streamStatus = "Consent saved for \(receiver.displayName)"
            if foregroundRequested { start() }
        } catch {
            streamStatus = "Could not save consent: \(error.localizedDescription)"
        }
    }

    func revokeConsent() {
        do { try consentCoordinator.revoke() }
        catch { streamStatus = "Consent revoked locally; storage reported an error" }
        consent = nil
        stopForConsentRevocation()
    }

    func revoke(receiver: PairedReceiver) {
        stop()
        do {
            try catalog.revoke(pairID: receiver.pairID)
            if selectedReceiver?.pairID == receiver.pairID { selectedReceiver = nil }
            refreshCatalog()
            if consent?.destinationID == receiver.pairID.uuidString { revokeConsent() }
            pairingStatus = "Revoked \(receiver.displayName)"
        } catch {
            pairingStatus = "Could not revoke \(receiver.displayName)"
        }
    }

    func presentPairingScanner() {
        guard qrScanner != nil else {
            pairingStatus = "QR scanning is unavailable on this device"
            return
        }
        isPairingScannerPresented = true
    }

    func startPairingScanner() throws {
        guard let qrScanner else { throw QRScannerError.cameraUnavailable }
        try qrScanner.start()
    }

    func stopPairingScanner() {
        qrScanner?.stop()
        isPairingScannerPresented = false
    }

    private func pauseForPairingScanner() {
        scannerPausedRunning = lifecycle.isRunning
        lifecycle.pauseForPresentation()
        isRunning = lifecycle.isRunning
        streamSessionID = lifecycle.streamSessionID
    }

    private func resumeAfterPairingScanner() {
        guard scannerPausedRunning else { return }
        scannerPausedRunning = false
        if foregroundRequested { start() }
    }

    private func handlePairingPayload(_ payload: String) {
        pairingStatus = "Validating Mac pairing offer…"
        do {
            let offer = try offerParser.parse(payload)
            pairingStatus = "Offer validated; waiting for authenticated Mac approval…"
            sessionTask?.cancel()
            sessionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let receiver = try await self.pairingSessionClient.pair(
                        offer: offer,
                        displayName: "Eagle Gaze iPhone"
                    )
                    // A returned receiver is proof the injected client has
                    // completed the transcript and Mac approval. The pairing
                    // client owns durable persistence; this root never stores
                    // QR text or a pre-authenticated record.
                    self.refreshCatalog()
                    self.select(receiver: receiver)
                    self.pairingStatus = "Paired \(receiver.displayName)"
                } catch {
                    self.pairingStatus = "Waiting for Mac pairing handshake: \(error.localizedDescription)"
                }
            }
        } catch {
            pairingStatus = "Invalid or expired pairing QR: \(error.localizedDescription)"
        }
    }

    private func restoreConsent() {
        // Load the disclosure for presentation only; authorization remains
        // destination-scoped and is rehydrated in start().
        consent = try? consentStore.load()
    }

    private func stopForConsentRevocation() {
        sessionTask?.cancel()
        activeSession = nil
        lifecycle.stop()
        sender.clearReceiverSelection()
        isRunning = false
        streamSessionID = nil
        streamStatus = "Consent is required before gaze can leave this iPhone"
    }

    private static func makeDefaultQRScanner() -> QRScannerBoundary? {
        #if canImport(AVFoundation)
        return AVFoundationQRScanner()
        #else
        return nil
        #endif
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
