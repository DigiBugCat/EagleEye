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
    /// The observations were finite, but fitting overflowed or produced a
    /// transform/result that cannot be safely consumed.
    case nonFiniteResult
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

        guard let meanInputX = finiteMean(observations.map { $0.input.x }),
              let meanInputY = finiteMean(observations.map { $0.input.y }),
              let meanOutputX = finiteMean(observations.map { $0.output.x }),
              let meanOutputY = finiteMean(observations.map { $0.output.y })
        else {
            throw AffineCalibrationError.nonFiniteResult
        }

        var xx = 0.0
        var xy = 0.0
        var yy = 0.0
        var xOutputX = 0.0
        var yOutputX = 0.0
        var xOutputY = 0.0
        var yOutputY = 0.0

        for observation in observations {
            guard let x = finiteDifference(observation.input.x, meanInputX),
                  let y = finiteDifference(observation.input.y, meanInputY),
                  let outputX = finiteDifference(observation.output.x, meanOutputX),
                  let outputY = finiteDifference(observation.output.y, meanOutputY),
                  let xxTerm = finiteProduct(x, x),
                  let xyTerm = finiteProduct(x, y),
                  let yyTerm = finiteProduct(y, y),
                  let xOutputXTerm = finiteProduct(x, outputX),
                  let yOutputXTerm = finiteProduct(y, outputX),
                  let xOutputYTerm = finiteProduct(x, outputY),
                  let yOutputYTerm = finiteProduct(y, outputY),
                  let nextXX = finiteSum(xx, xxTerm),
                  let nextXY = finiteSum(xy, xyTerm),
                  let nextYY = finiteSum(yy, yyTerm),
                  let nextXOutputX = finiteSum(xOutputX, xOutputXTerm),
                  let nextYOutputX = finiteSum(yOutputX, yOutputXTerm),
                  let nextXOutputY = finiteSum(xOutputY, xOutputYTerm),
                  let nextYOutputY = finiteSum(yOutputY, yOutputYTerm)
            else {
                throw AffineCalibrationError.nonFiniteResult
            }

            xx = nextXX
            xy = nextXY
            yy = nextYY
            xOutputX = nextXOutputX
            yOutputX = nextYOutputX
            xOutputY = nextXOutputY
            yOutputY = nextYOutputY
        }

        guard let xxYY = finiteProduct(xx, yy),
              let xyXY = finiteProduct(xy, xy),
              let determinant = finiteDifference(xxYY, xyXY),
              determinant.isFinite,
              xx.isFinite, xy.isFinite, yy.isFinite,
              xOutputX.isFinite, yOutputX.isFinite,
              xOutputY.isFinite, yOutputY.isFinite
        else {
            throw AffineCalibrationError.nonFiniteResult
        }

        let covarianceScale = max(xx, yy)
        guard covarianceScale > 0 else {
            throw AffineCalibrationError.degenerateInput
        }

        // Compare the determinant after normalizing by the largest diagonal
        // term. This is algebraically equivalent to the unscaled comparison,
        // without overflowing while squaring a very large covariance scale.
        let normalizedDeterminant = determinant / covarianceScale / covarianceScale
        guard normalizedDeterminant.isFinite else {
            throw AffineCalibrationError.nonFiniteResult
        }
        guard determinant > 0,
              normalizedDeterminant > degeneracyTolerance
        else {
            throw AffineCalibrationError.degenerateInput
        }

        guard let aNumerator = finiteDifference(
                  finiteProduct(xOutputX, yy), finiteProduct(yOutputX, xy)
              ),
              let bNumerator = finiteDifference(
                  finiteProduct(yOutputX, xx), finiteProduct(xOutputX, xy)
              ),
              let cNumerator = finiteDifference(
                  finiteProduct(xOutputY, yy), finiteProduct(yOutputY, xy)
              ),
              let dNumerator = finiteDifference(
                  finiteProduct(yOutputY, xx), finiteProduct(xOutputY, xy)
              )
        else {
            throw AffineCalibrationError.nonFiniteResult
        }

        let a = aNumerator / determinant
        let b = bNumerator / determinant
        let c = cNumerator / determinant
        let d = dNumerator / determinant
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite,
              let aInputX = finiteProduct(a, meanInputX),
              let bInputY = finiteProduct(b, meanInputY),
              let cInputX = finiteProduct(c, meanInputX),
              let dInputY = finiteProduct(d, meanInputY),
              let tx = finiteDifference(
                  finiteDifference(meanOutputX, aInputX), bInputY
              ),
              let ty = finiteDifference(
                  finiteDifference(meanOutputY, cInputX), dInputY
              ),
              tx.isFinite, ty.isFinite
        else {
            throw AffineCalibrationError.nonFiniteResult
        }

        let transform = AffineTransform2D(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        guard observations.allSatisfy({ observation in
            let mapped = transform.apply(to: observation.input)
            return mapped.x.isFinite && mapped.y.isFinite
        }) else {
            throw AffineCalibrationError.nonFiniteResult
        }
        return transform
    }

    private static func finiteMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        // Weighted accumulation avoids overflowing a sum when all values have
        // the same large finite sign. Differences are checked separately when
        // centering observations below.
        var mean = 0.0
        for (index, value) in values.enumerated() {
            let count = Double(index + 1)
            let weightedPrevious = mean * (count - 1) / count
            let weightedValue = value / count
            mean = weightedPrevious + weightedValue
            guard mean.isFinite else { return nil }
        }
        return mean
    }

    private static func finiteSum(_ lhs: Double, _ rhs: Double) -> Double? {
        let result = lhs + rhs
        return result.isFinite ? result : nil
    }

    private static func finiteDifference(_ lhs: Double, _ rhs: Double) -> Double? {
        let result = lhs - rhs
        return result.isFinite ? result : nil
    }

    private static func finiteDifference(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return finiteDifference(lhs, rhs)
    }

    private static func finiteProduct(_ lhs: Double, _ rhs: Double) -> Double? {
        let result = lhs * rhs
        return result.isFinite ? result : nil
    }
}
