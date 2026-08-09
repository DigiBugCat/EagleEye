import Foundation
import Testing
@testable import GazeCore

private let fixedOfferID = UUID(uuidString: "9E73C0AC-7857-4A57-AB9C-CC38AA7C2910")!
private let fixedPairID = UUID(uuidString: "C5B5E5CC-3FB8-4014-A9E0-9E898CD4F0A7")!
private let fixedSessionID = UUID(uuidString: "CD0E5D2E-5C94-46CB-91B6-4809D49393CF")!

private func transcript(
    receiverKey: Data,
    initiatorKey: Data,
    oneTimeSecret: Data = Data(repeating: 0xA5, count: 32)
) throws -> PairingTranscript {
    try PairingTranscript(
        offerID: fixedOfferID,
        receiverFingerprint: "sha256:receiver",
        serviceIdentity: "eagle-gaze-mac",
        receiverEphemeralPublicKey: receiverKey,
        initiatorEphemeralPublicKey: initiatorKey,
        oneTimeSecret: oneTimeSecret
    )
}

private func gazeSample(sessionID: UUID = fixedSessionID, sequence: UInt64 = 1) -> GazeSample {
    GazeSample(
        sessionID: sessionID,
        sequence: sequence,
        captureUptime: 20,
        sentUptime: 20.01,
        isTracked: true,
        lookAt: Vector3(x: 0.1, y: -0.2, z: 0.8),
        faceTransform: .identity,
        leftEyeTransform: .identity,
        rightEyeTransform: .identity,
        leftBlink: 0.2,
        rightBlink: 0.3
    )
}

@Test func pairingOfferValidatesVersionAndExpiryAtInjectedTime() throws {
    let receiver = P256EphemeralKeyPair()
    let offer = try PairingOffer(
        offerID: fixedOfferID,
        receiverFingerprint: "sha256:receiver",
        ephemeralPublicKey: receiver.publicKey,
        oneTimeSecret: Data(repeating: 3, count: 32),
        serviceIdentity: "eagle-gaze-mac",
        expiresAt: Date(timeIntervalSinceReferenceDate: 100)
    )

    try offer.validate(at: Date(timeIntervalSinceReferenceDate: 99.99))
    #expect(offer.isValid(at: Date(timeIntervalSinceReferenceDate: 100)) == false)
    #expect(throws: PairingOfferError.expired) {
        try offer.validate(at: Date(timeIntervalSinceReferenceDate: 100))
    }

    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    #expect(throws: PairingOfferError.invalidOfferID) {
        try PairingOffer(
            offerID: zero,
            receiverFingerprint: "sha256:receiver",
            ephemeralPublicKey: receiver.publicKey,
            oneTimeSecret: Data(repeating: 3, count: 32),
            serviceIdentity: "eagle-gaze-mac",
            expiresAt: Date(timeIntervalSinceReferenceDate: 100)
        )
    }
}

@Test func p256PairingIsTranscriptBoundAndAuthenticatesProof() throws {
    let receiver = P256EphemeralKeyPair()
    let initiator = P256EphemeralKeyPair()
    let transcriptValue = try transcript(receiverKey: receiver.publicKey, initiatorKey: initiator.publicKey)
    let receiverMaterial = try PairingKeyAgreement.derivePairingMaterial(
        localKeyPair: receiver,
        peerPublicKey: initiator.publicKey,
        transcript: transcriptValue
    )
    let initiatorMaterial = try PairingKeyAgreement.derivePairingMaterial(
        localKeyPair: initiator,
        peerPublicKey: receiver.publicKey,
        transcript: transcriptValue
    )

    #expect(receiverMaterial == initiatorMaterial)
    #expect(receiverMaterial.verificationCode.count == 6)
    #expect(PairingKeyAgreement.verifyTranscriptMAC(
        receiverMaterial.transcriptMAC,
        material: initiatorMaterial,
        transcript: transcriptValue
    ))

    let altered = try transcript(receiverKey: receiver.publicKey, initiatorKey: initiator.publicKey, oneTimeSecret: Data(repeating: 4, count: 32))
    let alteredMaterial = try PairingKeyAgreement.derivePairingMaterial(
        localKeyPair: receiver,
        peerPublicKey: initiator.publicKey,
        transcript: altered
    )
    #expect(alteredMaterial.pairingKey != receiverMaterial.pairingKey)
    #expect(PairingKeyAgreement.verifyTranscriptMAC(
        receiverMaterial.transcriptMAC,
        material: alteredMaterial,
        transcript: altered
    ) == false)
}

