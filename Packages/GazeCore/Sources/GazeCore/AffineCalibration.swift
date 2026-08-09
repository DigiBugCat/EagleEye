import Foundation

public struct Point2D: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AffineObservation: Equatable, Sendable {
    public var input: Point2D
    public var output: Point2D

    public init(input: Point2D, output: Point2D) {
        self.input = input
        self.output = output
    }
}

/// A 2D affine mapping where `(x, y)` maps to
/// `(a*x + b*y + tx, c*x + d*y + ty)`.
public struct AffineTransform2D: Codable, Equatable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public func apply(to point: Point2D) -> Point2D {
        Point2D(
            x: a * point.x + b * point.y + tx,
            y: c * point.x + d * point.y + ty
        )
    }
}

public enum AffineCalibrationError: Error, Equatable, Sendable {
    case insufficientObservations(required: Int, received: Int)
    case nonFiniteObservation
    case degenerateInput
}

public enum AffineCalibration {
    /// Fits an ordinary least-squares affine transform.
    ///
    /// The centered covariance formulation is equivalent to solving the full
    /// least-squares system while avoiding a poorly scaled intercept column.
    public static func fit(
        observations: [AffineObservation],
        degeneracyTolerance: Double = 1e-12
    ) throws -> AffineTransform2D {
        guard observations.count >= 3 else {
            throw AffineCalibrationError.insufficientObservations(
                required: 3,
                received: observations.count
            )
        }

        guard observations.allSatisfy({ observation in
            observation.input.x.isFinite && observation.input.y.isFinite
                && observation.output.x.isFinite && observation.output.y.isFinite
        }) else {
            throw AffineCalibrationError.nonFiniteObservation
        }

        let count = Double(observations.count)
        let meanInputX = observations.reduce(0) { $0 + $1.input.x } / count
        let meanInputY = observations.reduce(0) { $0 + $1.input.y } / count
        let meanOutputX = observations.reduce(0) { $0 + $1.output.x } / count
        let meanOutputY = observations.reduce(0) { $0 + $1.output.y } / count

        var xx = 0.0
        var xy = 0.0
        var yy = 0.0
        var xOutputX = 0.0
        var yOutputX = 0.0
        var xOutputY = 0.0
        var yOutputY = 0.0

        for observation in observations {
            let x = observation.input.x - meanInputX
            let y = observation.input.y - meanInputY
            let outputX = observation.output.x - meanOutputX
            let outputY = observation.output.y - meanOutputY

            xx += x * x
            xy += x * y
            yy += y * y
            xOutputX += x * outputX
            yOutputX += y * outputX
            xOutputY += x * outputY
            yOutputY += y * outputY
        }

        let determinant = xx * yy - xy * xy
        let covarianceScale = max(xx, yy)
        guard covarianceScale > 0,
              determinant.isFinite,
              determinant > degeneracyTolerance * covarianceScale * covarianceScale
        else {
            throw AffineCalibrationError.degenerateInput
        }

        let a = (xOutputX * yy - yOutputX * xy) / determinant
        let b = (yOutputX * xx - xOutputX * xy) / determinant
        let c = (xOutputY * yy - yOutputY * xy) / determinant
        let d = (yOutputY * xx - xOutputY * xy) / determinant
        let tx = meanOutputX - a * meanInputX - b * meanInputY
        let ty = meanOutputY - c * meanInputX - d * meanInputY

        return AffineTransform2D(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}
