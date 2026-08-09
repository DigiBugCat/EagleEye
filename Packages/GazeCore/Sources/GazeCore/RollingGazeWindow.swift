import Foundation

public enum RollingGazeWindowError: Error, Equatable, Sendable {
    case invalidWindowDuration
    case invalidMaximumSampleCount
    case nonFinitePoint
    case nonFiniteTimestamp
    case timeMovedBackward(lastObserved: TimeInterval, received: TimeInterval)
}

/// A robust summary of gaze samples inside a fixed monotonic-time horizon.
public struct RollingGazeEstimate: Equatable, Sendable {
    public let point: Point2D
    public let sampleCount: Int

    /// The elapsed capture time from the oldest to newest retained sample.
    /// A window containing one sample therefore has zero coverage.
    public let coverageDuration: TimeInterval

    /// The monotonic time immediately after which the oldest retained sample
    /// must be evicted from this window.
    public let nextEvictionUptime: TimeInterval

    public init(
        point: Point2D,
        sampleCount: Int,
        coverageDuration: TimeInterval,
        nextEvictionUptime: TimeInterval
    ) {
        self.point = point
        self.sampleCount = sampleCount
        self.coverageDuration = coverageDuration
        self.nextEvictionUptime = nextEvictionUptime
    }
}

/// Maintains gaze evidence over a hard, time-based rolling horizon.
///
/// Samples exactly `windowDuration` old remain in the estimate; samples older
/// than that are evicted. Appends and evaluations must use timestamps from the
/// same monotonic clock. Actual sample timestamps must remain monotonic with
/// other samples; an evaluation may project beyond a later-arriving sample.
public struct RollingGazeWindow2D: Sendable {
    /// A conservative bound for callers that only provide a time horizon.
    ///
    /// The time horizon remains the primary retention policy, while this
    /// bound prevents a high-rate source from turning a valid horizon into an
    /// unbounded in-memory queue.
    public static let defaultMaximumSampleCount = 512

    public let windowDuration: TimeInterval
    public let maximumSampleCount: Int

    private struct TimedPoint: Sendable {
        let point: Point2D
        let captureUptime: TimeInterval
    }

    private var samples: [TimedPoint] = []
    private var lastAppendedUptime: TimeInterval?
    private var lastEvaluationUptime: TimeInterval?

    public init(
        windowDuration: TimeInterval,
        maximumSampleCount: Int = Self.defaultMaximumSampleCount
    ) throws {
        guard windowDuration.isFinite, windowDuration > 0 else {
            throw RollingGazeWindowError.invalidWindowDuration
        }
        guard maximumSampleCount > 0 else {
            throw RollingGazeWindowError.invalidMaximumSampleCount
        }
        self.windowDuration = windowDuration
        self.maximumSampleCount = maximumSampleCount
        self.samples.reserveCapacity(maximumSampleCount)
    }

    /// Adds a calibrated gaze point and returns the estimate at its capture time.
    @discardableResult
    public mutating func append(
        _ point: Point2D,
        at captureUptime: TimeInterval
    ) throws -> RollingGazeEstimate? {
        guard point.x.isFinite, point.y.isFinite else {
            throw RollingGazeWindowError.nonFinitePoint
        }
        try validateFiniteTimestamp(captureUptime)
        if let lastAppendedUptime, captureUptime < lastAppendedUptime {
            throw RollingGazeWindowError.timeMovedBackward(
                lastObserved: lastAppendedUptime,
                received: captureUptime
            )
        }

        samples.append(TimedPoint(point: point, captureUptime: captureUptime))
        lastAppendedUptime = captureUptime
        let effectiveUptime = max(lastEvaluationUptime ?? captureUptime, captureUptime)
        evictSamples(olderThan: effectiveUptime - windowDuration)
        trimToMaximumSampleCount()
        return makeEstimate()
    }

    /// Returns the estimate at a monotonic time, evicting evidence during silence.
    public mutating func estimate(
        at captureUptime: TimeInterval
    ) throws -> RollingGazeEstimate? {
        try validateFiniteTimestamp(captureUptime)
        let lastObservedUptime = max(
            lastAppendedUptime ?? -.infinity,
            lastEvaluationUptime ?? -.infinity
        )
        if captureUptime < lastObservedUptime {
            throw RollingGazeWindowError.timeMovedBackward(
                lastObserved: lastObservedUptime,
                received: captureUptime
            )
        }

        lastEvaluationUptime = captureUptime
        evictSamples(olderThan: captureUptime - windowDuration)
        trimToMaximumSampleCount()
        return makeEstimate()
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastAppendedUptime = nil
        lastEvaluationUptime = nil
    }

    private func validateFiniteTimestamp(_ captureUptime: TimeInterval) throws {
        guard captureUptime.isFinite else {
            throw RollingGazeWindowError.nonFiniteTimestamp
        }
    }

    private mutating func evictSamples(olderThan cutoff: TimeInterval) {
        guard let firstRetainedIndex = samples.firstIndex(where: {
            $0.captureUptime >= cutoff
        }) else {
            samples.removeAll(keepingCapacity: true)
            return
        }

        if firstRetainedIndex > samples.startIndex {
            samples.removeFirst(firstRetainedIndex)
        }
    }

    private mutating func trimToMaximumSampleCount() {
        let excessCount = samples.count - maximumSampleCount
        guard excessCount > 0 else { return }
        samples.removeFirst(excessCount)
    }

    private func makeEstimate() -> RollingGazeEstimate? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }

        let sortedX = samples.map(\.point.x).sorted()
        let sortedY = samples.map(\.point.y).sorted()
        return RollingGazeEstimate(
            point: Point2D(x: median(of: sortedX), y: median(of: sortedY)),
            sampleCount: samples.count,
            coverageDuration: last.captureUptime - first.captureUptime,
            nextEvictionUptime: first.captureUptime + windowDuration
        )
    }

    private func median(of sortedValues: [Double]) -> Double {
        let midpoint = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            // Halving before addition avoids overflowing for large finite values.
            return sortedValues[midpoint - 1] / 2 + sortedValues[midpoint] / 2
        }
        return sortedValues[midpoint]
    }
}
