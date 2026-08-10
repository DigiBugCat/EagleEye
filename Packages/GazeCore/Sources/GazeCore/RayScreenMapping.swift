import Foundation

/// Metric dimensions of the selected display's visible surface.
public struct PhysicalSize2D: Codable, Equatable, Sendable {
    public let widthMeters: Double
    public let heightMeters: Double

    public init(widthMeters: Double, heightMeters: Double) {
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
    }

    public var isValid: Bool {
        widthMeters.isFinite && heightMeters.isFinite
            && widthMeters >= 0.10 && widthMeters <= 3
            && heightMeters >= 0.07 && heightMeters <= 2
    }
}

/// A physical display rectangle expressed in the phone tracking session.
/// Runtime mapping intersects the full eye ray with this plane, then resolves
/// the hit along the fitted horizontal and vertical screen axes.
public struct RayScreenMapping: Codable, Equatable, Sendable {
    public let center: Vector3
    public let horizontalAxis: Vector3
    public let verticalAxis: Vector3
    public let screenSize: PhysicalSize2D

    public init(
        center: Vector3,
        horizontalAxis: Vector3,
        verticalAxis: Vector3,
        screenSize: PhysicalSize2D
    ) {
        self.center = center
        self.horizontalAxis = horizontalAxis
        self.verticalAxis = verticalAxis
        self.screenSize = screenSize
    }

    public var isValid: Bool {
        guard screenSize.isValid,
              [center.x, center.y, center.z,
               horizontalAxis.x, horizontalAxis.y, horizontalAxis.z,
               verticalAxis.x, verticalAxis.y, verticalAxis.z].allSatisfy(\.isFinite)
        else { return false }
        let h = magnitude(horizontalAxis)
        let v = magnitude(verticalAxis)
        let orthogonality = abs(dot(horizontalAxis, verticalAxis))
        return abs(h - 1) < 0.02 && abs(v - 1) < 0.02 && orthogonality < 0.03
            && magnitude(cross(horizontalAxis, verticalAxis)) > 0.95
    }

    public func apply(to ray: GazeRay3D) -> Point2D? {
        guard isValid, let ray = ray.normalized else { return nil }
        let normal = cross(horizontalAxis, verticalAxis)
        let denominator = dot(normal, ray.direction)
        guard denominator.isFinite, abs(denominator) > 1e-5 else { return nil }
        let travel = dot(normal, subtract(center, ray.origin)) / denominator
        // The screen must lie in front of the emitted gaze direction. The
        // upper bound rejects numerically valid intersections far outside a
        // plausible face-to-display setup.
        guard travel.isFinite, travel > 0.02, travel < 3 else { return nil }
        let hit = add(ray.origin, scale(ray.direction, travel))
        let relative = subtract(hit, center)
        let x = 0.5 + dot(relative, horizontalAxis) / screenSize.widthMeters
        let y = 0.5 + dot(relative, verticalAxis) / screenSize.heightMeters
        guard x.isFinite, y.isFinite else { return nil }
        return Point2D(x: x, y: y)
    }
}

public struct RayScreenTargetObservation: Equatable, Sendable {
    public let target: Point2D
    public let rays: [GazeRay3D]

    public init(target: Point2D, rays: [GazeRay3D]) {
        self.target = target
        self.rays = rays
    }
}

public struct RayScreenCalibrationReport: Equatable, Sendable {
    public let mapping: RayScreenMapping
    public let residuals: [CalibrationResidual]
    public let rms: Double
    public let worstMagnitude: Double
    public let sampleCount: Int
    public let meanRayDistanceMeters: Double

    public init(
        mapping: RayScreenMapping,
        residuals: [CalibrationResidual],
        rms: Double,
        worstMagnitude: Double,
        sampleCount: Int,
        meanRayDistanceMeters: Double
    ) {
        self.mapping = mapping
        self.residuals = residuals
        self.rms = rms
        self.worstMagnitude = worstMagnitude
        self.sampleCount = sampleCount
        self.meanRayDistanceMeters = meanRayDistanceMeters
    }

    public var summary: String {
        String(
            format: "ray-plane · RMS %.4f · worst %.4f · mean ray distance %.1f mm · %d frames",
            rms,
            worstMagnitude,
            meanRayDistanceMeters * 1_000,
            sampleCount
        )
    }
}

