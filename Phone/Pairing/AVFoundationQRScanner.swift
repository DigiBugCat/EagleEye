#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import Foundation

/// Production AVFoundation implementation. Camera frames are consumed only
/// for metadata; no image, face transform, or gaze sample is retained.
public final class AVFoundationQRScanner: NSObject, QRScannerBoundary,
    AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    public var onPayload: ((String) -> Void)?
    public private(set) var isRunning = false

    private let session: AVCaptureSession
    private let queue = DispatchQueue(label: "com.aviary.eaglegaze.phone.qr")
    private var configured = false

    public init(session: AVCaptureSession = AVCaptureSession()) {
        self.session = session
    }

    public static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public func start() throws {
        guard !isRunning else { throw QRScannerError.alreadyRunning }
        guard AVCaptureDevice.default(for: .video) != nil else {
            throw QRScannerError.cameraUnavailable
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: throw QRScannerError.cameraPermissionRequired
        default: throw QRScannerError.cameraPermissionDenied
        }

        if !configured {
            try configure()
            configured = true
        }
        isRunning = true
        queue.async { [session] in session.startRunning() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [session] in session.stopRunning() }
    }

    private func configure() throws {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw QRScannerError.cameraUnavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw QRScannerError.configurationFailed
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw QRScannerError.configurationFailed }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { throw QRScannerError.configurationFailed }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: queue)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            throw QRScannerError.configurationFailed
        }
        output.metadataObjectTypes = [.qr]
    }

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let payload = metadataObjects
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .compactMap(\.stringValue)
            .first,
            !payload.isEmpty else { return }
        onPayload?(payload)
    }
}
#endif
