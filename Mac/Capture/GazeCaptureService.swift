import AppKit
import CoreGraphics
import Foundation
import GazeCore
import GazeCropKit
// Xcode 16's ScreenCaptureKit overlay does not annotate SCShareableContent as
// Sendable even though the async API returns it across the actor boundary.
// Newer SDKs carry the correct concurrency metadata; this keeps the macOS 14
// deployment target buildable with both toolchain generations.
@preconcurrency import ScreenCaptureKit

enum GazeCaptureMarker: String, Codable, Sendable {
    case circle
    case square
}

struct GazeCaptureArtifact: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let gazeX: Int
    let gazeY: Int
    let normalizedX: Double
    let normalizedY: Double
    let uncertaintyRadius: Int
    let attention: GazeCaptureAttentionMetadata
    let marker: GazeCaptureMarker
    let capturedAt: Date
    let region: GazeCaptureRegionMetadata
    let enrichment: VisionEnrichment?
    let enrichmentWarning: String?
}

struct GazeCaptureAttentionMetadata: Sendable {
    let estimator: String
    let confidence: Double?
    let sampleCount: Int?
    let fixationDurationMilliseconds: Int?
    let newestSampleAgeMilliseconds: Int?
    let uncertaintyRadiusX: Int
    let uncertaintyRadiusY: Int
}

struct GazeCaptureRegionMetadata: Sendable {
    let kind: SemanticRegionRole
    let resolvedBy: RegionResolutionSource
    let confidence: Double
    let fallbackUsed: Bool
    let topmostAtGaze: Bool?
    let userAdjusted: Bool
    let partiallyClipped: Bool
    let paddingPercent: Double?
    let includedRelationships: [String]
}

enum GazeCaptureError: LocalizedError, Equatable {
    case captureBusy
    case gazeStale
    case notCalibrated
    case displayUnavailable
    case permissionRequired
    case approvalRejected
    case captureFailed
    case encodingFailed
    case responseTooLarge
    case requestCancelled

    var errorDescription: String? {
        switch self {
        case .captureBusy: "Another gaze capture is awaiting approval."
        case .gazeStale: "A fresh stabilized gaze position is required."
        case .notCalibrated: "Complete calibration before capturing gaze."
        case .displayUnavailable: "The calibrated display is no longer available."
        case .permissionRequired: "Enable Screen Recording for EagleEye in System Settings."
        case .approvalRejected: "The capture was not approved in EagleEye."
        case .captureFailed: "EagleEye could not capture the selected display."
        case .encodingFailed: "EagleEye could not encode the annotated capture."
        case .responseTooLarge: "The annotated capture exceeded the 4 MiB response limit."
        case .requestCancelled: "The requesting connection closed before capture approval."
        }
    }
}

struct GazeCaptureLayout: Equatable {
    let cropRect: CGRect
    let gazeInCrop: CGPoint

    static func make(sourceSize: CGSize, normalizedGaze: Point2D) -> Self {
        let gaze = CGPoint(
            x: min(max(normalizedGaze.x, 0), 1) * sourceSize.width,
            y: min(max(normalizedGaze.y, 0), 1) * sourceSize.height
        )
        let cropWidth = min(sourceSize.width, 1_600)
        let cropHeight = min(sourceSize.height, cropWidth / 1.5)
        let origin = CGPoint(
            x: min(max(gaze.x - cropWidth * 0.5, 0), sourceSize.width - cropWidth),
            y: min(max(gaze.y - cropHeight * 0.5, 0), sourceSize.height - cropHeight)
        )
        let crop = CGRect(origin: origin, size: CGSize(width: cropWidth, height: cropHeight)).integral
        // Coordinates identify pixels, so the largest valid value is one less
        // than the image dimension even when the calibrated point reaches 1.0.
        let local = CGPoint(
            x: min(max(gaze.x - crop.minX, 0), max(crop.width - 1, 0)),
            y: min(max(gaze.y - crop.minY, 0), max(crop.height - 1, 0))
        )
        return Self(cropRect: crop, gazeInCrop: local)
    }
}

@MainActor
protocol GazeCaptureServicing: AnyObject {
    func requestScreenCapturePermission() -> Bool

