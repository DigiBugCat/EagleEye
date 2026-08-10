import CoreGraphics
import GazeCore
import Testing
@testable import EagleGazeMac

@Test func gazeCaptureLayoutCentersInteriorGaze() {
    let layout = GazeCaptureLayout.make(
        sourceSize: CGSize(width: 3_000, height: 2_000),
        normalizedGaze: Point2D(x: 0.5, y: 0.5)
    )
    #expect(layout.cropRect == CGRect(x: 700, y: 466, width: 1_600, height: 1_068))
    #expect(layout.gazeInCrop == CGPoint(x: 800, y: 534))
}

@Test func gazeCaptureLayoutClampsAtTopLeftAndRetainsImageCoordinates() {
    let layout = GazeCaptureLayout.make(
        sourceSize: CGSize(width: 3_000, height: 2_000),
        normalizedGaze: Point2D(x: 0.05, y: 0.10)
    )
    #expect(layout.cropRect.origin == .zero)
    #expect(layout.gazeInCrop == CGPoint(x: 150, y: 200))
}

@Test func gazeCaptureLayoutClampsNormalizedInput() {
    let layout = GazeCaptureLayout.make(
        sourceSize: CGSize(width: 800, height: 600),
        normalizedGaze: Point2D(x: -2, y: 4)
    )
    #expect(layout.cropRect == CGRect(x: 0, y: 66, width: 800, height: 534))
    #expect(layout.gazeInCrop == CGPoint(x: 0, y: 533))
}

@Test func bridgeConnectionCancellationTransitionsOnceDisconnected() {
    let cancellation = BridgeConnectionCancellation()
    #expect(!cancellation.isCancelled)
    cancellation.cancel()
    #expect(cancellation.isCancelled)
    cancellation.cancel()
    #expect(cancellation.isCancelled)
}

@Test @MainActor func captureRejectsAnAlreadyDisconnectedRequestBeforePermissionOrPixels() async {
    let cancellation = BridgeConnectionCancellation()
    cancellation.cancel()
    let service = GazeCaptureService()
    let display = DisplayDescriptor(
        id: "display-1",
        name: "Test Display",
        frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
        isMain: true
    )
    await #expect(throws: GazeCaptureError.requestCancelled) {
        try await service.capture(
            display: display,
            normalizedGaze: Point2D(x: 0.5, y: 0.5),
            attention: nil,
            marker: .circle,
            options: GazeCaptureOptions(smartCropEnabled: true, cerebrasAPIKey: nil),
            cancellation: cancellation
        )
    }
}
