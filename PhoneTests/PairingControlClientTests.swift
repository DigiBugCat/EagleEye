import CryptoKit
import Foundation
import GazeCore
import Testing
@testable import EagleGazePhone

@Test func pairingClientErrorsHaveActionableDescriptions() {
    #expect(PairingControlClientError.timeout.localizedDescription == "The Mac did not respond in time.")
    #expect(PairingControlClientError.identityMismatch.localizedDescription.contains("no longer matches"))
    #expect(PairingControlClientError.noMatchingReceiver.localizedDescription.contains("could not be authenticated"))
}

@Test @MainActor func nearbyPairingDiscoversOfferAndAuthenticatesApprovalBeforePersisting() async throws {
    let receiverKey = P256EphemeralKeyPair()
    let initiatorKey = P256EphemeralKeyPair()
    let testNow = Date()
    let offer = try PairingOffer(
        offerID: UUID(),
        receiverFingerprint: "sha256:mac",
        ephemeralPublicKey: receiverKey.publicKey,
        oneTimeSecret: Data(repeating: 7, count: 32),
        serviceIdentity: "mac-identity",
        expiresAt: testNow.addingTimeInterval(500)
    )
    let identity = try PhoneDeviceIdentity(deviceID: UUID(), displayName: "iPhone")
    let identityStore = InMemoryPhoneDeviceIdentityStore(identity: identity)
    let receiverStore = InMemoryPairedReceiverStore()
    let candidate = PairingControlCandidate(id: "mac", displayName: "Andrew's Mac")
    let channel = InMemoryPairingControlChannel()
    let transport = InMemoryPairingControlTransport(candidates: [candidate], channels: [candidate.id: channel])

    channel.onSend = { frame in
        var decoder = PairingWireFrameDecoder()
        guard let payload = try? decoder.append(frame).first,
              let message = try? PairingWireProtocol.decode(PairingControlMessage.self, payload: payload) else {
            return
        }
        if case let .nearbyOfferRequest(request) = message {
            if let response = try? NearbyPairingOfferResponse(requestID: request.requestID, offer: offer),
               let responseFrame = try? PairingWireProtocol.encode(
                   PairingControlMessage.nearbyOfferResponse(response)
               ) {
                channel.enqueueRaw(responseFrame)
            }
            return
        }
        guard case let .pairingRequest(request) = message,
              let transcript = try? PairingTranscript(
                offerID: offer.offerID,
                receiverFingerprint: offer.receiverFingerprint,
                serviceIdentity: offer.serviceIdentity,
                receiverEphemeralPublicKey: offer.ephemeralPublicKey,
                initiatorEphemeralPublicKey: request.initiatorEphemeralPublicKey,
                oneTimeSecret: offer.oneTimeSecret
              ),
              let material = try? PairingKeyAgreement.derivePairingMaterial(
                localKeyPair: receiverKey,
                peerPublicKey: request.initiatorEphemeralPublicKey,
                transcript: transcript
              ),
              let response = try? PairingMacResponse.approved(
                offerID: offer.offerID,
                pairID: UUID(),
                deviceID: UUID(),
                displayName: "Mac",
                receiverFingerprint: offer.receiverFingerprint,
                serviceIdentity: offer.serviceIdentity,
                createdAt: Date(timeIntervalSinceReferenceDate: 50),
                verificationCode: material.verificationCode,
                transcriptMAC: material.transcriptMAC,
                pairingKey: material.pairingKey
              ) else { return }
        if let pending = try? PairingMacResponse.pending(
            offerID: offer.offerID,
            verificationCode: material.verificationCode
        ),
           let pendingFrame = try? PairingWireProtocol.encode(PairingControlMessage.macResponse(pending)),
           let approvedFrame = try? PairingWireProtocol.encode(PairingControlMessage.macResponse(response)) {
            var coalesced = pendingFrame
            coalesced.append(approvedFrame)
            channel.enqueueRaw(coalesced)
        }
    }

    let client = PairingControlClient(
        identityStore: identityStore,
        receiverStore: receiverStore,
        transport: transport,
        clock: { testNow },
        keyPairFactory: { initiatorKey },
        responseTimeout: .seconds(1)
    )
    var presentedCode: String?
    let discovered = try await client.discoverNearbyMacs()
    #expect(discovered == [candidate])
    let paired = try await client.pair(
        candidate: candidate,
        displayName: "iPhone",
        onVerificationCode: { presentedCode = $0 }
    )
    #expect(presentedCode?.count == 6)
    #expect(paired.serviceIdentity == offer.serviceIdentity)
    #expect(try receiverStore.load().count == 1)
}

