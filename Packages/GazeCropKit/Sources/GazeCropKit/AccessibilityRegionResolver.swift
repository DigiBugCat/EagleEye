@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public enum AccessibilityRegionError: Error, Equatable, Sendable {
    case permissionRequired
    case noElementAtPosition
    case hitTestFailed(Int32)
}

public struct AccessibilityRegionConfiguration: Equatable, Sendable {
    public var maximumAncestorDepth: Int
    public var maximumRelationshipQueriesPerCandidate: Int
    public var maximumRelationshipAreaMultiplier: CGFloat

    public init(
        maximumAncestorDepth: Int = 8,
        maximumRelationshipQueriesPerCandidate: Int = 4,
        maximumRelationshipAreaMultiplier: CGFloat = 1.75
    ) {
        self.maximumAncestorDepth = maximumAncestorDepth
        self.maximumRelationshipQueriesPerCandidate = maximumRelationshipQueriesPerCandidate
        self.maximumRelationshipAreaMultiplier = maximumRelationshipAreaMultiplier
    }
}

/// A geometry-only, read-only Accessibility resolver.
///
/// It reads role, position, size, parent, and a small allowlist of semantic
/// relationships. It deliberately never reads values, text, URLs, paths,
/// application names, window titles, identifiers, or supported actions.
public struct AccessibilityRegionResolver: Sendable {
    public let configuration: AccessibilityRegionConfiguration

    public init(configuration: AccessibilityRegionConfiguration = .init()) {
        self.configuration = configuration
    }

    public static var isProcessTrusted: Bool { AXIsProcessTrusted() }

    /// Requests the standard macOS Accessibility prompt. The return value is
    /// the current trust state; the prompt itself is asynchronous.
    @discardableResult
    public static func requestTrustPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func candidates(
        at globalPoint: CGPoint,
        displayBounds: CGRect
    ) throws -> [RegionCandidate] {
        guard Self.isProcessTrusted else { throw AccessibilityRegionError.permissionRequired }

        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(globalPoint.x),
            Float(globalPoint.y),
            &hit
        )
        guard error == .success else {
            if error == .noValue { throw AccessibilityRegionError.noElementAtPosition }
            throw AccessibilityRegionError.hitTestFailed(error.rawValue)
        }
        guard var current = hit else { throw AccessibilityRegionError.noElementAtPosition }

        var results: [RegionCandidate] = []
        var seenBounds = Set<CGRectKey>()
        let maximumDepth = max(configuration.maximumAncestorDepth, 1)

        for depth in 0..<maximumDepth {
            guard let baseBounds = bounds(of: current),
                  !baseBounds.isEmpty,
                  !baseBounds.isInfinite,
                  baseBounds.intersects(displayBounds)
            else {
                guard let parent = elementAttribute(current, kAXParentAttribute as CFString) else { break }
                current = parent
                continue
            }

            let role = semanticRole(rawRole(of: current))
            let enriched = enrichedBounds(
                for: current,
                base: baseBounds,
                displayBounds: displayBounds
            )
            let key = CGRectKey(enriched.bounds)
            if seenBounds.insert(key).inserted {
                results.append(
                    RegionCandidate(
                        id: "accessibility-\(depth)-\(key.x)-\(key.y)-\(key.width)-\(key.height)",
                        globalBounds: enriched.bounds,
                        role: role,
                        source: .accessibility,
                        confidence: role == .unknown ? 0.55 : 0.85,
                        hierarchyDepth: depth,
                        includedRelationships: enriched.relationships
                    )
                )
            }

            guard let parent = elementAttribute(current, kAXParentAttribute as CFString) else { break }
            current = parent
        }
        return results
    }

    private func enrichedBounds(
        for element: AXUIElement,
        base: CGRect,
        displayBounds: CGRect
    ) -> (bounds: CGRect, relationships: Set<RegionRelationship>) {
        let attributes: [(CFString, RegionRelationship)] = [
            (kAXTitleUIElementAttribute as CFString, .title),
            (kAXHeaderAttribute as CFString, .header),
            (kAXLabelUIElementsAttribute as CFString, .label),
            (kAXLinkedUIElementsAttribute as CFString, .linkedElement),
        ]
        var result = base.intersection(displayBounds)
        var relationships = Set<RegionRelationship>()
        let queryLimit = max(configuration.maximumRelationshipQueriesPerCandidate, 0)

        for (attribute, relationship) in attributes.prefix(queryLimit) {
            for related in elementsAttribute(element, attribute) {
                guard let relatedBounds = bounds(of: related), relatedBounds.intersects(displayBounds) else { continue }
                let proposed = result.union(relatedBounds.intersection(displayBounds))
                let baseArea = max(base.width * base.height, 1)
                guard proposed.width * proposed.height
                        <= baseArea * configuration.maximumRelationshipAreaMultiplier
                else { continue }
                result = proposed
                relationships.insert(relationship)
            }
        }
        return (result.integral, relationships)
    }

    private func bounds(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
              let sizeValue = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              point.x.isFinite,
              point.y.isFinite,
              size.width.isFinite,
              size.height.isFinite
        else { return nil }
        return CGRect(origin: point, size: size).standardized
    }

    private func rawRole(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as CFString) as? String
    }

    private func semanticRole(_ raw: String?) -> SemanticRegionRole {
        switch raw {
        case "AXStaticText", "AXTextField", "AXTextArea": .text
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider": .control
        case "AXGroup", "AXToolbar": .controlGroup
        case "AXImage": .image
        case "AXCell": .tableCell
        case "AXRow": .tableRow
        case "AXTable", "AXOutline": .table
        case "AXDialog", "AXSheet": .dialog
        case "AXScrollArea", "AXSplitGroup": .panel
        case "AXWindow": .window
        default: .unknown
        }
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func elementsAttribute(_ element: AXUIElement, _ name: CFString) -> [AXUIElement] {
        guard let value = attribute(element, name) else { return [] }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }
        guard CFGetTypeID(value) == CFArrayGetTypeID(), let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }
}

private struct CGRectKey: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ rect: CGRect) {
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }
}
