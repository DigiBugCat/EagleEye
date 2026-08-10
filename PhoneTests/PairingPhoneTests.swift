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
