import Foundation
import GazeCore

public struct AuthenticatedGazeCodec: Sendable {
    public let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = 16 * 1024) {
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// Encodes only the canonical source contract and wraps it in the shared
    /// authenticated envelope.  The transport remains payload-agnostic: it
    /// authenticates bytes and does not inspect gaze fields.
    public func encode(
        _ frame: CanonicalGazeFrame,
        session: GazeSessionMaterial
    ) throws -> Data {
        guard frame.sourceSessionID == session.sessionID else {
            throw SecureGazeEnvelopeError.wrongSession
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(frame)
        guard !payload.isEmpty else { throw SecureGazeEnvelopeError.invalidPayload }
        guard payload.count <= maximumPayloadBytes else {
            throw GazeTransportError.payloadTooLarge(
                actual: payload.count,
                maximum: maximumPayloadBytes
            )
        }

        let envelope = try SecureGazeEnvelope.seal(
            plaintext: payload,
            pairID: session.pairID,
            sessionID: session.sessionID,
            sequence: frame.sequence,
            sessionKey: session.sessionKey,
            noncePrefix: session.noncePrefix
        )
        let encoded = try envelope.encoded()
        guard encoded.count <= maximumPayloadBytes else {
            throw GazeTransportError.payloadTooLarge(
                actual: encoded.count,
                maximum: maximumPayloadBytes
            )
        }
        return encoded
    }
}

/// A one-in-flight, latest-only queue.  A slow receiver can delay at most one
/// newer frame; stale gaze data is discarded instead of accumulating.
@MainActor
public final class LatestOnlyGazeSender {
    private let connection: GazeDatagramConnection
    private var pending: Data?
    private var sendInFlight = false
    private var stopped = false

    public private(set) var lastError: Error?
    public var onSendError: ((Error) -> Void)?

    public init(connection: GazeDatagramConnection) {
        self.connection = connection
    }

    public func sendLatest(_ data: Data) {
        guard !stopped else { return }
        pending = data
        drain()
    }

    public func stop() {
        stopped = true
        pending = nil
        sendInFlight = false
        connection.cancel()
    }

    private func drain() {
        guard !stopped, !sendInFlight, let data = pending else { return }
        pending = nil
        sendInFlight = true
        connection.send(data) { [weak self] error in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.lastError = error
                if let error { self.onSendError?(error) }
                self.sendInFlight = false
                self.drain()
            }
        }
    }
}
