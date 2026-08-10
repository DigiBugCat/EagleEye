import CoreGraphics
import Foundation
import Testing
@testable import GazeCropKit

@Test func geometryHandlesNegativeDisplayOriginsAndDownscaling() {
    let geometry = CaptureGeometry(
        displayGlobalBounds: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        imagePixelSize: CGSize(width: 960, height: 540)
    )

    let global = geometry.normalizedToGlobal(NormalizedPoint(x: 0.25, y: 0.5))
    #expect(global == CGPoint(x: -1_440, y: 540))
    #expect(geometry.globalToImage(global) == CGPoint(x: 240, y: 270))

    let imageRect = geometry.globalRectToImage(
        CGRect(x: -1_800, y: 100, width: 400, height: 200)
    )
    #expect(imageRect == CGRect(x: 60, y: 50, width: 200, height: 100))
}

@Test func attentionEstimatorResistsOneLargeOutlier() throws {
    var estimator = try AttentionEstimator(windowDuration: 0.55)
    let points = [
        NormalizedPoint(x: 0.49, y: 0.50),
        NormalizedPoint(x: 0.50, y: 0.49),
        NormalizedPoint(x: 0.51, y: 0.50),
        NormalizedPoint(x: 0.50, y: 0.51),
        NormalizedPoint(x: 0.49, y: 0.50),
        NormalizedPoint(x: 0.50, y: 0.50),
        NormalizedPoint(x: 0.51, y: 0.49),
        NormalizedPoint(x: 0.90, y: 0.10),
    ]
    for (index, point) in points.enumerated() {
        try estimator.append(
            TimedGazePoint(point: point, confidence: 0.92, captureUptime: Double(index) * 0.03)
        )
    }

    let estimated = try estimator.snapshot(
        at: 0.22,
        calibrationError: NormalizedPoint(x: 0.01, y: 0.015)
    )
    let snapshot = try #require(estimated)
    #expect(abs(snapshot.center.x - 0.50) < 0.001)
    #expect(abs(snapshot.center.y - 0.50) < 0.001)
    #expect(snapshot.radiusX >= 0.01)
    #expect(snapshot.radiusY >= 0.015)
    #expect(snapshot.sampleCount == 8)
    #expect(snapshot.isEligible())
}

@Test func attentionEstimatorRejectsStaleEvidence() throws {
    var estimator = try AttentionEstimator(windowDuration: 0.55)
    for index in 0..<8 {
        try estimator.append(
            TimedGazePoint(
                point: NormalizedPoint(x: 0.5, y: 0.5),
                confidence: 0.9,
                captureUptime: Double(index) * 0.03
            )
        )
    }
    let estimated = try estimator.snapshot(at: 0.50)
    let snapshot = try #require(estimated)
    #expect(snapshot.newestSampleAge > 0.20)
    #expect(!snapshot.isEligible())
}

@Test func regionSelectorChoosesSmallestCompleteAncestor() throws {
    let display = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let candidates = [
        RegionCandidate(
            id: "text",
            globalBounds: CGRect(x: 280, y: 290, width: 90, height: 24),
            role: .text,
            source: .accessibility,
            confidence: 0.9,
            hierarchyDepth: 0
        ),
        RegionCandidate(
            id: "card",
            globalBounds: CGRect(x: 220, y: 220, width: 360, height: 240),
            role: .panel,
            source: .accessibility,
            confidence: 0.85,
            hierarchyDepth: 1,
            includedRelationships: [.title]
        ),
        RegionCandidate(
            id: "window",
            globalBounds: CGRect(x: 0, y: 0, width: 1_100, height: 760),
            role: .window,
            source: .accessibility,
            confidence: 0.8,
            hierarchyDepth: 2
        ),
    ]

    let selection = try #require(
        RegionSelector().select(
            candidates: candidates,
            gazeGlobalPoint: CGPoint(x: 320, y: 302),
            uncertaintySize: CGSize(width: 30, height: 20),
            displayBounds: display
        )
    )
    #expect(selection.selected.id == "card")
    #expect(selection.tighterCandidateID == "text")
    #expect(selection.widerCandidateID == "window")
    #expect(selection.cropGlobalBounds.contains(selection.selected.globalBounds))
}

@Test func cropPlanKeepsCoordinatesRelativeToReturnedImage() throws {
    let geometry = CaptureGeometry(
        displayGlobalBounds: CGRect(x: 0, y: 0, width: 1_200, height: 800),
        imagePixelSize: CGSize(width: 600, height: 400)
    )
    let candidate = RegionCandidate(
        id: "panel",
        globalBounds: CGRect(x: 200, y: 200, width: 400, height: 240),
        role: .panel,
        source: .accessibility,
        confidence: 0.9,
        hierarchyDepth: 1
    )
    let selection = RegionSelection(
        selected: candidate,
        cropGlobalBounds: candidate.globalBounds,
        tighterCandidateID: nil,
        widerCandidateID: nil
    )
    let plan = try #require(
        CropPlan.make(
            geometry: geometry,
            selection: selection,
            gazeGlobalPoint: CGPoint(x: 300, y: 300),
            uncertaintyGlobalBounds: CGRect(x: 280, y: 285, width: 40, height: 30)
        )
    )
    #expect(plan.sourceImageRect == CGRect(x: 100, y: 100, width: 200, height: 120))
    #expect(plan.gazeInCrop == CGPoint(x: 50, y: 50))
    #expect(plan.focusRectInCrop == CGRect(x: 40, y: 42, width: 20, height: 16))
}

