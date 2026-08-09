import Foundation
import Testing
@testable import GazeCore

/// A 3x3 grid of gaze-feature inputs on the scale the phone actually produces —
/// direction ratios clustered within a few tenths of a unit.
private func featureGrid() -> [Point2D] {
    let axis = [-0.18, 0.02, 0.22]
    return axis.flatMap { y in axis.map { x in Point2D(x: x, y: y) } }
}

private func project(_ point: Point2D, through m: [Double]) -> Point2D {
    let w = m[6] * point.x + m[7] * point.y + m[8]
    return Point2D(
        x: (m[0] * point.x + m[1] * point.y + m[2]) / w,
        y: (m[3] * point.x + m[4] * point.y + m[5]) / w
    )
}

@Test
func linearSolverSolvesKnownSystem() throws {
    // [2 1; 1 3] x = [5; 10]  ->  x = [1; 3]
    let x = try #require(LinearSolver.solve(
        matrix: [2, 1, 1, 3],
        vector: [5, 10],
        size: 2
    ))
    #expect(abs(x[0] - 1) < 1e-12)
    #expect(abs(x[1] - 3) < 1e-12)
}

@Test
func linearSolverRejectsSingularMatrix() {
    #expect(LinearSolver.solve(matrix: [1, 2, 2, 4], vector: [1, 2], size: 2) == nil)
}

@Test
func homographyRecoversKnownProjectiveTransform() throws {
    let truth: [Double] = [
        2.10, 0.14, 0.50,
        0.09, 1.85, 0.48,
        0.35, -0.22, 1.0,
    ]

    let observations = featureGrid().map { input in
        AffineObservation(input: input, output: project(input, through: truth))
    }

    let fitted = try HomographyCalibration.fit(observations: observations)

    for observation in observations {
        let mapped = try #require(fitted.apply(to: observation.input))
        #expect(abs(mapped.x - observation.output.x) < 1e-9)
        #expect(abs(mapped.y - observation.output.y) < 1e-9)
    }
}

@Test
func homographyBeatsAffineOnKeystoneData() throws {
    // Strong perspective terms — the distortion an affine fit structurally
    // cannot represent.
    let truth: [Double] = [
        1.90, 0.05, 0.50,
        0.04, 1.70, 0.47,
        0.55, -0.40, 1.0,
    ]

    let observations = featureGrid().map { input in
        AffineObservation(input: input, output: project(input, through: truth))
    }

    let affine = GazeMapping.affine(try AffineCalibration.fit(observations: observations))
    let projective = GazeMapping.projective(try HomographyCalibration.fit(observations: observations))

    let affineRMS = CalibrationDiagnostics.rms(
        CalibrationDiagnostics.residuals(of: affine, on: observations)
    )
    let projectiveRMS = CalibrationDiagnostics.rms(
        CalibrationDiagnostics.residuals(of: projective, on: observations)
    )

    #expect(projectiveRMS < affineRMS)
    #expect(projectiveRMS < 1e-9)
}

@Test
func fitSelectsProjectiveForKeystoneAndAffineForAffine() throws {
    let keystone: [Double] = [
        1.90, 0.05, 0.50,
        0.04, 1.70, 0.47,
        0.55, -0.40, 1.0,
    ]
    let keystoneObservations = featureGrid().map { input in
        AffineObservation(input: input, output: project(input, through: keystone))
    }
    let keystoneReport = try GazeMapping.fit(observations: keystoneObservations)
    #expect(keystoneReport.mapping.modelName == "projective")
    #expect(keystoneReport.rms < 1e-9)

    let pureAffine = AffineTransform2D(a: 2.0, b: 0.1, c: 0.05, d: 1.8, tx: 0.5, ty: 0.48)
    let affineObservations = featureGrid().map { input in
        AffineObservation(input: input, output: pureAffine.apply(to: input))
    }
    let affineReport = try GazeMapping.fit(observations: affineObservations)
    #expect(affineReport.mapping.modelName == "affine")
    #expect(affineReport.rms < 1e-9)
}

@Test
func fitPrefersAffineWhenProjectiveOnlyFitsNoise() throws {
    // Affine truth plus deterministic jitter. The extra two parameters can
    // only chase the noise, so held-out error must not favour them.
    let truth = AffineTransform2D(a: 2.0, b: 0.0, c: 0.0, d: 1.9, tx: 0.5, ty: 0.5)
    let jitter: [Double] = [
        0.004, -0.003, 0.002, -0.004, 0.003,
        -0.002, 0.004, -0.001, 0.002,
    ]

    let observations = featureGrid().enumerated().map { index, input -> AffineObservation in
        let clean = truth.apply(to: input)
        let noise = jitter[index % jitter.count]
        return AffineObservation(
            input: input,
            output: Point2D(x: clean.x + noise, y: clean.y - noise)
        )
    }

    let report = try GazeMapping.fit(observations: observations)
    #expect(report.mapping.modelName == "affine")
    #expect(report.affineHeldOutRMS != nil)
    #expect(report.projectiveHeldOutRMS != nil)
}

