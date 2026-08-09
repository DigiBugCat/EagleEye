import Foundation

/// Main-actor contract for a camera-backed face tracker.
///
/// Implementations keep SDK objects (ARSession, anchors, transforms) at the
/// edge. The only value crossing into the application pipeline is a copied,
/// Sendable `FaceCaptureEvent`.
@MainActor
protocol FaceTrackingSource: AnyObject {
    var status: String { get }
    var isTracking: Bool { get }
    var onCaptureEvent: (@MainActor @Sendable (FaceCaptureEvent) -> Void)? { get set }

    @discardableResult
    func start() -> UInt64
    func stop()
}

extension FaceTrackingService: FaceTrackingSource {}
