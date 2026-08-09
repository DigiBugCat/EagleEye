import Foundation

/// A fitted gaze-to-screen mapping, either affine or projective.
///
/// Callers apply this instead of choosing a model by hand. `GazeMapping.fit`
/// picks between the two by held-out error, so a session that genuinely needs
/// only six parameters is not saddled with eight fitted to noise.
public enum GazeMapping: Codable, Equatable, Sendable {
    case affine(AffineTransform2D)
    case projective(Homography2D)

    public func apply(to point: Point2D) -> Point2D? {
        switch self {
        case .affine(let transform):
            let mapped = transform.apply(to: point)
            guard mapped.x.isFinite, mapped.y.isFinite else { return nil }
            return mapped
        case .projective(let homography):
            return homography.apply(to: point)
        }
    }

    public var modelName: String {
        switch self {
        case .affine: return "affine"
        case .projective: return "projective"
        }
    }

    /// Free parameters in the model — 6 for affine, 8 for projective.
    public var degreesOfFreedom: Int {
        switch self {
        case .affine: return 6
        case .projective: return 8
        }
    }
}

/// One target's fit error, in output (normalized screen) units.
public struct CalibrationResidual: Equatable, Sendable {
    public let index: Int
    public let dx: Double
    public let dy: Double

    public init(index: Int, dx: Double, dy: Double) {
        self.index = index
        self.dx = dx
        self.dy = dy
    }

    public var magnitude: Double { (dx * dx + dy * dy).squareRoot() }
}

/// The outcome of a calibration fit, including the evidence for the choice.
public struct CalibrationReport: Equatable, Sendable {
    public let mapping: GazeMapping
    public let residuals: [CalibrationResidual]
    public let rms: Double
    public let worstMagnitude: Double
    /// Leave-one-out error for each candidate. `nil` when a model could not be
    /// fitted with the available observations.
    public let affineHeldOutRMS: Double?
    public let projectiveHeldOutRMS: Double?
    /// Indices into the original observation array that were discarded as
    /// outliers before the final fit.
    public let droppedObservationIndices: [Int]

    public init(
        mapping: GazeMapping,
        residuals: [CalibrationResidual],
        rms: Double,
        worstMagnitude: Double,
        affineHeldOutRMS: Double?,
        projectiveHeldOutRMS: Double?,
        droppedObservationIndices: [Int] = []
    ) {
        self.mapping = mapping
        self.residuals = residuals
        self.rms = rms
        self.worstMagnitude = worstMagnitude
        self.affineHeldOutRMS = affineHeldOutRMS
        self.projectiveHeldOutRMS = projectiveHeldOutRMS
        self.droppedObservationIndices = droppedObservationIndices
    }

    /// Why the chosen model won, phrased for a status line.
    public var summary: String {
        let dropped = droppedObservationIndices.isEmpty
            ? ""
            : " · dropped \(droppedObservationIndices.map(String.init).joined(separator: ","))"
        let held: String
        switch (affineHeldOutRMS, projectiveHeldOutRMS) {
        case let (a?, p?):
            held = String(format: "held-out affine %.4f vs projective %.4f", a, p)
        case (_?, nil):
            held = "projective not fittable"
        case (nil, _?):
            held = "affine not fittable"
        case (nil, nil):
            held = "no held-out comparison"
        }
        return String(
            format: "%@ · RMS %.4f · worst %.4f%@ · %@",
            mapping.modelName, rms, worstMagnitude, dropped, held
        )
    }
}

public enum GazeMappingError: Error, Equatable, Sendable {
    case noModelFitted(affine: String, projective: String)
}

public enum CalibrationDiagnostics {
    public static func residuals(
        of mapping: GazeMapping,
        on observations: [AffineObservation]
    ) -> [CalibrationResidual] {
        observations.enumerated().compactMap { index, observation in
            guard let predicted = mapping.apply(to: observation.input) else { return nil }
            return CalibrationResidual(
                index: index,
                dx: predicted.x - observation.output.x,
                dy: predicted.y - observation.output.y
            )
        }
    }

    public static func rms(_ residuals: [CalibrationResidual]) -> Double {
        guard !residuals.isEmpty else { return .infinity }
        let sum = residuals.reduce(0.0) { $0 + $1.dx * $1.dx + $1.dy * $1.dy }
        return (sum / Double(residuals.count)).squareRoot()
    }

    /// Leave-one-out cross-validated error. Refitting without each observation
    /// and scoring on the excluded one is what stops eight parameters from
    /// simply memorizing nine targets.
    public static func leaveOneOutRMS(
        observations: [AffineObservation],
        fit: ([AffineObservation]) throws -> GazeMapping
    ) -> Double? {
        guard observations.count >= 3 else { return nil }

        var squaredError = 0.0
        var scored = 0

        for excluded in observations.indices {
            var training = observations
            training.remove(at: excluded)
            guard let mapping = try? fit(training),
                  let predicted = mapping.apply(to: observations[excluded].input)
            else { continue }

            let dx = predicted.x - observations[excluded].output.x
            let dy = predicted.y - observations[excluded].output.y
            guard dx.isFinite, dy.isFinite else { continue }
            squaredError += dx * dx + dy * dy
            scored += 1
        }

        guard scored >= 3 else { return nil }
        return (squaredError / Double(scored)).squareRoot()
    }
}

