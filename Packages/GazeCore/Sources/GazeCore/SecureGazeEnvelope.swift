import CryptoKit
import Foundation

public enum SecureGazeEnvelopeError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case invalidKeyLength
    case invalidNoncePrefix
    case invalidEnvelope
    case authenticationFailed
    case invalidPayload
    case unknownPair
    case wrongSession
    case replayOrOutOfOrder(lastAccepted: UInt64, received: UInt64)
}

private struct SecureGazeEnvelopeWire: Codable {
    let version: Int
    let pairID: UUID
    let sessionID: UUID
    let sequence: UInt64
    let noncePrefix: Data
    let ciphertext: Data
    let authenticationTag: Data
}

/// Authenticated, latest-only transport wrapper for one canonical gaze sample.
/// The pair/session/sequence fields are intentionally visible so a receiver
/// can reject an unknown or replayed packet before attempting to decode gaze.
public struct SecureGazeEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let pairID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let noncePrefix: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        version: Int = Self.currentVersion,
        pairID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        noncePrefix: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) throws {
        guard version == Self.currentVersion else {
            throw SecureGazeEnvelopeError.unsupportedVersion(received: version, supported: Self.currentVersion)
        }
        guard noncePrefix.count == PairingProtocol.noncePrefixLength else {
            throw SecureGazeEnvelopeError.invalidNoncePrefix
        }
        guard authenticationTag.count == 16, !ciphertext.isEmpty else {
            throw SecureGazeEnvelopeError.invalidEnvelope
        }
        self.version = version
        self.pairID = pairID
        self.sessionID = sessionID
        self.sequence = sequence
        self.noncePrefix = noncePrefix
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }

    public static func seal(
        _ sample: GazeSample,
        pairID: UUID,
        sessionKey: Data,
        noncePrefix: Data
    ) throws -> SecureGazeEnvelope {
        guard sample.version == GazeSample.currentVersion else {
            throw SecureGazeEnvelopeError.unsupportedVersion(received: sample.version, supported: GazeSample.currentVersion)
        }
        let payload: Data
        do {
            payload = try GazeDatagramCodec.encode(sample)
        } catch {
            throw SecureGazeEnvelopeError.invalidPayload
        }
        return try seal(
            plaintext: payload,
            pairID: pairID,
            sessionID: sample.sessionID,
            sequence: sample.sequence,
            sessionKey: sessionKey,
            noncePrefix: noncePrefix
        )
    }

    /// Payload-agnostic primitive used by canonical gaze frames and future
    /// source adapters.  The transport layer authenticates bytes; it does not
    /// prescribe the source model or codec.
    public static func seal(
        plaintext: Data,
        pairID: UUID,
        sessionID: UUID,
        sequence: UInt64,
        sessionKey: Data,
        noncePrefix: Data
    ) throws -> SecureGazeEnvelope {
        guard sessionKey.count == PairingProtocol.keyLength else { throw SecureGazeEnvelopeError.invalidKeyLength }
        guard noncePrefix.count == PairingProtocol.noncePrefixLength else { throw SecureGazeEnvelopeError.invalidNoncePrefix }
        guard !plaintext.isEmpty else { throw SecureGazeEnvelopeError.invalidPayload }
        let aad = associatedData(version: Self.currentVersion, pairID: pairID, sessionID: sessionID, sequence: sequence)
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: sessionKey),
                nonce: try nonce(prefix: noncePrefix, sequence: sequence),
                authenticating: aad
            )
            return try SecureGazeEnvelope(
                pairID: pairID,
                sessionID: sessionID,
                sequence: sequence,
                noncePrefix: noncePrefix,
                ciphertext: box.ciphertext,
                authenticationTag: box.tag
            )
        } catch {
            throw SecureGazeEnvelopeError.invalidEnvelope
        }
    }

    public func open(sessionKey: Data) throws -> GazeSample {
        let payload = try openData(sessionKey: sessionKey)
        do {
            let sample = try GazeDatagramCodec.decode(payload)
            guard sample.sessionID == sessionID, sample.sequence == sequence else {
                throw SecureGazeEnvelopeError.invalidPayload
            }
            return sample
        } catch let error as SecureGazeEnvelopeError {
            throw error
        } catch {
            throw SecureGazeEnvelopeError.invalidPayload
        }
    }

    public func openData(sessionKey: Data) throws -> Data {
        guard version == Self.currentVersion else {
            throw SecureGazeEnvelopeError.unsupportedVersion(received: version, supported: Self.currentVersion)
        }
        guard sessionKey.count == PairingProtocol.keyLength else { throw SecureGazeEnvelopeError.invalidKeyLength }
        guard noncePrefix.count == PairingProtocol.noncePrefixLength else { throw SecureGazeEnvelopeError.invalidNoncePrefix }
        let aad = Self.associatedData(version: version, pairID: pairID, sessionID: sessionID, sequence: sequence)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try Self.nonce(prefix: noncePrefix, sequence: sequence),
                ciphertext: ciphertext,
                tag: authenticationTag
            )
            return try ChaChaPoly.open(box, using: SymmetricKey(data: sessionKey), authenticating: aad)
        } catch let error as SecureGazeEnvelopeError {
            throw error
        } catch {
            throw SecureGazeEnvelopeError.authenticationFailed
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SecureGazeEnvelope {
        do {
            let wire = try JSONDecoder().decode(SecureGazeEnvelopeWire.self, from: data)
            return try SecureGazeEnvelope(
                version: wire.version,
                pairID: wire.pairID,
                sessionID: wire.sessionID,
                sequence: wire.sequence,
                noncePrefix: wire.noncePrefix,
                ciphertext: wire.ciphertext,
                authenticationTag: wire.authenticationTag
            )
        } catch let error as SecureGazeEnvelopeError {
            throw error
        } catch {
            throw SecureGazeEnvelopeError.invalidEnvelope
        }
    }

    /// Associated data is a fixed-width binary representation, so JSON
    /// formatting or UUID textual casing can never alter authentication.
    public static func associatedData(version: Int, pairID: UUID, sessionID: UUID, sequence: UInt64) -> Data {
        var result = Data()
        var versionValue = UInt32(version).bigEndian
        var sequenceValue = sequence.bigEndian
        withUnsafeBytes(of: &versionValue) { result.append(contentsOf: $0) }
        result.append(contentsOf: withUnsafeBytes(of: pairID.uuid) { Data($0) })
        result.append(contentsOf: withUnsafeBytes(of: sessionID.uuid) { Data($0) })
        withUnsafeBytes(of: &sequenceValue) { result.append(contentsOf: $0) }
        return result
    }

    private static func nonce(prefix: Data, sequence: UInt64) throws -> ChaChaPoly.Nonce {
        guard prefix.count == PairingProtocol.noncePrefixLength else { throw SecureGazeEnvelopeError.invalidNoncePrefix }
        var sequenceValue = sequence.bigEndian
        var bytes = prefix
        withUnsafeBytes(of: &sequenceValue) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

/// Stateful latest-only receiver.  Ordering is checked before decryption and
/// JSON decoding, which avoids spending work on obvious replays.
public struct SecureGazeEnvelopeReceiver: Sendable {
    public let pairID: UUID
    public let sessionID: UUID
    public let sessionKey: Data
    public let noncePrefix: Data
    public private(set) var lastAcceptedSequence: UInt64?

    public init(pairID: UUID, sessionID: UUID, sessionKey: Data, noncePrefix: Data) throws {
        guard sessionKey.count == PairingProtocol.keyLength else { throw SecureGazeEnvelopeError.invalidKeyLength }
        guard noncePrefix.count == PairingProtocol.noncePrefixLength else { throw SecureGazeEnvelopeError.invalidNoncePrefix }
        self.pairID = pairID
        self.sessionID = sessionID
        self.sessionKey = sessionKey
        self.noncePrefix = noncePrefix
        self.lastAcceptedSequence = nil
    }

    public mutating func open(_ envelope: SecureGazeEnvelope) throws -> GazeSample {
        let payload = try openData(envelope)
        do {
            return try GazeDatagramCodec.decode(payload)
        } catch {
            throw SecureGazeEnvelopeError.invalidPayload
        }
    }

    public mutating func openData(_ envelope: SecureGazeEnvelope) throws -> Data {
        guard envelope.version == SecureGazeEnvelope.currentVersion else {
            throw SecureGazeEnvelopeError.unsupportedVersion(received: envelope.version, supported: SecureGazeEnvelope.currentVersion)
        }
        guard envelope.pairID == pairID else { throw SecureGazeEnvelopeError.unknownPair }
        guard envelope.sessionID == sessionID else { throw SecureGazeEnvelopeError.wrongSession }
        guard envelope.noncePrefix == noncePrefix else { throw SecureGazeEnvelopeError.authenticationFailed }
        if let lastAcceptedSequence, envelope.sequence <= lastAcceptedSequence {
            throw SecureGazeEnvelopeError.replayOrOutOfOrder(lastAccepted: lastAcceptedSequence, received: envelope.sequence)
        }
        let payload = try envelope.openData(sessionKey: sessionKey)
        lastAcceptedSequence = envelope.sequence
        return payload
    }

    public mutating func reset() {
        lastAcceptedSequence = nil
    }
}
