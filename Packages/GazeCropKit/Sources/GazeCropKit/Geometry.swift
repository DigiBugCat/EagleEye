import CoreGraphics
import Foundation

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var clamped: Self {
        Self(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

public struct NormalizedRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect, relativeTo container: CGRect) {
        guard container.width > 0, container.height > 0 else {
            self.init(x: 0, y: 0, width: 0, height: 0)
            return
        }
        self.init(
            x: (rect.minX - container.minX) / container.width,
            y: (rect.minY - container.minY) / container.height,
            width: rect.width / container.width,
            height: rect.height / container.height
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Converts between EagleGaze's normalized top-left display coordinates,
/// Core Graphics global display coordinates, and captured-image pixels.
public struct CaptureGeometry: Equatable, Sendable {
    public let displayGlobalBounds: CGRect
    public let imagePixelSize: CGSize

    public init(displayGlobalBounds: CGRect, imagePixelSize: CGSize) {
        self.displayGlobalBounds = displayGlobalBounds
        self.imagePixelSize = imagePixelSize
    }

    public func normalizedToGlobal(_ point: NormalizedPoint) -> CGPoint {
        let point = point.clamped
        return CGPoint(
            x: displayGlobalBounds.minX + point.x * displayGlobalBounds.width,
            y: displayGlobalBounds.minY + point.y * displayGlobalBounds.height
        )
    }

    public func globalToImage(_ point: CGPoint) -> CGPoint {
        guard displayGlobalBounds.width > 0, displayGlobalBounds.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: (point.x - displayGlobalBounds.minX) * imagePixelSize.width / displayGlobalBounds.width,
            y: (point.y - displayGlobalBounds.minY) * imagePixelSize.height / displayGlobalBounds.height
        )
    }

    public func globalRectToImage(_ rect: CGRect) -> CGRect {
        let clipped = rect.standardized.intersection(displayGlobalBounds)
        guard !clipped.isNull else { return .null }
        let origin = globalToImage(clipped.origin)
        let maximum = globalToImage(CGPoint(x: clipped.maxX, y: clipped.maxY))
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: maximum.x - origin.x,
            height: maximum.y - origin.y
        ).integral
    }
}

public extension CGRect {
    func expanded(by ratio: CGFloat, clippedTo limit: CGRect) -> CGRect {
        let horizontal = width * max(ratio, 0)
        let vertical = height * max(ratio, 0)
        return insetBy(dx: -horizontal, dy: -vertical).intersection(limit).integral
    }
}
