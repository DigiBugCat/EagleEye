import CryptoKit
import Foundation
import Testing
@testable import EagleGazePhone
import GazeCore

private func receiver(_ name: String) throws -> PairedReceiver {
    try PairedReceiver(
        pairID: UUID(),
        deviceID: UUID(),
        displayName: name,
        receiverFingerprint: "sha256:\(name)",
        pairingKey: Data(repeating: 0x11, count: PairingProtocol.keyLength),
        createdAt: Date(timeIntervalSinceReferenceDate: 10)
    )
}

@Test func parserValidatesExpiryAndPublicKey() throws {
    let key = P256EphemeralKeyPair().publicKey
    let offer = try PairingOffer(
        offerID: UUID(),
        receiverFingerprint: "sha256:mac",
        ephemeralPublicKey: key,
        oneTimeSecret: Data(repeating: 0x22, count: 32),
        serviceIdentity: "eagle-gaze-mac",
        expiresAt: Date(timeIntervalSinceReferenceDate: 100)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = String(decoding: try encoder.encode(offer), as: UTF8.self)
    let parsed = try PairingOfferParser.parse(payload, now: Date(timeIntervalSinceReferenceDate: 99))
    #expect(parsed == offer)
    #expect(throws: PairingQRPayloadError.invalidOffer(.expired)) {
        try PairingOfferParser.parse(payload, now: Date(timeIntervalSinceReferenceDate: 100))
    }
}

@Test func catalogRequiresChoiceAndRevocationRemovesReceiver() throws {
    let first = try receiver("Mac A")
    let second = try receiver("Mac B")
    let store = InMemoryPairedReceiverStore([first, second])
    let catalog = PairedReceiverCatalog(store: store)
    guard case let .requiresChoice(choices) = try catalog.selection() else {
        Issue.record("two receivers must require explicit selection")
        return
    }
    #expect(choices.count == 2)
    #expect(try catalog.select(pairID: second.pairID) == second)
    try catalog.revoke(pairID: second.pairID)
    #expect(try store.load() == [first])
}

@Test @MainActor func scannerCoordinatorPausesAndResumesARKit() async throws {
    let scanner = InMemoryQRScannerBoundary()
    var pauses = 0
    var resumes = 0
    let coordinator = QRScannerCoordinator(
        scanner: scanner,
        pauseARKit: { pauses += 1 },
        resumeARKit: { resumes += 1 }
    )
    try coordinator.start()
    #expect(coordinator.isScanning)
    #expect(pauses == 1)
    #expect(throws: QRScannerError.alreadyRunning) { try coordinator.start() }
    scanner.emit("payload")
    // The scanner callback may originate off-main and deliberately hops to
    // MainActor before mutating presentation state.
    await Task.yield()
    #expect(!coordinator.isScanning)
    #expect(resumes == 1)
}
