import SwiftUI
import GazeCore
import UIKit

@main
struct EagleGazePhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PhoneAppModel()

    var body: some Scene {
        WindowGroup {
            PhoneStatusView(
                faceTracking: model.faceTracking,
                sender: model.sender
            )
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                model.start()
            case .inactive, .background:
                model.stop()
            @unknown default:
                model.stop()
            }
        }
    }
}

@MainActor
final class PhoneAppModel: ObservableObject {
    @Published private(set) var isRunning = false

    let faceTracking = FaceTrackingService()
    let sender = GazeSender()

    private let sessionID = UUID()
    private var sequence: UInt64 = 0

    init() {
        faceTracking.onCapture = { [weak self] capture in
            guard let self else { return }

            guard let faceTransform = try? Matrix4x4(elements: capture.faceTransform),
                  let leftEyeTransform = try? Matrix4x4(elements: capture.leftEyeTransform),
                  let rightEyeTransform = try? Matrix4x4(elements: capture.rightEyeTransform) else {
                return
            }

            sequence &+= 1
            let sample = GazeSample(
                version: GazeSample.currentVersion,
                sessionID: sessionID,
                sequence: sequence,
                captureUptime: capture.captureUptime,
                sentUptime: ProcessInfo.processInfo.systemUptime,
                isTracked: capture.isTracked,
                lookAt: Vector3(
                    x: Double(capture.lookAt.x),
                    y: Double(capture.lookAt.y),
                    z: Double(capture.lookAt.z)
                ),
                faceTransform: faceTransform,
                leftEyeTransform: leftEyeTransform,
                rightEyeTransform: rightEyeTransform,
                leftBlink: Double(capture.blinkLeft),
                rightBlink: Double(capture.blinkRight)
            )
            sender.sendLatest(sample)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        sender.start()
        faceTracking.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        faceTracking.stop()
        sender.stop()
    }
}

private struct PhoneStatusView: View {
    @ObservedObject var faceTracking: FaceTrackingService
    @ObservedObject var sender: GazeSender

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: faceTracking.isTracking ? "eye.circle.fill" : "eye.slash.circle")
                    .font(.system(size: 72))
                    .foregroundStyle(faceTracking.isTracking ? .green : .secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(faceTracking.status)
                        .font(.title2.weight(.semibold))
                    Text(sender.status)
                        .font(.body.monospaced())
                        .foregroundStyle(sender.isConnected ? .green : .secondary)
                        .multilineTextAlignment(.center)
                }

                if let lookAt = faceTracking.latestLookAt {
                    VStack(spacing: 6) {
                        Text("ARKit look-at point")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "x %+.3f   y %+.3f   z %+.3f", lookAt.x, lookAt.y, lookAt.z))
                            .font(.body.monospacedDigit())
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Mount the phone directly below the center of the Mac display.", systemImage: "iphone.gen3")
                    Label("Aim the TrueDepth camera at your face from arm's length.", systemImage: "ruler")
                    Label("This build only streams measurements; it cannot control the cursor.", systemImage: "cursorarrow.slash")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding(28)
            .navigationTitle("Eagle Gaze")
        }
    }
}
