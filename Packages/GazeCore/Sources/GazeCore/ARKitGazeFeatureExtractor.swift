import Foundation

/// Pure conversion of an ARKit wire sample into the source-coordinate gaze
/// contract.  It deliberately depends only on GazeCore value types, so it can
/// run on either side of the transport and can be tested without ARKit.
public struct ARKitGazeFeatureExtractor: Sendable {
    public init() {}

    public func extract(
        from sample: GazeSample,
        sourceID: GazeSourceID
    ) -> CanonicalGazeFrame? {
        Self.extract(from: sample, sourceID: sourceID)
    }

    public func extract(
        _ sample: GazeSample,
        sourceID: GazeSourceID
    ) -> CanonicalGazeFrame? {
        extract(from: sample, sourceID: sourceID)
    }

    public static func extract(
        from sample: GazeSample,
        sourceID: GazeSourceID
    ) -> CanonicalGazeFrame? {
        guard sourceID.isValid,
              sample.lookAt.x.isFinite,
              sample.lookAt.y.isFinite,
              sample.lookAt.z.isFinite
        else { return nil }

        let left = sample.leftEyeTransform.elements
        let right = sample.rightEyeTransform.elements
        let eyeInFace = Vector3(
            x: (left[12] + right[12]) / 2,
            y: (left[13] + right[13]) / 2,
            z: (left[14] + right[14]) / 2
        )

        let eyeInSession = transform(point: eyeInFace, by: sample.faceTransform)
        let targetInSession = transform(point: sample.lookAt, by: sample.faceTransform)
        let dx = targetInSession.x - eyeInSession.x
        let dy = targetInSession.y - eyeInSession.y
        let dz = targetInSession.z - eyeInSession.z

        // A near-zero depth makes the perspective ratio unstable.  Returning
        // nil lets the adapter drop this frame without publishing a bogus
        // point or leaking raw ARKit matrices to downstream consumers.
        guard dx.isFinite, dy.isFinite, dz.isFinite, abs(dz) > 1e-6 else {
            return nil
        }

        let projectedX = dx / dz
        let projectedY = dy / dz
        guard projectedX.isFinite, projectedY.isFinite else {
            // Finite matrix components can still produce an overflowing
            // perspective ratio (for example, a very large lateral offset
            // divided by a small but valid depth). Never publish an infinite
            // canonical point.
            return nil
        }

        let leftBlink = sample.leftBlink
        let rightBlink = sample.rightBlink
        let blink: BlinkState?
        let blinkConfidence: Double?
        if leftBlink.isFinite, rightBlink.isFinite {
            let mean = max(0, min(1, (leftBlink + rightBlink) / 2))
            blink = max(leftBlink, rightBlink) >= 0.75 ? .closed : .open
            blinkConfidence = mean
        } else {
            blink = .unknown
            blinkConfidence = nil
        }

        return CanonicalGazeFrame(
            sourceID: sourceID,
            sourceSessionID: sample.sessionID,
            sequence: sample.sequence,
            captureUptime: sample.captureUptime,
            // `isTracked == false` is represented as an invalid canonical
            // point.  The source wire model retains the more specific
            // tracking bit; canonical consumers only need the validity gate.
            validity: sample.isTracked ? .valid : .invalid,
            confidence: sample.isTracked ? 1 : 0,
            point: Point2D(x: projectedX, y: projectedY),
            coordinateSpace: .source,
            blink: blink,
            blinkConfidence: blinkConfidence
        )
    }

    public static func extract(
        _ sample: GazeSample,
        sourceID: GazeSourceID
    ) -> CanonicalGazeFrame? {
        extract(from: sample, sourceID: sourceID)
    }

    private static func transform(point: Vector3, by matrix: Matrix4x4) -> Vector3 {
        let m = matrix.elements
        // Matrix4x4 is column-major, matching simd_float4x4's flattened
        // columns and the original ARKit integration.
        return Vector3(
            x: m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
            y: m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
            z: m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14]
        )
    }
}
