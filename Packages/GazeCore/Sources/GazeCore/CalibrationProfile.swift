import Foundation

/// Stable identity for a calibration record.
///
/// A setup identifies the physical arrangement (for example, a phone mount),
/// while the display identifies the destination display. Changing either one
/// must produce a different key instead of silently reusing a mapping.
public struct CalibrationProfileKey: Codable, Equatable, Hashable, Sendable {
    public let sourceID: GazeSourceID
    public let displayID: String
    public let setupID: String

    public init(sourceID: GazeSourceID, displayID: String, setupID: String) {
        self.sourceID = sourceID
        self.displayID = displayID
        self.setupID = setupID
    }

    public init(sourceID: String, displayID: String, setupID: String) {
        self.init(sourceID: GazeSourceID(sourceID), displayID: displayID, setupID: setupID)
    }

    public var isValid: Bool {
        sourceID.isValid
            && !displayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !setupID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum CalibrationProfileValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case invalidKey
    case keyMismatch
    case coordinateSpaceMismatch(expected: GazeCoordinateSpace, received: GazeCoordinateSpace)
    case nonFiniteMapping
    case invalidFineAdjustment
    case invalidQuality
    case invalidDate
}

/// Alias retained for calibration callers; the canonical source contract owns
/// the coordinate-space definition.
public typealias CalibrationCoordinateSpace = GazeCoordinateSpace

/// The model family selected by independent validation. `nil` on older
/// profiles means the legacy 2D mapping.
public enum CalibrationModelSelection: String, Codable, Equatable, Hashable, Sendable {
    case legacy2D
    case rayPlane3D
}

/// A small post-affine correction. Scaling is deliberately center-relative;
/// this means changing scale does not move the display center.
public struct FineAdjustment: Codable, Equatable, Sendable {
    public var scaleX: Double
    public var scaleY: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(
        scaleX: Double = 1,
        scaleY: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0
    ) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public init(scale: Point2D = Point2D(x: 1, y: 1), offset: Point2D = Point2D(x: 0, y: 0)) {
        self.init(scaleX: scale.x, scaleY: scale.y, offsetX: offset.x, offsetY: offset.y)
    }

    public static let identity = FineAdjustment()

    public var isValid: Bool {
        scaleX.isFinite && scaleY.isFinite && offsetX.isFinite && offsetY.isFinite
            && scaleX > 0 && scaleY > 0
    }

    /// Applies center-relative scale first, then the translation offset.
    public func apply(to point: Point2D, around center: Point2D = Point2D(x: 0.5, y: 0.5)) -> Point2D {
        Point2D(
            x: center.x + (point.x - center.x) * scaleX + offsetX,
            y: center.y + (point.y - center.y) * scaleY + offsetY
        )
    }

    public func applying(to point: Point2D, around center: Point2D = Point2D(x: 0.5, y: 0.5)) -> Point2D {
        apply(to: point, around: center)
    }

    public func apply(to point: Point2D, center: Point2D) -> Point2D {
        apply(to: point, around: center)
    }

    public func applying(to point: Point2D, center: Point2D) -> Point2D {
        apply(to: point, around: center)
    }

    public var scale: Point2D { Point2D(x: scaleX, y: scaleY) }
    public var offset: Point2D { Point2D(x: offsetX, y: offsetY) }
}

/// Summary statistics retained alongside a fitted profile.
public struct CalibrationQualitySummary: Codable, Equatable, Sendable {
    public var sampleCount: Int
    public var targetCount: Int
    public var meanError: Double
    public var rmsError: Double
    public var maxError: Double
    public var validationRMSError: Double?
    public var validationMaxError: Double?
    public var meanTargetDispersion: Double?
    public var rejectedSampleCount: Int?
    public var modelName: String?
    public var legacyValidationRMSError: Double?
    public var legacyValidationMaxError: Double?
    public var rayPlaneValidationRMSError: Double?
    public var rayPlaneValidationMaxError: Double?

    public init(
        sampleCount: Int = 0,
        targetCount: Int = 0,
        meanError: Double = 0,
        rmsError: Double = 0,
        maxError: Double = 0,
        validationRMSError: Double? = nil,
        validationMaxError: Double? = nil,
        meanTargetDispersion: Double? = nil,
        rejectedSampleCount: Int? = nil,
        modelName: String? = nil,
        legacyValidationRMSError: Double? = nil,
        legacyValidationMaxError: Double? = nil,
        rayPlaneValidationRMSError: Double? = nil,
        rayPlaneValidationMaxError: Double? = nil
    ) {
        self.sampleCount = sampleCount
        self.targetCount = targetCount
        self.meanError = meanError
        self.rmsError = rmsError
        self.maxError = maxError
        self.validationRMSError = validationRMSError
        self.validationMaxError = validationMaxError
        self.meanTargetDispersion = meanTargetDispersion
        self.rejectedSampleCount = rejectedSampleCount
        self.modelName = modelName
        self.legacyValidationRMSError = legacyValidationRMSError
        self.legacyValidationMaxError = legacyValidationMaxError
        self.rayPlaneValidationRMSError = rayPlaneValidationRMSError
        self.rayPlaneValidationMaxError = rayPlaneValidationMaxError
    }

