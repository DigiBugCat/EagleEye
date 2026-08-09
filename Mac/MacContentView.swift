import AppKit
import GazeCore
import SwiftUI

struct MacContentView: View {
    @ObservedObject var application: EagleGazeApplication
    @ObservedObject var voiceOSBridge: VoiceOSBridge
    @ObservedObject var overlayController: GazeOverlayController

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            canvas
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: application.selectedDisplayID) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.mappedPoint) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.snapshot) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.showsGazeOverlay) { _, _ in overlayController.update(application: application) }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("EagleGaze").font(.largeTitle.bold())
                    Text("Canonical gaze setup for macOS").foregroundStyle(.secondary)
                }

                sourcePicker
                displayPicker
                pairingCard
                sessionCard
                fineAdjustmentCard
                diagnosticsCard
                voiceOSCard

                Text("Mount the phone rigidly below the display center, with its front camera close to the lower bezel and aimed at your face from about 60 cm. Keep both devices still while calibrating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(width: 360)
    }

    private var sourcePicker: some View {
        GroupBox("Gaze source") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(application.sourceOptions) { option in
                    Button {
                        application.selectSource(option.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: option.isAvailable ? "checkmark.circle" : "nosign")
                                .foregroundStyle(option.isAvailable ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.headline)
                                Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if application.selectedSourceID == option.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isAvailable)
                }
                Text(application.sourceStatusText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayPicker: some View {
        GroupBox("Display and physical setup") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Destination display", selection: $application.selectedDisplayID) {
                    ForEach(application.displayProvider.displays) { display in
                        Text(display.isMain ? "\(display.name) (Main)" : display.name).tag(display.id)
                    }
                }
                .onChange(of: application.selectedDisplayID) { _, id in application.selectDisplay(id) }
                Text("Setup: default phone mount").font(.caption).foregroundStyle(.secondary)
                Text("Changing display pauses the active calibration context and clears the overlay until this display is calibrated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pairingCard: some View {
        GroupBox("Secure phone pairing") {
            VStack(alignment: .leading, spacing: 10) {
                switch application.pairingState {
                case .idle:
                    Text("Pairing uses a short-lived QR offer. A phone is not stored until you explicitly approve its verification code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !application.pairingControlAvailable {
                        Text("Secure pairing control is unavailable; no QR offer will be shown.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Show pairing QR") { application.beginPairingOffer() }
                        .buttonStyle(.bordered)
                case .offerVisible(let presentation):
                    PairingQRView(value: presentation.qrString)
                        .frame(maxWidth: .infinity)
                    Text("Scan this code from the iPhone. It expires \(presentation.offer.expiresAt, style: .time).")
                        .font(.caption)
                    Button("Cancel offer") { application.cancelPairingOffer() }
                        .buttonStyle(.bordered)
                case .awaitingConfirmation(let pending):
                    Text("Approve \(pending.displayName)?").font(.headline)
                    Text("Verification code: \(pending.verificationCode)")
                        .font(.title3.monospaced().weight(.semibold))
                    HStack {
                        Button("Approve") { application.confirmPairing() }.buttonStyle(.borderedProminent)
                        Button("Reject") { application.rejectPairing() }.buttonStyle(.bordered)
                    }
                case .paired(let record):
                    Label("Paired with \(record.displayName)", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("Pairing is separate from calibration; moving the phone requires a new setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionCard: some View {
        GroupBox("Calibration and evaluation") {
            VStack(alignment: .leading, spacing: 8) {
                Text(phaseTitle).font(.headline)
                Text(progressText).font(.body.monospacedDigit())
                if let error = application.snapshot.error {
                    Text(String(describing: error)).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    switch application.snapshot.phase {
                    case .idle, .failed:
                        Button("Start 3×3 calibration") { run { try application.startCalibration() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!application.isFresh)
                    case .calibrated:
                        Button("Start evaluation") { run { try application.startEvaluation() } }
                            .buttonStyle(.borderedProminent)
                    case .complete:
                        Button("Run evaluation again") { run { try application.startEvaluation() } }
                            .buttonStyle(.borderedProminent)
                    case .calibrating, .evaluating:
                        Text("Hold your gaze on the teal target.").font(.caption).foregroundStyle(.secondary)
                    }
                    if application.snapshot.phase != .idle {
                        Button("Reset") { run { try application.resetCalibration() } }
                    }
                }
                if application.snapshot.phase == .complete {
                    Text("\(application.snapshot.evaluationHits) of \(application.snapshot.trialCount) grid targets identified")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(application.snapshot.evaluationHits * 10 >= application.snapshot.trialCount * 9 ? .green : .orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fineAdjustmentCard: some View {
        GroupBox("Fine alignment") {
            VStack(alignment: .leading, spacing: 7) {
                adjustmentSlider("X scale", value: adjustmentBinding(\.scaleX), range: 0.5...1.5, format: "%.2f×")
                adjustmentSlider("Y scale", value: adjustmentBinding(\.scaleY), range: 0.5...1.5, format: "%.2f×")
                adjustmentSlider("X offset", value: adjustmentBinding(\.offsetX), range: -0.2...0.2, format: "%+.3f")
                adjustmentSlider("Y offset", value: adjustmentBinding(\.offsetY), range: -0.2...0.2, format: "%+.3f")
                Button("Reset fine alignment") { application.resetFineAdjustment() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func adjustmentSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .font(.caption)
    }

    private var diagnosticsCard: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 4) {
                Label(application.isFresh ? "Fresh canonical frame" : "No fresh frame", systemImage: application.isFresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(application.isFresh ? .green : .orange)
                if let frame = application.latestFrame {
                    Text("Validity: \(frame.validity.rawValue) • space: \(frame.coordinateSpace.rawValue)")
                    Text("Session: \(frame.sourceSessionID.uuidString.prefix(8)) • sequence \(frame.sequence)")
                }
                Text("Accepted \(application.receiver.acceptedPacketCount) • rejected \(application.receiver.rejectedPacketCount + application.receiver.decodeErrorCount)")
                if let error = application.lastError { Text(error).foregroundStyle(.red) }
            }
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var voiceOSCard: some View {
        GroupBox("VoiceOS") {
            Label(voiceOSBridge.status, systemImage: voiceOSBridge.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(voiceOSBridge.isListening ? .green : .orange)
            Text("VoiceOS receives connection, calibration, and evaluation state only; continuous gaze remains local.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                grid
                if let point = application.mappedPoint, application.isFresh, application.snapshot.phase != .calibrating {
                    Circle().fill(.pink.opacity(0.88)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(position(clamped(point), in: geometry.size))
                }
                if let target = application.snapshot.target {
                    targetView.position(position(target, in: geometry.size))
                }
                if application.snapshot.phase == .complete {
                    VStack(spacing: 10) {
                        Text(accuracyText).font(.system(size: 72, weight: .bold, design: .rounded))
                        Text("Grid evaluation complete").font(.title2)
                    }
                } else if application.snapshot.phase == .idle && !application.isFresh {
                    ContentUnavailableView("Connect the iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right", description: Text("Select ARKit and wait for a fresh stream, then start calibration."))
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

    private var targetView: some View {
        ZStack {
            Circle().fill(.teal).frame(width: 42, height: 42)
            Circle().stroke(.white, lineWidth: 3).frame(width: 42, height: 42)
            Circle().fill(.white).frame(width: 7, height: 7)
        }
        .shadow(color: .black.opacity(0.5), radius: 5)
    }

    private var phaseTitle: String {
        switch application.snapshot.phase {
        case .idle: "Ready to calibrate"
        case .calibrating: "Calibrating"
        case .calibrated: "Calibration complete"
        case .evaluating: "Evaluating"
        case .complete: "Evaluation complete"
        case .failed: "Calibration failed"
        }
    }

    private var progressText: String {
        switch application.snapshot.phase {
        case .calibrating: "Point \(min(application.snapshot.targetIndex + 1, application.snapshot.targetCount)) of \(application.snapshot.targetCount)"
        case .calibrated: "\(application.snapshot.targetCount) points fitted"
        case .evaluating, .complete: "\(application.snapshot.evaluationHits) / \(application.snapshot.trialIndex) hits"
        default: "No calibration"
        }
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

    private func position(_ point: Point2D, in size: CGSize) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
    private func clamped(_ point: Point2D) -> Point2D { Point2D(x: min(max(point.x, 0.015), 0.985), y: min(max(point.y, 0.015), 0.985)) }
}
