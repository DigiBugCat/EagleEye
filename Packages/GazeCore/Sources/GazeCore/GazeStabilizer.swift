import Foundation

/// One axis of a 1€ filter.
///
/// A fixed-alpha average has one setting for two opposite problems: raise it
/// and a still gaze jitters, lower it and a moving gaze drags behind. The 1€
/// filter varies its cutoff with speed — heavy smoothing when slow, light when
/// fast — so it can be still *and* responsive instead of splitting the
/// difference.
struct OneEuroAxis: Sendable {
    var minimumCutoff: Double
    var beta: Double
    var derivativeCutoff: Double

    private var value: Double?
    private var derivative: Double = 0

    init(minimumCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private func alpha(cutoff: Double, period: Double) -> Double {
        let tau = 1 / (2 * Double.pi * max(cutoff, 1e-6))
        return 1 / (1 + tau / max(period, 1e-6))
    }

    mutating func update(_ sample: Double, period: Double) -> Double {
        guard let previous = value else {
            value = sample
            derivative = 0
            return sample
        }

        let rawDerivative = (sample - previous) / max(period, 1e-6)
        let derivativeAlpha = alpha(cutoff: derivativeCutoff, period: period)
        derivative += derivativeAlpha * (rawDerivative - derivative)

        let cutoff = minimumCutoff + beta * abs(derivative)
        let valueAlpha = alpha(cutoff: cutoff, period: period)
        let filtered = previous + valueAlpha * (sample - previous)
        value = filtered
        return filtered
    }

    mutating func reset(to sample: Double? = nil) {
        value = sample
        derivative = 0
    }
}

/// Turns raw mapped gaze into a pointer that is comfortable to watch.
///
/// Three mechanisms, each aimed at a different source of discomfort:
///
/// 1. **Adaptive smoothing** removes the high-frequency tremor that makes a
///    still dot look like it is vibrating.
/// 2. **A dead zone** holds the dot completely motionless while the estimate
///    wanders inside tracker noise. Constant small motion in the periphery is
///    the single most fatiguing thing an overlay can do — it keeps claiming the
///    eye's attention.
/// 3. **Saccade snapping** teleports the dot on a genuine jump instead of
///    sliding it across the screen. A smooth glide over a long distance is
///    exactly the kind of large-field motion that provokes nausea, and it is
///    also a lie: the eye did not travel that path, it jumped.
public struct GazeStabilizer: Sendable {
    /// Below this cutoff the filter is at its heaviest. Hz.
    public var minimumCutoff: Double
    /// How aggressively the cutoff opens up with speed.
    public var beta: Double
    /// Movement smaller than this leaves the output untouched. Normalized
    /// screen units.
    public var deadZone: Double
    /// A single-frame jump larger than this is treated as a saccade and snapped.
    public var saccadeThreshold: Double

    private var x: OneEuroAxis
    private var y: OneEuroAxis
    private var held: Point2D?
    private var lastTimestamp: TimeInterval?

    public private(set) var lastWasSaccade = false
    public private(set) var isHolding = false

    public init(
        minimumCutoff: Double = 0.7,
        beta: Double = 0.35,
        deadZone: Double = 0.010,
        saccadeThreshold: Double = 0.09
    ) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.deadZone = deadZone
        self.saccadeThreshold = saccadeThreshold
        self.x = OneEuroAxis(minimumCutoff: minimumCutoff, beta: beta)
        self.y = OneEuroAxis(minimumCutoff: minimumCutoff, beta: beta)
    }

    @discardableResult
    public mutating func update(_ sample: Point2D, at timestamp: TimeInterval) -> Point2D {
        defer { lastTimestamp = timestamp }

        guard let previousTimestamp = lastTimestamp, let currentHeld = held else {
            x.reset(to: sample.x)
            y.reset(to: sample.y)
            held = sample
            lastWasSaccade = false
            isHolding = false
            return sample
        }

        // Guard the period: a dropped connection or a paused app can hand us a
        // gap of seconds, and dividing by it makes the filter behave as if the
        // pointer teleported at zero speed.
        let period = min(max(timestamp - previousTimestamp, 1.0 / 240), 0.25)

        let jump = distance(sample, currentHeld)
        if jump > saccadeThreshold {
            // Genuine saccade: snap, do not glide.
            x.reset(to: sample.x)
            y.reset(to: sample.y)
            held = sample
            lastWasSaccade = true
            isHolding = false
            return sample
        }
        lastWasSaccade = false

        let filtered = Point2D(
            x: x.update(sample.x, period: period),
            y: y.update(sample.y, period: period)
        )

        // Dead zone is applied to the *filtered* value against what is being
        // displayed, so the dot stays put rather than creeping.
        if distance(filtered, currentHeld) < deadZone {
            isHolding = true
            return currentHeld
        }

        isHolding = false
        held = filtered
        return filtered
    }

    public var value: Point2D? { held }

    public mutating func reset() {
        x.reset()
        y.reset()
        held = nil
        lastTimestamp = nil
        lastWasSaccade = false
        isHolding = false
    }

    private func distance(_ a: Point2D, _ b: Point2D) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
