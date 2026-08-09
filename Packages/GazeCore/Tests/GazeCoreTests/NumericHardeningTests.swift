import Foundation
import Testing
@testable import GazeCore

@Test func rollingWindowCapsRetainedSamplesUnderFlood() throws {
    let maximumSampleCount = 8
    var window = try RollingGazeWindow2D(
        windowDuration: 10,
        maximumSampleCount: maximumSampleCount
    )

    for index in 0..<10_000 {
        _ = try window.append(
            Point2D(x: Double(index), y: -Double(index)),
            at: 1
        )
    }

    let estimate = try #require(try window.estimate(at: 1))
    #expect(estimate.sampleCount == maximumSampleCount)
    #expect(estimate.point == Point2D(x: 9_995.5, y: -9_995.5))
}
@Test func rollingWindowDefaultMaximumSampleCountIsBounded() throws {
    var window = try RollingGazeWindow2D(windowDuration: 10)
    for index in 0..<(RollingGazeWindow2D.defaultMaximumSampleCount + 1) {
        _ = try window.append(Point2D(x: Double(index), y: 0), at: 1)
    }

    let estimate = try #require(try window.estimate(at: 1))
    #expect(estimate.sampleCount == RollingGazeWindow2D.defaultMaximumSampleCount)
}

@Test func rollingWindowRejectsInvalidMaximumSampleCount() {
    for maximumSampleCount in [0, -1] {
        #expect(throws: RollingGazeWindowError.invalidMaximumSampleCount) {
            try RollingGazeWindow2D(windowDuration: 1, maximumSampleCount: maximumSampleCount)
        }
    }
}

@Test func affineFitRejectsFiniteObservationsThatOverflowFitArithmetic() {
    let extreme = Double.greatestFiniteMagnitude
    let observations = [
        AffineObservation(
            input: Point2D(x: -extreme, y: 0),
            output: Point2D(x: -extreme, y: 0)
        ),
        AffineObservation(
            input: Point2D(x: extreme, y: 0),
            output: Point2D(x: extreme, y: 0)
        ),
        AffineObservation(
            input: Point2D(x: 0, y: extreme),
            output: Point2D(x: 0, y: extreme)
        ),
    ]

    #expect(throws: AffineCalibrationError.nonFiniteResult) {
        try AffineCalibration.fit(observations: observations)
    }
}
