import Foundation
import GazeCore
import OSLog

private let phonePipelineLog = Logger(subsystem: "com.aviary.EagleGazePhone", category: "gaze-pipeline")

/// A consumer of source-independent gaze frames. Keeping this protocol free of
/// ARKit and transport types makes the pipeline straightforward to compose in
/// tests and with future tracker implementations.
@MainActor
protocol CanonicalGazeFrameSink: AnyObject {
    func receive(_ frame: CanonicalGazeFrame)
}

/// Composition contract for a phone source pipeline. Implementations must
/// reject captures whose generation does not match the active stream.
@MainActor
protocol GazeFramePipeline: AnyObject {
    var sourceID: GazeSourceID { get }
    var streamSessionID: UUID? { get }
    var generation: UInt64 { get }
    @discardableResult
    func start(sessionID: UUID) -> UInt64
    func stop()
    func ingest(_ event: FaceCaptureEvent)
}

/// Converts copied ARKit edge values to GazeCore's canonical contract.
///
/// The legacy sample callback is intentionally an adapter seam for the current
/// UDP sender. New consumers should use `onFrame`; raw matrices never appear
/// in that callback. A generation token is required on ingestion so callbacks
/// already queued before backgrounding cannot enter a new stream.
@MainActor
final class PhoneGazePipeline {
    typealias FrameHandler = @MainActor @Sendable (CanonicalGazeFrame) -> Void
    typealias LegacySampleHandler = @MainActor @Sendable (GazeSample) -> Void

    let sourceID: GazeSourceID
    var onFrame: FrameHandler?
    var onLegacySample: LegacySampleHandler?

    private let extractor = ARKitGazeFeatureExtractor()
    private(set) var streamSessionID: UUID?
    private(set) var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var hasLoggedFirstFrame = false
    private var lastDropReason: String?
    private var previousGeometry: GazeGeometrySample?
    private var previousGeometryTimestamp: TimeInterval?

    init(sourceID: GazeSourceID = GazeSourceID("iphone-arkit")) {
        self.sourceID = sourceID
    }

    /// Starts a fresh logical stream and resets its wire sequence.
    @discardableResult
    func start(sessionID: UUID = UUID(), generation sourceGeneration: UInt64? = nil) -> UInt64 {
        generation = sourceGeneration ?? (generation &+ 1)
        streamSessionID = sessionID
        sequence = 0
        hasLoggedFirstFrame = false
        lastDropReason = nil
        previousGeometry = nil
        previousGeometryTimestamp = nil
        phonePipelineLog.notice("Gaze pipeline started generation=\(self.generation, privacy: .public) session=\(sessionID.uuidString.prefix(8), privacy: .public)")
        return generation
    }

    @discardableResult
    func start(sessionID: UUID) -> UInt64 {
        start(sessionID: sessionID, generation: nil)
    }

    /// Invalidates all queued captures from the current stream.
    func stop() {
        generation &+= 1
        streamSessionID = nil
        sequence = 0
        hasLoggedFirstFrame = false
        lastDropReason = nil
        previousGeometry = nil
        previousGeometryTimestamp = nil
        phonePipelineLog.info("Gaze pipeline stopped")
    }

    /// Ingests one generation-tagged edge capture. This method is synchronous
    /// on the main actor by design: no unbounded task queue can form here.
    func ingest(_ event: FaceCaptureEvent) {
        guard event.generation == generation else {
            logDrop("generation-mismatch event=\(event.generation) pipeline=\(generation)")
            return
        }
        guard let streamSessionID else {
            logDrop("no-stream-session")
            return
        }
        ingest(event.capture, generation: event.generation, sessionID: streamSessionID)
    }

    /// Test and adapter seam for callers that already hold a copied capture.
    func ingest(_ capture: FaceCapture, generation: UInt64) {
        guard let streamSessionID else { return }
        ingest(capture, generation: generation, sessionID: streamSessionID)
    }