public enum RayScreenCalibrationError: Error, Equatable, Sendable {
    case invalidScreenSize
    case insufficientTargets
    case insufficientRays
    case optimizationFailed
    case invalidMapping
    case insufficientForwardIntersections(accepted: Int, total: Int)
}

/// Fits the 6-DoF pose of a rectangle with known physical dimensions. Each
/// target contributes its stable raw rays; the objective minimizes the
/// perpendicular distance between the physical target point and its gaze ray.
/// Known screen dimensions remove the scale ambiguity that otherwise makes a
/// plane learned from a nearly stationary eye origin underdetermined.
public enum RayScreenCalibrator {
    public static func fit(
        observations: [RayScreenTargetObservation],
        screenSize: PhysicalSize2D
    ) throws -> RayScreenCalibrationReport {
        guard screenSize.isValid else { throw RayScreenCalibrationError.invalidScreenSize }
        let usable = observations.compactMap { observation -> RayScreenTargetObservation? in
            let rays = observation.rays.compactMap(\.normalized)
            guard rays.count >= 3,
                  observation.target.x.isFinite,
                  observation.target.y.isFinite else { return nil }
            return RayScreenTargetObservation(target: observation.target, rays: rays)
        }
        guard usable.count >= 6 else { throw RayScreenCalibrationError.insufficientTargets }

        let samples = usable.flatMap { observation in
            observation.rays.map { FitSample(ray: $0, target: observation.target) }
        }
        guard samples.count >= 24 else { throw RayScreenCalibrationError.insufficientRays }

        let seedCenter = initialCenter(samples: samples)
        let rotations: [[Double]] = [
            [0, 0, 0],
            [0, 0, .pi / 2],
            [0, 0, -.pi / 2],
            [0, 0, .pi],
        ]
        var best: (parameters: [Double], cost: Double)?
        for rotation in rotations {
            let seed = [seedCenter.x, seedCenter.y, seedCenter.z] + rotation
            guard let optimized = optimize(seed: seed, samples: samples, size: screenSize) else { continue }
            if best == nil || optimized.cost < best!.cost { best = optimized }
        }
        guard let best else { throw RayScreenCalibrationError.optimizationFailed }
        let mapping = makeMapping(parameters: best.parameters, size: screenSize)
        guard mapping.isValid else { throw RayScreenCalibrationError.invalidMapping }

        let forwardIntersections = samples.reduce(into: 0) { count, sample in
            if mapping.apply(to: sample.ray) != nil { count += 1 }
        }
        guard forwardIntersections >= samples.count * 3 / 4 else {
            throw RayScreenCalibrationError.insufficientForwardIntersections(
                accepted: forwardIntersections,
                total: samples.count
            )
        }

        let residuals = usable.enumerated().compactMap { index, observation -> CalibrationResidual? in
            let points = observation.rays.compactMap(mapping.apply)
            guard !points.isEmpty else { return nil }
            let estimate = median(points)
            return CalibrationResidual(
                index: index,
                dx: estimate.x - observation.target.x,
                dy: estimate.y - observation.target.y
            )
        }
        guard residuals.count >= 6 else { throw RayScreenCalibrationError.invalidMapping }
        let distances = perpendicularDistances(parameters: best.parameters, samples: samples, size: screenSize)
        return RayScreenCalibrationReport(
            mapping: mapping,
            residuals: residuals,
            rms: CalibrationDiagnostics.rms(residuals),
            worstMagnitude: residuals.map(\.magnitude).max() ?? .infinity,
            sampleCount: samples.count,
            meanRayDistanceMeters: distances.reduce(0, +) / Double(distances.count)
        )
    }

    private struct FitSample {
        let ray: GazeRay3D
        let target: Point2D
    }