    func capture(
        display: DisplayDescriptor,
        normalizedGaze: Point2D,
        attention: AttentionSnapshot?,
        marker: GazeCaptureMarker,
        options: GazeCaptureOptions,
        cancellation: any GazeCaptureCancellationChecking
    ) async throws -> GazeCaptureArtifact
}

protocol GazeCaptureCancellationChecking: Sendable {
    var isCancelled: Bool { get }
}

struct NeverCancelledGazeCapture: GazeCaptureCancellationChecking {
    let isCancelled = false
}

/// One-shot, in-memory screen capture. Eagle-owned UI must approve the exact
/// annotated pixels before they can cross the loopback bridge.
@MainActor
final class GazeCaptureService: GazeCaptureServicing {
    static let maximumBodyBytes = 4 * 1_024 * 1_024
    private static let maximumEdge = 2_048
    private var isCapturing = false
    private let accessibilityResolver = AccessibilityRegionResolver()
    private let regionSelector = RegionSelector()
    private let fallbackResolver = FixedContextFallbackResolver()
    private let cropRenderer = ImageCropRenderer()
    private let cerebrasEnricher = CerebrasVisionEnricher()

    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func capture(
        display: DisplayDescriptor,
        normalizedGaze: Point2D,
        attention: AttentionSnapshot?,
        marker: GazeCaptureMarker,
        options: GazeCaptureOptions,
        cancellation: any GazeCaptureCancellationChecking
    ) async throws -> GazeCaptureArtifact {
        guard !isCapturing else { throw GazeCaptureError.captureBusy }
        guard !cancellation.isCancelled else { throw GazeCaptureError.requestCancelled }
        guard CGPreflightScreenCaptureAccess() else { throw GazeCaptureError.permissionRequired }
        isCapturing = true
        defer { isCapturing = false }

        let image = try await captureDisplay(display)
        // This timestamp describes the pixels, not the later approval or
        // optional provider-enrichment completion time.
        let capturedAt = Date()
        guard !cancellation.isCancelled else { throw GazeCaptureError.requestCancelled }
        let rendered = try renderContext(
            from: image,
            display: display,
            normalizedGaze: normalizedGaze,
            attention: attention,
            smartCropEnabled: options.smartCropEnabled,
            marker: marker
        )
        // Encode first, then decode the exact outgoing bytes for approval. The
        // preview therefore includes JPEG compression artifacts rather than a
        // cleaner pre-encoding image the downstream integration will not see.
        let jpeg = try encodeJPEG(rendered.image)
        guard jpeg.count <= Self.maximumBodyBytes else { throw GazeCaptureError.responseTooLarge }
        guard let outgoingImage = NSBitmapImageRep(data: jpeg)?.cgImage else {
            throw GazeCaptureError.encodingFailed
        }
        let focusJPEG = options.cerebrasEnrichmentEnabled
            ? try rendered.focus.map(encodeJPEG)
            : nil
        let outgoingFocus: CGImage?
        if let focusJPEG {
            guard let decoded = NSBitmapImageRep(data: focusJPEG)?.cgImage else {
                throw GazeCaptureError.encodingFailed
            }
            outgoingFocus = decoded
        } else {
            outgoingFocus = nil
        }
        switch approve(
            outgoingImage,
            focus: outgoingFocus,
            sendsToCerebras: options.cerebrasEnrichmentEnabled,
            cancellation: cancellation
        ) {
        case .approved: break
        case .rejected: throw GazeCaptureError.approvalRejected
        case .cancelled: throw GazeCaptureError.requestCancelled
        }
        var enrichment: VisionEnrichment?
        var enrichmentWarning: String?
        if let apiKey = options.cerebrasAPIKey {
            guard !cancellation.isCancelled else { throw GazeCaptureError.requestCancelled }
            var inputs = [VisionImageInput(data: jpeg, mimeType: "image/jpeg", purpose: .completeContext)]
            if let focusJPEG {
                inputs.append(VisionImageInput(data: focusJPEG, mimeType: "image/jpeg", purpose: .enlargedFocus))
            }
            do {
                enrichment = try await cerebrasEnricher.enrich(
                    VisionEnrichmentRequest(
                        images: inputs,
                        gazeInContext: NormalizedPoint(
                            x: rendered.gaze.x / CGFloat(rendered.image.width),
                            y: rendered.gaze.y / CGFloat(rendered.image.height)
                        ),
                        regionKind: rendered.region.kind
                    ),
                    apiKey: apiKey
                ).enrichment
            } catch {
                // The approved local capture is still useful if the optional
                // provider is unavailable. Keep provider errors bounded and
                // never include the credential or response body.
                enrichmentWarning = "Cerebras enrichment was unavailable for this capture."
            }
        }
        return GazeCaptureArtifact(
            jpeg: jpeg,
            width: rendered.image.width,
            height: rendered.image.height,
            gazeX: Int(rendered.gaze.x.rounded()),
            gazeY: Int(rendered.gaze.y.rounded()),
            normalizedX: rendered.gaze.x / CGFloat(rendered.image.width),
            normalizedY: rendered.gaze.y / CGFloat(rendered.image.height),
            uncertaintyRadius: Int(rendered.uncertaintyRadius.rounded()),
            attention: rendered.attention,
            marker: marker,
            capturedAt: capturedAt,
            region: rendered.region,
            enrichment: enrichment,
            enrichmentWarning: enrichmentWarning
        )
    }