@Test func pairingClientDoesNotUseBonjourResultOrderForIdentityBinding() async throws {
    let receiverKey = P256EphemeralKeyPair()
    let wrongKey = P256EphemeralKeyPair()
    let initiatorKey = P256EphemeralKeyPair()
    let offer = try PairingOffer(
        offerID: UUID(), receiverFingerprint: "sha256:mac",
        ephemeralPublicKey: receiverKey.publicKey,
        oneTimeSecret: Data(repeating: 9, count: 32), serviceIdentity: "mac-identity",
        expiresAt: Date(timeIntervalSinceReferenceDate: 500)
    )
    let identityStore = InMemoryPhoneDeviceIdentityStore(
        identity: try PhoneDeviceIdentity(deviceID: UUID(), displayName: "iPhone")
    )
    let store = InMemoryPairedReceiverStore()
    let wrong = InMemoryPairingControlChannel()
    let correct = InMemoryPairingControlChannel()

    @Sendable func respond(
        _ frame: Data,
        on channel: InMemoryPairingControlChannel,
        receiverKey: P256EphemeralKeyPair,
        fragmented: Bool = false
    ) {
        var decoder = PairingWireFrameDecoder()
        guard let payload = try? decoder.append(frame).first,
              let message = try? PairingWireProtocol.decode(PairingControlMessage.self, payload: payload),
              case let .pairingRequest(request) = message,
              let transcript = try? PairingTranscript(
                offerID: offer.offerID, receiverFingerprint: offer.receiverFingerprint,
                serviceIdentity: offer.serviceIdentity, receiverEphemeralPublicKey: offer.ephemeralPublicKey,
                initiatorEphemeralPublicKey: request.initiatorEphemeralPublicKey,
                oneTimeSecret: offer.oneTimeSecret
              ),
              let material = try? PairingKeyAgreement.derivePairingMaterial(
                localKeyPair: receiverKey, peerPublicKey: request.initiatorEphemeralPublicKey,
                transcript: transcript
              ),
              let response = try? PairingMacResponse.approved(
                offerID: offer.offerID, pairID: UUID(), deviceID: UUID(), displayName: "Mac",
                receiverFingerprint: offer.receiverFingerprint, serviceIdentity: offer.serviceIdentity,
                createdAt: Date(timeIntervalSinceReferenceDate: 50),
                verificationCode: material.verificationCode, transcriptMAC: material.transcriptMAC,
                pairingKey: material.pairingKey
              ) else { return }
        guard let encoded = try? PairingWireProtocol.encode(PairingControlMessage.macResponse(response)) else { return }
        if fragmented {
            channel.enqueueRaw(Data(encoded.prefix(2)))
            channel.enqueueRaw(Data(encoded.dropFirst(2)))
        } else {
            channel.enqueueRaw(encoded)
        }
    }
    wrong.onSend = { frame in respond(frame, on: wrong, receiverKey: wrongKey) }
    correct.onSend = { frame in respond(frame, on: correct, receiverKey: receiverKey, fragmented: true) }

    let first = PairingControlCandidate(id: "a-collision", displayName: "Mac")
    let second = PairingControlCandidate(id: "z-collision", displayName: "Mac")
    let transport = InMemoryPairingControlTransport(
        candidates: [second, first], channels: [first.id: wrong, second.id: correct]
    )
    let client = PairingControlClient(
        identityStore: identityStore, receiverStore: store, transport: transport,
        clock: { Date(timeIntervalSinceReferenceDate: 100) },
        keyPairFactory: { initiatorKey }, responseTimeout: .seconds(1)
    )
    let paired = try await client.pair(offer: offer, displayName: "iPhone")
    #expect(paired.serviceIdentity == offer.serviceIdentity)
    #expect(try store.load().count == 1)
}
