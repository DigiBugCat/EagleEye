import AppKit
import GazeCore
import SwiftUI

/// A compact, presentation-only projection used by the menu-bar icon and
/// popover. Keeping this resolver independent of AppKit makes status priority
/// deterministic and directly testable.
enum EagleGazeMenuBarStatus: Equatable {
    case needsPhone
    case waiting
    case connected
    case calibrating
    case evaluating
    case ready

    static func resolve(
        hasSource: Bool,
        isFresh: Bool,
        phase: CalibrationEnginePhase,
        hasProfile: Bool
    ) -> Self {
        guard hasSource else { return .needsPhone }
        guard isFresh else { return .waiting }
        if phase == .calibrating || phase == .validating || phase == .recentering { return .calibrating }
        if phase == .evaluating { return .evaluating }
        return hasProfile ? .ready : .connected
    }

    var title: String {
        switch self {
        case .needsPhone: "Pair an iPhone"
        case .waiting: "Waiting for iPhone"
        case .connected: "Ready to calibrate"
        case .calibrating: "Calibrating"
        case .evaluating: "Evaluating"
        case .ready: "Live tracking"
        }
    }

    var detail: String {
        switch self {
        case .needsPhone: "Open EagleGaze to create a secure pairing code."
        case .waiting: "The selected source has not sent a fresh gaze frame."
        case .connected: "The stream is live; calibration is the next step."
        case .calibrating: "Keep looking at the target on the selected display."
        case .evaluating: "Evaluation is measuring the current calibration."
        case .ready: "Calibrated gaze is available on this Mac."
        }
    }

    var symbolName: String {
        switch self {
        case .needsPhone: "iphone.gen3.radiowaves.left.and.right"
        case .waiting: "eye.slash.circle"
        case .connected: "scope"
        case .calibrating: "dot.scope"
        case .evaluating: "checkmark.circle"
        case .ready: "eye.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsPhone, .waiting: .orange
        case .connected, .calibrating, .evaluating: .blue
        case .ready: .green
        }
    }
}

struct EagleGazeMenuBarView: View {
    @ObservedObject var application: EagleGazeApplication
    @ObservedObject var overlayController: GazeOverlayController
    @Environment(\.openWindow) private var openWindow

