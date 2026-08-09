import Foundation

public enum QRScannerError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case cameraUnavailable
    case cameraPermissionRequired
    case cameraPermissionDenied
    case configurationFailed
}

/// Narrow boundary around AVFoundation, allowing scanner coordination to be
/// tested without a camera or an ARSession.
public protocol QRScannerBoundary: AnyObject {
    var onPayload: ((String) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

@MainActor
public final class QRScannerCoordinator {
    public private(set) var isScanning = false
    public var onPayload: ((String) -> Void)?

    private let scanner: QRScannerBoundary
    private let pauseARKit: @MainActor () -> Void
    private let resumeARKit: @MainActor () -> Void

    public init(
        scanner: QRScannerBoundary,
        pauseARKit: @escaping @MainActor () -> Void,
        resumeARKit: @escaping @MainActor () -> Void
    ) {
        self.scanner = scanner
        self.pauseARKit = pauseARKit
        self.resumeARKit = resumeARKit
        scanner.onPayload = { [weak self] payload in
            // Stop capture on the callback's queue before hopping to the
            // main actor. This closes the duplicate-frame window while the
            // validated payload is handed to presentation.
            self?.scanner.stop()
            Task { @MainActor [weak self] in self?.received(payload) }
        }
    }

    public func start() throws {
        guard !isScanning else { throw QRScannerError.alreadyRunning }
        pauseARKit()
        do {
            try scanner.start()
            isScanning = true
        } catch {
            resumeARKit()
            throw error
        }
    }

    public func stop() {
        guard isScanning else { return }
        if scanner.isRunning { scanner.stop() }
        isScanning = false
        resumeARKit()
    }

    private func received(_ payload: String) {
        guard isScanning else { return }
        stop()
        onPayload?(payload)
    }
}

/// Deterministic fake used by PhoneTests and previews.
public final class InMemoryQRScannerBoundary: QRScannerBoundary, @unchecked Sendable {
    public var onPayload: ((String) -> Void)?
    public private(set) var isRunning = false
    public var startError: Error?

    public init() {}

    public func start() throws {
        if let startError { throw startError }
        guard !isRunning else { throw QRScannerError.alreadyRunning }
        isRunning = true
    }

    public func stop() { isRunning = false }

    public func emit(_ payload: String) {
        guard isRunning else { return }
        onPayload?(payload)
    }
}