    private static func optimize(
        seed: [Double],
        samples: [FitSample],
        size: PhysicalSize2D
    ) -> (parameters: [Double], cost: Double)? {
        var parameters = seed
        var damping = 1e-4
        var cost = robustCost(parameters: parameters, samples: samples, size: size)
        guard cost.isFinite else { return nil }

        for _ in 0..<55 {
            let rawVectors = residualVectors(parameters: parameters, samples: samples, size: size)
            let magnitudes = rawVectors.map(magnitude)
            let sorted = magnitudes.sorted()
            let medianDistance = sorted[sorted.count / 2]
            let huberCutoff = max(0.0025, medianDistance * 2.5)
            let weights = magnitudes.map { distance in
                distance <= huberCutoff ? 1 : huberCutoff / max(distance, 1e-12)
            }
            let residual = weightedFlattened(rawVectors, weights: weights)
            var jacobian = Array(
                repeating: Array(repeating: 0.0, count: parameters.count),
                count: residual.count
            )
            for column in parameters.indices {
                var shifted = parameters
                let step = column < 3 ? 1e-5 : 2e-5
                shifted[column] += step
                let shiftedResidual = weightedFlattened(
                    residualVectors(parameters: shifted, samples: samples, size: size),
                    weights: weights
                )
                for row in residual.indices {
                    jacobian[row][column] = (shiftedResidual[row] - residual[row]) / step
                }
            }

            var normal = Array(repeating: Array(repeating: 0.0, count: 6), count: 6)
            var gradient = Array(repeating: 0.0, count: 6)
            for row in residual.indices {
                for column in 0..<6 {
                    gradient[column] += jacobian[row][column] * residual[row]
                    for other in 0..<6 {
                        normal[column][other] += jacobian[row][column] * jacobian[row][other]
                    }
                }
            }
            for index in 0..<6 { normal[index][index] += damping }
            guard let delta = solve(normal, gradient.map { -$0 }) else { return nil }
            let candidate = zip(parameters, delta).map(+)
            guard candidate.allSatisfy(\.isFinite), magnitude(Vector3(
                x: candidate[0], y: candidate[1], z: candidate[2]
            )) < 3 else { return nil }
            let candidateCost = robustCost(parameters: candidate, samples: samples, size: size)
            if candidateCost < cost {
                parameters = candidate
                if abs(cost - candidateCost) < 1e-12 { break }
                cost = candidateCost
                damping = max(1e-8, damping * 0.35)
            } else {
                damping = min(1e4, damping * 8)
            }
            if delta.map(abs).max() ?? .infinity < 1e-7 { break }
        }
        return (parameters, cost)
    }

    private static func residualVectors(
        parameters: [Double],
        samples: [FitSample],
        size: PhysicalSize2D
    ) -> [Vector3] {
        let mapping = makeMapping(parameters: parameters, size: size)
        return samples.map { sample in
            let target = physicalTarget(mapping: mapping, normalized: sample.target)
            let relative = subtract(target, sample.ray.origin)
            let along = dot(relative, sample.ray.direction)
            let perpendicular = subtract(relative, scale(sample.ray.direction, along))
            // Distance to an infinite line has a mirrored solution behind the
            // eyes. Penalize targets outside the physically plausible forward
            // ray segment so optimization cannot select that false plane.
            let longitudinalPenalty: Double
            if along < 0.03 {
                longitudinalPenalty = 0.03 - along
            } else if along > 2.5 {
                longitudinalPenalty = along - 2.5
            } else {
                longitudinalPenalty = 0
            }
            return add(perpendicular, scale(sample.ray.direction, longitudinalPenalty))
        }
    }

    private static func perpendicularDistances(
        parameters: [Double],
        samples: [FitSample],
        size: PhysicalSize2D
    ) -> [Double] {
        residualVectors(parameters: parameters, samples: samples, size: size).map(magnitude)
    }

    private static func robustCost(
        parameters: [Double],
        samples: [FitSample],
        size: PhysicalSize2D
    ) -> Double {
        let distances = perpendicularDistances(parameters: parameters, samples: samples, size: size)
        guard !distances.isEmpty else { return .infinity }
        let sorted = distances.sorted()
        let cutoff = max(0.0025, sorted[sorted.count / 2] * 2.5)
        let sum = distances.reduce(0.0) { partial, value in
            if value <= cutoff { return partial + value * value }
            return partial + 2 * cutoff * value - cutoff * cutoff
        }
        return sum / Double(distances.count)
    }

    private static func weightedFlattened(_ vectors: [Vector3], weights: [Double]) -> [Double] {
        zip(vectors, weights).flatMap { vector, weight in
            let scale = weight.squareRoot()
            return [vector.x * scale, vector.y * scale, vector.z * scale]
        }
    }

    private static func makeMapping(parameters: [Double], size: PhysicalSize2D) -> RayScreenMapping {
        let rotation = rotationMatrix(Vector3(x: parameters[3], y: parameters[4], z: parameters[5]))
        return RayScreenMapping(
            center: Vector3(x: parameters[0], y: parameters[1], z: parameters[2]),
            horizontalAxis: matrixVector(rotation, Vector3(x: 1, y: 0, z: 0)),
            verticalAxis: matrixVector(rotation, Vector3(x: 0, y: 1, z: 0)),
            screenSize: size
        )
    }