    private func captureDisplay(_ display: DisplayDescriptor) async throws -> CGImage {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let displayID = UInt32(display.id.replacingOccurrences(of: "display-", with: "")),
                  let target = content.displays.first(where: { $0.displayID == displayID }) else {
                throw GazeCaptureError.displayUnavailable
            }
            let ownBundleID = Bundle.main.bundleIdentifier
            let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            let filter = SCContentFilter(display: target, excludingApplications: excluded, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let downscale = min(
                1,
                CGFloat(Self.maximumEdge) / CGFloat(target.width),
                CGFloat(Self.maximumEdge) / CGFloat(target.height)
            )
            configuration.width = max(1, Int(CGFloat(target.width) * downscale))
            configuration.height = max(1, Int(CGFloat(target.height) * downscale))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch let error as GazeCaptureError {
            throw error
        } catch {
            throw GazeCaptureError.captureFailed
        }
    }

    private func renderContext(
        from source: CGImage,
        display: DisplayDescriptor,
        normalizedGaze: Point2D,
        attention: AttentionSnapshot?,
        smartCropEnabled: Bool,
        marker: GazeCaptureMarker
    ) throws -> (
        image: CGImage,
        focus: CGImage?,
        gaze: CGPoint,
        uncertaintyRadius: CGFloat,
        attention: GazeCaptureAttentionMetadata,
        region: GazeCaptureRegionMetadata
    ) {
        if smartCropEnabled,
           let displayID = UInt32(display.id.replacingOccurrences(of: "display-", with: "")),
           let smart = try? renderSmartContext(
               from: source,
               displayID: displayID,
               normalizedGaze: normalizedGaze,
               attention: attention,
               marker: marker
           ) {
            return smart
        }
        let layout = GazeCaptureLayout.make(
            sourceSize: CGSize(width: source.width, height: source.height),
            normalizedGaze: normalizedGaze
        )
        let cropRectTopLeft = layout.cropRect
        // CGImage cropping uses a top-left pixel origin, matching the normalized
        // gaze coordinates used by Eagle's SwiftUI overlays.
        guard let cropped = source.cropping(to: cropRectTopLeft) else { throw GazeCaptureError.captureFailed }
        let localGaze = layout.gazeInCrop

        guard let context = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw GazeCaptureError.captureFailed }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))

        // CGContext drawing has a bottom-left origin, so invert only for the
        // annotation. Returned coordinates retain the image/top-left contract.
        let drawPoint = CGPoint(x: localGaze.x, y: CGFloat(cropped.height) - localGaze.y)
        let uncertainty = max(36, min(CGFloat(cropped.width), CGFloat(cropped.height)) * 0.06)
        context.setFillColor(NSColor.systemPink.withAlphaComponent(0.14).cgColor)
        context.setStrokeColor(NSColor.systemPink.cgColor)
        context.setLineWidth(5)
        let region = CGRect(
            x: drawPoint.x - uncertainty,
            y: drawPoint.y - uncertainty,
            width: uncertainty * 2,
            height: uncertainty * 2
        )
        if marker == .circle {
            context.fillEllipse(in: region)
            context.strokeEllipse(in: region)
        } else {
            context.fill(region)
            context.stroke(region)
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: drawPoint.x - 5, y: drawPoint.y - 5, width: 10, height: 10))
        guard let result = context.makeImage() else { throw GazeCaptureError.captureFailed }
        return (
            result,
            nil,
            localGaze,
            uncertainty,
            GazeCaptureAttentionMetadata(
                estimator: "mapped_point_fallback",
                confidence: nil,
                sampleCount: nil,
                fixationDurationMilliseconds: nil,
                newestSampleAgeMilliseconds: nil,
                uncertaintyRadiusX: Int(uncertainty.rounded()),
                uncertaintyRadiusY: Int(uncertainty.rounded())
            ),
            GazeCaptureRegionMetadata(
                kind: .unknown,
                resolvedBy: .fixedContextFallback,
                confidence: 0.35,
                fallbackUsed: true,
                topmostAtGaze: nil,
                userAdjusted: false,
                partiallyClipped: false,
                paddingPercent: nil,
                includedRelationships: []
            )
        )
    }

    private func renderSmartContext(
        from source: CGImage,
        displayID: CGDirectDisplayID,
        normalizedGaze: Point2D,
        attention: AttentionSnapshot?,
        marker: GazeCaptureMarker
    ) throws -> (
        image: CGImage,
        focus: CGImage?,
        gaze: CGPoint,
        uncertaintyRadius: CGFloat,
        attention: GazeCaptureAttentionMetadata,
        region: GazeCaptureRegionMetadata
    ) {
        let displayBounds = CGDisplayBounds(displayID)
        let geometry = CaptureGeometry(
            displayGlobalBounds: displayBounds,
            imagePixelSize: CGSize(width: source.width, height: source.height)
        )
        let center = attention?.center
            ?? NormalizedPoint(x: normalizedGaze.x, y: normalizedGaze.y)
        let gazeGlobal = geometry.normalizedToGlobal(center)
        let radiusX = max(attention?.radiusX ?? 0.06, 0.015) * displayBounds.width
        let radiusY = max(attention?.radiusY ?? 0.06, 0.015) * displayBounds.height
        let uncertaintySize = CGSize(width: radiusX, height: radiusY)
        let uncertaintyBounds = CGRect(
            x: gazeGlobal.x - radiusX,
            y: gazeGlobal.y - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        )

        var candidates = (try? accessibilityResolver.candidates(
            at: gazeGlobal,
            displayBounds: displayBounds
        )) ?? []
        let fallback = fallbackResolver.candidate(at: gazeGlobal, displayBounds: displayBounds)
        candidates.append(fallback)
        guard let selection = regionSelector.select(
            candidates: candidates,
            gazeGlobalPoint: gazeGlobal,
            uncertaintySize: uncertaintySize,
            displayBounds: displayBounds
        ), let plan = CropPlan.make(
            geometry: geometry,
            selection: selection,
            gazeGlobalPoint: gazeGlobal,
            uncertaintyGlobalBounds: uncertaintyBounds
        ) else { throw GazeCaptureError.captureFailed }

        let crops = try cropRenderer.render(source: source, plan: plan)
        let uncertaintyPixelsX = max(18, radiusX * CGFloat(source.width) / displayBounds.width)
        let uncertaintyPixelsY = max(18, radiusY * CGFloat(source.height) / displayBounds.height)
        let uncertaintyPixels = max(
            18,
            max(uncertaintyPixelsX, uncertaintyPixelsY)
        )
        let annotated = try annotate(
            crops.context,
            gaze: plan.gazeInCrop,
            uncertainty: uncertaintyPixels,
            marker: marker
        )
        return (
            annotated,
            crops.enlargedFocus,
            plan.gazeInCrop,
            uncertaintyPixels,
            GazeCaptureAttentionMetadata(
                estimator: attention == nil ? "mapped_point_fallback" : "rolling_fixation",
                confidence: attention?.sourceConfidence,
                sampleCount: attention?.sampleCount,
                fixationDurationMilliseconds: attention.map { Int(($0.coverageDuration * 1_000).rounded()) },
                newestSampleAgeMilliseconds: attention.map { Int(($0.newestSampleAge * 1_000).rounded()) },
                uncertaintyRadiusX: Int(uncertaintyPixelsX.rounded()),
                uncertaintyRadiusY: Int(uncertaintyPixelsY.rounded())
            ),
            GazeCaptureRegionMetadata(
                kind: selection.selected.role,
                resolvedBy: selection.selected.source,
                confidence: selection.selected.confidence,
                fallbackUsed: selection.selected.source == .fixedContextFallback,
                topmostAtGaze: selection.selected.source == .accessibility ? true : nil,
                userAdjusted: selection.selected.source == .userAdjusted,
                partiallyClipped: !displayBounds.contains(
                    selection.selected.globalBounds.insetBy(
                        dx: -selection.selected.globalBounds.width * regionSelector.policy.paddingRatio,
                        dy: -selection.selected.globalBounds.height * regionSelector.policy.paddingRatio
                    )
                ),
                paddingPercent: Double(regionSelector.policy.paddingRatio * 100),
                includedRelationships: selection.selected.includedRelationships
                    .map(\.rawValue)
                    .sorted()
            )
        )
    }

    private func annotate(
        _ image: CGImage,
        gaze: CGPoint,
        uncertainty: CGFloat,
        marker: GazeCaptureMarker
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw GazeCaptureError.captureFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let drawPoint = CGPoint(x: gaze.x, y: CGFloat(image.height) - gaze.y)
        let region = CGRect(
            x: drawPoint.x - uncertainty,
            y: drawPoint.y - uncertainty,
            width: uncertainty * 2,
            height: uncertainty * 2
        )
        context.setFillColor(NSColor.systemPink.withAlphaComponent(0.14).cgColor)
        context.setStrokeColor(NSColor.systemPink.cgColor)
        context.setLineWidth(5)
        if marker == .circle {
            context.fillEllipse(in: region)
            context.strokeEllipse(in: region)
        } else {
            context.fill(region)
            context.stroke(region)
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: drawPoint.x - 5, y: drawPoint.y - 5, width: 10, height: 10))
        guard let result = context.makeImage() else { throw GazeCaptureError.captureFailed }
        return result
    }

    private enum ApprovalDecision { case approved, rejected, cancelled }

    private func approve(
        _ image: CGImage,
        focus: CGImage?,
        sendsToCerebras: Bool,
        cancellation: any GazeCaptureCancellationChecking
    ) -> ApprovalDecision {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Share this gaze capture?"
        alert.informativeText = sendsToCerebras
            ? "An unidentified local process requested this capture. If approved, the context image enters the local downstream integration and both previewed images are sent to Cerebras for optional labeling. They may contain private on-screen information."
            : "An unidentified local process requested this capture. If you approve, these exact annotated pixels leave EagleEye and enter the downstream integration, where they may contain private on-screen information."
        alert.addButton(withTitle: "Share Capture")
        alert.addButton(withTitle: "Cancel")
        let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
        imageView.image = preview
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignTopLeft
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        scrollView.documentView = imageView
        scrollView.hasHorizontalScroller = image.width > 720
        scrollView.hasVerticalScroller = image.height > 520
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        if let focus {
            let focusView = NSImageView(frame: NSRect(x: 0, y: 0, width: focus.width, height: focus.height))
            focusView.image = NSImage(cgImage: focus, size: NSSize(width: focus.width, height: focus.height))
            focusView.imageScaling = .scaleProportionallyDown
            let stack = NSStackView(views: [scrollView, NSTextField(labelWithString: "Enlarged focus sent to Cerebras"), focusView])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            focusView.widthAnchor.constraint(equalToConstant: 720).isActive = true
            focusView.heightAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            alert.accessoryView = stack
        } else {
            alert.accessoryView = scrollView
        }
        NSApp.activate(ignoringOtherApps: true)
        let startedAt = ContinuousClock.now
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if cancellation.isCancelled || startedAt.duration(to: .now) >= .seconds(30) {
                    guard NSApp.modalWindow == alert.window else { return }
                    NSApp.abortModal()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitor.cancel() }
        let response = alert.runModal()
        if cancellation.isCancelled { return .cancelled }
        return response == .alertFirstButtonReturn ? .approved : .rejected
    }

    private func encodeJPEG(_ image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        for quality in [0.82, 0.70, 0.58] {
            if let data = representation.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               data.count <= Self.maximumBodyBytes {
                return data
            }
        }
        throw GazeCaptureError.responseTooLarge
    }
}
