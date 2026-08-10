import Foundation

import GazeCore

/// The app-facing pairing boundary.  Pairing and reconnect handshakes belong
/// to the transport/pairing implementation; presentation only receives a
/// fully authenticated value object after that work succeeds.
@MainActor
protocol PhonePairingSessionClient: AnyObject {
    /// Lists user-selectable Macs currently advertising on the nearby network.
    func discoverNearbyMacs() async throws -> [PairingControlCandidate]

    /// Completes the nearby pairing transcript and returns a durable record.
    /// Implementations must not persist a record until the Mac has authenticated
    /// the transcript and explicitly approved it.
    func pair(
        candidate: PairingControlCandidate,
        displayName: String,
        onVerificationCode: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> PairedReceiver

    /// Performs a fresh reconnect handshake.  Returning a new session on every
    /// foreground is required; a cached pairing key is not sufficient to send
    /// gaze frames.
    func establishSession(for receiver: PairedReceiver, sessionID: UUID) async throws -> GazeSessionMaterial
}

enum PhonePairingSessionError: Error, Equatable, Sendable {
    /// The network handshake is intentionally not guessed or emulated.  This
    /// is the safe default until the Mac transport is injected by composition.
    case handshakeUnavailable
    case noAuthenticatedSession
}

/// Fail-closed default used by the MVP until the Bonjour handshake adapter is
/// wired.  It makes the missing integration seam visible in the UI rather than
/// fabricating nonces, stream keys, or endpoints.
final class UnavailablePhonePairingSessionClient: PhonePairingSessionClient {
    func discoverNearbyMacs() async throws -> [PairingControlCandidate] {
        throw PhonePairingSessionError.handshakeUnavailable
    }

    func pair(
        candidate: PairingControlCandidate,
        displayName: String,
        onVerificationCode: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> PairedReceiver {
        throw PhonePairingSessionError.handshakeUnavailable
    }

    func establishSession(for receiver: PairedReceiver, sessionID: UUID) async throws -> GazeSessionMaterial {
        throw PhonePairingSessionError.handshakeUnavailable
    }
}

/// Adapter for the concrete control client.  Keeping this conformance here
/// means the app composition can inject the real Bonjour/TCP implementation
/// without exposing its wire messages to SwiftUI.
extension PairingControlClient: PhonePairingSessionClient {
    func establishSession(
        for receiver: PairedReceiver,
        sessionID: UUID
    ) async throws -> GazeSessionMaterial {
        let material = try await reconnect(receiver: receiver, sessionID: sessionID)
        return try GazeSessionMaterial(
            pairID: receiver.pairID,
            sessionID: material.sessionID,
            sessionKey: material.streamKey,
            noncePrefix: material.noncePrefix
        )
    }
}
