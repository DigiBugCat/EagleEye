import XCTest
import GazeCore
@testable import EagleGazePhone

@MainActor
final class TransportTests: XCTestCase {
    func testCanonicalFrameIsAuthenticatedAndBoundToSession() throws {
        let sessionID = UUID()
        let material = try GazeSessionMaterial(
            pairID: UUID(),
            sessionID: sessionID,
            sessionKey: Data(repeating: 0x44, count: PairingProtocol.keyLength),
            noncePrefix: Data(repeating: 0x09, count: PairingProtocol.noncePrefixLength)
        )
        let frame = CanonicalGazeFrame(
            sourceID: "phone",
            sourceSessionID: sessionID,
            sequence: 7,
            captureUptime: 12.5,
            validity: .valid,
            confidence: 0.9,
            point: Point2D(x: 0.4, y: 0.6),
            coordinateSpace: .source,
            blink: .open,
            blinkConfidence: 0.8
        )

        let encoded = try AuthenticatedGazeCodec().encode(frame, session: material)
        let envelope = try SecureGazeEnvelope.decode(encoded)
        XCTAssertEqual(envelope.pairID, material.pairID)
        XCTAssertEqual(envelope.sessionID, sessionID)
        XCTAssertEqual(envelope.sequence, 7)
        let payload = try envelope.openData(sessionKey: material.sessionKey)
        XCTAssertEqual(try JSONDecoder().decode(CanonicalGazeFrame.self, from: payload), frame)
    }

    func testSelectionUsesExplicitReceiverAndLatestOnlyQueue() async throws {
        let browser = InMemoryGazeReceiverBrowser()
        let factory = InMemoryGazeDatagramConnectionFactory()
        let coordinator = GazeTransportCoordinator(browser: browser, factory: factory)
        let first = DiscoveredGazeReceiver(
            id: GazeReceiverID(rawValue: "first"),
            displayName: "First",
            endpoint: .host(name: "first.local", port: 1),
            receiverFingerprint: "sha256:first"
        )
        let second = DiscoveredGazeReceiver(
            id: GazeReceiverID(rawValue: "second"),
            displayName: "Second",
            endpoint: .host(name: "second.local", port: 2),
            receiverFingerprint: "sha256:second"
        )
        coordinator.start()
        browser.emit([first, second])
        await Task.yield()
        await Task.yield()

        let sessionID = UUID()
        let material = try GazeSessionMaterial(
            pairID: UUID(),
            sessionID: sessionID,
            sessionKey: Data(repeating: 0x77, count: PairingProtocol.keyLength),
            noncePrefix: Data(repeating: 0x03, count: PairingProtocol.noncePrefixLength)
        )
        try coordinator.selectReceiver(
            id: second.id,
            receiverFingerprint: second.receiverFingerprint,
            session: material
        )
        XCTAssertEqual(factory.endpoints, [second.endpoint])
        guard let connection = factory.connections.first else {
            return XCTFail("expected a connection for the explicitly selected receiver")
        }
        connection.emit(.ready)
        await Task.yield()

        let makeFrame: (UInt64) -> CanonicalGazeFrame = { sequence in
            CanonicalGazeFrame(
                sourceID: "phone",
                sourceSessionID: sessionID,
                sequence: sequence,
                captureUptime: Double(sequence),
                validity: .valid,
                confidence: 1,
                point: Point2D(x: 0.5, y: 0.5),
                coordinateSpace: .source
            )
        }
        coordinator.sendLatest(makeFrame(1))
        coordinator.sendLatest(makeFrame(2))
        XCTAssertEqual(connection.sent.count, 1)
        connection.completeNext()
        await Task.yield()
        XCTAssertEqual(connection.sent.count, 2)
        let secondEnvelope = try SecureGazeEnvelope.decode(connection.sent[1])
        XCTAssertEqual(secondEnvelope.sequence, 2)
    }

    func testSelectionRejectsFingerprintThatDoesNotMatchDiscovery() async throws {
        let browser = InMemoryGazeReceiverBrowser()
        let factory = InMemoryGazeDatagramConnectionFactory()
        let coordinator = GazeTransportCoordinator(browser: browser, factory: factory)
        let receiver = DiscoveredGazeReceiver(
            id: GazeReceiverID(rawValue: "stable-endpoint-id"),
            displayName: "Receiver",
            endpoint: .host(name: "receiver.local", port: 42),
            receiverFingerprint: "sha256:paired"
        )
        coordinator.start()
        browser.emit([receiver])
        await Task.yield()
        await Task.yield()
        let session = try GazeSessionMaterial(
            pairID: UUID(),
            sessionID: UUID(),
            sessionKey: Data(repeating: 0x11, count: PairingProtocol.keyLength),
            noncePrefix: Data(repeating: 0x22, count: PairingProtocol.noncePrefixLength)
        )
        XCTAssertThrowsError(
            try coordinator.selectReceiver(
                id: receiver.id,
                receiverFingerprint: "sha256:other",
                session: session
            )
        ) { error in
            XCTAssertEqual(error as? GazeTransportError, .receiverIdentityMismatch)
        }
        XCTAssertTrue(factory.connections.isEmpty)
    }
}
