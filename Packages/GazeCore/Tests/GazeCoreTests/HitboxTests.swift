import Foundation
import Testing
@testable import GazeCore

@Test
func visualAngleConvertsToPhysicalExtent() {
    let geometry = ScreenGeometry(
        physicalWidthMillimetres: 300,
        physicalHeightMillimetres: 200,
        viewingDistanceMillimetres: 600
    )

    // Half-extent of 2° at 600 mm = 600 * tan(1°) ≈ 10.47 mm, so the full
    // foveal patch is roughly 21 mm across — about two centimetres, which is
    // the textbook figure for foveal coverage at a normal desk distance.
    let half = geometry.millimetres(forVisualAngle: 2.0)
    #expect(abs(half - 10.472) < 0.01)

    #expect(geometry.millimetres(forVisualAngle: 0) == 0)
    #expect(geometry.millimetres(forVisualAngle: 5.0) > half)
}

@Test
func fovealHitboxIsASmallFractionOfTheScreen() {
    let geometry = ScreenGeometry.laptop13Inch
    let box = HitboxCalculator.hitbox(
        centre: Point2D(x: 0.5, y: 0.5),
        ring: .foveal,
        geometry: geometry
    )

    // Roughly 3.7% of screen width, 5.9% of height on a 13-inch panel.
    #expect(box.radiusX > 0.03 && box.radiusX < 0.05)
    #expect(box.radiusY > 0.05 && box.radiusY < 0.07)

    // The whole point of the exercise: nothing like the whole screen.
    #expect(box.screenAreaFraction < 0.01)
}

@Test
func parafovealRingIsLargerThanFoveal() {
    let geometry = ScreenGeometry.laptop13Inch
    let foveal = HitboxCalculator.hitbox(
        centre: Point2D(x: 0.5, y: 0.5), ring: .foveal, geometry: geometry
    )
    let parafoveal = HitboxCalculator.hitbox(
        centre: Point2D(x: 0.5, y: 0.5), ring: .parafoveal, geometry: geometry
    )

    #expect(parafoveal.radiusX > foveal.radiusX)
    #expect(parafoveal.screenAreaFraction > foveal.screenAreaFraction)
    #expect(parafoveal.screenAreaFraction < 0.05)
}

@Test
func uncertaintyRingGrowsToTheMeasuredTrackingError() {
    let geometry = ScreenGeometry.laptop13Inch

    let clean = HitboxCalculator.hitbox(
        centre: Point2D(x: 0.5, y: 0.5),
        ring: .uncertainty,
        geometry: geometry,
        trackingErrorRMS: 0
    )
    // The measured RMS from the first real calibration run on this hardware.
    let measured = HitboxCalculator.hitbox(
        centre: Point2D(x: 0.5, y: 0.5),
        ring: .uncertainty,
        geometry: geometry,
        trackingErrorRMS: 0.2368
    )

    #expect(measured.radiusX > clean.radiusX)
    #expect(abs(measured.radiusX - 0.2368) < 1e-9)
    #expect(abs(measured.radiusY - 0.2368) < 1e-9)

    // And it must be honest about how much worse that is.
    let penalty = HitboxCalculator.precisionPenalty(
        geometry: geometry,
        trackingErrorRMS: 0.2368
    )
    #expect(penalty > 20)
}

@Test
func hitboxContainsIsElliptical() {
    let box = Hitbox(
        centre: Point2D(x: 0.5, y: 0.5),
        radiusX: 0.1,
        radiusY: 0.05,
        visualAngleDegrees: 2
    )

    #expect(box.contains(Point2D(x: 0.5, y: 0.5)))
    #expect(box.contains(Point2D(x: 0.59, y: 0.5)))
    #expect(!box.contains(Point2D(x: 0.61, y: 0.5)))
    #expect(box.contains(Point2D(x: 0.5, y: 0.549)))
    #expect(!box.contains(Point2D(x: 0.5, y: 0.551)))

    // The rectangle corner sits outside the ellipse.
    #expect(!box.contains(Point2D(x: 0.599, y: 0.549)))
}

@Test
func hitboxBoundsClampToTheScreen() {
    let corner = Hitbox(
        centre: Point2D(x: 0.02, y: 0.98),
        radiusX: 0.1,
        radiusY: 0.1,
        visualAngleDegrees: 2
    )

    let bounds = corner.bounds
    #expect(bounds.minX == 0)
    #expect(bounds.maxY == 1)
    #expect(bounds.maxX > 0)
    #expect(bounds.minY < 1)
}

@Test
func hitboxIntersectsRectangles() {
    let box = Hitbox(
        centre: Point2D(x: 0.5, y: 0.5),
        radiusX: 0.05,
        radiusY: 0.05,
        visualAngleDegrees: 2
    )

    #expect(box.intersects(rect: (minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)))
    #expect(box.intersects(rect: (minX: 0.53, minY: 0.53, maxX: 0.9, maxY: 0.9)))
    #expect(!box.intersects(rect: (minX: 0.7, minY: 0.7, maxX: 0.9, maxY: 0.9)))
}

@Test
func ringsAreOrderedInnermostFirst() {
    let rings = HitboxCalculator.rings(
        centre: Point2D(x: 0.5, y: 0.5),
        geometry: .laptop13Inch,
        trackingErrorRMS: 0.2368
    )

    #expect(rings.count == 3)
    #expect(rings[0].ring == .foveal)
    #expect(rings[1].ring == .parafoveal)
    #expect(rings[2].ring == .uncertainty)
    #expect(rings[0].hitbox.screenAreaFraction < rings[1].hitbox.screenAreaFraction)
    #expect(rings[1].hitbox.screenAreaFraction < rings[2].hitbox.screenAreaFraction)
}
