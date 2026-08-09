import Foundation
import GazeCore

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

    init(sourceID: GazeSourceID = GazeSourceID("iphone-arkit")) {
        self.sourceID = sourceID
    }

    /// Starts a fresh logical stream and resets its wire sequence.
    @discardableResult
    func start(sessionID: UUID = UUID(), generation sourceGeneration: UInt64? = nil) -> UInt64 {
        generation = sourceGeneration ?? (generation &+ 1)
        streamSessionID = sessionID
        sequence = 0
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
    }

    /// Ingests one generation-tagged edge capture. This method is synchronous
    /// on the main actor by design: no unbounded task queue can form here.
    func ingest(_ event: FaceCaptureEvent) {
        guard event.generation == generation,
              let streamSessionID else { return }
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
        guard let frame = extractor.extract(from: sample, sourceID: sourceID) else { return }
        sequence = nextSequence
        onFrame?(frame)
        // Compatibility transport receives the original wire sample only at
        // this edge; canonical consumers above never see raw transforms.
        onLegacySample?(sample)
    }
}

extension PhoneGazePipeline: CanonicalGazeFrameSink {
    func receive(_ frame: CanonicalGazeFrame) {
        onFrame?(frame)
    }
}

extension PhoneGazePipeline: GazeFramePipeline {}
