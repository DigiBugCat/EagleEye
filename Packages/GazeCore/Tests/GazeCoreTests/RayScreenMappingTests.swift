import Foundation
import Testing
@testable import GazeCore

private let syntheticScreenSize = PhysicalSize2D(widthMeters: 0.60, heightMeters: 0.34)

private func normalizedVector(from origin: Vector3, to target: Vector3) -> Vector3 {
    let x = target.x - origin.x
    let y = target.y - origin.y
    let z = target.z - origin.z
    let length = (x * x + y * y + z * z).squareRoot()
    return Vector3(x: x / length, y: y / length, z: z / length)
}

private func physicalPoint(_ point: Point2D) -> Vector3 {
    Vector3(
        x: (point.x - 0.5) * syntheticScreenSize.widthMeters,
        y: (point.y - 0.5) * syntheticScreenSize.heightMeters,
        z: 0
    )
}

private func ray(origin: Vector3, target: Point2D) -> GazeRay3D {
    GazeRay3D(origin: origin, direction: normalizedVector(from: origin, to: physicalPoint(target)))
}

@Test func knownRayPlaneMapsCornersAcrossDifferentHeadPositions() throws {
    let mapping = RayScreenMapping(
        center: Vector3(x: 0, y: 0, z: 0),
        horizontalAxis: Vector3(x: 1, y: 0, z: 0),
        verticalAxis: Vector3(x: 0, y: 1, z: 0),
        screenSize: syntheticScreenSize
    )
    let shiftedOrigin = Vector3(x: 0.09, y: -0.05, z: 0.72)
    for target in [
        Point2D(x: 0.03, y: 0.03),
        Point2D(x: 0.97, y: 0.03),
        Point2D(x: 0.97, y: 0.97),
        Point2D(x: 0.03, y: 0.97),
    ] {
        let mapped = try #require(mapping.apply(to: ray(origin: shiftedOrigin, target: target)))
        #expect(abs(mapped.x - target.x) < 1e-10)
        #expect(abs(mapped.y - target.y) < 1e-10)
    }
}

@Test func calibratorRecoversMetricPlaneAndGeneralizesToShiftedHeadCorners() throws {
    let grid = [0.10, 0.50, 0.90].flatMap { y in
        [0.10, 0.50, 0.90].map { x in Point2D(x: x, y: y) }
    }
    let calibrationOrigins = [
        Vector3(x: -0.012, y: 0.006, z: 0.60),
        Vector3(x: 0.008, y: -0.004, z: 0.61),
        Vector3(x: 0.003, y: 0.009, z: 0.595),
        Vector3(x: -0.006, y: -0.008, z: 0.605),
    ]
    let observations = grid.map { target in
        RayScreenTargetObservation(
            target: target,
            rays: calibrationOrigins.map { ray(origin: $0, target: target) }
        )
    }
    let report = try RayScreenCalibrator.fit(
        observations: observations,
        screenSize: syntheticScreenSize
    )
    #expect(report.rms < 0.01)
    #expect(report.worstMagnitude < 0.02)

    let shiftedOrigin = Vector3(x: 0.075, y: -0.045, z: 0.72)
    for target in [
        Point2D(x: 0.05, y: 0.05),
        Point2D(x: 0.95, y: 0.05),
        Point2D(x: 0.95, y: 0.95),
        Point2D(x: 0.05, y: 0.95),
    ] {
        let mapped = try #require(report.mapping.apply(to: ray(origin: shiftedOrigin, target: target)))
        #expect(abs(mapped.x - target.x) < 0.025)
        #expect(abs(mapped.y - target.y) < 0.025)
    }
}

