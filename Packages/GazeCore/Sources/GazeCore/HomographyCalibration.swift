import Foundation

/// A 2D projective mapping where `(x, y)` maps to
/// `((a*x + b*y + c) / (g*x + h*y + 1), (d*x + e*y + f) / (g*x + h*y + 1))`.
///
/// The gaze feature is a direction ratio measured at the eye, and the screen is
/// a plane at an angle to that eye. For a fixed ray origin, the map between the
/// two is projective, not affine — the affine fit cannot represent the keystone
/// distortion produced by a phone mounted below and tilted up toward the face.
/// Eight parameters instead of six buy exactly that correction.
public struct Homography2D: Codable, Equatable, Sendable {
    public static let elementCount = 9

    /// Row-major 3x3, normalized so `elements[8] == 1` whenever possible.
    public let elements: [Double]

    public init(elements: [Double]) throws {
        guard elements.count == Self.elementCount else {
            throw HomographyCalibrationError.invalidElementCount(elements.count)
        }
        guard elements.allSatisfy(\.isFinite) else {
            throw HomographyCalibrationError.nonFiniteObservation
        }
        self.elements = elements
    }

    public static let identity = try! Homography2D(elements: [
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    ])

    /// Applies the mapping. Returns `nil` when the point lands on or beyond the
    /// horizon line, where the perspective divide is undefined — callers should
    /// treat that as a dropped sample rather than clamping to a wild value.
    public func apply(to point: Point2D) -> Point2D? {
        let m = elements
        let w = m[6] * point.x + m[7] * point.y + m[8]
        guard w.isFinite, abs(w) > 1e-9 else { return nil }

        let x = (m[0] * point.x + m[1] * point.y + m[2]) / w
        let y = (m[3] * point.x + m[4] * point.y + m[5]) / w
        guard x.isFinite, y.isFinite else { return nil }
        return Point2D(x: x, y: y)
    }

    /// The affine sub-map, useful as a fallback when a projective fit degenerates.
    public var affineApproximation: AffineTransform2D {
        AffineTransform2D(
            a: elements[0], b: elements[1],
            c: elements[3], d: elements[4],
            tx: elements[2], ty: elements[5]
        )
    }
}

public enum HomographyCalibrationError: Error, Equatable, Sendable {
    case invalidElementCount(Int)
    case insufficientObservations(required: Int, received: Int)
    case nonFiniteObservation
    case degenerateInput
}

public enum HomographyCalibration {
    /// Minimum correspondences for the eight free parameters.
    public static let minimumObservations = 4

    /// Fits a projective transform by normalized Direct Linear Transform.
    ///
    /// Both point sets are conditioned to zero mean and mean radius `sqrt(2)`
    /// before solving. Gaze direction ratios cluster within a fraction of a unit
    /// while screen coordinates span 0...1, and without that conditioning the
    /// normal equations are numerically hopeless.
    public static func fit(
        observations: [AffineObservation],
        degeneracyTolerance: Double = 1e-12
    ) throws -> Homography2D {
        guard observations.count >= minimumObservations else {
            throw HomographyCalibrationError.insufficientObservations(
                required: minimumObservations,
                received: observations.count
            )
        }

        guard observations.allSatisfy({ observation in
            observation.input.x.isFinite && observation.input.y.isFinite
                && observation.output.x.isFinite && observation.output.y.isFinite
        }) else {
            throw HomographyCalibrationError.nonFiniteObservation
        }

        guard let inputNormalizer = Normalizer(points: observations.map(\.input)),
              let outputNormalizer = Normalizer(points: observations.map(\.output))
        else {
            throw HomographyCalibrationError.degenerateInput
        }

        var rows: [[Double]] = []
        var targets: [Double] = []
        rows.reserveCapacity(observations.count * 2)
        targets.reserveCapacity(observations.count * 2)

        for observation in observations {
            let p = inputNormalizer.apply(observation.input)
            let q = outputNormalizer.apply(observation.output)

            rows.append([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y])
            targets.append(q.x)

            rows.append([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y])
            targets.append(q.y)
        }

        guard let h = LinearSolver.leastSquares(
            rows: rows,
            targets: targets,
            columns: 8,
            tolerance: degeneracyTolerance
        ) else {
            throw HomographyCalibrationError.degenerateInput
        }

        let normalized = [
            h[0], h[1], h[2],
            h[3], h[4], h[5],
            h[6], h[7], 1,
        ]

        // H = T_out⁻¹ · H_norm · T_in
        let denormalized = multiply(
            outputNormalizer.inverseMatrix,
            multiply(normalized, inputNormalizer.matrix)
        )

        guard let scale = denormalized.last, scale.isFinite, abs(scale) > 1e-12 else {
            throw HomographyCalibrationError.degenerateInput
        }

        return try Homography2D(elements: denormalized.map { $0 / scale })
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += a[row * 3 + k] * b[k * 3 + column]
                }
                result[row * 3 + column] = sum
            }
        }
        return result
    }

    /// Hartley conditioning: translate to the centroid, scale to mean radius `sqrt(2)`.
    private struct Normalizer {
        let matrix: [Double]
        let inverseMatrix: [Double]
        private let scale: Double
        private let meanX: Double
        private let meanY: Double

        init?(points: [Point2D]) {
            guard !points.isEmpty else { return nil }
            let count = Double(points.count)
            let meanX = points.reduce(0) { $0 + $1.x } / count
            let meanY = points.reduce(0) { $0 + $1.y } / count

            let meanRadius = points.reduce(0.0) { partial, point in
                let dx = point.x - meanX
                let dy = point.y - meanY
                return partial + (dx * dx + dy * dy).squareRoot()
            } / count

            guard meanRadius.isFinite, meanRadius > 1e-12 else { return nil }

            let scale = 2.0.squareRoot() / meanRadius
            self.scale = scale
            self.meanX = meanX
            self.meanY = meanY
            self.matrix = [
                scale, 0, -scale * meanX,
                0, scale, -scale * meanY,
                0, 0, 1,
            ]
            self.inverseMatrix = [
                1 / scale, 0, meanX,
                0, 1 / scale, meanY,
                0, 0, 1,
            ]
        }

        func apply(_ point: Point2D) -> Point2D {
            Point2D(x: scale * (point.x - meanX), y: scale * (point.y - meanY))
        }
    }
}