@Test func cropRendererProducesContextAndEnlargedFocusImages() throws {
    let drawing = try #require(
        CGContext(
            data: nil,
            width: 400,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    drawing.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
    drawing.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    let source = try #require(drawing.makeImage())
    let plan = CropPlan(
        sourceImageRect: CGRect(x: 80, y: 60, width: 200, height: 120),
        gazeInCrop: CGPoint(x: 60, y: 50),
        focusRectInCrop: CGRect(x: 40, y: 40, width: 40, height: 20)
    )

    let rendered = try ImageCropRenderer().render(
        source: source,
        plan: plan,
        focusPaddingRatio: 0,
        focusScale: 2
    )
    #expect(rendered.context.width == 200)
    #expect(rendered.context.height == 120)
    #expect(rendered.enlargedFocus?.width == 80)
    #expect(rendered.enlargedFocus?.height == 40)
}

@Test func fixedFallbackClampsToDisplayEdges() {
    let display = CGRect(x: -1_200, y: 0, width: 1_200, height: 800)
    let candidate = FixedContextFallbackResolver().candidate(
        at: CGPoint(x: -1_195, y: 10),
        displayBounds: display
    )
    #expect(candidate.source == .fixedContextFallback)
    #expect(display.contains(candidate.globalBounds))
    #expect(candidate.globalBounds.minX == display.minX)
    #expect(candidate.globalBounds.minY == display.minY)
}

@Test func cerebrasDecoderRemovesControlCharactersAndKeepsUsage() throws {
    let modelContent: [String: Any] = [
        "content_type": "ui_settings_panel",
        "region_summary": "Connection setup",
        "focused_subject": "Tobii option",
        "focused_text": "Unavailable\u{11} adapter not installed",
        "context_sufficient": true,
        "labels": ["settings", "gaze_tracking"],
        "confidence": 1.2,
        "warnings": [],
    ]
    let response: [String: Any] = [
        "choices": [["message": [
            "content": String(data: try JSONSerialization.data(withJSONObject: modelContent), encoding: .utf8)!,
        ]]],
        "usage": [
            "prompt_tokens": 100,
            "completion_tokens": 20,
            "total_tokens": 120,
            "prompt_tokens_details": ["image_tokens": 64],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: response)
    let result = try CerebrasVisionEnricher().decodeResponse(data)

    #expect(result.enrichment.focusedText == "Unavailable adapter not installed")
    #expect(result.enrichment.providerConfidence == 1)
    #expect(result.usage?.imageTokens == 64)
}

@Test func cerebrasDecoderBoundsEveryWireVisibleField() throws {
    let modelContent: [String: Any] = [
        "content_type": String(repeating: "c", count: 600),
        "region_summary": String(repeating: "s", count: 4_100),
        "focused_subject": String(repeating: "u", count: 2_100),
        "focused_text": String(repeating: "😀", count: 2_100),
        "context_sufficient": true,
        "labels": (0..<60).map { "label-\($0)-" + String(repeating: "l", count: 250) },
        "confidence": 0.5,
        "warnings": (0..<30).map { "warning-\($0)-" + String(repeating: "w", count: 550) },
    ]
    let response: [String: Any] = [
        "choices": [["message": [
            "content": String(data: try JSONSerialization.data(withJSONObject: modelContent), encoding: .utf8)!,
        ]]],
    ]
    let result = try CerebrasVisionEnricher().decodeResponse(
        JSONSerialization.data(withJSONObject: response)
    ).enrichment

    #expect(result.contentType.utf16.count == 500)
    #expect(result.regionSummary.utf16.count == 4_000)
    #expect(result.focusedSubject.utf16.count == 2_000)
    #expect(result.focusedText.utf16.count == 4_000)
    #expect(result.labels.count == 50)
    #expect(result.labels.allSatisfy { $0.utf16.count <= 200 })
    #expect(result.warnings.count == 20)
    #expect(result.warnings.allSatisfy { $0.utf16.count <= 500 })
}

@Test func envelopeContainsOnlyImageRelativeCoordinates() throws {
    let envelope = GazeCropEnvelope(
        image: ImageDescriptor(mimeType: "image/png", width: 568, height: 243),
        attention: AttentionDescriptor(
            point: NormalizedPoint(x: 0.1444, y: 0.4938),
            uncertainty: NormalizedRect(x: 0.10, y: 0.45, width: 0.08, height: 0.09),
            confidence: 0.88,
            sampleCount: 14,
            fixationDurationMilliseconds: 380
        ),
        region: RegionDescriptor(
            kind: .panel,
            resolvedBy: .accessibility,
            confidence: 0.91,
            fallbackUsed: false,
            userAdjusted: false
        ),
        visibility: VisibilityDescriptor(
            topmostAtGaze: true,
            focusedWindow: true,
            partiallyClipped: false,
            occlusionConfidence: nil
        ),
        includedContext: IncludedContextDescriptor(
            relationships: [.title, .label],
            paddingPercent: 6
        )
    )
    let json = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!
    #expect(!json.contains("displayID"))
    #expect(!json.contains("global"))
    #expect(!json.contains("windowTitle"))
}
