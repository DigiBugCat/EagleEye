import Foundation
import Testing
@testable import GazeCore

private let wireOfferID = UUID(uuidString: "12345678-1234-4234-8234-123456789012")!
private let wirePairID = UUID(uuidString: "22345678-1234-4234-8234-123456789012")!
private let wireSessionID = UUID(uuidString: "32345678-1234-4234-8234-123456789012")!
private let wireDeviceID = UUID(uuidString: "42345678-1234-4234-8234-123456789012")!

private func wireRequest() throws -> PairingInitiationRequest {
    let key = P256EphemeralKeyPair()
    let receiverKey = P256EphemeralKeyPair()
    return try PairingInitiationRequest(
        offerID: wireOfferID,
        receiverFingerprint: "sha256:receiver",
        serviceIdentity: "eagle-gaze-mac",
        expiresAt: Date(timeIntervalSinceReferenceDate: 10_000),
        receiverEphemeralPublicKey: receiverKey.publicKey,
        oneTimeSecret: Data(repeating: 4, count: 32),
        initiatorDeviceID: wireDeviceID,
        initiatorDisplayName: "Phone",
        initiatorEphemeralPublicKey: key.publicKey,
        verificationCode: "123456",
        transcriptMAC: Data(repeating: 8, count: PairingWireProtocol.proofLength)
    )
}

@Test func nearbyOfferRequestAndResponseRoundTrip() throws {
    let request = try NearbyPairingOfferRequest(requestID: wireSessionID)
    let offer = try PairingOffer(
        offerID: wireOfferID,
        receiverFingerprint: "sha256:receiver",
        ephemeralPublicKey: P256EphemeralKeyPair().publicKey,
        oneTimeSecret: Data(repeating: 4, count: 32),
        serviceIdentity: "eagle-gaze-mac",
        expiresAt: Date().addingTimeInterval(60)
    )
    let response = try NearbyPairingOfferResponse(requestID: request.requestID, offer: offer)

    for message in [
        PairingControlMessage.nearbyOfferRequest(request),
        PairingControlMessage.nearbyOfferResponse(response),
    ] {
        let frame = try PairingWireProtocol.encode(message)
        var decoder = PairingWireFrameDecoder()
        let payload = try #require(try decoder.append(frame).first)
        #expect(try PairingWireProtocol.decode(PairingControlMessage.self, payload: payload) == message)
    }
}

@Test func pairingWireRequestAndApprovedResponseRoundTrip() throws {
    let request = try wireRequest()
    let requestPayload = try PairingWireProtocol.encode(request)
    var parser = PairingWireFrameDecoder()
    let requestFrames = try parser.append(requestPayload)
    #expect(requestFrames.count == 1)
    #expect(try PairingWireProtocol.decode(PairingInitiationRequest.self, payload: requestFrames[0]) == request)

    let response = try PairingMacResponse.approved(
        offerID: wireOfferID, pairID: wirePairID, deviceID: wireDeviceID,
        displayName: "Mac", receiverFingerprint: "sha256:receiver",
        serviceIdentity: "eagle-gaze-mac", createdAt: Date(timeIntervalSinceReferenceDate: 9_000),
        verificationCode: "123456", transcriptMAC: Data(repeating: 8, count: 32),
        pairingKey: Data(repeating: 0x99, count: PairingProtocol.keyLength)
    )
    let responseFrame = try PairingWireProtocol.encode(response)
    let decodedResponse = try PairingWireProtocol.decode(
        PairingMacResponse.self, payload: Data(responseFrame.dropFirst(4))
    )
    #expect(decodedResponse == response)
    #expect(decodedResponse.status == .approved)
    #expect(decodedResponse.pairID == wirePairID)
    #expect(!(String(data: Data(responseFrame.dropFirst(4)), encoding: .utf8) ?? "").contains("pairingKey"))
    try decodedResponse.verifyApproval(pairingKey: Data(repeating: 0x99, count: PairingProtocol.keyLength))
    #expect(throws: PairingWireError.invalidProof) {
        try decodedResponse.verifyApproval(pairingKey: Data(repeating: 0x98, count: PairingProtocol.keyLength))
    }

    let tagged = try PairingWireProtocol.encode(PairingControlMessage.macResponse(response))
    var taggedParser = PairingWireFrameDecoder()
    let taggedPayload = try #require(try taggedParser.append(tagged).first)
    let decodedTagged = try PairingWireProtocol.decode(PairingControlMessage.self, payload: taggedPayload)
    #expect(decodedTagged == .macResponse(response))
}

