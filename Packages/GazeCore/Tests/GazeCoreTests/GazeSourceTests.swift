import Foundation
import Testing
@testable import GazeCore

@Test func sourceDescriptorRoundTripsStableIdentityAndCapabilities() throws {
    let descriptor = GazeSourceDescriptor(
        id: GazeSourceID("phone.true-depth.01"),
        kind: .arkitRemote,
        displayName: "iPhone TrueDepth",
        capabilities: [.eyeTracking, .blinkDetection, .sourceCoordinates]
    )

    let decoded = try JSONDecoder().decode(
        GazeSourceDescriptor.self,
        from: JSONEncoder().encode(descriptor)
    )
    #expect(decoded == descriptor)
    #expect(decoded.id.rawValue == "phone.true-depth.01")
    #expect(decoded.id.isValid)
    #expect(decoded.capabilities.contains(.gaze))
    #expect(decoded.capabilities.contains(.blink))
    #expect(!decoded.capabilities.contains(.displayNormalized))
}

@Test func sourceKindPreservesCustomKindsAndUnknownWireValues() throws {
    let custom: GazeSourceKind = .custom("vendor.sdk.v2")
    let customDecoded = try JSONDecoder().decode(
        GazeSourceKind.self,
        from: JSONEncoder().encode(custom)
    )
    #expect(customDecoded == custom)

    let unknown = Data(#"{"kind":"future-tracker"}"#.utf8)
    #expect(try JSONDecoder().decode(GazeSourceKind.self, from: unknown) == .custom("future-tracker"))
}

@Test func canonicalFrameRoundTripsAndExposesSessionAlias() throws {
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    let frame = CanonicalGazeFrame(
        sourceID: "phone-1",
        sourceSessionID: sessionID,
        sequence: 14,
        captureUptime: 123.45,
        validity: .valid,
        confidence: 0.92,
        point: Point2D(x: -0.25, y: 0.4),
        coordinateSpace: .source,
        blink: .open,
        blinkConfidence: 0.97
    )

    #expect(frame.sessionID == sessionID)
    #expect(try JSONDecoder().decode(
        CanonicalGazeFrame.self,
        from: JSONEncoder().encode(frame)
    ) == frame)
}

private func matrix(_ elements: [Double]) throws -> Matrix4x4 {
    try Matrix4x4(elements: elements)
}

private func sample(
    isTracked: Bool = true,
    lookAt: Vector3 = Vector3(x: 0, y: 0, z: 2),
    faceTransform: Matrix4x4 = .identity,
    leftEyeTransform: Matrix4x4,
    rightEyeTransform: Matrix4x4,
    leftBlink: Double = 0.1,
    rightBlink: Double = 0.2
) -> GazeSample {
    GazeSample(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        sequence: 42,
        captureUptime: 99.5,
        sentUptime: 99.6,
        isTracked: isTracked,
        lookAt: lookAt,
        faceTransform: faceTransform,
        leftEyeTransform: leftEyeTransform,
        rightEyeTransform: rightEyeTransform,
        leftBlink: leftBlink,
        rightBlink: rightBlink
    )
}

@Test func arkitExtractorUsesEyeAndFaceTransformsInColumnMajorSpace() throws {
    // Eye midpoint in face space is (0, 0, 0.25). The face is translated by
    // (1, 2, 3), so the target (0, 0, 2) and eye become (1, 2, 5) and
    // (1, 2, 3.25), producing a straight-ahead source point (0, 0).
    let left = try matrix([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0.0,
        -0.1, 0.0, 0.25, 1,
    ])
    let right = try matrix([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0.0,
        0.1, 0.0, 0.25, 1,
    ])
    let face = try matrix([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        1, 2, 3, 1,
    ])

    let result = try #require(ARKitGazeFeatureExtractor.extract(
        from: sample(faceTransform: face, leftEyeTransform: left, rightEyeTransform: right),
        sourceID: "phone-arkit"
    ))
    #expect(result.sourceID == GazeSourceID("phone-arkit"))
    #expect(result.sourceSessionID == UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
    #expect(result.sequence == 42)
    #expect(result.validity == .valid)
    #expect(result.coordinateSpace == .source)
    #expect(result.point == Point2D(x: 0, y: 0))
    #expect(result.blink == .open)
    #expect(abs((result.blinkConfidence ?? 0) - 0.15) < 1e-12)
}

@Test func arkitExtractorRetainsHeadRotationAndMarksUntrackedFrames() throws {
    // A 90-degree Z rotation turns the target's face-local x direction into
    // the session y direction. The eye midpoint remains at the origin.
    let quarterTurn = try matrix([
        0, 1, 0, 0,
        -1, 0, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])
    let eye = try matrix([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    let result = try #require(ARKitGazeFeatureExtractor().extract(
        from: sample(
            isTracked: false,
            lookAt: Vector3(x: 1, y: 0, z: 2),
            faceTransform: quarterTurn,
            leftEyeTransform: eye,
            rightEyeTransform: eye,
            leftBlink: 0.9,
            rightBlink: 0.8
        ),
        sourceID: "phone-arkit"
    ))
    #expect(result.point == Point2D(x: 0, y: 0.5))
    #expect(result.validity == .invalid)
    #expect(result.confidence == 0)
    #expect(result.blink == .closed)
    #expect(abs((result.blinkConfidence ?? 0) - 0.85) < 1e-12)
}

@Test func arkitExtractorRejectsNonFiniteLookAtAndUnstableDepth() throws {
    let eye = Matrix4x4.identity
    let sourceID: GazeSourceID = "phone-arkit"

    #expect(ARKitGazeFeatureExtractor.extract(
        from: sample(
            lookAt: Vector3(x: .nan, y: 0, z: 2),
            leftEyeTransform: eye,
            rightEyeTransform: eye
        ),
        sourceID: sourceID
    ) == nil)

    #expect(ARKitGazeFeatureExtractor.extract(
        from: sample(
            lookAt: Vector3(x: 0, y: 0, z: 0),
            leftEyeTransform: eye,
            rightEyeTransform: eye
        ),
        sourceID: sourceID
    ) == nil)

    #expect(ARKitGazeFeatureExtractor.extract(
        from: sample(leftEyeTransform: eye, rightEyeTransform: eye),
        sourceID: GazeSourceID("   ")
    ) == nil)
}

@Test func arkitExtractorRejectsFiniteInputsThatOverflowProjectedDirection() throws {
    let finiteButExtreme = sample(
        lookAt: Vector3(
            x: Double.greatestFiniteMagnitude,
            y: Double.greatestFiniteMagnitude,
            z: 1e-6
        ),
        leftEyeTransform: .identity,
        rightEyeTransform: .identity
    )

    // All source values are finite and depth passes the stability threshold,
    // but both perspective ratios overflow to infinity.
    #expect(ARKitGazeFeatureExtractor.extract(
        from: finiteButExtreme,
        sourceID: "phone-arkit"
    ) == nil)
}

@Test func arkitExtractorHandlesUnknownBlinkConfidenceWithoutDroppingGeometry() throws {
    let result = try #require(ARKitGazeFeatureExtractor.extract(
        from: sample(
            leftEyeTransform: .identity,
            rightEyeTransform: .identity,
            leftBlink: .nan,
            rightBlink: 0.1
        ),
        sourceID: "phone-arkit"
    ))
    #expect(result.point == Point2D(x: 0, y: 0))
    #expect(result.blink == .unknown)
    #expect(result.blinkConfidence == nil)
}