    private func ingest(_ capture: FaceCapture, generation: UInt64, sessionID: UUID) {
        guard generation == self.generation, streamSessionID == sessionID else { return }

        guard let faceTransform = try? Matrix4x4(elements: capture.faceTransform),
              let leftEyeTransform = try? Matrix4x4(elements: capture.leftEyeTransform),
              let rightEyeTransform = try? Matrix4x4(elements: capture.rightEyeTransform) else {
            logDrop("invalid-transform")
            return
        }

        let nextSequence = sequence &+ 1
        let sample = GazeSample(
            version: GazeSample.currentVersion,
            sessionID: sessionID,
            sequence: nextSequence,
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

        // Extraction is the sole conversion from the ARKit wire model to the
        // source-independent contract. Drop malformed geometry at this edge.
        guard let extractedFrame = extractor.extract(from: sample, sourceID: sourceID) else {
            logDrop("feature-extraction-failed")
            return
        }
        let metrics = trackingMetrics(
            face: faceTransform,
            leftEye: leftEyeTransform,
            rightEye: rightEyeTransform,
            capture: capture
        )
        let frame = CanonicalGazeFrame(
            sourceID: extractedFrame.sourceID,
            sourceSessionID: extractedFrame.sourceSessionID,
            sequence: extractedFrame.sequence,
            captureUptime: extractedFrame.captureUptime,
            validity: extractedFrame.validity,
            confidence: extractedFrame.confidence,
            point: extractedFrame.point,
            coordinateSpace: extractedFrame.coordinateSpace,
            blink: extractedFrame.blink,
            blinkConfidence: extractedFrame.blinkConfidence,
            trackingRunID: generation,
            trackingMetrics: metrics
        )
        sequence = nextSequence
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            phonePipelineLog.notice(
                "First canonical gaze frame produced generation=\(generation, privacy: .public) session=\(sessionID.uuidString.prefix(8), privacy: .public) tracked=\(capture.isTracked, privacy: .public)"
            )
        }
        onFrame?(frame)
        // Compatibility transport receives the original wire sample only at
        // this edge; canonical consumers above never see raw transforms.
        onLegacySample?(sample)
    }

    private func trackingMetrics(
        face: Matrix4x4,
        leftEye: Matrix4x4,
        rightEye: Matrix4x4,
        capture: FaceCapture
    ) -> GazeTrackingMetrics {
        let faceElements = face.elements
        let left = leftEye.elements
        let right = rightEye.elements
        let position = Vector3(x: faceElements[12], y: faceElements[13], z: faceElements[14])
        let forward = normalized(Vector3(x: faceElements[8], y: faceElements[9], z: faceElements[10]))
        let eyeSeparation = vectorDistance(
            Vector3(x: left[12], y: left[13], z: left[14]),
            Vector3(x: right[12], y: right[13], z: right[14])
        )
        let geometry = GazeGeometrySample(
            facePosition: position,
            faceForward: forward,
            eyeSeparation: eyeSeparation
        )

        let deltaTime = previousGeometryTimestamp.map { capture.captureUptime - $0 } ?? 0
        let linearVelocity: Double
        let angularVelocity: Double
        if let previousGeometry, deltaTime > 1.0 / 240, deltaTime < 0.5 {
            linearVelocity = vectorDistance(position, previousGeometry.facePosition) / deltaTime
            let dot = max(-1, min(1, vectorDot(forward, previousGeometry.faceForward)))
            angularVelocity = acos(dot) / deltaTime
        } else {
            linearVelocity = 0
            angularVelocity = 0
        }
        previousGeometry = geometry
        previousGeometryTimestamp = capture.captureUptime

        let bothEyesUsable = capture.isTracked
            && capture.blinkLeft < 0.75
            && capture.blinkRight < 0.75
            && eyeSeparation.isFinite
            && eyeSeparation >= 0.025
            && eyeSeparation <= 0.09

        if sequence.isMultiple(of: 120) {
            phonePipelineLog.debug(
                "Tracking quality generation=\(self.generation, privacy: .public) eyes=\(bothEyesUsable, privacy: .public) linear=\(linearVelocity, format: .fixed(precision: 3), privacy: .public)mps angular=\(angularVelocity, format: .fixed(precision: 3), privacy: .public)radps"
            )
        }
        return GazeTrackingMetrics(
            bothEyesUsable: bothEyesUsable,
            headAngularVelocity: angularVelocity,
            headLinearVelocity: linearVelocity,
            geometry: geometry.isFinite ? geometry : nil
        )
    }

    private func normalized(_ value: Vector3) -> Vector3 {
        let magnitude = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        guard magnitude.isFinite, magnitude > 1e-9 else { return Vector3(x: 0, y: 0, z: 1) }
        return Vector3(x: value.x / magnitude, y: value.y / magnitude, z: value.z / magnitude)
    }

    private func vectorDistance(_ a: Vector3, _ b: Vector3) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func vectorDot(_ a: Vector3, _ b: Vector3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private func logDrop(_ reason: String) {
        guard reason != lastDropReason else { return }
        lastDropReason = reason
        phonePipelineLog.error("Gaze capture dropped reason=\(reason, privacy: .public)")
    }
}

extension PhoneGazePipeline: CanonicalGazeFrameSink {
    func receive(_ frame: CanonicalGazeFrame) {
        onFrame?(frame)
    }
}

extension PhoneGazePipeline: GazeFramePipeline {}