    public static let empty = CalibrationQualitySummary()

    public var isFinite: Bool {
        meanError.isFinite && rmsError.isFinite && maxError.isFinite
            && (validationRMSError?.isFinite ?? true)
            && (validationMaxError?.isFinite ?? true)
            && (meanTargetDispersion?.isFinite ?? true)
            && (legacyValidationRMSError?.isFinite ?? true)
            && (legacyValidationMaxError?.isFinite ?? true)
            && (rayPlaneValidationRMSError?.isFinite ?? true)
            && (rayPlaneValidationMaxError?.isFinite ?? true)
    }

    public var isValid: Bool {
        isFinite && sampleCount >= 0 && targetCount >= 0
            && (rejectedSampleCount.map { $0 >= 0 } ?? true)
    }

    public func meetsMinimumSamples(_ minimum: Int) -> Bool {
        sampleCount >= minimum && minimum > 0 && isFinite
    }

    /// Builds residual statistics from the observations used for a fit.
    public static func from(
        observations: [AffineObservation],
        transform: AffineTransform2D
    ) -> CalibrationQualitySummary {
        guard !observations.isEmpty else { return .empty }
        let errors = observations.map { observation in
            let mapped = transform.apply(to: observation.input)
            let dx = mapped.x - observation.output.x
            let dy = mapped.y - observation.output.y
            return (dx * dx + dy * dy).squareRoot()
        }
        let sum = errors.reduce(0, +)
        let squaredSum = errors.reduce(0) { $0 + $1 * $1 }
        return CalibrationQualitySummary(
            sampleCount: observations.count,
            targetCount: observations.count,
            meanError: sum / Double(errors.count),
            rmsError: (squaredSum / Double(errors.count)).squareRoot(),
            maxError: errors.max() ?? 0
        )
    }
}

/// Versioned mapping and metadata for one source/display/setup combination.
public struct CalibrationProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var key: CalibrationProfileKey
    public var baseTransform: AffineTransform2D?
    /// Preferred mapping for new profiles. `baseTransform` remains populated
    /// for affine candidates so version-1 readers and stored profiles continue
    /// to work during migration.
    public var mapping: GazeMapping?
    /// Optional geometry-aware candidate. It is used only when
    /// `selectedModel == .rayPlane3D`; legacy profiles decode with both fields
    /// absent and continue to use `mapping`/`baseTransform`.
    public var rayScreenMapping: RayScreenMapping?
    public var selectedModel: CalibrationModelSelection?
    public var fineAdjustment: FineAdjustment
    public var coordinateSpace: CalibrationCoordinateSpace
    public var quality: CalibrationQualitySummary
    public var createdAt: Date
    public var updatedAt: Date
    public var geometryBaseline: GazeGeometrySample?

    public init(
        version: Int = Self.currentVersion,
        key: CalibrationProfileKey,
        baseTransform: AffineTransform2D? = nil,
        mapping: GazeMapping? = nil,
        rayScreenMapping: RayScreenMapping? = nil,
        selectedModel: CalibrationModelSelection? = nil,
        fineAdjustment: FineAdjustment = .identity,
        coordinateSpace: CalibrationCoordinateSpace = .source,
        quality: CalibrationQualitySummary = .empty,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        geometryBaseline: GazeGeometrySample? = nil
    ) {
        self.version = version
        self.key = key
        self.baseTransform = baseTransform
        self.mapping = mapping
        self.rayScreenMapping = rayScreenMapping
        self.selectedModel = selectedModel
        self.fineAdjustment = fineAdjustment
        self.coordinateSpace = coordinateSpace
        self.quality = quality
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.geometryBaseline = geometryBaseline
    }

    public static func identity(
        key: CalibrationProfileKey,
        coordinateSpace: CalibrationCoordinateSpace = .source,
        at date: Date = Date()
    ) -> CalibrationProfile {
        CalibrationProfile(
            key: key,
            baseTransform: nil,
            coordinateSpace: coordinateSpace,
            createdAt: date,
            updatedAt: date
        )
    }

