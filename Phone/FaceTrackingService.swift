import ARKit
import Foundation
import OSLog
import simd

private let faceTrackingLog = Logger(subsystem: "com.aviary.EagleGazePhone", category: "face-tracking")

struct FaceCapture: Sendable {
    let captureUptime: TimeInterval
    let isTracked: Bool
    let lookAt: SIMD3<Float>
    let faceTransform: [Double]
    let leftEyeTransform: [Double]
    let rightEyeTransform: [Double]
    let blinkLeft: Float
    let blinkRight: Float
}

/// A copied capture paired with the AR session generation that produced it.
/// Delegate callbacks can be queued while a session is paused; consumers use
/// this token to reject those late values after a lifecycle transition.
struct FaceCaptureEvent: Sendable {
    let capture: FaceCapture
    let generation: UInt64
}

@MainActor
final class FaceTrackingService: NSObject, ObservableObject {
    @Published private(set) var status = "Face tracking is stopped"
    @Published private(set) var isTracking = false

    /// Generation-aware callback for the modular pipeline.
    var onCaptureEvent: (@MainActor @Sendable (FaceCaptureEvent) -> Void)?

    private let session = ARSession()
    private let delegateQueue = DispatchQueue(label: "com.eaglegaze.phone.arkit")
    nonisolated private let generationStore = FaceTrackingGenerationStore()
    private var isRunning = false
    private var hasReceivedCapture = false
    private var startupWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    @discardableResult
    func start() -> UInt64 {
        guard !isRunning else { return generationStore.current }
        guard ARFaceTrackingConfiguration.isSupported else {
            faceTrackingLog.error("ARKit face tracking unsupported on this device")
            status = "This iPhone does not support ARKit face tracking"
            isTracking = false
            return generationStore.current
        }

        let generation = generationStore.advance()
        isRunning = true
        hasReceivedCapture = false
        startupWatchdog?.cancel()
        status = "Starting TrueDepth face tracking…"
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        faceTrackingLog.notice("TrueDepth face tracking started generation=\(generation, privacy: .public)")
        startupWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.isRunning, !self.hasReceivedCapture else { return }
            self.status = "Move your face into view of the TrueDepth camera"
            faceTrackingLog.warning("TrueDepth started but no face anchor arrived within four seconds")
        }
        return generation
    }

    func stop() {
        // Invalidate queued delegate work even if ARKit is already paused.
        generationStore.advance()
        startupWatchdog?.cancel()
        startupWatchdog = nil
        guard isRunning else { return }
        isRunning = false
        session.pause()
        isTracking = false
        status = "Face tracking is paused while the app is not active"
        faceTrackingLog.info("TrueDepth face tracking stopped")
    }

    private func receive(_ event: FaceCaptureEvent) {
        guard isRunning, event.generation == generationStore.current else { return }
        if !hasReceivedCapture {
            hasReceivedCapture = true
            startupWatchdog?.cancel()
            startupWatchdog = nil
            faceTrackingLog.notice("First TrueDepth face anchor received tracked=\(event.capture.isTracked, privacy: .public)")
        }
        let capture = event.capture
        isTracking = capture.isTracked
        status = capture.isTracked ? "Face and eyes are tracking" : "Face found; eye tracking is limited"
        onCaptureEvent?(event)
    }
}

extension FaceTrackingService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        let capture = FaceCapture(
            captureUptime: ProcessInfo.processInfo.systemUptime,
            isTracked: face.isTracked,
            lookAt: face.lookAtPoint,
            faceTransform: Self.flatten(face.transform),
            leftEyeTransform: Self.flatten(face.leftEyeTransform),
            rightEyeTransform: Self.flatten(face.rightEyeTransform),
            blinkLeft: face.blendShapes[.eyeBlinkLeft]?.floatValue ?? 0,
            blinkRight: face.blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        )

        // Everything crossing from the ARKit delegate queue is an immutable
        // value. The generation is read at callback time, then checked again
        // on the main actor before publication.
        let event = FaceCaptureEvent(capture: capture, generation: generationStore.current)
        Task { @MainActor [weak self, event] in
            self?.receive(event)
        }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state: String
        switch camera.trackingState {
        case .normal: state = "normal"
        case .notAvailable: state = "not-available"
        case .limited(let reason): state = "limited-\(String(describing: reason))"
        }
        faceTrackingLog.info("ARKit camera tracking state=\(state, privacy: .public)")
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARFaceAnchor }) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.isTracking = false
            self.status = "Move your face into view of the TrueDepth camera"
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        faceTrackingLog.error("ARKit session failed error=\(message, privacy: .public)")
        Task { @MainActor [weak self] in
            self?.isTracking = false
            self?.status = "ARKit error: \(message)"
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        faceTrackingLog.warning("ARKit session interrupted")
        Task { @MainActor [weak self] in
            self?.isTracking = false
            self?.status = "Face tracking was interrupted"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        faceTrackingLog.notice("ARKit interruption ended; restarting tracking")
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            let configuration = ARFaceTrackingConfiguration()
            configuration.isLightEstimationEnabled = false
            self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            self.status = "Restarting face tracking…"
        }
    }

    nonisolated private static func flatten(_ matrix: simd_float4x4) -> [Double] {
        [
            Double(matrix.columns.0.x), Double(matrix.columns.0.y), Double(matrix.columns.0.z), Double(matrix.columns.0.w),
            Double(matrix.columns.1.x), Double(matrix.columns.1.y), Double(matrix.columns.1.z), Double(matrix.columns.1.w),
            Double(matrix.columns.2.x), Double(matrix.columns.2.y), Double(matrix.columns.2.z), Double(matrix.columns.2.w),
            Double(matrix.columns.3.x), Double(matrix.columns.3.y), Double(matrix.columns.3.z), Double(matrix.columns.3.w),
        ]
    }
}

/// Tiny lock-backed token store used only at the ARSession queue boundary.
/// ARKit invokes delegate methods off the main actor, while lifecycle methods
/// run on the main actor. Keeping the token in this Sendable box avoids
/// crossing mutable actor-isolated state into a delegate callback.
private final class FaceTrackingGenerationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}