    private var status: EagleGazeMenuBarStatus {
        .resolve(
            hasSource: application.hasAuthenticatedPhoneSession,
            isFresh: application.isFresh,
            phase: application.snapshot.phase,
            hasProfile: application.snapshot.profile != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: status.symbolName)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(status.title).font(.headline)
                        liveStatusDot
                    }
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label(application.sourceStatusText, systemImage: application.isFresh ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                Label(application.selectedDisplay?.name ?? "No display selected", systemImage: "display")
                Label(calibrationSummary, systemImage: application.snapshot.profile == nil ? "scope" : "checkmark.seal.fill")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1) }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let error = application.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionArea

            Toggle("Show gaze overlay", isOn: overlayBinding)
                .disabled(application.snapshot.profile == nil)

            Divider()

            HStack {
                Button("Open EagleGaze…") { showMainWindow() }
                    .keyboardShortcut("o")
                Button("Status window") { showStatusWindow() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 330)
        .tint(Color.blue)
        .onAppear { overlayController.show(application: application) }
        .onChange(of: application.mappedPoint) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.showsGazeOverlay) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.snapshot) { _, _ in overlayController.update(application: application) }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch application.pairingState {
        case .awaitingConfirmation(let pending):
            VStack(alignment: .leading, spacing: 8) {
                Text("Approve \(pending.displayName)?")
                    .font(.headline)
                Text("Code \(formattedVerificationCode(pending.verificationCode))")
                    .font(.body.monospaced().weight(.semibold))
                HStack {
                    Button("Approve") { application.confirmPairing() }
                        .buttonStyle(.borderedProminent)
                    Button("Review…") { showMainWindow() }
                        .buttonStyle(.bordered)
                }
            }
        default:
            if isTargetPhase {
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: application.snapshot.targetProgress)
                        .tint(.teal)
                    Text(calibrationSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Open calibration window…") { showMainWindow() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    if !application.hasAuthenticatedPhoneSession {
                    Button("Pair iPhone…") {
                        showMainWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!application.pairingControlAvailable)
                } else if application.snapshot.profile == nil {
                    Button("Start calibration") { run { try application.startCalibration() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!application.isFresh)
                } else {
                    Button("Start evaluation") { run { try application.startEvaluation() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!application.isFresh)
                    Button("Recalibrate") {
                        run {
                            try application.recalibrateEagleEye()
                            showMainWindow()
                        }
                    }
                        .buttonStyle(.bordered)
                        .disabled(!application.isFresh)
                }
                    Spacer()
                }
            }
        }
    }

    private var calibrationSummary: String {
        switch application.snapshot.phase {
        case .idle: "Not calibrated"
        case .calibrating: "Point \(min(application.snapshot.targetIndex + 1, application.snapshot.targetCount)) of \(application.snapshot.targetCount)"
        case .validating: "Validation \(min(application.snapshot.trialIndex + 1, application.snapshot.trialCount)) of \(application.snapshot.trialCount)"
        case .recentering: "Recentering on the display center"
        case .calibrated: "Calibration saved"
        case .evaluating: "Trial \(min(application.snapshot.trialIndex + 1, application.snapshot.trialCount)) of \(application.snapshot.trialCount)"
        case .complete: "Evaluation: \(application.snapshot.evaluationHits) of \(application.snapshot.trialCount) hits"
        case .failed: "Calibration needs attention"
        }
    }

    private var isTargetPhase: Bool {
        switch application.snapshot.phase {
        case .calibrating, .validating, .recentering, .evaluating: true
        case .idle, .calibrated, .complete, .failed: false
        }
    }

    private var liveStatusDot: some View {
        TimelineView(.animation(minimumInterval: 0.14, paused: !application.isFresh)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let pulse = (sin(phase * .pi * 2) + 1) / 2
            ZStack {
                if application.isFresh {
                    Circle()
                        .fill(Color.blue.opacity(0.18 * (1 - pulse)))
                        .frame(width: 16, height: 16)
                        .scaleEffect(0.8 + pulse * 0.4)
                }
                Circle().fill(status.tint).frame(width: 7, height: 7)
            }
        }
        .frame(width: 16, height: 16)
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

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: EagleGazeSceneID.mainWindow)
    }

    private func showStatusWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: EagleGazeSceneID.statusWindow)
    }

    private func run(_ action: () throws -> Void) {
        do { try action() }
        catch { application.lastError = error.localizedDescription }
    }

    private func formattedVerificationCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// A small persistent window for people who prefer a visible corner status
/// surface over a transient menu-bar popover. It intentionally carries only
/// coarse state and controls; setup and diagnostics remain in the main window.
struct EagleGazeCompactStatusView: View {
    @ObservedObject var application: EagleGazeApplication
    @ObservedObject var overlayController: GazeOverlayController
    @Environment(\.openWindow) private var openWindow

    private var status: EagleGazeMenuBarStatus {
        .resolve(
            hasSource: application.hasAuthenticatedPhoneSession,
            isFresh: application.isFresh,
            phase: application.snapshot.phase,
            hasProfile: application.snapshot.profile != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: status.symbolName)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EagleGaze").font(.headline)
                    Text(status.title).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(status.tint)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(status.title)
            }

            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show gaze overlay", isOn: Binding(
                get: { application.showsGazeOverlay },
                set: { value in
                    application.showsGazeOverlay = value
                    overlayController.update(application: application)
                }
            ))
            .disabled(application.snapshot.profile == nil)
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1) }

            HStack {
                Text(application.selectedDisplay?.name ?? "No display selected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Open setup…") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: EagleGazeSceneID.mainWindow)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .tint(Color.blue)
        .onAppear { overlayController.show(application: application) }
        .onChange(of: application.mappedPoint) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.snapshot) { _, _ in overlayController.update(application: application) }
    }
}