extension GazeMapping {
    /// Fits both candidate models and returns the one with lower held-out error.
    ///
    /// The projective model must beat affine by a clear margin to be adopted —
    /// a marginal win on nine noisy targets is overfitting, not geometry.
    public static func fit(
        observations: [AffineObservation],
        projectiveMargin: Double = 0.95
    ) throws -> CalibrationReport {
        var affineError = "not attempted"
        var projectiveError = "not attempted"

        var affineMapping: GazeMapping?
        var projectiveMapping: GazeMapping?

        do {
            affineMapping = .affine(try AffineCalibration.fit(observations: observations))
        } catch {
            affineError = String(describing: error)
        }

        do {
            projectiveMapping = .projective(try HomographyCalibration.fit(observations: observations))
        } catch {
            projectiveError = String(describing: error)
        }

        let affineHeldOut = affineMapping == nil ? nil : CalibrationDiagnostics.leaveOneOutRMS(
            observations: observations,
            fit: { .affine(try AffineCalibration.fit(observations: $0)) }
        )
        let projectiveHeldOut = projectiveMapping == nil ? nil : CalibrationDiagnostics.leaveOneOutRMS(
            observations: observations,
            fit: { .projective(try HomographyCalibration.fit(observations: $0)) }
        )

        let chosen: GazeMapping
        switch (affineMapping, projectiveMapping) {
        case let (affine?, projective?):
            if let a = affineHeldOut, let p = projectiveHeldOut, p < a * projectiveMargin {
                chosen = projective
            } else {
                chosen = affine
            }
        case let (affine?, nil):
            chosen = affine
        case let (nil, projective?):
            chosen = projective
        case (nil, nil):
            throw GazeMappingError.noModelFitted(affine: affineError, projective: projectiveError)
        }

        let residuals = CalibrationDiagnostics.residuals(of: chosen, on: observations)
        return CalibrationReport(
            mapping: chosen,
            residuals: residuals,
            rms: CalibrationDiagnostics.rms(residuals),
            worstMagnitude: residuals.map(\.magnitude).max() ?? .infinity,
            affineHeldOutRMS: affineHeldOut,
            projectiveHeldOutRMS: projectiveHeldOut
        )
    }

    /// Fits, then discards targets whose residual is a clear outlier and refits.
    ///
    /// One target where the user blinked, glanced away, or saccaded late drags
    /// the whole least-squares solution, and with only a dozen observations a
    /// single bad point measurably warps the map everywhere else. Dropping is
    /// preferred over reweighting here because the failure is categorical — the
    /// user was not looking at that target — not heavy-tailed noise.
    ///
    /// - Parameters:
    ///   - maxDrops: hard ceiling on discarded targets, so a genuinely noisy
    ///     session cannot be whittled down to a flattering subset.
    ///   - outlierFactor: a residual must exceed this multiple of the median
    ///     residual to be considered a mistake rather than ordinary error.
    ///   - minimumRetained: never fit on fewer than this many observations.
    ///   - absoluteFloor: in normalized screen units. Once the remaining fit is
    ///     this tight, the ratio test is meaningless — a near-zero median makes
    ///     every rounding error look like an outlier — so stop dropping.
    public static func robustFit(
        observations: [AffineObservation],
        maxDrops: Int = 2,
        outlierFactor: Double = 2.5,
        minimumRetained: Int = 8,
        absoluteFloor: Double = 0.01,
        projectiveMargin: Double = 0.95
    ) throws -> CalibrationReport {
        var surviving = Array(observations.indices)
        var report = try fit(observations: observations, projectiveMargin: projectiveMargin)

        for _ in 0..<maxDrops {
            guard surviving.count > minimumRetained else { break }

            let current = surviving.map { observations[$0] }
            let residuals = CalibrationDiagnostics.residuals(of: report.mapping, on: current)
            guard residuals.count == current.count else { break }

            let magnitudes = residuals.map(\.magnitude).sorted()
            let median = magnitudes[magnitudes.count / 2]
            guard median > 0 else { break }

            guard let worst = residuals.max(by: { $0.magnitude < $1.magnitude }),
                  worst.magnitude > median * outlierFactor,
                  worst.magnitude > absoluteFloor
            else { break }

            var candidate = surviving
            let droppedOriginalIndex = candidate.remove(at: worst.index)

            guard let refitted = try? fit(
                observations: candidate.map { observations[$0] },
                projectiveMargin: projectiveMargin
            ), refitted.rms < report.rms else {
                _ = droppedOriginalIndex
                break
            }

            surviving = candidate
            report = refitted
        }

        let dropped = Set(observations.indices).subtracting(surviving).sorted()
        guard !dropped.isEmpty else { return report }

        // Re-index residuals against the retained observations so callers can
        // still line them up with `droppedObservationIndices`.
        let retained = surviving.map { observations[$0] }
        let residuals = CalibrationDiagnostics.residuals(of: report.mapping, on: retained)
        return CalibrationReport(
            mapping: report.mapping,
            residuals: residuals,
            rms: CalibrationDiagnostics.rms(residuals),
            worstMagnitude: residuals.map(\.magnitude).max() ?? .infinity,
            affineHeldOutRMS: report.affineHeldOutRMS,
            projectiveHeldOutRMS: report.projectiveHeldOutRMS,
            droppedObservationIndices: dropped
        )
    }
}
