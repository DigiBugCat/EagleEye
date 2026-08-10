import Combine
import Foundation
import GazeCore
import GazeCropKit
import OSLog

private let macApplicationLog = Logger(subsystem: "com.aviary.EagleGazeMac", category: "application")

/// A source row that can be rendered without making an unavailable vendor
/// integration look selectable.  Keeping the Tobii row here makes the source
/// choice explicit while the adapter is still a future integration.
struct GazeSourceOption: Identifiable, Equatable {
    let id: GazeSourceID
    let title: String
    let subtitle: String
    let kind: GazeSourceKind
    let isAvailable: Bool
    let capabilities: GazeSourceCapabilities
}

/// A Sendable callback box lets PairingControlServer (which owns a Network
/// queue) hand authenticated lifecycle events back to the MainActor app.
private final class PairingCompositionCallbacks: @unchecked Sendable {
    weak var application: EagleGazeApplication?

    func sessionReady(_ session: PairingAuthenticatedSession) {
        Task { @MainActor [weak self] in
            self?.application?.handleSessionReady(session)
        }
    }

    func sessionEnded(_ sessionID: UUID) {
        Task { @MainActor [weak self] in
            self?.application?.handleSessionEnded(sessionID)
        }
    }
}

/// macOS application composition root.  The view layer talks to this object;
/// it never consumes packets, performs coordinate transforms, or owns the
/// calibration state machine.
@MainActor
final class EagleGazeApplication: ObservableObject, GazeApplicationService {
    let receiver: GazeReceiver
    let sourceManager: GazeSourceManager
    let calibration: CalibrationCoordinator
    let pairing: PairingService
    let pairingServer: PairingControlServer?
    let displayProvider: DisplayProvider
    private let gazeCaptureService: any GazeCaptureServicing

    @Published private(set) var latestFrame: CanonicalGazeFrame?
    @Published private(set) var isFresh = false
    @Published private(set) var mappedPoint: Point2D?
    @Published private(set) var snapshot: CalibrationCoordinatorSnapshot
    @Published var lastError: String?
    @Published private(set) var sourceOptions: [GazeSourceOption]
    @Published private(set) var pairingState: PairingServiceState = .idle
    @Published private(set) var pairingControlAvailable = false
    @Published private(set) var hasAuthenticatedPhoneSession = false
    @Published var selectedSourceID: GazeSourceID?
    @Published var selectedDisplayID: String
    @Published var showsGazeOverlay = true
    @Published var smartCropEnabled: Bool {
        didSet { UserDefaults.standard.set(smartCropEnabled, forKey: Self.smartCropPreferenceKey) }
    }
    @Published var cerebrasEnrichmentEnabled: Bool {
        didSet { UserDefaults.standard.set(cerebrasEnrichmentEnabled, forKey: Self.cerebrasPreferenceKey) }
    }
    @Published private(set) var hasCerebrasAPIKey = false
    @Published private(set) var accessibilityTrusted = AccessibilityRegionResolver.isProcessTrusted
    @Published private(set) var geometryAssessment: CalibrationGeometryAssessment?

    private var cancellables = Set<AnyCancellable>()
    private let setupID = "default-mount"
    // Presentation-only filtering. Calibration always consumes the raw
    // canonical point; the 1-Euro/dead-zone/saccade filter is applied only to
    // the dot users see after mapping.
    private var stabilizer = GazeStabilizer()
    private var geometryMonitor = CalibrationGeometryMonitor()
    private var lastLoggedGeometryStatus: CalibrationGeometryStatus = .stable
    private var attentionEstimator = try! AttentionEstimator()
    private let cerebrasCredentialStore = CerebrasCredentialStore()
    private let pairingCallbacks: PairingCompositionCallbacks
    private var activeSessionID: UUID?
    private var activeSessionSourceID: GazeSourceID?
    private var lastCalibrationRejectionAt: TimeInterval = 0
    private var lastCalibrationRejectionDescription: String?
    private static let smartCropPreferenceKey = "capture.smartCropEnabled"
    private static let cerebrasPreferenceKey = "capture.cerebrasEnrichmentEnabled"

