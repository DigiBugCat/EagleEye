import Foundation

/// A continuously moving calibration target.
///
/// Nine or thirteen static points sample the mapping only where they sit, and
/// they cluster away from the edges because a target at the very corner is
/// uncomfortable to fixate. A moving target fixes both problems: smooth pursuit
/// produces hundreds of correspondences per run and can be driven right out to
/// the extremes, which is exactly where a fit constrained only by interior
/// points extrapolates worst.
///
/// The path is deliberately ordered: the two long diagonals first, to pin the
/// widest excursions the eye will make, then a ring to fill in the perimeter
/// where the diagonals leave gaps.
public struct CalibrationSweep: Sendable {
    /// Inset from the screen edge, in normalized units. Targets are not driven
    /// fully to 0 or 1 because gaze at the extreme bezel is unreliable and the
    /// eye tends to undershoot it.
    public let margin: Double
    /// Revolutions of the ring segment.
    public let revolutions: Double

    public init(margin: Double = 0.06, revolutions: Double = 1.5) {
        self.margin = Swift.max(0, Swift.min(0.4, margin))
        self.revolutions = Swift.max(0.25, revolutions)
    }

    /// Fraction of the run spent on each of the two diagonals.
    private static let diagonalShare = 0.22

    private var low: Double { margin }
    private var high: Double { 1 - margin }

    /// Target position for a normalized progress value in `0...1`.
    public func position(at progress: Double) -> Point2D {
        let t = Swift.max(0, Swift.min(1, progress))
        let firstEnd = Self.diagonalShare
        let secondEnd = Self.diagonalShare * 2

        if t < firstEnd {
            // Top-left to bottom-right.
            let u = ease(t / firstEnd)
            return Point2D(x: lerp(low, high, u), y: lerp(low, high, u))
        }

        if t < secondEnd {
            // Top-right to bottom-left — the opposite extreme.
            let u = ease((t - firstEnd) / Self.diagonalShare)
            return Point2D(x: lerp(high, low, u), y: lerp(low, high, u))
        }

        // Ring through the perimeter, starting at the left edge mid-height so
        // it joins the end of the second diagonal without a jump.
        let u = (t - secondEnd) / (1 - secondEnd)
        let angle = .pi + u * revolutions * 2 * .pi
        let centre = (low + high) / 2
        let radius = (high - low) / 2
        return Point2D(
            x: centre + radius * Foundation.cos(angle),
            y: centre + radius * Foundation.sin(angle)
        )
    }

    /// Eases in and out of each diagonal so the eye is not asked to track an
    /// instantaneous velocity step at a segment boundary.
    private func ease(_ u: Double) -> Double {
        let clamped = Swift.max(0, Swift.min(1, u))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double {
        a + (b - a) * u
    }
}

/// Pairs live gaze samples with where the moving target was a moment earlier.
///
/// Smooth pursuit lags its target — the eye is chasing, not predicting — so
/// pairing a gaze sample with the target's *current* position bakes that lag
/// into the fit as a systematic offset along the direction of travel. Holding a
/// short history and pairing against the delayed position removes it.
public struct PursuitPairing: Sendable {
    public let latency: TimeInterval
    private var history: [(time: TimeInterval, point: Point2D)] = []
    private let horizon: TimeInterval

    public init(latency: TimeInterval = 0.12) {
        self.latency = Swift.max(0, latency)
        self.horizon = Swift.max(0.5, latency * 4)
    }

    public mutating func record(target: Point2D, at time: TimeInterval) {
        history.append((time, target))
        let cutoff = time - horizon
        if let firstKept = history.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
    }

    /// The target position `latency` seconds before `time`, linearly
    /// interpolated. Returns `nil` until the history covers that far back, so
    /// the opening frames of a sweep are discarded rather than mispaired.
    public func delayedTarget(at time: TimeInterval) -> Point2D? {
        let wanted = time - latency
        guard let first = history.first, first.time <= wanted else { return nil }

        var previous = first
        for entry in history.dropFirst() {
            if entry.time >= wanted {
                let span = entry.time - previous.time
                guard span > 0 else { return entry.point }
                let u = (wanted - previous.time) / span
                return Point2D(
                    x: previous.point.x + (entry.point.x - previous.point.x) * u,
                    y: previous.point.y + (entry.point.y - previous.point.y) * u
                )
            }
            previous = entry
        }
        return nil
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
    }
}

/// Reduces a dense pursuit stream to a set of observations a least-squares fit
/// can use without one slow-moving stretch of the path dominating the others.
public enum SweepDownsampler {
    /// Buckets observations by target position on a `resolution x resolution`
    /// grid and keeps the component-wise median input of each bucket.
    ///
    /// Median rather than mean because a blink or a lost frame produces a wild
    /// input, and one such sample would drag a bucket's mean well off.
    public static func condense(
        _ observations: [AffineObservation],
        resolution: Int = 8
    ) -> [AffineObservation] {
        guard resolution > 0, !observations.isEmpty else { return observations }

        var buckets: [Int: [AffineObservation]] = [:]
        for observation in observations {
            let column = bucketIndex(observation.output.x, resolution: resolution)
            let row = bucketIndex(observation.output.y, resolution: resolution)
            buckets[row * resolution + column, default: []].append(observation)
        }

        return buckets.keys.sorted().compactMap { key in
            guard let group = buckets[key], !group.isEmpty else { return nil }
            return AffineObservation(
                input: medianPoint(group.map(\.input)),
                output: medianPoint(group.map(\.output))
            )
        }
    }

    private static func bucketIndex(_ value: Double, resolution: Int) -> Int {
        let scaled = Int((value * Double(resolution)).rounded(.down))
        return Swift.max(0, Swift.min(resolution - 1, scaled))
    }

    private static func medianPoint(_ points: [Point2D]) -> Point2D {
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        return Point2D(x: xs[xs.count / 2], y: ys[ys.count / 2])
    }
}
