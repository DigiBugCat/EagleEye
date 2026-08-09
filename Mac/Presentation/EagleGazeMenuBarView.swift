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
        if phase == .calibrating { return .calibrating }
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
        case .connected: .blue
        case .calibrating: .teal
        case .evaluating: .purple
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
            hasSource: application.activeSource != nil,
            isFresh: application.isFresh,
            phase: application.snapshot.phase,
            hasProfile: application.snapshot.profile != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: status.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(status.tint)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.headline)
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
                Text("Verification code \(pending.verificationCode)")
                    .font(.body.monospaced().weight(.semibold))
                HStack {
                    Button("Approve") { application.confirmPairing() }
                        .buttonStyle(.borderedProminent)
                    Button("Review…") { showMainWindow() }
                        .buttonStyle(.bordered)
                }
            }
        default:
            HStack {
                if application.activeSource == nil {
                    Button("Pair iPhone…") {
                        application.beginPairingOffer()
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
                    Button("Reset…") { showMainWindow() }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
        }
    }

    private var calibrationSummary: String {
        switch application.snapshot.phase {
        case .idle: "Not calibrated"
        case .calibrating: "Point \(min(application.snapshot.targetIndex + 1, application.snapshot.targetCount)) of \(application.snapshot.targetCount)"
        case .calibrated: "Calibration saved"
        case .evaluating: "Trial \(min(application.snapshot.trialIndex + 1, application.snapshot.trialCount)) of \(application.snapshot.trialCount)"
        case .complete: "Evaluation: \(application.snapshot.evaluationHits) of \(application.snapshot.trialCount) hits"
        case .failed: "Calibration needs attention"
        }
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
            hasSource: application.activeSource != nil,
            isFresh: application.isFresh,
            phase: application.snapshot.phase,
            hasProfile: application.snapshot.profile != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: status.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(status.tint)
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
        .onAppear { overlayController.show(application: application) }
        .onChange(of: application.mappedPoint) { _, _ in overlayController.update(application: application) }
        .onChange(of: application.snapshot) { _, _ in overlayController.update(application: application) }
    }
}