    private static func physicalTarget(mapping: RayScreenMapping, normalized: Point2D) -> Vector3 {
        add(
            mapping.center,
            add(
                scale(mapping.horizontalAxis, (normalized.x - 0.5) * mapping.screenSize.widthMeters),
                scale(mapping.verticalAxis, (normalized.y - 0.5) * mapping.screenSize.heightMeters)
            )
        )
    }

    private static func initialCenter(samples: [FitSample]) -> Vector3 {
        let hits = samples.compactMap { sample -> Vector3? in
            guard abs(sample.ray.direction.z) > 1e-5 else { return nil }
            let travel = -sample.ray.origin.z / sample.ray.direction.z
            guard travel.isFinite, travel > 0, travel < 3 else { return nil }
            return add(sample.ray.origin, scale(sample.ray.direction, travel))
        }
        guard !hits.isEmpty else { return Vector3(x: 0, y: 0, z: 0) }
        return Vector3(
            x: scalarMedian(hits.map(\.x)),
            y: scalarMedian(hits.map(\.y)),
            z: scalarMedian(hits.map(\.z))
        )
    }

    private static func rotationMatrix(_ vector: Vector3) -> [[Double]] {
        let angle = magnitude(vector)
        guard angle > 1e-12 else {
            return [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        }
        let x = vector.x / angle
        let y = vector.y / angle
        let z = vector.z / angle
        let c = cos(angle)
        let s = sin(angle)
        let oneMinusC = 1 - c
        return [
            [c + x * x * oneMinusC, x * y * oneMinusC - z * s, x * z * oneMinusC + y * s],
            [y * x * oneMinusC + z * s, c + y * y * oneMinusC, y * z * oneMinusC - x * s],
            [z * x * oneMinusC - y * s, z * y * oneMinusC + x * s, c + z * z * oneMinusC],
        ]
    }

    private static func matrixVector(_ matrix: [[Double]], _ vector: Vector3) -> Vector3 {
        Vector3(
            x: matrix[0][0] * vector.x + matrix[0][1] * vector.y + matrix[0][2] * vector.z,
            y: matrix[1][0] * vector.x + matrix[1][1] * vector.y + matrix[1][2] * vector.z,
            z: matrix[2][0] * vector.x + matrix[2][1] * vector.y + matrix[2][2] * vector.z
        )
    }

    private static func solve(_ matrix: [[Double]], _ values: [Double]) -> [Double]? {
        var augmented = zip(matrix, values).map { $0 + [$1] }
        let count = values.count
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }), abs(augmented[pivot][column]) > 1e-12 else { return nil }
            if pivot != column { augmented.swapAt(pivot, column) }
            let divisor = augmented[column][column]
            for index in column...count { augmented[column][index] /= divisor }
            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                guard factor != 0 else { continue }
                for index in column...count {
                    augmented[row][index] -= factor * augmented[column][index]
                }
            }
        }
        return augmented.map { $0[count] }
    }
}

private func add(_ a: Vector3, _ b: Vector3) -> Vector3 {
    Vector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
}

private func subtract(_ a: Vector3, _ b: Vector3) -> Vector3 {
    Vector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
}

private func scale(_ vector: Vector3, _ scalar: Double) -> Vector3 {
    Vector3(x: vector.x * scalar, y: vector.y * scalar, z: vector.z * scalar)
}

private func dot(_ a: Vector3, _ b: Vector3) -> Double {
    a.x * b.x + a.y * b.y + a.z * b.z
}

private func cross(_ a: Vector3, _ b: Vector3) -> Vector3 {
    Vector3(
        x: a.y * b.z - a.z * b.y,
        y: a.z * b.x - a.x * b.z,
        z: a.x * b.y - a.y * b.x
    )
}

private func magnitude(_ vector: Vector3) -> Double {
    (vector.x * vector.x + vector.y * vector.y + vector.z * vector.z).squareRoot()
}

private func median(_ points: [Point2D]) -> Point2D {
    Point2D(x: scalarMedian(points.map(\.x)), y: scalarMedian(points.map(\.y)))
}

private func scalarMedian(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return sorted[middle - 1] / 2 + sorted[middle] / 2
    }
    return sorted[middle]
}
