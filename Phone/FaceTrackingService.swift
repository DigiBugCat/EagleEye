import ARKit
import Foundation
import simd

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

@MainActor
final class FaceTrackingService: NSObject, ObservableObject {
    @Published private(set) var status = "Face tracking is stopped"
    @Published private(set) var isTracking = false
    @Published private(set) var latestLookAt: SIMD3<Float>?

    var onCapture: ((FaceCapture) -> Void)?

    private let session = ARSession()
    private let delegateQueue = DispatchQueue(label: "com.eaglegaze.phone.arkit")
    private var isRunning = false

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = delegateQueue
    }

    func start() {
        guard !isRunning else { return }
        guard ARFaceTrackingConfiguration.isSupported else {
            status = "This iPhone does not support ARKit face tracking"
            isTracking = false
            return
        }

        isRunning = true
        status = "Starting TrueDepth face tracking…"
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session.pause()
        isTracking = false
        latestLookAt = nil
        status = "Face tracking is paused while the app is not active"
    }

    private func receive(_ capture: FaceCapture) {
        guard isRunning else { return }
        isTracking = capture.isTracked
        latestLookAt = capture.lookAt
        status = capture.isTracked ? "Face and eyes are tracking" : "Face found; eye tracking is limited"
        onCapture?(capture)
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

        Task { @MainActor [weak self] in
            self?.receive(capture)
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARFaceAnchor }) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.isTracking = false
            self.latestLookAt = nil
            self.status = "Move your face into view of the TrueDepth camera"
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.isTracking = false
            self?.status = "ARKit error: \(message)"
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.isTracking = false
            self?.status = "Face tracking was interrupted"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
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