    init(
        receiver: GazeReceiver = GazeReceiver(),
        calibration: CalibrationCoordinator = CalibrationCoordinator(),
        pairing: PairingService? = nil,
        pairingServer: PairingControlServer? = nil,
        displayProvider: DisplayProvider = DisplayProvider(),
        gazeCaptureService: (any GazeCaptureServicing)? = nil
    ) {
        let callbacks = PairingCompositionCallbacks()
        let service: PairingService
        let server: PairingControlServer?
        var identityError: Error?
        if let pairing {
            service = pairing
            server = pairingServer
        } else {
            let createdServer = pairingServer ?? PairingControlServer(
                serviceIdentity: "EagleGaze Mac",
                onSessionReady: { session in callbacks.sessionReady(session) },
                onSessionEnded: { sessionID in callbacks.sessionEnded(sessionID) }
            )
            do {
                service = try PairingService(
                    identityStore: KeychainMacReceiverIdentityStore(),
                    serviceIdentity: "EagleGaze Mac",
                    store: KeychainPairedDeviceStore(),
                    advertisement: createdServer
                )
                createdServer.attach(service)
                server = createdServer
            } catch {
                // A missing/unavailable Keychain identity must not silently
                // fall back to a portable fingerprint. Pairing remains
                // disabled and no pairing listener is exposed for this run.
                identityError = error
                // This service is deliberately inert: the control server is
                // nil and the UI refuses to create an offer. A process-local
                // fingerprint only satisfies object construction after the
                // durable Keychain identity failed; it is never advertised or
                // accepted as a paired identity.
                service = PairingService(
                    receiverFingerprint: MacReceiverIdentity.random().fingerprint,
                    store: KeychainPairedDeviceStore(),
                    advertisement: nil
                )
                server = nil
            }
        }
        self.receiver = receiver
        self.sourceManager = receiver.sourceManager
        self.calibration = calibration
        self.pairing = service
        self.pairingServer = server
        self.displayProvider = displayProvider
        self.gazeCaptureService = gazeCaptureService ?? GazeCaptureService()
        self.pairingCallbacks = callbacks
        self.snapshot = calibration.snapshot
        self.selectedSourceID = sourceManager.activeSourceID
        self.selectedDisplayID = displayProvider.selectedDisplayID
        self.sourceOptions = Self.makeSourceOptions(from: sourceManager.sources)
        self.smartCropEnabled = UserDefaults.standard.object(forKey: Self.smartCropPreferenceKey) as? Bool ?? true
        self.cerebrasEnrichmentEnabled = UserDefaults.standard.bool(forKey: Self.cerebrasPreferenceKey)
        self.hasCerebrasAPIKey = ((try? cerebrasCredentialStore.load()) ?? nil)?.isEmpty == false
        if !hasCerebrasAPIKey { self.cerebrasEnrichmentEnabled = false }

        receiver.$latestFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in self?.consume(frame) }
            .store(in: &cancellables)
        receiver.$isFresh
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fresh in self?.setFresh(fresh) }
            .store(in: &cancellables)
        displayProvider.$selectedDisplayID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, self.selectedDisplayID != id else { return }
                self.selectDisplay(id)
            }
            .store(in: &cancellables)

        configureContext()
        refreshSnapshot()
        callbacks.application = self
        service.setStateChangeHandler { [weak self] state in
            self?.pairingState = state
        }
        if let identityError {
            macApplicationLog.fault("Secure pairing disabled identity error=\(identityError.localizedDescription, privacy: .public)")
            lastError = "Mac receiver identity unavailable; secure pairing is disabled: \(identityError.localizedDescription)"
        } else if let server {
            do {
                try server.start()
                pairingControlAvailable = true
                macApplicationLog.notice("Pairing control service started")
            } catch {
                macApplicationLog.error("Pairing control service failed error=\(error.localizedDescription, privacy: .public)")
                lastError = "Pairing control server unavailable: \(error.localizedDescription)"
            }
        }
    }

    deinit {
        pairingServer?.stop()
    }

    var activeSource: GazeSourceDescriptor? { sourceManager.activeSource }
    var selectedDisplay: DisplayDescriptor? { displayProvider.display(id: selectedDisplayID) }
    var fineAdjustment: FineAdjustment { snapshot.profile?.fineAdjustment ?? .identity }

    var sourceStatusText: String {
        guard let activeSource else { return "No source selected" }
        return isFresh ? "\(activeSource.displayName) is live" : "\(activeSource.displayName) is waiting for a fresh frame"
    }

    var geometryStatusText: String? {
        guard let assessment = geometryAssessment else { return nil }
        switch assessment.status {
        case .stable: return nil
        case .recenterRecommended:
            return "Your viewing position shifted. Recenter for a quick correction."
        case .recalibrationRequired:
            return "The phone-to-face geometry changed materially. Run a full recalibration."
        }
    }

    var calibrationFailureText: String? {
        guard snapshot.phase == .failed, let error = snapshot.calibrationError else { return nil }
        switch error {
        case let .validationFailed(rms, worst):
            return "The candidate was not accurate enough (RMS \(rms.formatted(.number.precision(.fractionLength(3)))), worst \(worst.formatted(.number.precision(.fractionLength(3))))). Your previous accepted calibration was not replaced."
        case .cannotFitCalibration, .cannotFitMapping:
            return "The collected targets could not produce a stable mapping. Keep the phone fixed, make sure both eyes are visible, and try again."
        default:
            return "Calibration stopped because the collected evidence was not reliable enough. Try again with the phone fixed and both eyes visible."
        }
    }

    func selectSource(_ id: GazeSourceID) {
        guard let option = sourceOptions.first(where: { $0.id == id }) else { return }
        guard option.isAvailable else {
            lastError = "Tobii is not available in this MVP. Select ARKit when an iPhone is paired."
            return
        }
        guard option.kind != .arkitRemote || hasAuthenticatedPhoneSession else {
            macApplicationLog.warning("Blocked pre-authentication ARKit source selection")
            lastError = "Authenticate an iPhone before selecting its gaze source."
            return
        }
        do {
            _ = try sourceManager.select(sourceID: id)
            selectedSourceID = id
            clearPresentationState()
            configureContext()
            refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectDisplay(_ id: String) {
        guard displayProvider.display(id: id) != nil else { return }
        let changed = id != selectedDisplayID || displayProvider.selectedDisplayID != id
        selectedDisplayID = id
        displayProvider.select(id: id)
        guard changed else { return }
        clearPresentationState()
        configureContext()
        refreshSnapshot()
    }

    /// Called by the authenticated pairing transport when the phone completes
    /// its side of the transcript. The resulting pending state is published;
    /// durable storage still waits for the UI's explicit confirmation.
    @discardableResult
    func receivePairingRequest(_ request: PairingRequest) throws -> PendingPairingConfirmation {
        let confirmation = try pairing.beginPairing(request)
        pairingState = pairing.state
        return confirmation
    }

    /// Wire-level overload used by the Mac pairing control server. Validation
    /// of the short-lived offer remains inside PairingService.
    @discardableResult
    func receivePairingRequest(_ request: PairingInitiationRequest) throws -> PendingPairingConfirmation {
        let confirmation = try pairing.beginPairing(request)
        pairingState = pairing.state
        return confirmation
    }

    func confirmPairing() {
        guard let pending = pairing.pendingConfirmation else { return }
        guard let pairingServer else {
            lastError = "Secure pairing control is unavailable."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await pairingServer.approve(confirmationID: pending.confirmationID)
                macApplicationLog.notice("Pairing confirmation completed")
                pairingState = pairing.state
                lastError = nil
            } catch { lastError = error.localizedDescription }
        }
    }

    func rejectPairing() {
        guard let pending = pairing.pendingConfirmation else { return }
        guard let pairingServer else {
            lastError = "Secure pairing control is unavailable."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await pairingServer.reject(confirmationID: pending.confirmationID)
                pairingState = pairing.state
            } catch { lastError = error.localizedDescription }
        }
    }

    func restartPairingControl() {
        guard let pairingServer, !hasAuthenticatedPhoneSession else { return }
        macApplicationLog.notice("User requested pairing control restart")
        pairingServer.stop()
        pairingControlAvailable = false
        do {
            try pairingServer.start()
            pairingControlAvailable = true
            lastError = nil
        } catch {
            lastError = "Could not restart nearby pairing: \(error.localizedDescription)"
            macApplicationLog.error("Pairing control restart failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func applyFineAdjustment(_ adjustment: FineAdjustment) {
        do {
            _ = try calibration.applyFineAdjustment(adjustment)
            refreshSnapshot()
            updateMappedPoint()
        } catch { lastError = error.localizedDescription }
    }

    func resetFineAdjustment() { applyFineAdjustment(.identity) }

    /// Integration seam for the pairing/reconnect control server.  The
    /// control plane supplies the durable paired device's source identity and
    /// a freshly derived opaque session. Pair IDs are encryption identities;
    /// they are intentionally not used as gaze-source IDs.
    func installSecureSession(
        _ material: ReconnectSessionMaterial,
        pairID: UUID,
        sourceID: GazeSourceID,
        displayName: String,
        receiverFingerprint: String? = nil
    ) {
        // Freshness belongs to one authenticated session and must never carry
        // across a reconnect before the new session produces a frame.
        isFresh = false
        clearPresentationState()
        do {
            try receiver.activatePairedSource(
                sourceID: sourceID,
                displayName: displayName,
                secureSession: ARKitNetworkSource.SecureSession(
                    pairID: pairID,
                    sessionID: material.sessionID,
                    sessionKey: material.streamKey,
                    noncePrefix: material.noncePrefix
                ),
                receiverFingerprint: receiverFingerprint
            )
            sourceOptions = Self.makeSourceOptions(from: sourceManager.sources)
            selectedSourceID = sourceID
            activeSessionID = material.sessionID
            activeSessionSourceID = sourceID
            hasAuthenticatedPhoneSession = true
            configureContext()
            refreshSnapshot()
            lastError = nil
            macApplicationLog.notice("Secure gaze source installed device=\(displayName, privacy: .public) session=\(material.sessionID.uuidString.prefix(8), privacy: .public)")
        } catch {
            macApplicationLog.error("Secure gaze source installation failed error=\(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func handleSessionReady(_ session: PairingAuthenticatedSession) {
        installSecureSession(
            session.material,
            pairID: session.pairID,
            sourceID: session.sourceID,
            displayName: session.displayName,
            receiverFingerprint: pairing.receiverFingerprintValue
        )
    }

    func handleSessionEnded(_ sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        if let activeSessionSourceID,
           sourceManager.activeSourceID == activeSessionSourceID {
            sourceManager.stopActive()
            selectedSourceID = nil
            clearPresentationState()
            refreshSnapshot()
        }
        activeSessionID = nil
        self.activeSessionSourceID = nil
        hasAuthenticatedPhoneSession = false
        isFresh = false
        clearPresentationState()
        macApplicationLog.notice("Authenticated phone session ended session=\(sessionID.uuidString.prefix(8), privacy: .public)")
    }


    // MARK: GazeApplicationService (coarse state plus approved one-shot capture)

    var voiceOSSnapshot: GazeApplicationSnapshot {
        let connection: GazeApplicationConnectionState = if !hasAuthenticatedPhoneSession {
            .offline
        } else if isFresh {
            .connected
        } else {
            .stale
        }
        let state: GazeApplicationCalibrationState = switch snapshot.phase {
        case .idle: .setup
        case .calibrating, .validating, .recentering: .calibrating
        case .calibrated, .evaluating, .complete: .calibrated
        case .failed: .failed
        }
        let evaluation: GazeApplicationEvaluationState = switch snapshot.phase {
        case .evaluating: .evaluating
        case .complete: .complete
        default: .idle
        }
        return GazeApplicationSnapshot(
            sourceKind: activeSource.map(Self.applicationSourceKind) ?? .unknown,
            connectionState: connection,
            calibrationState: state,
            calibrationStep: snapshot.targetIndex,
            calibrationPointCount: snapshot.targetCount,
            calibrationSampleCount: snapshot.sampleCount,
            evaluationState: evaluation,
            evaluationTrial: snapshot.trialIndex,
            evaluationTrialCount: snapshot.trialCount,
            evaluationHits: snapshot.evaluationHits,
            overlayVisible: showsGazeOverlay
        )
    }

    func startCalibration() throws {
        try beginFreshCalibration(reason: "initial")
    }

    func resetCalibration() throws {
        guard activeSource != nil else { throw GazeApplicationServiceError.notConnected }
        try calibration.reset()
        macApplicationLog.notice("Calibration reset display=\(self.selectedDisplayID, privacy: .public)")
        clearPresentationState()
        refreshSnapshot()
    }

    func recalibrateEagleEye() throws {
        try beginFreshCalibration(reason: "recalibrate")
    }

    /// Starts a new candidate calibration immediately. The last accepted
    /// profile remains usable and persisted until the replacement passes its
    /// independent validation targets.
    private func beginFreshCalibration(reason: String) throws {
        guard activeSource != nil, isFresh else {
            let sourceState = activeSource == nil ? "missing" : "ready"
            macApplicationLog.error(
                "Calibration request gated reason=\(reason, privacy: .public) source=\(sourceState, privacy: .public) fresh=\(self.isFresh, privacy: .public)"
            )
            throw GazeApplicationServiceError.notConnected
        }
        let priorPhase = snapshot.phase.rawValue
        let hasRollbackProfile = snapshot.profile != nil
        macApplicationLog.notice(
            "Calibration request accepted reason=\(reason, privacy: .public) priorPhase=\(priorPhase, privacy: .public) rollbackProfile=\(hasRollbackProfile, privacy: .public) display=\(self.selectedDisplayID, privacy: .public)"
        )
        try calibration.startCalibration()
        clearPresentationState()
        refreshSnapshot()
        lastError = nil
        macApplicationLog.notice(
            "Calibration collection active reason=\(reason, privacy: .public) target=\(self.snapshot.targetIndex + 1, privacy: .public)/\(self.snapshot.targetCount, privacy: .public)"
        )
    }

    func captureGaze(
        marker: GazeCaptureMarker,
        cancellation: any GazeCaptureCancellationChecking = NeverCancelledGazeCapture()
    ) async throws -> GazeCaptureArtifact {
        guard snapshot.profile != nil else { throw GazeCaptureError.notCalibrated }
        guard isFresh, let mappedPoint else { throw GazeCaptureError.gazeStale }
        guard let selectedDisplay else { throw GazeCaptureError.displayUnavailable }
        let calibrationError = snapshot.profile?.quality.rmsError ?? 0
        let estimate = try? attentionEstimator.snapshot(
            at: ProcessInfo.processInfo.systemUptime,
            calibrationError: NormalizedPoint(x: calibrationError, y: calibrationError)
        )
        let attention = estimate?.isEligible() == true ? estimate : nil
        let apiKey = cerebrasEnrichmentEnabled ? try? cerebrasCredentialStore.load() : nil
        return try await gazeCaptureService.capture(
            display: selectedDisplay,
            normalizedGaze: mappedPoint,
            attention: attention,
            marker: marker,
            options: GazeCaptureOptions(
                smartCropEnabled: smartCropEnabled,
                cerebrasAPIKey: apiKey ?? nil
            ),
            cancellation: cancellation
        )
    }

    func requestAccessibilityPermission() {
        accessibilityTrusted = AccessibilityRegionResolver.requestTrustPrompt()
        if !accessibilityTrusted {
            lastError = "Accessibility permission is needed to identify complete app controls and text regions. Smart crop will use its local fixed-region fallback until permission is enabled."
        }
    }

    func refreshAccessibilityPermission() {
        accessibilityTrusted = AccessibilityRegionResolver.isProcessTrusted
    }

    func saveCerebrasAPIKey(_ key: String) {
        do {
            try cerebrasCredentialStore.save(key)
            hasCerebrasAPIKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeCerebrasAPIKey() {
        do {
            try cerebrasCredentialStore.delete()
            hasCerebrasAPIKey = false
            cerebrasEnrichmentEnabled = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requestScreenCapturePermission() {
        if !gazeCaptureService.requestScreenCapturePermission() {
            lastError = "Screen Recording permission is required to share a gaze capture. Enable EagleGaze in System Settings → Privacy & Security → Screen Recording."
        } else {
            lastError = nil
        }
    }

    func startEvaluation() throws {
        guard snapshot.profile != nil else { throw GazeApplicationServiceError.notCalibrated }
        try calibration.startEvaluation()
        macApplicationLog.notice("Calibration evaluation started")
        clearPresentationState()
        refreshSnapshot()
    }

    func recenterGaze() throws {
        guard activeSource != nil, isFresh else { throw GazeApplicationServiceError.notConnected }
        guard snapshot.profile != nil else { throw GazeApplicationServiceError.notCalibrated }
        try calibration.startRecenter()
        clearPresentationState()
        refreshSnapshot()
        lastError = nil
    }

    private func consume(_ frame: CanonicalGazeFrame?) {
        guard let frame else { clearPresentationState(); return }
        guard frame.sourceID == sourceManager.activeSourceID else { return }
        latestFrame = frame
        // A source emits a frame before its freshness notification. Treat the
        // accepted canonical frame as fresh here; a subsequent stale event
        // clears presentation state synchronously.
        do {
            let priorPhase = snapshot.phase
            let priorTarget = snapshot.targetIndex
            let priorSamples = snapshot.sampleCount
            _ = try calibration.consume(frame)
            refreshSnapshot()
            if (priorPhase == .validating || priorPhase == .calibrating), snapshot.phase == .calibrated, let profile = snapshot.profile {
                macApplicationLog.notice(
                    "Calibration completed samples=\(profile.quality.sampleCount, privacy: .public) fitRMS=\(profile.quality.rmsError, privacy: .public) validationRMS=\(profile.quality.validationRMSError ?? -1, privacy: .public)"
                )
            } else if snapshot.phase == .calibrating || snapshot.phase == .validating || snapshot.phase == .recentering {
                if snapshot.targetIndex != priorTarget {
                    macApplicationLog.notice("Calibration advanced phase=\(self.snapshot.phase.rawValue, privacy: .public) target=\(self.snapshot.targetIndex + 1, privacy: .public)/\(self.snapshot.targetCount, privacy: .public)")
                } else if priorSamples == 0, snapshot.sampleCount > 0 {
                    macApplicationLog.info("Calibration accepted first sample target=\(self.snapshot.targetIndex + 1, privacy: .public)")
                }
            } else if priorPhase == .evaluating, snapshot.phase == .complete {
                macApplicationLog.notice(
                    "Calibration evaluation completed hits=\(self.snapshot.evaluationHits, privacy: .public)/\(self.snapshot.trialCount, privacy: .public)"
                )
            }
            updateGeometryAssessment(from: frame)
            guard frame.validity == .valid, frame.blink != .closed else {
                mappedPoint = nil
                stabilizer.reset()
                return
            }
            updateMappedPoint()
            if let calibratedPoint = snapshot.mappedPoint {
                try? attentionEstimator.append(
                    TimedGazePoint(
                        point: NormalizedPoint(x: calibratedPoint.x, y: calibratedPoint.y),
                        confidence: min(max(frame.confidence, 0), 1),
                        captureUptime: ProcessInfo.processInfo.systemUptime
                    )
                )
            }
        } catch {
            // Invalid frames are presentation boundaries, not application
            // failures.  The coordinator has already rejected the frame.
            if case CalibrationCoordinatorError.engine = error {
                lastError = nil
            }
            if snapshot.phase == .calibrating || snapshot.phase == .validating || snapshot.phase == .recentering {
                let now = ProcessInfo.processInfo.systemUptime
                let description = error.localizedDescription
                if description != lastCalibrationRejectionDescription || now - lastCalibrationRejectionAt >= 1 {
                    macApplicationLog.warning("Calibration rejected frame reason=\(description, privacy: .public)")
                    lastCalibrationRejectionAt = now
                    lastCalibrationRejectionDescription = description
                }
            }
            clearPresentationState()
        }
    }

    private func setFresh(_ fresh: Bool) {
        isFresh = fresh
        if !fresh {
            clearPresentationState()
        } else {
            updateMappedPoint()
        }
    }

    private func configureContext() {
        guard let sourceID = selectedSourceID, !selectedDisplayID.isEmpty else { return }
        do {
            try calibration.setContext(
                sourceID: sourceID,
                displayID: selectedDisplayID,
                setupID: setupID,
                coordinateSpace: activeSource?.capabilities.contains(.displayNormalizedCoordinates) == true
                    ? .displayNormalized : .source
            )
            geometryMonitor.reset()
            geometryAssessment = nil
            lastLoggedGeometryStatus = .stable
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private func clearPresentationState() {
        mappedPoint = nil
        latestFrame = nil
        stabilizer.reset()
        attentionEstimator.reset()
    }

    private func updateMappedPoint() {
        guard isFresh, let point = snapshot.mappedPoint else {
            mappedPoint = nil
            return
        }
        let timestamp = latestFrame?.captureUptime ?? ProcessInfo.processInfo.systemUptime
        mappedPoint = stabilizer.update(point, at: timestamp)
    }

    private func updateGeometryAssessment(from frame: CanonicalGazeFrame) {
        guard snapshot.phase == .calibrated || snapshot.phase == .complete || snapshot.phase == .evaluating,
              let baseline = snapshot.profile?.geometryBaseline,
              let current = frame.trackingMetrics?.geometry,
              let assessment = geometryMonitor.update(current: current, baseline: baseline) else { return }
        geometryAssessment = assessment
        guard assessment.status != lastLoggedGeometryStatus else { return }
        lastLoggedGeometryStatus = assessment.status
        macApplicationLog.notice(
            "Geometry status changed status=\(assessment.status.rawValue, privacy: .public) positionDeltaM=\(assessment.positionDeltaMeters, format: .fixed(precision: 3), privacy: .public) angleDeltaDeg=\(assessment.angleDeltaDegrees, format: .fixed(precision: 1), privacy: .public)"
        )
    }

    private func refreshSnapshot() { snapshot = calibration.snapshot; updateMappedPoint() }

    private static func makeSourceOptions(from descriptors: [GazeSourceDescriptor]) -> [GazeSourceOption] {
        let arkit = descriptors.first(where: { $0.kind == .arkitRemote })
            ?? GazeSourceDescriptor(
                sourceID: "arkit-phone",
                kind: .arkitRemote,
                displayName: "iPhone ARKit",
                capabilities: [.eyeTracking, .blinkDetection, .sourceCoordinates, .faceTracking]
            )
        return [
            GazeSourceOption(
                id: arkit.sourceID,
                title: arkit.displayName,
                subtitle: "Paired iPhone • secure canonical frames",
                kind: arkit.kind,
                isAvailable: true,
                capabilities: arkit.capabilities
            ),
            GazeSourceOption(
                id: "tobii",
                title: "Tobii",
                subtitle: "Unavailable — adapter not installed",
                kind: .tobii,
                isAvailable: false,
                capabilities: []
            ),
        ]
    }

    private static func applicationSourceKind(_ descriptor: GazeSourceDescriptor) -> GazeApplicationSourceKind {
        switch descriptor.kind {
        case .arkitRemote: .phone
        case .tobii: .vendor
        case .custom: .unknown
        }
    }
}