@Test func reconnectDerivationUsesFreshNoncesAndSharedSessionContext() throws {
    let pairingKey = Data(repeating: 0x11, count: PairingProtocol.keyLength)
    let first = try ReconnectSessionDerivation.derive(
        pairingKey: pairingKey,
        pairID: fixedPairID,
        sessionID: fixedSessionID,
        initiatorNonce: Data(repeating: 1, count: 32),
        responderNonce: Data(repeating: 2, count: 32)
    )
    let same = try ReconnectSessionDerivation.derive(
        pairingKey: pairingKey,
        pairID: fixedPairID,
        sessionID: fixedSessionID,
        initiatorNonce: Data(repeating: 1, count: 32),
        responderNonce: Data(repeating: 2, count: 32)
    )
    let fresh = try ReconnectSessionDerivation.derive(
        pairingKey: pairingKey,
        pairID: fixedPairID,
        sessionID: fixedSessionID,
        initiatorNonce: Data(repeating: 9, count: 32),
        responderNonce: Data(repeating: 2, count: 32)
    )
    #expect(first == same)
    #expect(first.streamKey != fresh.streamKey)
    #expect(first.noncePrefix != fresh.noncePrefix)
}

@Test func secureEnvelopeRoundTripWrongKeyAndTamperRejection() throws {
    let key = Data(repeating: 0x44, count: PairingProtocol.keyLength)
    let sample = gazeSample()
    let envelope = try SecureGazeEnvelope.seal(sample, pairID: fixedPairID, sessionKey: key, noncePrefix: Data([1, 2, 3, 4]))
    let opened = try envelope.openData(sessionKey: key)
    let expectedPayload = try GazeDatagramCodec.encode(sample)
    #expect(opened == expectedPayload)

    #expect(throws: SecureGazeEnvelopeError.authenticationFailed) {
        try envelope.open(sessionKey: Data(repeating: 0x45, count: PairingProtocol.keyLength))
    }
    var tamperedCiphertext = envelope.ciphertext
    tamperedCiphertext = Data([0x01]) + tamperedCiphertext.dropFirst()
    let tampered = try SecureGazeEnvelope(
        pairID: envelope.pairID,
        sessionID: envelope.sessionID,
        sequence: envelope.sequence,
        noncePrefix: envelope.noncePrefix,
        ciphertext: tamperedCiphertext,
        authenticationTag: envelope.authenticationTag
    )
    #expect(throws: SecureGazeEnvelopeError.authenticationFailed) {
        try tampered.open(sessionKey: key)
    }
}

@Test func secureReceiverRejectsReplayAndOutOfOrderBeforePayloadDecode() throws {
    let key = Data(repeating: 0x55, count: PairingProtocol.keyLength)
    let prefix = Data([9, 8, 7, 6])
    let first = try SecureGazeEnvelope.seal(gazeSample(sequence: 4), pairID: fixedPairID, sessionKey: key, noncePrefix: prefix)
    let second = try SecureGazeEnvelope.seal(gazeSample(sequence: 6), pairID: fixedPairID, sessionKey: key, noncePrefix: prefix)
    let older = try SecureGazeEnvelope.seal(gazeSample(sequence: 5), pairID: fixedPairID, sessionKey: key, noncePrefix: prefix)
    var receiver = try SecureGazeEnvelopeReceiver(pairID: fixedPairID, sessionID: fixedSessionID, sessionKey: key, noncePrefix: prefix)

    #expect(try receiver.open(first) == gazeSample(sequence: 4))
    #expect(throws: SecureGazeEnvelopeError.replayOrOutOfOrder(lastAccepted: 4, received: 4)) {
        try receiver.open(first)
    }
    #expect(try receiver.open(second) == gazeSample(sequence: 6))
    #expect(throws: SecureGazeEnvelopeError.replayOrOutOfOrder(lastAccepted: 6, received: 5)) {
        try receiver.open(older)
    }
}
