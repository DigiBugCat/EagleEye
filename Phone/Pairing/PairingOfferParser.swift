import Foundation
import CryptoKit
import GazeCore

/// Errors raised while turning camera text into a validated pairing offer.
public enum PairingQRPayloadError: Error, Equatable, Sendable {
    case emptyPayload
    case malformedPayload
    case unsupportedPayloadScheme
    case invalidOffer(PairingOfferError)
}

/// Decodes the JSON (or URL-wrapped JSON) carried by a pairing QR code.
///
/// The parser is deliberately the only phone boundary that accepts QR text.
/// It never stores the payload and validates all security-sensitive fields
/// before returning a `GazeCore.PairingOffer`.
public struct PairingOfferParser: Sendable {
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    public func parse(_ payload: String) throws -> PairingOffer {
        try Self.parse(payload, now: clock())
    }

    public func parse(_ payload: Data) throws -> PairingOffer {
        try Self.parse(payload, now: clock())
    }

    public static func parse(_ payload: String, now: Date = Date()) throws -> PairingOffer {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingQRPayloadError.emptyPayload }
        let data = try dataFromPayload(text)
        return try parse(data, now: now)
    }

    public static func parse(payload: String, now: Date = Date()) throws -> PairingOffer {
        try parse(payload, now: now)
    }

    public static func parse(_ payload: Data, now: Date = Date()) throws -> PairingOffer {
        guard !payload.isEmpty else { throw PairingQRPayloadError.emptyPayload }

        let offer: PairingOffer
        do {
            // QR implementations commonly use ISO-8601 strings. The second
            // decoder keeps compatibility with Foundation's numeric Date
            // representation used by JSONEncoder.
            let isoDecoder = JSONDecoder()
            isoDecoder.dateDecodingStrategy = .iso8601
            if let decoded = try? isoDecoder.decode(PairingOffer.self, from: payload) {
                offer = decoded
            } else {
                offer = try JSONDecoder().decode(PairingOffer.self, from: payload)
            }
        } catch {
            throw PairingQRPayloadError.malformedPayload
        }

        do {
            try offer.validate(at: now)
            guard Self.isCryptographicallyValidPublicKey(offer.ephemeralPublicKey) else {
                throw PairingOfferError.invalidEphemeralPublicKey
            }
        } catch let error as PairingOfferError {
            throw PairingQRPayloadError.invalidOffer(error)
        } catch {
            throw PairingQRPayloadError.malformedPayload
        }
        return offer
    }

    private static func dataFromPayload(_ payload: String) throws -> Data {
        if payload.first == "{" || payload.first == "[" {
            guard let data = payload.data(using: .utf8) else {
                throw PairingQRPayloadError.malformedPayload
            }
            return data
        }

        if let url = URL(string: payload),
           let scheme = url.scheme?.lowercased() {
            guard scheme == "eagle-gaze" else {
                throw PairingQRPayloadError.unsupportedPayloadScheme
            }
            guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "payload" })?.value else {
                throw PairingQRPayloadError.malformedPayload
            }
            return try dataFromEncodedValue(value)
        }

        return try dataFromEncodedValue(payload)
    }

    private static func dataFromEncodedValue(_ value: String) throws -> Data {
        if let json = value.data(using: .utf8),
           json.first == 123 {
            return json
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else {
            throw PairingQRPayloadError.malformedPayload
        }
        return data
    }

    private static func isCryptographicallyValidPublicKey(_ data: Data) -> Bool {
        let normalized = data.count == 65 && data.first == 4
            ? Data(data.dropFirst())
            : data
        guard normalized.count == 64 else { return false }
        return (try? P256.KeyAgreement.PublicKey(rawRepresentation: normalized)) != nil
    }
}
