import CoreGraphics
import Foundation

public struct CropPlan: Equatable, Sendable {
    public let sourceImageRect: CGRect
    public let gazeInCrop: CGPoint
    public let focusRectInCrop: CGRect

    public init(sourceImageRect: CGRect, gazeInCrop: CGPoint, focusRectInCrop: CGRect) {
        self.sourceImageRect = sourceImageRect
        self.gazeInCrop = gazeInCrop
        self.focusRectInCrop = focusRectInCrop
    }

    public static func make(
        geometry: CaptureGeometry,
        selection: RegionSelection,
        gazeGlobalPoint: CGPoint,
        uncertaintyGlobalBounds: CGRect
    ) -> Self? {
        let sourceRect = geometry.globalRectToImage(selection.cropGlobalBounds)
        guard !sourceRect.isNull, sourceRect.width > 0, sourceRect.height > 0 else { return nil }
        let gazeInImage = geometry.globalToImage(gazeGlobalPoint)
        let focusInImage = geometry.globalRectToImage(uncertaintyGlobalBounds)
        return Self(
            sourceImageRect: sourceRect,
            gazeInCrop: CGPoint(x: gazeInImage.x - sourceRect.minX, y: gazeInImage.y - sourceRect.minY),
            focusRectInCrop: focusInImage.offsetBy(dx: -sourceRect.minX, dy: -sourceRect.minY)
        )
    }
}

public enum CropRenderingError: Error, Equatable, Sendable {
    case invalidSourceRect
    case contextCropFailed
    case focusCropFailed
    case resizeFailed
}

public struct RenderedCropImages {
    public let context: CGImage
    public let enlargedFocus: CGImage?

    public init(context: CGImage, enlargedFocus: CGImage?) {
        self.context = context
        self.enlargedFocus = enlargedFocus
    }
}

/// Renders the exact context crop and, when useful, a magnified focus image.
/// Encoding and approval remain caller-owned so the application can preview
/// the exact outgoing bytes rather than a cleaner pre-encoding image.
public struct ImageCropRenderer: Sendable {
    public init() {}

    public func render(
        source: CGImage,
        plan: CropPlan,
        includeEnlargedFocus: Bool = true,
        focusPaddingRatio: CGFloat = 0.35,
        focusScale: CGFloat = 2
    ) throws -> RenderedCropImages {
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let sourceRect = plan.sourceImageRect.standardized.intersection(imageBounds).integral
        guard !sourceRect.isNull, sourceRect.width > 0, sourceRect.height > 0 else {
            throw CropRenderingError.invalidSourceRect
        }
        guard let context = source.cropping(to: sourceRect) else {
            throw CropRenderingError.contextCropFailed
        }
        guard includeEnlargedFocus else {
            return RenderedCropImages(context: context, enlargedFocus: nil)
        }

        let contextBounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        let focusInContext = plan.focusRectInCrop
            .standardized
            .expanded(by: focusPaddingRatio, clippedTo: contextBounds)
        guard !focusInContext.isNull, focusInContext.width > 0, focusInContext.height > 0,
              let focus = context.cropping(to: focusInContext)
        else { throw CropRenderingError.focusCropFailed }
        guard focusScale > 1 else {
            return RenderedCropImages(context: context, enlargedFocus: focus)
        }
        return RenderedCropImages(
            context: context,
            enlargedFocus: try resize(focus, scale: focusScale)
        )
    }

    private func resize(_ image: CGImage, scale: CGFloat) throws -> CGImage {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CropRenderingError.resizeFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw CropRenderingError.resizeFailed }
        return result
    }
}

public struct GazeCropEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let image: ImageDescriptor
    public let attention: AttentionDescriptor
    public let region: RegionDescriptor
    public let visibility: VisibilityDescriptor
    public let includedContext: IncludedContextDescriptor

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        image: ImageDescriptor,
        attention: AttentionDescriptor,
        region: RegionDescriptor,
        visibility: VisibilityDescriptor,
        includedContext: IncludedContextDescriptor
    ) {
        self.schemaVersion = schemaVersion
        self.image = image
        self.attention = attention
        self.region = region
        self.visibility = visibility
        self.includedContext = includedContext
    }
}

public struct ImageDescriptor: Codable, Equatable, Sendable {
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let sha256: String?
    public let coordinateSpace: String

    public init(mimeType: String, width: Int, height: Int, sha256: String? = nil) {
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.coordinateSpace = "returned_image_top_left"
    }
}

public struct AttentionDescriptor: Codable, Equatable, Sendable {
    public let point: NormalizedPoint
    public let uncertainty: NormalizedRect
    public let confidence: Double
    public let sampleCount: Int
    public let fixationDurationMilliseconds: Int

    public init(
        point: NormalizedPoint,
        uncertainty: NormalizedRect,
        confidence: Double,
        sampleCount: Int,
        fixationDurationMilliseconds: Int
    ) {
        self.point = point
        self.uncertainty = uncertainty
        self.confidence = confidence
        self.sampleCount = sampleCount
        self.fixationDurationMilliseconds = fixationDurationMilliseconds
    }
}

public struct RegionDescriptor: Codable, Equatable, Sendable {
    public let kind: SemanticRegionRole
    public let resolvedBy: RegionResolutionSource
    public let confidence: Double
    public let fallbackUsed: Bool
    public let userAdjusted: Bool

    public init(
        kind: SemanticRegionRole,
        resolvedBy: RegionResolutionSource,
        confidence: Double,
        fallbackUsed: Bool,
        userAdjusted: Bool
    ) {
        self.kind = kind
        self.resolvedBy = resolvedBy
        self.confidence = confidence
        self.fallbackUsed = fallbackUsed
        self.userAdjusted = userAdjusted
    }
}

public struct VisibilityDescriptor: Codable, Equatable, Sendable {
    public let topmostAtGaze: Bool
    public let focusedWindow: Bool?
    public let partiallyClipped: Bool
    public let occlusionConfidence: Double?

    public init(
        topmostAtGaze: Bool,
        focusedWindow: Bool?,
        partiallyClipped: Bool,
        occlusionConfidence: Double?
    ) {
        self.topmostAtGaze = topmostAtGaze
        self.focusedWindow = focusedWindow
        self.partiallyClipped = partiallyClipped
        self.occlusionConfidence = occlusionConfidence
    }
}

public struct IncludedContextDescriptor: Codable, Equatable, Sendable {
    public let relationships: Set<RegionRelationship>
    public let paddingPercent: Double

    public init(relationships: Set<RegionRelationship>, paddingPercent: Double) {
        self.relationships = relationships
        self.paddingPercent = paddingPercent
    }
}
