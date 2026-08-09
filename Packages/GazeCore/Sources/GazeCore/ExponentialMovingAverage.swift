import Foundation

public enum ExponentialMovingAverageError: Error, Equatable, Sendable {
    case invalidAlpha
}

/// Stateful exponential smoothing for gaze coordinates.
public struct ExponentialMovingAverage2D: Sendable {
    public let alpha: Double
    public private(set) var value: Point2D?

    public init(alpha: Double) throws {
        guard alpha.isFinite, alpha > 0, alpha <= 1 else {
            throw ExponentialMovingAverageError.invalidAlpha
        }
        self.alpha = alpha
        self.value = nil
    }

    @discardableResult
    public mutating func update(with sample: Point2D) -> Point2D {
        guard let value else {
            self.value = sample
            return sample
        }

        let updated = Point2D(
            x: alpha * sample.x + (1 - alpha) * value.x,
            y: alpha * sample.y + (1 - alpha) * value.y
        )
        self.value = updated
        return updated
    }

    public mutating func reset() {
        value = nil
    }
}
