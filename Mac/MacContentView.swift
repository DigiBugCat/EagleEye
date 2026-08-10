import AppKit
import GazeCore
import SwiftUI

struct MacContentView: View {
    @ObservedObject var application: EagleGazeApplication
    @ObservedObject var voiceOSBridge: VoiceOSBridge
    @ObservedObject var overlayController: GazeOverlayController

    @State private var showsAdvancedSetup = false
    @State private var showsDiagnostics = false
    @State private var cerebrasKeyDraft = ""

    private let brandBlue = Color.blue

    var body: some View {
        HStack(spacing: 0) {
            stepRail
            Divider().opacity(0.55)
            workspace
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(brandBlue)
        .onChange(of: application.selectedDisplayID) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.mappedPoint) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.snapshot) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.showsGazeOverlay) { _, _ in overlayController.update(application: application) }
        .onAppear { application.refreshAccessibilityPermission() }
    }

    // MARK: - Prototype step rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(brandBlue.opacity(0.12))
                    Image(systemName: "eye.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(brandBlue)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("EagleEye").font(.headline)
                    Text("Eye tracking for Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 4) {
                railStep(1, "Pair iPhone", symbol: "iphone.gen3", state: pairStepState)
                railConnector(complete: application.hasAuthenticatedPhoneSession)
                railStep(2, "Calibrate", symbol: "scope", state: calibrationStepState)
                railConnector(complete: application.snapshot.profile != nil)
                railStep(3, "Live tracking", symbol: "eye", state: liveStepState)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    syncIndicator
                    VStack(alignment: .leading, spacing: 1) {
                        Text(application.isFresh ? "iPhone connected" : "Waiting for iPhone")
                            .font(.caption.weight(.semibold))
                        Text(application.selectedDisplay?.name ?? "No display selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsDiagnostics.toggle() }
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 238)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private enum StepState { case complete, current, upcoming }

    private var pairStepState: StepState {
        if application.hasAuthenticatedPhoneSession { return .complete }
        return .current
    }

    private var calibrationStepState: StepState {
        if application.snapshot.profile != nil { return .complete }
        return application.hasAuthenticatedPhoneSession ? .current : .upcoming
    }

    private var liveStepState: StepState {
        application.snapshot.profile != nil ? .current : .upcoming
    }

    private func railStep(_ number: Int, _ title: String, symbol: String, state: StepState) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(state == .complete ? brandBlue : (state == .current ? brandBlue.opacity(0.1) : .clear))
                    .overlay {
                        Circle().stroke(state == .upcoming ? Color.secondary.opacity(0.35) : brandBlue, lineWidth: 1.5)
                    }
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption2.bold())
                        .foregroundStyle(state == .current ? brandBlue : .secondary)
                }
            }
            .frame(width: 22, height: 22)

            Label(title, systemImage: symbol)
                .font(.callout.weight(state == .current ? .semibold : .regular))
                .foregroundStyle(state == .upcoming ? .secondary : .primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(state == .current ? brandBlue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .complete ? "Complete" : (state == .current ? "Current step" : "Upcoming"))
    }

    private func railConnector(complete: Bool) -> some View {
        Capsule()
            .fill(complete ? brandBlue : Color.secondary.opacity(0.22))
            .frame(width: 2, height: 10)
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }

    // MARK: - Task-focused workspace

    @ViewBuilder
    private var workspace: some View {
        if isTargetPhase {
            activeCalibrationCanvas
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    workspaceHeader
                    if !application.hasAuthenticatedPhoneSession {
                        pairingWorkspace
                    } else if application.snapshot.profile == nil {
                        calibrationWorkspace
                    } else {
                        liveWorkspace
                    }
                    if showsDiagnostics { diagnosticsPanel }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(workspaceTitle)
                .font(.system(size: 25, weight: .bold))
            Text(workspaceSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceTitle: String {
        if !application.hasAuthenticatedPhoneSession { return "Pair your iPhone" }
        if application.snapshot.profile == nil { return "Calibrate your gaze" }
        return "Live tracking"
    }

    private var workspaceSubtitle: String {
        if !application.hasAuthenticatedPhoneSession { return "Connect securely, then use the iPhone camera to estimate where you look." }
        if application.snapshot.profile == nil { return "Complete a quick 3×3 calibration on the selected display." }
        return "Your calibrated gaze stream is ready across the selected display."
    }

    private var pairingWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandedCard {
                VStack(alignment: .leading, spacing: 14) {
                    switch application.pairingState {
                    case .idle:
                        HStack(alignment: .top, spacing: 16) {
                            featureIcon("dot.radiowaves.left.and.right")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Ready for nearby pairing").font(.headline)
                                Text("Open EagleEye on your iPhone, choose this Mac, and compare the six-digit code before approving.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !application.pairingControlAvailable {
                            Label("Nearby pairing is unavailable because the secure control service could not start.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Restart nearby service") {
                            application.restartPairingControl()
                        }
                        .buttonStyle(.bordered)
                    case .offerVisible(let presentation):
                        HStack(alignment: .top, spacing: 16) {
                            featureIcon("iphone.radiowaves.left.and.right")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Nearby iPhone connected").font(.title3.bold())
                                Text("Establishing a one-time encrypted transcript. The confirmation code will appear when it is ready.")
                                    .foregroundStyle(.secondary)
                                Text("Request expires at \(presentation.offer.expiresAt, style: .time)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .awaitingConfirmation(let pending):
                        HStack(alignment: .top, spacing: 16) {
                            featureIcon("checkmark.shield")
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Approve \(pending.displayName)?").font(.title3.bold())
                                Text("Confirm that the iPhone shows this same six-digit code, then approve it.")
                                    .foregroundStyle(.secondary)
                                Text(formattedVerificationCode(pending.verificationCode))
                                    .font(.title2.monospaced().weight(.semibold))
                                    .tracking(2)
                                    .padding(.vertical, 4)
                                HStack {
                                    Button("Approve") { application.confirmPairing() }.buttonStyle(.borderedProminent)
                                    Button("Reject") { application.rejectPairing() }.buttonStyle(.bordered)
                                }
                            }
                        }
                    case .paired(let record):
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Paired with \(record.displayName)", systemImage: "checkmark.shield.fill")
                                .font(.headline)
                                .foregroundStyle(.green)
                            Text("Waiting for the iPhone to authenticate this saved connection. On the iPhone, tap Retry authentication or Repair saved connection if retry fails.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Restart nearby service") { application.restartPairingControl() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            sourceAndDisplaySetup
        }
    }

    private func formattedVerificationCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private var calibrationWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandedCard {
                HStack(alignment: .center, spacing: 18) {
                    calibrationTarget
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hold your gaze on nine teal targets").font(.title3.bold())
                        Text("Keep your head still and look at each teal target until it advances to the next point.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Keep the phone rigid and centered on the display. Recalibrate whenever the phone, display, or seating geometry changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Start 3×3 calibration") { run { try application.startCalibration() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!application.isFresh)
                }
                if !application.isFresh {
                    Label("Waiting for a fresh gaze stream from the iPhone.", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let failure = application.calibrationFailureText {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sourceAndDisplaySetup
            advancedSetup
        }
    }

    private var liveWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandedCard {
                HStack(spacing: 12) {
                    Label(application.isFresh ? "Stream live" : "Stream waiting", systemImage: application.isFresh ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(application.isFresh ? .green : .orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background((application.isFresh ? Color.green : Color.orange).opacity(0.1), in: Capsule())
                    Label("Calibrated · \(application.snapshot.targetCount) points", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brandBlue)
                    Spacer()
                }

                if let geometryStatusText = application.geometryStatusText,
                   let status = application.geometryAssessment?.status {
                    HStack(spacing: 10) {
                        Label(
                            geometryStatusText,
                            systemImage: status == .recalibrationRequired ? "exclamationmark.triangle.fill" : "scope"
                        )
                        .font(.callout)
                        .foregroundStyle(status == .recalibrationRequired ? Color.orange : brandBlue)
                        Spacer()
                        if status == .recenterRecommended {
                            Button("Recenter now") { run { try application.recenterGaze() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Recalibrate now") { run { try application.recalibrateEagleEye() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(10)
                    .background(
                        (status == .recalibrationRequired ? Color.orange : brandBlue).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }

                HStack(spacing: 14) {
                    Toggle("Show gaze dot over Mac apps", isOn: overlayBinding)
                        .font(.headline)
                    Spacer()
                    Button(application.snapshot.phase == .complete ? "Run evaluation again" : "Start evaluation") {
                        run { try application.startEvaluation() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!application.isFresh)
                    Button("Recenter") { run { try application.recenterGaze() } }
                        .buttonStyle(.bordered)
                        .disabled(!application.isFresh)
                    Button("Recalibrate") { run { try application.recalibrateEagleEye() } }
                        .buttonStyle(.bordered)
                        .disabled(!application.isFresh)
                }

                Text("The pink dot is the live smoothed gaze estimate. The overlay is click-through and continuous gaze data remains local to this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if application.snapshot.phase == .complete {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accuracyText).font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("Evaluation accuracy").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(application.snapshot.evaluationHits) of \(application.snapshot.trialCount) targets identified")
                            .font(.callout.weight(.semibold))
                    }
                }
            }

            advancedSetup
        }
    }

    private var sourceAndDisplaySetup: some View {
        brandedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection setup").font(.headline)
                sourcePicker
                Divider()
                displayPicker
            }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gaze source").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(application.sourceOptions) { option in
                Button {
                    application.selectSource(option.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.isAvailable ? "iphone.gen3.radiowaves.left.and.right" : "nosign")
                            .foregroundStyle(option.isAvailable ? brandBlue : Color.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(.callout.weight(.semibold))
                            Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if application.selectedSourceID == option.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(brandBlue)
                        }
                    }
                    .padding(9)
                    .background(application.selectedSourceID == option.id ? brandBlue.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.isAvailable)
            }
            Text(application.sourceStatusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displayPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Destination display").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Destination display", selection: $application.selectedDisplayID) {
                ForEach(application.displayProvider.displays) { display in
                    Text(display.isMain ? "\(display.name) (Main)" : display.name).tag(display.id)
                }
            }
            .labelsHidden()
            .onChange(of: application.selectedDisplayID) { _, id in application.selectDisplay(id) }
            Text("Changing the display clears its active overlay until that display is calibrated.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSetup: some View {
        brandedCard {
            DisclosureGroup("Fine alignment and integrations", isExpanded: $showsAdvancedSetup) {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    adjustmentSlider("X scale", value: adjustmentBinding(\.scaleX), range: 0.5...1.5, format: "%.2f×")
                    adjustmentSlider("Y scale", value: adjustmentBinding(\.scaleY), range: 0.5...1.5, format: "%.2f×")
                    adjustmentSlider("X offset", value: adjustmentBinding(\.offsetX), range: -0.2...0.2, format: "%+.3f")
                    adjustmentSlider("Y offset", value: adjustmentBinding(\.offsetY), range: -0.2...0.2, format: "%+.3f")
                    Button("Reset fine alignment") { application.resetFineAdjustment() }
                        .buttonStyle(.bordered)
                    Divider()
                    Label(voiceOSBridge.status, systemImage: voiceOSBridge.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(voiceOSBridge.isListening ? .green : .orange)
                    Button("Allow approved gaze captures…") {
                        application.requestScreenCapturePermission()
                    }
                    .buttonStyle(.bordered)
                    Divider()
                    Toggle("Smart crop around what I am looking at", isOn: $application.smartCropEnabled)
                    Label(
                        application.accessibilityTrusted
                            ? "Accessibility geometry available"
                            : "Accessibility geometry unavailable — fixed crop fallback will be used",
                        systemImage: application.accessibilityTrusted ? "checkmark.shield.fill" : "rectangle.dashed"
                    )
                    .foregroundStyle(application.accessibilityTrusted ? .green : .secondary)
                    if !application.accessibilityTrusted {
                        Button("Allow app-region detection…") {
                            application.requestAccessibilityPermission()
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Smart crop reads only Accessibility roles and bounds near the gaze point. It does not read element text, values, app names, window titles, URLs, actions, or the full Accessibility tree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Toggle("Enhance approved captures with Cerebras", isOn: $application.cerebrasEnrichmentEnabled)
                        .disabled(!application.hasCerebrasAPIKey)
                    HStack {
                        SecureField(
                            application.hasCerebrasAPIKey ? "API key saved in Keychain" : "Cerebras API key",
                            text: $cerebrasKeyDraft
                        )
                        Button("Save Key") {
                            application.saveCerebrasAPIKey(cerebrasKeyDraft)
                            cerebrasKeyDraft = ""
                        }
                        .disabled(cerebrasKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if application.hasCerebrasAPIKey {
                            Button("Remove", role: .destructive) {
                                application.removeCerebrasAPIKey()
                                cerebrasKeyDraft = ""
                            }
                        }
                    }
                    Text("Optional • gemma-4-31b. After each approval, Cerebras receives only the exact previewed context and focus images and returns labels and focused-text metadata. The API key stays in this Mac’s Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("VoiceOS receives coarse state and, only after an EagleEye preview is approved, an annotated gaze-context image with image-relative coordinates and bounded region metadata. Continuous gaze remains local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.callout.weight(.semibold))
        }
    }

    private var diagnosticsPanel: some View {
        brandedCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Diagnostics").font(.headline)
                    Spacer()
                    Button { withAnimation { showsDiagnostics = false } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close diagnostics")
                }
                Label(application.isFresh ? "Fresh canonical frame" : "No fresh frame", systemImage: application.isFresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(application.isFresh ? .green : .orange)
                if let frame = application.latestFrame {
                    Text("Validity: \(frame.validity.rawValue) • space: \(frame.coordinateSpace.rawValue)")
                    Text("Session: \(frame.sourceSessionID.uuidString.prefix(8)) • sequence \(frame.sequence)")
                    if let metrics = frame.trackingMetrics {
                        Text("Eyes: \(metrics.bothEyesUsable ? "usable" : "limited") • head \(metrics.headAngularVelocity, format: .number.precision(.fractionLength(2))) rad/s")
                    }
                }
                Text("Accepted \(application.receiver.acceptedPacketCount) • rejected \(application.receiver.rejectedPacketCount + application.receiver.decodeErrorCount)")
                if let size = application.selectedDisplay?.physicalSize {
                    Text("Physical display \(size.widthMeters, format: .number.precision(.fractionLength(3))) × \(size.heightMeters, format: .number.precision(.fractionLength(3))) m • full ray \(application.latestFrame?.gazeRay == nil ? "missing" : "available")")
                }
                Text("Calibration run \(application.snapshot.calibrationRunID?.uuidString.prefix(8) ?? "—") • epoch \(application.snapshot.targetEpoch) • rejected \(application.snapshot.rejectedSampleCount)")
                if let dispersion = application.snapshot.targetDispersion {
                    Text("Target dispersion \(dispersion, format: .number.precision(.fractionLength(4))) • retry \(application.snapshot.targetRetryCount)")
                }
                if let profile = application.snapshot.profile {
                    Text("Selected model: \(profile.quality.modelName ?? "legacy")")
                    if let legacyRMS = profile.quality.legacyValidationRMSError,
                       let legacyWorst = profile.quality.legacyValidationMaxError {
                        Text("2D validation RMS \(legacyRMS, format: .number.precision(.fractionLength(4))) • perimeter worst \(legacyWorst, format: .number.precision(.fractionLength(4)))")
                    }
                    if let rayRMS = profile.quality.rayPlaneValidationRMSError,
                       let rayWorst = profile.quality.rayPlaneValidationMaxError {
                        Text("3D validation RMS \(rayRMS, format: .number.precision(.fractionLength(4))) • perimeter worst \(rayWorst, format: .number.precision(.fractionLength(4)))")
                    }
                }
                if let error = application.lastError { Text(error).foregroundStyle(.red) }
            }
            .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Calibration canvas

    private var activeCalibrationCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                grid
                // The click-through display overlay is the authoritative
                // calibration surface. Drawing a second target inside this
                // smaller canvas gives the user two different physical points
                // for one normalized observation and corrupts the fit.

                VStack {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phaseTitle).font(.headline)
                            Text(progressText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(holdInstruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { run { try application.resetCalibration() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                    .padding(.top, 18)
                    .padding(.horizontal, 24)
                    ProgressView(value: application.snapshot.targetProgress)
                        .tint(.teal)
                        .animation(.easeInOut(duration: 0.16), value: application.snapshot.targetProgress)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            }
            .clipShape(Rectangle())
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }
            .stroke(.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [6, 8]))
        }
    }

    private var gazeDot: some View {
        Circle()
            .fill(Color.pink.opacity(0.88))
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.45), radius: 4)
    }

    private var calibrationTarget: some View {
        ZStack {
            Circle().fill(.teal).frame(width: 42, height: 42)
            Circle().stroke(.white, lineWidth: 3).frame(width: 42, height: 42)
            Circle().fill(.white).frame(width: 7, height: 7)
        }
        .shadow(color: .black.opacity(0.5), radius: 5)
        .accessibilityLabel("Calibration target")
    }

    // MARK: - Shared presentation helpers

    private func brandedCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
    }

    private func featureIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 25, weight: .medium))
            .foregroundStyle(brandBlue)
            .frame(width: 52, height: 52)
            .background(brandBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var overlayBinding: Binding<Bool> {
        Binding(
            get: { application.showsGazeOverlay },
            set: { value in
                application.showsGazeOverlay = value
                overlayController.update(application: application)
            }
        )
    }

    private func adjustmentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .font(.caption)
    }

    private var phaseTitle: String {
        switch application.snapshot.phase {
        case .idle: "Ready to calibrate"
        case .calibrating: "Calibrating"
        case .validating: "Validating calibration"
        case .recentering: "Recentering"
        case .calibrated: "Calibration complete"
        case .evaluating: "Evaluating accuracy"
        case .complete: "Evaluation complete"
        case .failed: "Calibration failed"
        }
    }

    private var progressText: String {
        switch application.snapshot.phase {
        case .calibrating: "Point \(min(application.snapshot.targetIndex + 1, application.snapshot.targetCount)) of \(application.snapshot.targetCount)"
        case .validating: "Validation \(min(application.snapshot.trialIndex + 1, application.snapshot.trialCount)) of \(application.snapshot.trialCount)"
        case .recentering: "Hold gaze on the center target"
        case .calibrated: "\(application.snapshot.targetCount) points fitted"
        case .evaluating, .complete: "\(application.snapshot.evaluationHits) / \(application.snapshot.trialIndex) hits"
        default: "No calibration"
        }
    }

    private var holdInstruction: String {
        switch application.snapshot.holdReason {
        case .settling: "Move your eyes to the teal target and hold still."
        case .eyesUnavailable: "Make sure the TrueDepth camera can see both eyes."
        case .blink: "Blink normally, then hold your gaze on the target."
        case .headMoving: "Keep your head still while the ring fills."
        case .unstableGaze: "Keep looking at the target; the estimate is still settling."
        case .waitingForFrame: "Waiting for fresh tracking frames from the iPhone."
        case .streamRestarted: "The stream restarted; recollecting this point."
        case .collecting: "Locked on — keep looking until the ring closes."
        case .none: "Hold your gaze on the teal target."
        }
    }

    private var isTargetPhase: Bool {
        switch application.snapshot.phase {
        case .calibrating, .validating, .recentering, .evaluating: true
        case .idle, .calibrated, .complete, .failed: false
        }
    }

    private var syncIndicator: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !application.isFresh)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let pulse = (sin(phase * .pi * 2) + 1) / 2
            ZStack {
                if application.isFresh {
                    Circle()
                        .fill(brandBlue.opacity(0.18 * (1 - pulse)))
                        .frame(width: 18, height: 18)
                        .scaleEffect(0.75 + pulse * 0.5)
                }
                Circle()
                    .fill(application.isFresh ? brandBlue : Color.secondary.opacity(0.7))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityLabel(application.isFresh ? "Live gaze frames synchronized" : "Waiting for gaze frames")
    }

    private var accuracyText: String {
        guard application.snapshot.trialIndex > 0 else { return "0%" }
        return (Double(application.snapshot.evaluationHits) / Double(application.snapshot.trialIndex)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func adjustmentBinding(_ keyPath: WritableKeyPath<FineAdjustment, Double>) -> Binding<Double> {
        Binding(
            get: { application.fineAdjustment[keyPath: keyPath] },
            set: { value in
                var adjustment = application.fineAdjustment
                adjustment[keyPath: keyPath] = value
                application.applyFineAdjustment(adjustment)
            }
        )
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { application.lastError = error.localizedDescription }
    }

    private func position(_ point: Point2D, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func clamped(_ point: Point2D) -> Point2D {
        Point2D(x: min(max(point.x, 0.015), 0.985), y: min(max(point.y, 0.015), 0.985))
    }
}
