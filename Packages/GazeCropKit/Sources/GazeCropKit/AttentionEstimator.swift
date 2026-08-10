import Foundation

public struct TimedGazePoint: Equatable, Sendable {
    public let point: NormalizedPoint
    public let confidence: Double
    public let captureUptime: TimeInterval

    public init(point: NormalizedPoint, confidence: Double, captureUptime: TimeInterval) {
        self.point = point
        self.confidence = confidence
        self.captureUptime = captureUptime
    }
}

public struct AttentionSnapshot: Equatable, Sendable {
    public let center: NormalizedPoint
    public let radiusX: Double
    public let radiusY: Double
    public let sourceConfidence: Double
    public let sampleCount: Int
    public let coverageDuration: TimeInterval
    public let newestSampleAge: TimeInterval

    public init(
        center: NormalizedPoint,
        radiusX: Double,
        radiusY: Double,
        sourceConfidence: Double,
        sampleCount: Int,
        coverageDuration: TimeInterval,
        newestSampleAge: TimeInterval
    ) {
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.sourceConfidence = sourceConfidence
        self.sampleCount = sampleCount
        self.coverageDuration = coverageDuration
        self.newestSampleAge = newestSampleAge
    }

    public func isEligible(using policy: FixationPolicy = .init()) -> Bool {
        sampleCount >= policy.minimumSampleCount
            && coverageDuration >= policy.minimumCoverageDuration
            && newestSampleAge <= policy.maximumSampleAge
            && sourceConfidence >= policy.minimumSourceConfidence
            && max(radiusX, radiusY) <= policy.maximumNormalizedRadius
    }
}

public struct FixationPolicy: Equatable, Sendable {
    public var minimumSampleCount: Int
    public var minimumCoverageDuration: TimeInterval
    public var maximumSampleAge: TimeInterval
    public var minimumSourceConfidence: Double
    public var maximumNormalizedRadius: Double

    public init(
        minimumSampleCount: Int = 6,
        minimumCoverageDuration: TimeInterval = 0.15,
        maximumSampleAge: TimeInterval = 0.20,
        minimumSourceConfidence: Double = 0.50,
        maximumNormalizedRadius: Double = 0.08
    ) {
        self.minimumSampleCount = minimumSampleCount
        self.minimumCoverageDuration = minimumCoverageDuration
        self.maximumSampleAge = maximumSampleAge
        self.minimumSourceConfidence = minimumSourceConfidence
        self.maximumNormalizedRadius = maximumNormalizedRadius
    }
}

public enum AttentionEstimatorError: Error, Equatable, Sendable {
    case invalidWindowDuration
    case invalidMaximumSampleCount
    case invalidSample
    case timeMovedBackward
}

/// A bounded, transient fixation estimator. It deliberately retains evidence
/// for selection separately from any smoothing used to animate a gaze dot.
public struct AttentionEstimator: Sendable {
    public let windowDuration: TimeInterval
    public let maximumSampleCount: Int

    private var samples: [TimedGazePoint] = []
    private var lastUptime: TimeInterval?

    public init(windowDuration: TimeInterval = 0.55, maximumSampleCount: Int = 512) throws {
        guard windowDuration.isFinite, windowDuration > 0 else {
            throw AttentionEstimatorError.invalidWindowDuration
        }
        guard maximumSampleCount > 0 else {
            throw AttentionEstimatorError.invalidMaximumSampleCount
        }
        self.windowDuration = windowDuration
        self.maximumSampleCount = maximumSampleCount
        self.samples.reserveCapacity(maximumSampleCount)
    }

    public mutating func append(_ sample: TimedGazePoint) throws {
        guard sample.point.x.isFinite,
              sample.point.y.isFinite,
              sample.confidence.isFinite,
              sample.captureUptime.isFinite,
              (0...1).contains(sample.confidence)
        else { throw AttentionEstimatorError.invalidSample }
        if let lastUptime, sample.captureUptime < lastUptime {
            throw AttentionEstimatorError.timeMovedBackward
        }
        samples.append(sample)
        lastUptime = sample.captureUptime
        evict(before: sample.captureUptime - windowDuration)
        if samples.count > maximumSampleCount {
            samples.removeFirst(samples.count - maximumSampleCount)
        }
    }

    public mutating func snapshot(
        at uptime: TimeInterval,
        calibrationError: NormalizedPoint = .init(x: 0, y: 0)
    ) throws -> AttentionSnapshot? {
        guard uptime.isFinite else { throw AttentionEstimatorError.invalidSample }
        if let lastUptime, uptime < lastUptime { throw AttentionEstimatorError.timeMovedBackward }
        evict(before: uptime - windowDuration)
        guard let first = samples.first, let last = samples.last else { return nil }

        let xs = samples.map(\.point.x).sorted()
        let ys = samples.map(\.point.y).sorted()
        let confidences = samples.map(\.confidence).sorted()
        let centerX = median(xs)
        let centerY = median(ys)
        let madX = median(xs.map { abs($0 - centerX) }.sorted())
        let madY = median(ys.map { abs($0 - centerY) }.sorted())
        // 1.4826 converts MAD to a normal-distribution sigma estimate; two
        // sigmas give a useful conservative region without claiming certainty.
        let radiusX = max(madX * 1.4826 * 2, max(calibrationError.x, 0))
        let radiusY = max(madY * 1.4826 * 2, max(calibrationError.y, 0))

        return AttentionSnapshot(
            center: NormalizedPoint(x: centerX, y: centerY),
            radiusX: radiusX,
            radiusY: radiusY,
            sourceConfidence: median(confidences),
            sampleCount: samples.count,
            coverageDuration: last.captureUptime - first.captureUptime,
            newestSampleAge: max(0, uptime - last.captureUptime)
        )
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastUptime = nil
    }

    private mutating func evict(before cutoff: TimeInterval) {
        if let first = samples.firstIndex(where: { $0.captureUptime >= cutoff }) {
            if first > samples.startIndex { samples.removeFirst(first) }
        } else {
            samples.removeAll(keepingCapacity: true)
        }
    }

    private func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] / 2 + sorted[middle] / 2
        }
        return sorted[middle]
    }
}
