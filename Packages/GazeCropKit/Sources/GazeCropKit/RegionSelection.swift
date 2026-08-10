import CoreGraphics
import Foundation

public enum SemanticRegionRole: String, Codable, CaseIterable, Sendable {
    case text
    case control
    case controlGroup
    case image
    case chart
    case tableCell
    case tableRow
    case table
    case dialog
    case panel
    case window
    case unknown
}

public enum RegionResolutionSource: String, Codable, Sendable {
    case explicitApplicationRegion
    case accessibility
    case segmentation
    case fixedContextFallback
    case userAdjusted
}

public enum RegionRelationship: String, Codable, Hashable, Sendable {
    case title
    case header
    case label
    case linkedElement
}

public struct RegionCandidate: Equatable, Sendable {
    public let id: String
    public let globalBounds: CGRect
    public let role: SemanticRegionRole
    public let source: RegionResolutionSource
    public let confidence: Double
    public let hierarchyDepth: Int
    public let includedRelationships: Set<RegionRelationship>

    public init(
        id: String,
        globalBounds: CGRect,
        role: SemanticRegionRole,
        source: RegionResolutionSource,
        confidence: Double,
        hierarchyDepth: Int,
        includedRelationships: Set<RegionRelationship> = []
    ) {
        self.id = id
        self.globalBounds = globalBounds
        self.role = role
        self.source = source
        self.confidence = confidence
        self.hierarchyDepth = hierarchyDepth
        self.includedRelationships = includedRelationships
    }
}

public struct RegionSelectionPolicy: Equatable, Sendable {
    public var minimumWidth: CGFloat
    public var minimumHeight: CGFloat
    public var maximumDisplayAreaRatio: CGFloat
    public var minimumUncertaintyCoverage: CGFloat
    public var paddingRatio: CGFloat

    public init(
        minimumWidth: CGFloat = 120,
        minimumHeight: CGFloat = 80,
        maximumDisplayAreaRatio: CGFloat = 0.60,
        minimumUncertaintyCoverage: CGFloat = 0.80,
        paddingRatio: CGFloat = 0.06
    ) {
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.maximumDisplayAreaRatio = maximumDisplayAreaRatio
        self.minimumUncertaintyCoverage = minimumUncertaintyCoverage
        self.paddingRatio = paddingRatio
    }
}

public struct RegionSelection: Equatable, Sendable {
    public let selected: RegionCandidate
    public let cropGlobalBounds: CGRect
    public let tighterCandidateID: String?
    public let widerCandidateID: String?

    public init(
        selected: RegionCandidate,
        cropGlobalBounds: CGRect,
        tighterCandidateID: String?,
        widerCandidateID: String?
    ) {
        self.selected = selected
        self.cropGlobalBounds = cropGlobalBounds
        self.tighterCandidateID = tighterCandidateID
        self.widerCandidateID = widerCandidateID
    }
}

/// Selects the smallest candidate that contains enough gaze uncertainty and
/// meets explicit completeness bounds. Source-specific resolvers remain free
/// to produce candidates; this policy owns the provider-neutral decision.
public struct RegionSelector: Sendable {
    public let policy: RegionSelectionPolicy

    public init(policy: RegionSelectionPolicy = .init()) {
        self.policy = policy
    }

    public func select(
        candidates: [RegionCandidate],
        gazeGlobalPoint: CGPoint,
        uncertaintySize: CGSize,
        displayBounds: CGRect
    ) -> RegionSelection? {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let uncertainty = CGRect(
            x: gazeGlobalPoint.x - uncertaintySize.width,
            y: gazeGlobalPoint.y - uncertaintySize.height,
            width: uncertaintySize.width * 2,
            height: uncertaintySize.height * 2
        )
        let displayArea = displayBounds.width * displayBounds.height

        let eligible = candidates.filter { candidate in
            let bounds = candidate.globalBounds.standardized.intersection(displayBounds)
            guard !bounds.isNull,
                  bounds.contains(gazeGlobalPoint),
                  bounds.width >= policy.minimumWidth,
                  bounds.height >= policy.minimumHeight,
                  bounds.width * bounds.height <= displayArea * policy.maximumDisplayAreaRatio
            else { return false }

            let uncertaintyArea = max(uncertainty.width * uncertainty.height, 1)
            let overlap = bounds.intersection(uncertainty)
            let coverage = overlap.isNull ? 0 : overlap.width * overlap.height / uncertaintyArea
            return coverage >= policy.minimumUncertaintyCoverage
        }.sorted { lhs, rhs in
            let lhsArea = lhs.globalBounds.width * lhs.globalBounds.height
            let rhsArea = rhs.globalBounds.width * rhs.globalBounds.height
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.hierarchyDepth < rhs.hierarchyDepth
        }

        guard let chosen = eligible.first,
              let index = candidates.firstIndex(where: { $0.id == chosen.id })
        else { return nil }

        let crop = chosen.globalBounds.expanded(by: policy.paddingRatio, clippedTo: displayBounds)
        return RegionSelection(
            selected: chosen,
            cropGlobalBounds: crop,
            tighterCandidateID: index > candidates.startIndex ? candidates[index - 1].id : nil,
            widerCandidateID: candidates.index(after: index) < candidates.endIndex ? candidates[index + 1].id : nil
        )
    }
}

public protocol SegmentationRegionResolving: Sendable {
    func candidates(
        image: CGImage,
        positiveImagePoints: [CGPoint],
        uncertaintyImageBounds: CGRect
    ) async throws -> [RegionCandidate]
}

public struct FixedContextFallbackResolver: Sendable {
    public var preferredDisplayWidthRatio: CGFloat
    public var minimumSize: CGSize

    public init(
        preferredDisplayWidthRatio: CGFloat = 0.50,
        minimumSize: CGSize = CGSize(width: 480, height: 320)
    ) {
        self.preferredDisplayWidthRatio = preferredDisplayWidthRatio
        self.minimumSize = minimumSize
    }

    public func candidate(at gazeGlobalPoint: CGPoint, displayBounds: CGRect) -> RegionCandidate {
        let width = min(
            displayBounds.width,
            max(minimumSize.width, displayBounds.width * preferredDisplayWidthRatio)
        )
        let height = min(
            displayBounds.height,
            max(minimumSize.height, width / 1.5)
        )
        let origin = CGPoint(
            x: min(max(gazeGlobalPoint.x - width / 2, displayBounds.minX), displayBounds.maxX - width),
            y: min(max(gazeGlobalPoint.y - height / 2, displayBounds.minY), displayBounds.maxY - height)
        )
        return RegionCandidate(
            id: "fixed-context-fallback",
            globalBounds: CGRect(origin: origin, size: CGSize(width: width, height: height)).integral,
            role: .unknown,
            source: .fixedContextFallback,
            confidence: 0.35,
            hierarchyDepth: 0
        )
    }
}