@Test func pairingWireFrameParserHandlesSingleByteTCPFragmentsAndMultipleFrames() throws {
    let request = try wireRequest()
    let first = try PairingWireProtocol.encode(request)
    let second = try PairingWireProtocol.encode(try PairingMacResponse.pending(offerID: wireOfferID))
    var parser = PairingWireFrameDecoder()
    var frames: [Data] = []
    for byte in first + second { frames.append(contentsOf: try parser.append(Data([byte]))) }
    #expect(frames.count == 2)
    #expect(try PairingWireProtocol.decode(PairingInitiationRequest.self, payload: frames[0]) == request)
    #expect(try PairingWireProtocol.decode(PairingMacResponse.self, payload: frames[1]).status == .pending)
    #expect(parser.bufferedByteCount == 0)
}

@Test func pairingWireCodecAndParserRejectOversizedFrames() throws {
    let oversized = Data(repeating: 7, count: PairingWireProtocol.maxEncodedFrameSize + 1)
    do {
        _ = try PairingWireProtocol.encode(oversized)
        Issue.record("Expected oversized encoded payload to be rejected")
    } catch let error as PairingWireError {
        guard case let .frameTooLarge(size) = error else {
            Issue.record("Expected frameTooLarge, got \(error)")
            return
        }
        #expect(size > PairingWireProtocol.maxEncodedFrameSize)
    } catch {
        Issue.record("Expected PairingWireError, got \(error)")
    }

    var prefix = Data()
    var length = UInt32(PairingWireProtocol.maxEncodedFrameSize + 1).bigEndian
    withUnsafeBytes(of: &length) { prefix.append(contentsOf: $0) }
    var parser = PairingWireFrameDecoder()
    #expect(throws: PairingWireError.frameTooLarge(PairingWireProtocol.maxEncodedFrameSize + 1)) {
        try parser.append(prefix)
    }
}

@Test func pairingWireMessagesStrictlyValidateIDsVersionsAndNonces() throws {
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    #expect(throws: PairingWireError.invalidID) {
        try ReconnectChallenge(pairID: zero, sessionID: wireSessionID, initiatorNonce: Data(repeating: 1, count: 32))
    }
    #expect(throws: PairingWireError.invalidNonce) {
        try ReconnectChallenge(pairID: wirePairID, sessionID: wireSessionID, initiatorNonce: Data(repeating: 1, count: 31))
    }
    #expect(throws: PairingWireError.unsupportedVersion(received: 9, supported: 1)) {
        try ReconnectChallenge(version: 9, pairID: wirePairID, sessionID: wireSessionID, initiatorNonce: Data(repeating: 1, count: 32))
    }
    #expect(throws: PairingWireError.invalidResponse) {
        try PairingMacResponse(offerID: wireOfferID, status: .pending, displayName: "unexpected")
    }
    let request = try wireRequest()
    #expect(throws: PairingWireError.expired) {
        try request.validate(at: Date(timeIntervalSinceReferenceDate: 10_000))
    }
}

@Test func reconnectProofBindsPairSessionBothNoncesAndDirection() throws {
    let key = Data(repeating: 0xA1, count: PairingProtocol.keyLength)
    let initiatorNonce = Data(repeating: 1, count: PairingWireProtocol.nonceLength)
    let responderNonce = Data(repeating: 2, count: PairingWireProtocol.nonceLength)
    let challenge = try ReconnectChallenge(pairID: wirePairID, sessionID: wireSessionID, initiatorNonce: initiatorNonce)
    let response = try ReconnectResponse(challenge: challenge, responderNonce: responderNonce, pairingKey: key)
    try response.verify(pairingKey: key)
    let confirmation = try ReconnectConfirmation(response: response, pairingKey: key)
    try confirmation.verify(pairingKey: key)

    #expect(throws: PairingWireError.invalidProof) { try response.verify(pairingKey: Data(repeating: 0xA2, count: 32)) }
    var tamperedProof = response.proof
    tamperedProof[0] ^= 1
    let tampered = try ReconnectResponse(pairID: wirePairID, sessionID: wireSessionID,
                                         initiatorNonce: initiatorNonce, responderNonce: responderNonce, proof: tamperedProof)
    #expect(throws: PairingWireError.invalidProof) { try tampered.verify(pairingKey: key) }

    let alteredSession = UUID(uuidString: "52345678-1234-4234-8234-123456789012")!
    let altered = try ReconnectResponse(pairID: wirePairID, sessionID: alteredSession,
                                        initiatorNonce: initiatorNonce, responderNonce: responderNonce, proof: response.proof)
    #expect(throws: PairingWireError.invalidProof) { try altered.verify(pairingKey: key) }
    #expect(response.proof != confirmation.proof)
}
