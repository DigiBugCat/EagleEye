import Foundation

/// Physical facts needed to turn an angle at the eye into a distance on screen.
public struct ScreenGeometry: Sendable, Equatable {
    /// Physical display size. Millimetres, because visual angle is physical.
    public let physicalWidthMillimetres: Double
    public let physicalHeightMillimetres: Double
    /// Eye-to-screen distance.
    public let viewingDistanceMillimetres: Double

    public init(
        physicalWidthMillimetres: Double,
        physicalHeightMillimetres: Double,
        viewingDistanceMillimetres: Double = 600
    ) {
        self.physicalWidthMillimetres = max(1, physicalWidthMillimetres)
        self.physicalHeightMillimetres = max(1, physicalHeightMillimetres)
        self.viewingDistanceMillimetres = max(50, viewingDistanceMillimetres)
    }

    /// A 13-inch laptop display at a normal desk distance.
    public static let laptop13Inch = ScreenGeometry(
        physicalWidthMillimetres: 286,
        physicalHeightMillimetres: 179,
        viewingDistanceMillimetres: 600
    )

    /// Half-extent on screen, in millimetres, subtended by `degrees` of visual angle.
    public func millimetres(forVisualAngle degrees: Double) -> Double {
        let radians = max(0, degrees) * .pi / 180
        return viewingDistanceMillimetres * Foundation.tan(radians / 2)
    }
}

/// An elliptical region of the screen, in normalized `0...1` coordinates.
///
/// Elliptical rather than rectangular because the region it stands for — the
/// patch of the visual field the eye actually resolves — is radial. A square
/// box would claim the corners, which sit further from the fixation point than
/// anything the fovea is reading.
public struct Hitbox: Sendable, Equatable {
    public let centre: Point2D
    public let radiusX: Double
    public let radiusY: Double
    /// Visual angle this box was built from, before any uncertainty inflation.
    public let visualAngleDegrees: Double

    public init(centre: Point2D, radiusX: Double, radiusY: Double, visualAngleDegrees: Double) {
        self.centre = centre
        self.radiusX = max(0, radiusX)
        self.radiusY = max(0, radiusY)
        self.visualAngleDegrees = visualAngleDegrees
    }

    public func contains(_ point: Point2D) -> Bool {
        guard radiusX > 0, radiusY > 0 else { return false }
        let dx = (point.x - centre.x) / radiusX
        let dy = (point.y - centre.y) / radiusY
        return dx * dx + dy * dy <= 1
    }

    /// Axis-aligned bounds, clamped to the screen.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        (
            minX: max(0, centre.x - radiusX),
            minY: max(0, centre.y - radiusY),
            maxX: min(1, centre.x + radiusX),
            maxY: min(1, centre.y + radiusY)
        )
    }

    /// Does this region overlap a normalized rectangle at all?
    ///
    /// Uses the axis-aligned bounds rather than the ellipse: a UI element
    /// clipping the corner of the box is still plausibly being read, and
    /// excluding it would lose context for no benefit.
    public func intersects(rect: (minX: Double, minY: Double, maxX: Double, maxY: Double)) -> Bool {
        let b = bounds
        return rect.minX <= b.maxX && rect.maxX >= b.minX
            && rect.minY <= b.maxY && rect.maxY >= b.minY
    }

    /// Fraction of the screen area this box covers — the honest measure of how
    /// much the payload has actually been narrowed.
    public var screenAreaFraction: Double {
        min(1, .pi * radiusX * radiusY)
    }
}

/// Nested regions of attention, ordered from certain to speculative.
public enum AttentionRing: String, Sendable, CaseIterable {
    /// ~2°. The patch the eye genuinely resolves — where reading happens.
    case foveal
    /// ~5°. Recognizable shape and layout, not legible text.
    case parafoveal
    /// Inflated by measured tracking error. Not a claim about vision; a claim
    /// about where the estimate could actually be.
    case uncertainty

    public var visualAngleDegrees: Double {
        switch self {
        case .foveal: return 2.0
        case .parafoveal: return 5.0
        case .uncertainty: return 5.0
        }
    }
}

public enum HitboxCalculator {
    /// Builds the region for one ring around a gaze point.
    ///
    /// - Parameter trackingErrorRMS: calibration RMS in normalized screen
    ///   units. For the `.uncertainty` ring the box is grown to at least this
    ///   radius: claiming a 2° hitbox while the tracker is off by a fifth of the
    ///   screen would be a lie about precision, and every consumer downstream
    ///   would inherit it.
    public static func hitbox(
        centre: Point2D,
        ring: AttentionRing,
        geometry: ScreenGeometry,
        trackingErrorRMS: Double = 0
    ) -> Hitbox {
        let halfExtent = geometry.millimetres(forVisualAngle: ring.visualAngleDegrees)
        var radiusX = halfExtent / geometry.physicalWidthMillimetres
        var radiusY = halfExtent / geometry.physicalHeightMillimetres

        if ring == .uncertainty, trackingErrorRMS > 0 {
            radiusX = max(radiusX, trackingErrorRMS)
            radiusY = max(radiusY, trackingErrorRMS)
        }

        return Hitbox(
            centre: centre,
            radiusX: radiusX,
            radiusY: radiusY,
            visualAngleDegrees: ring.visualAngleDegrees
        )
    }

    /// All three rings, innermost first.
    public static func rings(
        centre: Point2D,
        geometry: ScreenGeometry,
        trackingErrorRMS: Double = 0
    ) -> [(ring: AttentionRing, hitbox: Hitbox)] {
        AttentionRing.allCases.map { ring in
            (ring, hitbox(
                centre: centre,
                ring: ring,
                geometry: geometry,
                trackingErrorRMS: trackingErrorRMS
            ))
        }
    }

    /// How much bigger the honest region is than the foveal one.
    ///
    /// A value near 1 means tracking is good enough to claim foveal precision.
    /// Large values mean the hitbox is being driven by tracker error, not by
    /// human vision — and that the scan is guessing over a wide area.
    public static func precisionPenalty(
        geometry: ScreenGeometry,
        trackingErrorRMS: Double
    ) -> Double {
        let foveal = hitbox(
            centre: Point2D(x: 0.5, y: 0.5),
            ring: .foveal,
            geometry: geometry
        )
        let honest = hitbox(
            centre: Point2D(x: 0.5, y: 0.5),
            ring: .uncertainty,
            geometry: geometry,
            trackingErrorRMS: trackingErrorRMS
        )
        guard foveal.screenAreaFraction > 0 else { return .infinity }
        return honest.screenAreaFraction / foveal.screenAreaFraction
    }
}
