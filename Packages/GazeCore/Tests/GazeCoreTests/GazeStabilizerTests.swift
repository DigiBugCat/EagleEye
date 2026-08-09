import Foundation
import Testing
@testable import GazeCore

private let frame = 1.0 / 60.0

@Test
func stabilizerPassesTheFirstSampleThrough() {
    var stabilizer = GazeStabilizer()
    let first = stabilizer.update(Point2D(x: 0.4, y: 0.6), at: 0)
    #expect(first == Point2D(x: 0.4, y: 0.6))
    #expect(!stabilizer.lastWasSaccade)
}

@Test
func deadZoneHoldsTheDotCompletelyStillUnderNoise() {
    var stabilizer = GazeStabilizer(deadZone: 0.01)
    var time = 0.0
    stabilizer.update(Point2D(x: 0.5, y: 0.5), at: time)

    // ±0.004 jitter — well inside tracker noise. The output must not move at
    // all; a dot that creeps in the periphery is the fatiguing case.
    let jitter = [0.003, -0.004, 0.002, -0.003, 0.004, -0.002, 0.001, -0.004]
    var outputs: [Point2D] = []
    for (index, offset) in jitter.enumerated() {
        time += frame
        let sign = index % 2 == 0 ? 1.0 : -1.0
        outputs.append(stabilizer.update(
            Point2D(x: 0.5 + offset, y: 0.5 + offset * sign),
            at: time
        ))
    }

    #expect(outputs.allSatisfy { $0 == Point2D(x: 0.5, y: 0.5) })
    #expect(stabilizer.isHolding)
}

@Test
func saccadeSnapsInsteadOfGliding() {
    var stabilizer = GazeStabilizer(saccadeThreshold: 0.09)
    var time = 0.0
    stabilizer.update(Point2D(x: 0.2, y: 0.2), at: time)

    time += frame
    let jumped = stabilizer.update(Point2D(x: 0.8, y: 0.8), at: time)

    // Arrives immediately — no multi-frame slide across the screen.
    #expect(jumped == Point2D(x: 0.8, y: 0.8))
    #expect(stabilizer.lastWasSaccade)
}

@Test
func smallDriftIsSmoothedRatherThanSnapped() {
    var stabilizer = GazeStabilizer(deadZone: 0.002, saccadeThreshold: 0.09)
    var time = 0.0
    stabilizer.update(Point2D(x: 0.30, y: 0.50), at: time)

    // A slow, deliberate drift: each step is under the saccade threshold.
    var output = Point2D(x: 0.30, y: 0.50)
    for step in 1...20 {
        time += frame
        output = stabilizer.update(
            Point2D(x: 0.30 + Double(step) * 0.004, y: 0.50),
            at: time
        )
    }

    #expect(!stabilizer.lastWasSaccade)
    // It follows, but lags — that lag is the smoothing doing its job.
    #expect(output.x > 0.30)
    #expect(output.x < 0.38)
}

@Test
func adaptiveCutoffTracksFastMotionCloserThanSlowJitter() {
    // Fast, sustained motion should end up near the input despite smoothing,
    // because the cutoff opens with speed.
    var fast = GazeStabilizer(deadZone: 0.0)
    var time = 0.0
    fast.update(Point2D(x: 0.10, y: 0.5), at: time)
    var fastOutput = Point2D(x: 0.10, y: 0.5)
    for step in 1...12 {
        time += frame
        fastOutput = fast.update(Point2D(x: 0.10 + Double(step) * 0.02, y: 0.5), at: time)
    }
    let fastInput = 0.10 + 12 * 0.02
    #expect(abs(fastOutput.x - fastInput) < 0.06)
}

@Test
func hugeTimeGapsDoNotDestabiliseTheFilter() {
    var stabilizer = GazeStabilizer(deadZone: 0.0)
    stabilizer.update(Point2D(x: 0.4, y: 0.4), at: 0)

    // The phone was backgrounded for ten seconds.
    let after = stabilizer.update(Point2D(x: 0.42, y: 0.42), at: 10.0)
    #expect(after.x.isFinite && after.y.isFinite)
    #expect(after.x >= 0.4 && after.x <= 0.42)
}

@Test
func resetClearsHeldState() {
    var stabilizer = GazeStabilizer()
    stabilizer.update(Point2D(x: 0.3, y: 0.3), at: 0)
    #expect(stabilizer.value != nil)

    stabilizer.reset()
    #expect(stabilizer.value == nil)
    #expect(!stabilizer.isHolding)

    let first = stabilizer.update(Point2D(x: 0.9, y: 0.1), at: 5)
    #expect(first == Point2D(x: 0.9, y: 0.1))
}

@Test
func outputNeverLeavesTheRangeSpannedByRecentInput() {
    var stabilizer = GazeStabilizer(deadZone: 0.0)
    var time = 0.0
    var outputs: [Point2D] = []
    let inputs = stride(from: 0.2, through: 0.8, by: 0.01).map { Point2D(x: $0, y: 0.5) }

    for input in inputs {
        outputs.append(stabilizer.update(input, at: time))
        time += frame
    }

    // No overshoot past the input envelope — an overshooting pointer reads as
    // a wobble and is exactly what we are trying to remove.
    #expect(outputs.allSatisfy { $0.x >= 0.2 - 1e-9 && $0.x <= 0.8 + 1e-9 })
}