    /// Applies the base mapping, followed by the center-relative adjustment.
    public func apply(to point: Point2D, center: Point2D = Point2D(x: 0.5, y: 0.5)) -> Point2D {
        let mapped = mapping?.apply(to: point) ?? baseTransform?.apply(to: point) ?? point
        return fineAdjustment.apply(to: mapped, around: center)
    }

    /// Applies the independently selected model to a complete observation.
    /// A ray-plane profile deliberately returns nil when a full ray is absent
    /// or cannot intersect the learned plane; silently falling back to 2D here
    /// would make 3D validation scores dishonest.
    public func apply(
        to point: Point2D,
        gazeRay: GazeRay3D?,
        center: Point2D = Point2D(x: 0.5, y: 0.5)
    ) -> Point2D? {
        let mapped: Point2D
        switch selectedModel ?? .legacy2D {
        case .legacy2D:
            mapped = mapping?.apply(to: point) ?? baseTransform?.apply(to: point) ?? point
        case .rayPlane3D:
            guard let gazeRay,
                  let mappedRay = rayScreenMapping?.apply(to: gazeRay) else { return nil }
            mapped = mappedRay
        }
        return fineAdjustment.apply(to: mapped, around: center)
    }

    public func apply(
        to frame: CanonicalGazeFrame,
        center: Point2D = Point2D(x: 0.5, y: 0.5)
    ) -> Point2D? {
        apply(to: frame.point, gazeRay: frame.gazeRay, center: center)
    }

    public func mappedPoint(from point: Point2D, center: Point2D = Point2D(x: 0.5, y: 0.5)) -> Point2D {
        apply(to: point, center: center)
    }

    /// Validates a profile before it is restored into an active engine. This
    /// is intentionally separate from decoding so persisted data cannot bypass
    /// version, identity, coordinate-space, or numeric checks.
    public func validate(
        expectedKey: CalibrationProfileKey? = nil,
        expectedCoordinateSpace: CalibrationCoordinateSpace? = nil
    ) throws {
        guard version == Self.currentVersion else {
            throw CalibrationProfileValidationError.unsupportedVersion(
                received: version,
                supported: Self.currentVersion
            )
        }
        guard key.isValid else { throw CalibrationProfileValidationError.invalidKey }
        if let expectedKey, key != expectedKey {
            throw CalibrationProfileValidationError.keyMismatch
        }
        if let expectedCoordinateSpace, coordinateSpace != expectedCoordinateSpace {
            throw CalibrationProfileValidationError.coordinateSpaceMismatch(
                expected: expectedCoordinateSpace,
                received: coordinateSpace
            )
        }
        if let baseTransform,
           ![baseTransform.a, baseTransform.b, baseTransform.c,
             baseTransform.d, baseTransform.tx, baseTransform.ty].allSatisfy(\.isFinite) {
            throw CalibrationProfileValidationError.nonFiniteMapping
        }
        if let mapping {
            let probes = [
                Point2D(x: 0, y: 0), Point2D(x: 0.5, y: 0.5), Point2D(x: 1, y: 1),
            ]
            guard probes.allSatisfy({ mapping.apply(to: $0) != nil }) else {
                throw CalibrationProfileValidationError.nonFiniteMapping
            }
        }
        if let rayScreenMapping, !rayScreenMapping.isValid {
            throw CalibrationProfileValidationError.nonFiniteMapping
        }
        if selectedModel == .rayPlane3D, rayScreenMapping == nil {
            throw CalibrationProfileValidationError.nonFiniteMapping
        }
        if let geometryBaseline, !geometryBaseline.isFinite {
            throw CalibrationProfileValidationError.nonFiniteMapping
        }
        guard fineAdjustment.isValid else {
            throw CalibrationProfileValidationError.invalidFineAdjustment
        }
        guard quality.isValid else {
            throw CalibrationProfileValidationError.invalidQuality
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CalibrationProfileValidationError.invalidDate
        }
    }

    /// Naming aliases make persistence adapters explicit without duplicating
    /// the affine transform model.
    public var baseMapping: AffineTransform2D? {
        get { baseTransform }
        set { baseTransform = newValue }
    }

    public var sourceCoordinateSpace: CalibrationCoordinateSpace {
        get { coordinateSpace }
        set { coordinateSpace = newValue }
    }

    public var qualitySummary: CalibrationQualitySummary {
        get { quality }
        set { quality = newValue }
    }

    public var sourceID: GazeSourceID { key.sourceID }
    public var displayID: String { key.displayID }
    public var setupID: String { key.setupID }
}

public typealias CalibrationAdjustment = FineAdjustment
public typealias CalibrationFineAdjustment = FineAdjustment
public typealias CalibrationQuality = CalibrationQualitySummary
public typealias CalibrationProfileIdentity = CalibrationProfileKey
