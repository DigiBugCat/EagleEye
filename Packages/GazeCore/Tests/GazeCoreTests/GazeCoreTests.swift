import Foundation
import Testing
@testable import GazeCore

private func sample(
    sessionID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    sequence: UInt64 = 7,
    captureUptime: TimeInterval = 10,
    sentUptime: TimeInterval = 10.01,
    version: Int = GazeSample.currentVersion
) -> GazeSample {
    GazeSample(
        version: version,
        sessionID: sessionID,
        sequence: sequence,
        captureUptime: captureUptime,
        sentUptime: sentUptime,
        isTracked: true,
        lookAt: Vector3(x: 0.1, y: -0.2, z: 0.8),
        faceTransform: .identity,
        leftEyeTransform: .identity,
        rightEyeTransform: .identity,
        leftBlink: 0.25,
        rightBlink: 0.5
    )
}

@Test func datagramRoundTrip() throws {
    let original = sample()
    let decoded = try GazeDatagramCodec.decode(GazeDatagramCodec.encode(original))
    #expect(decoded == original)
}

@Test func datagramRejectsUnsupportedVersion() throws {
    let futureSample = sample(version: 99)
    #expect(throws: GazeDatagramError.unsupportedVersion(received: 99, supported: 1)) {
        try GazeDatagramCodec.encode(futureSample)
    }

    let rawFutureDatagram = try JSONEncoder().encode(futureSample)
    #expect(throws: GazeDatagramError.unsupportedVersion(received: 99, supported: 1)) {
        try GazeDatagramCodec.decode(rawFutureDatagram)
    }
}

@Test func sampleGateRejectsStaleAndNonMonotonicSamples() throws {
    var gate = GazeSampleGate(maximumTransitAge: 0.2)
    let session = UUID()

    #expect(gate.accept(sample(sessionID: session, sequence: 1), receivedAtUptime: 10.1).isSuccess)

    guard case let .failure(duplicateRejection) = gate.accept(
        sample(sessionID: session, sequence: 1),
        receivedAtUptime: 10.1
    ) else {
        Issue.record("Expected duplicate rejection")
        return
    }
    #expect(duplicateRejection == .duplicateOrOutOfOrder(lastAccepted: 1, received: 1))

    guard case let .failure(backwardRejection) = gate.accept(
        sample(sessionID: session, sequence: 2, captureUptime: 9.9),
        receivedAtUptime: 10.1
    ) else {
        Issue.record("Expected backward capture-time rejection")
        return
    }
    #expect(backwardRejection == .captureTimeMovedBackward(lastAccepted: 10, received: 9.9))

    let staleResult = gate.accept(
        sample(sessionID: session, sequence: 2, captureUptime: 10.1, sentUptime: 10.1),
        receivedAtUptime: 10.5
    )
    guard case let .failure(.stale(age)) = staleResult else {
        Issue.record("Expected stale rejection")
        return
    }
    #expect(abs(age - 0.4) < 1e-12)

    #expect(gate.accept(
        sample(sessionID: UUID(), sequence: 0, captureUptime: 1, sentUptime: 10.45),
        receivedAtUptime: 10.5
    ).isSuccess)
}

@Test func exactAffineFit() throws {
    let expected = AffineTransform2D(a: 2, b: -0.5, c: 0.25, d: 3, tx: 10, ty: -4)
    let inputs = [
        Point2D(x: -2, y: -1), Point2D(x: 0, y: 0), Point2D(x: 1, y: 0),
        Point2D(x: 0, y: 1), Point2D(x: 2, y: 3), Point2D(x: -1, y: 4),
    ]
    let fitted = try AffineCalibration.fit(observations: inputs.map {
        AffineObservation(input: $0, output: expected.apply(to: $0))
    })

    #expect(abs(fitted.a - expected.a) < 1e-12)
    #expect(abs(fitted.b - expected.b) < 1e-12)
    #expect(abs(fitted.c - expected.c) < 1e-12)
    #expect(abs(fitted.d - expected.d) < 1e-12)
    #expect(abs(fitted.tx - expected.tx) < 1e-12)
    #expect(abs(fitted.ty - expected.ty) < 1e-12)
}

@Test func noisyAffineFit() throws {
    let expected = AffineTransform2D(a: 1.2, b: 0.3, c: -0.2, d: 0.9, tx: 100, ty: 50)
    let noise = [-0.08, 0.04, -0.02, 0.07, -0.05, 0.01, 0.06, -0.03, 0.0]
    var observations: [AffineObservation] = []

    for row in 0..<3 {
        for column in 0..<3 {
            let index = row * 3 + column
            let input = Point2D(x: Double(column - 1), y: Double(row - 1))
            var output = expected.apply(to: input)
            output.x += noise[index]
            output.y -= noise[(index + 3) % noise.count]
            observations.append(AffineObservation(input: input, output: output))
        }
    }

    let fitted = try AffineCalibration.fit(observations: observations)
    #expect(abs(fitted.a - expected.a) < 0.05)
    #expect(abs(fitted.b - expected.b) < 0.05)
    #expect(abs(fitted.c - expected.c) < 0.05)
    #expect(abs(fitted.d - expected.d) < 0.05)
    #expect(abs(fitted.tx - expected.tx) < 0.05)
    #expect(abs(fitted.ty - expected.ty) < 0.05)
}

@Test func affineFitRejectsDegenerateInputs() {
    let observations = (0..<5).map { value in
        let input = Point2D(x: Double(value), y: Double(value) * 2)
        return AffineObservation(input: input, output: Point2D(x: Double(value), y: 0))
    }

    #expect(throws: AffineCalibrationError.degenerateInput) {
        try AffineCalibration.fit(observations: observations)
    }
}

@Test func exponentialSmoothingAndReset() throws {
    var smoother = try ExponentialMovingAverage2D(alpha: 0.25)
    #expect(smoother.update(with: Point2D(x: 0, y: 8)) == Point2D(x: 0, y: 8))
    #expect(smoother.update(with: Point2D(x: 4, y: 0)) == Point2D(x: 1, y: 6))
    #expect(smoother.update(with: Point2D(x: 5, y: 2)) == Point2D(x: 2, y: 5))

    smoother.reset()
    #expect(smoother.value == nil)
    #expect(smoother.update(with: Point2D(x: 9, y: 9)) == Point2D(x: 9, y: 9))
}

private extension Result where Success == Void, Failure == GazeSampleRejection {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
