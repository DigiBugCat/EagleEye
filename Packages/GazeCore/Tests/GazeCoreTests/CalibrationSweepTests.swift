import Foundation
import Testing
@testable import GazeCore

@Test
func sweepDrivesBothDiagonalsToTheExtremes() {
    let sweep = CalibrationSweep(margin: 0.06)

    let start = sweep.position(at: 0)
    #expect(abs(start.x - 0.06) < 1e-9)
    #expect(abs(start.y - 0.06) < 1e-9)

    // End of the first diagonal: bottom-right.
    let firstEnd = sweep.position(at: 0.2199)
    #expect(firstEnd.x > 0.93)
    #expect(firstEnd.y > 0.93)

    // Start of the second diagonal: top-right.
    let secondStart = sweep.position(at: 0.2201)
    #expect(secondStart.x > 0.93)
    #expect(secondStart.y < 0.07)

    // End of the second diagonal: bottom-left.
    let secondEnd = sweep.position(at: 0.4399)
    #expect(secondEnd.x < 0.07)
    #expect(secondEnd.y > 0.93)
}

@Test
func sweepStaysInsideTheScreenAndCoversAWideExtent() {
    let sweep = CalibrationSweep(margin: 0.06)
    var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0

    for step in 0...1000 {
        let point = sweep.position(at: Double(step) / 1000)
        #expect(point.x >= -1e-9 && point.x <= 1 + 1e-9)
        #expect(point.y >= -1e-9 && point.y <= 1 + 1e-9)
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }

    // Both axes must be driven nearly edge to edge, or the fit is being asked
    // to extrapolate to the corners it never saw.
    #expect(maxX - minX > 0.85)
    #expect(maxY - minY > 0.85)
}

@Test
func sweepClampsProgressOutsideTheUnitInterval() {
    let sweep = CalibrationSweep()
    #expect(sweep.position(at: -5) == sweep.position(at: 0))
    #expect(sweep.position(at: 5) == sweep.position(at: 1))
}

@Test
func pursuitPairingReturnsTheDelayedTarget() {
    var pairing = PursuitPairing(latency: 0.10)

    // Target moving right at 1.0 units/second, sampled at 100 Hz.
    for step in 0...40 {
        let time = Double(step) * 0.01
        pairing.record(target: Point2D(x: time, y: 0.5), at: time)
    }

    // At t = 0.40 the eye is where the target was at t = 0.30.
    let delayed = pairing.delayedTarget(at: 0.40)
    #expect(delayed != nil)
    #expect(abs((delayed?.x ?? 0) - 0.30) < 1e-9)
    #expect(abs((delayed?.y ?? 0) - 0.5) < 1e-9)
}

@Test
func pursuitPairingWithholdsUntilHistoryCoversTheLatency() {
    var pairing = PursuitPairing(latency: 0.12)
    pairing.record(target: Point2D(x: 0.1, y: 0.1), at: 1.00)
    pairing.record(target: Point2D(x: 0.2, y: 0.1), at: 1.02)

    // Only 20 ms of history against a 120 ms latency.
    #expect(pairing.delayedTarget(at: 1.02) == nil)

    for step in 1...20 {
        pairing.record(target: Point2D(x: 0.2, y: 0.1), at: 1.02 + Double(step) * 0.01)
    }
    #expect(pairing.delayedTarget(at: 1.22) != nil)

    pairing.reset()
    #expect(pairing.delayedTarget(at: 1.22) == nil)
}

@Test
func downsamplerCondensesDenseSweepIntoGridBuckets() {
    var observations: [AffineObservation] = []
    for step in 0..<400 {
        let u = Double(step) / 400
        let target = Point2D(x: u, y: u)
        observations.append(
            AffineObservation(
                input: Point2D(x: u * 0.2 - 0.1, y: u * 0.2 - 0.1),
                output: target
            )
        )
    }

    let condensed = SweepDownsampler.condense(observations, resolution: 8)
    // The path is diagonal, so it touches 8 of the 64 buckets.
    #expect(condensed.count == 8)
    #expect(condensed.count < observations.count)
}

@Test
func downsamplerMedianIgnoresAWildSample() {
    var observations = (0..<9).map { _ in
        AffineObservation(input: Point2D(x: 0.10, y: 0.20), output: Point2D(x: 0.5, y: 0.5))
    }
    observations.append(
        AffineObservation(input: Point2D(x: 99, y: -99), output: Point2D(x: 0.5, y: 0.5))
    )

    let condensed = SweepDownsampler.condense(observations, resolution: 4)
    #expect(condensed.count == 1)
    #expect(abs(condensed[0].input.x - 0.10) < 1e-9)
    #expect(abs(condensed[0].input.y - 0.20) < 1e-9)
}