@Test
func homographyRejectsInsufficientAndDegenerateInput() {
    let tooFew = [
        AffineObservation(input: Point2D(x: 0, y: 0), output: Point2D(x: 0, y: 0)),
        AffineObservation(input: Point2D(x: 1, y: 0), output: Point2D(x: 1, y: 0)),
        AffineObservation(input: Point2D(x: 0, y: 1), output: Point2D(x: 0, y: 1)),
    ]
    #expect(throws: HomographyCalibrationError.insufficientObservations(required: 4, received: 3)) {
        _ = try HomographyCalibration.fit(observations: tooFew)
    }

    // All inputs identical — no spread to condition on.
    let collapsed = (0..<6).map { _ in
        AffineObservation(input: Point2D(x: 0.1, y: 0.1), output: Point2D(x: 0.5, y: 0.5))
    }
    #expect(throws: HomographyCalibrationError.degenerateInput) {
        _ = try HomographyCalibration.fit(observations: collapsed)
    }

    let nonFinite = [
        AffineObservation(input: Point2D(x: .nan, y: 0), output: Point2D(x: 0, y: 0)),
        AffineObservation(input: Point2D(x: 1, y: 0), output: Point2D(x: 1, y: 0)),
        AffineObservation(input: Point2D(x: 0, y: 1), output: Point2D(x: 0, y: 1)),
        AffineObservation(input: Point2D(x: 1, y: 1), output: Point2D(x: 1, y: 1)),
    ]
    #expect(throws: HomographyCalibrationError.nonFiniteObservation) {
        _ = try HomographyCalibration.fit(observations: nonFinite)
    }
}

@Test
func homographyReturnsNilAtTheHorizon() throws {
    // w = -x + 1 vanishes at x = 1.
    let horizon = try Homography2D(elements: [
        1, 0, 0,
        0, 1, 0,
        -1, 0, 1,
    ])

    #expect(horizon.apply(to: Point2D(x: 1, y: 0)) == nil)
    #expect(horizon.apply(to: Point2D(x: 0, y: 0)) != nil)
}

@Test
func residualsAndRMSReportFitError() throws {
    let mapping = GazeMapping.affine(
        AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    )
    let observations = [
        AffineObservation(input: Point2D(x: 0, y: 0), output: Point2D(x: 0.3, y: 0.4)),
        AffineObservation(input: Point2D(x: 1, y: 1), output: Point2D(x: 1, y: 1)),
    ]

    let residuals = CalibrationDiagnostics.residuals(of: mapping, on: observations)
    #expect(residuals.count == 2)
    #expect(abs(residuals[0].magnitude - 0.5) < 1e-12)
    #expect(abs(residuals[1].magnitude) < 1e-12)

    let rms = CalibrationDiagnostics.rms(residuals)
    #expect(abs(rms - (0.25 / 2).squareRoot()) < 1e-12)
}

@Test
func gazeMappingRoundTripsThroughCodable() throws {
    let report = try GazeMapping.fit(
        observations: featureGrid().map { input in
            AffineObservation(
                input: input,
                output: project(input, through: [
                    1.90, 0.05, 0.50,
                    0.04, 1.70, 0.47,
                    0.55, -0.40, 1.0,
                ])
            )
        }
    )

    let data = try JSONEncoder().encode(report.mapping)
    let decoded = try JSONDecoder().decode(GazeMapping.self, from: data)
    #expect(decoded == report.mapping)
}

@Test
func robustFitDropsASingleBadTargetAndImprovesTheFit() throws {
    let truth = AffineTransform2D(a: 2.0, b: 0.0, c: 0.0, d: 1.9, tx: 0.5, ty: 0.5)
    var observations = featureGrid().map { input in
        AffineObservation(input: input, output: truth.apply(to: input))
    }
    // Add interior points so 13 observations survive the minimumRetained floor.
    for point in [Point2D(x: -0.08, y: -0.08), Point2D(x: 0.12, y: -0.08),
                  Point2D(x: -0.08, y: 0.12), Point2D(x: 0.12, y: 0.12)] {
        observations.append(AffineObservation(input: point, output: truth.apply(to: point)))
    }

    // Target 5: the user glanced away. Output is far from where it belongs.
    let corrupted = observations[5]
    observations[5] = AffineObservation(
        input: corrupted.input,
        output: Point2D(x: corrupted.output.x + 0.45, y: corrupted.output.y - 0.35)
    )

    let plain = try GazeMapping.fit(observations: observations)
    let robust = try GazeMapping.robustFit(observations: observations)

    #expect(robust.droppedObservationIndices == [5])
    #expect(robust.rms < plain.rms)
    #expect(robust.rms < 1e-9)
}

@Test
func robustFitKeepsEveryTargetWhenNoneIsAnOutlier() throws {
    let truth = AffineTransform2D(a: 2.0, b: 0.0, c: 0.0, d: 1.9, tx: 0.5, ty: 0.5)
    let jitter: [Double] = [0.004, -0.003, 0.002, -0.004, 0.003, -0.002, 0.004, -0.001, 0.002]
    let observations = featureGrid().enumerated().map { index, input -> AffineObservation in
        let clean = truth.apply(to: input)
        let noise = jitter[index % jitter.count]
        return AffineObservation(
            input: input,
            output: Point2D(x: clean.x + noise, y: clean.y - noise)
        )
    }

    let robust = try GazeMapping.robustFit(observations: observations)
    #expect(robust.droppedObservationIndices.isEmpty)
}

@Test
func robustFitRespectsTheMinimumRetainedFloor() throws {
    let truth = AffineTransform2D(a: 2.0, b: 0.0, c: 0.0, d: 1.9, tx: 0.5, ty: 0.5)
    var observations = featureGrid().map { input in
        AffineObservation(input: input, output: truth.apply(to: input))
    }
    observations[2] = AffineObservation(
        input: observations[2].input,
        output: Point2D(x: 5.0, y: -5.0)
    )

    // Nine observations with a floor of nine leaves no room to drop anything.
    let robust = try GazeMapping.robustFit(observations: observations, minimumRetained: 9)
    #expect(robust.droppedObservationIndices.isEmpty)
}