@Test func rayPlaneProfileRoundTripsAndRequiresTheFullRay() throws {
    let mapping = RayScreenMapping(
        center: Vector3(x: 0, y: 0, z: 0),
        horizontalAxis: Vector3(x: 1, y: 0, z: 0),
        verticalAxis: Vector3(x: 0, y: 1, z: 0),
        screenSize: syntheticScreenSize
    )
    let profile = CalibrationProfile(
        key: CalibrationProfileKey(sourceID: "phone", displayID: "display", setupID: "mount"),
        mapping: .affine(AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)),
        rayScreenMapping: mapping,
        selectedModel: .rayPlane3D,
        quality: CalibrationQualitySummary(modelName: "ray-plane-3D")
    )
    let decoded = try JSONDecoder().decode(
        CalibrationProfile.self,
        from: JSONEncoder().encode(profile)
    )
    try decoded.validate(expectedKey: profile.key, expectedCoordinateSpace: .source)
    #expect(decoded == profile)
    #expect(decoded.apply(to: Point2D(x: 0.5, y: 0.5), gazeRay: nil) == nil)

    let target = Point2D(x: 0.91, y: 0.08)
    let mapped = try #require(decoded.apply(
        to: Point2D(x: 123, y: 456),
        gazeRay: ray(origin: Vector3(x: 0.04, y: 0.02, z: 0.65), target: target)
    ))
    #expect(abs(mapped.x - target.x) < 1e-10)
    #expect(abs(mapped.y - target.y) < 1e-10)
}

@Test func engineSelectsRayPlaneWhenShiftedHeadBreaksDirectionOnlyCorners() throws {
    let training = [0.10, 0.50, 0.90].flatMap { y in
        [0.10, 0.50, 0.90].map { x in Point2D(x: x, y: y) }
    }
    let perimeter = [
        Point2D(x: 0.05, y: 0.05),
        Point2D(x: 0.95, y: 0.05),
        Point2D(x: 0.95, y: 0.95),
        Point2D(x: 0.05, y: 0.95),
    ]
    let plan = try CalibrationPlan(
        targets: training,
        evaluationTargets: perimeter,
        timing: CalibrationTimingConfiguration(
            settleDuration: 0,
            collectDuration: 0.001,
            minimumSamplesPerTarget: 3
        ),
        quality: nil,
        validation: CalibrationValidationPolicy(
            maximumRMSError: 0.035,
            maximumWorstError: 0.05,
            maximumSelectiveRetries: 0
        )
    )
    let key = CalibrationProfileKey(sourceID: "phone", displayID: "display", setupID: "mount")
    var engine = CalibrationEngine(
        plan: plan,
        profileKey: key,
        screenSizeMeters: syntheticScreenSize
    )
    var timestamp = 0.0
    var sequence: UInt64 = 0
    let session = UUID()
    _ = try engine.startCalibration(at: timestamp)

    func frame(target: Point2D, origin: Vector3) -> CanonicalGazeFrame {
        sequence += 1
        let fullRay = ray(origin: origin, target: target).normalized!
        return CanonicalGazeFrame(
            sourceID: key.sourceID,
            sourceSessionID: session,
            sequence: sequence,
            captureUptime: timestamp,
            validity: .valid,
            confidence: 1,
            point: Point2D(
                x: fullRay.direction.x / fullRay.direction.z,
                y: fullRay.direction.y / fullRay.direction.z
            ),
            coordinateSpace: .source,
            blink: .open,
            gazeRay: fullRay
        )
    }

    while engine.state.phase == .calibrating {
        let target = try #require(engine.state.target)
        for offset in [-0.003, 0, 0.003] {
            timestamp += 0.0005
            _ = try engine.consume(
                frame(target: target, origin: Vector3(x: offset, y: -offset / 2, z: 0.60)),
                at: timestamp
            )
        }
    }
    #expect(engine.state.phase == .validating)

    while engine.state.phase == .validating {
        let target = try #require(engine.state.target)
        for offset in [-0.003, 0, 0.003] {
            timestamp += 0.0005
            _ = try engine.consume(
                frame(target: target, origin: Vector3(x: 0.08 + offset, y: -0.04, z: 0.72)),
                at: timestamp
            )
        }
    }
    #expect(engine.state.phase == .calibrated)
    #expect(engine.profile?.selectedModel == .rayPlane3D)
    #expect(engine.profile?.quality.modelName == "ray-plane-3D")
    #expect((engine.profile?.quality.rayPlaneValidationMaxError ?? 1) < 0.05)
    #expect((engine.profile?.quality.legacyValidationMaxError ?? 0) > 0.05)
}
