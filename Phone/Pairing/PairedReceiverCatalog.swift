import Foundation
import GazeCore

/// Phone-side durable peer. Pairing material is retained as part of the
/// record, while calibration remains keyed and stored separately by Mac.
public struct PairedReceiver: Codable, Equatable, Identifiable, Sendable {
    public let record: PairedDeviceRecord
    /// Bonjour service identity returned by the Mac during approval. It is
    /// persisted with the record so reconnect never depends on result order.
    public let serviceIdentity: String

    public init(record: PairedDeviceRecord, serviceIdentity: String = "eagle-gaze-pair") {
        self.record = record
        self.serviceIdentity = serviceIdentity
    }

    public init(
        pairID: UUID,
        deviceID: UUID,
        displayName: String,
        receiverFingerprint: String,
        pairingKey: Data,
        createdAt: Date,
        lastConnectedAt: Date? = nil,
        serviceIdentity: String = "eagle-gaze-pair"
    ) throws {
        self.record = try PairedDeviceRecord(
            pairID: pairID,
            deviceID: deviceID,
            displayName: displayName,
            receiverFingerprint: receiverFingerprint,
            pairingKey: pairingKey,
            createdAt: createdAt,
            lastConnectedAt: lastConnectedAt
        )
        guard !serviceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PairedDeviceRecordError.invalidFingerprint
        }
        self.serviceIdentity = serviceIdentity
    }

    private enum CodingKeys: String, CodingKey { case record, serviceIdentity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decode(PairedDeviceRecord.self, forKey: .record)
        serviceIdentity = try container.decodeIfPresent(String.self, forKey: .serviceIdentity)
            ?? "eagle-gaze-pair"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(record, forKey: .record)
        try container.encode(serviceIdentity, forKey: .serviceIdentity)
    }

    public var id: UUID { record.pairID }
    public var pairID: UUID { record.pairID }
    public var deviceID: UUID { record.deviceID }
    public var displayName: String { record.displayName }
    public var receiverFingerprint: String { record.receiverFingerprint }
    public var pairingKey: Data { record.pairingKey }
    public var createdAt: Date { record.createdAt }
    public var lastConnectedAt: Date? { record.lastConnectedAt }
}

public protocol PairedReceiverStore: AnyObject {
    func load() throws -> [PairedReceiver]
    func save(_ receiver: PairedReceiver) throws
    func remove(pairID: UUID) throws
}

public extension PairedReceiverStore {
    func allReceivers() throws -> [PairedReceiver] { try load() }
    func delete(pairID: UUID) throws { try remove(pairID: pairID) }
    func save(_ record: PairedDeviceRecord) throws { try save(PairedReceiver(record: record)) }
}

public enum PairedReceiverSelection: Equatable, Sendable {
    case none
    case selected(PairedReceiver)
    case requiresChoice([PairedReceiver])
}

public enum PairedReceiverSelectionError: Error, Equatable, Sendable {
    case receiverNotFound(UUID)
}

/// Applies the explicit multi-Mac selection rule used by the phone.
public final class PairedReceiverCatalog: @unchecked Sendable {
    private let store: PairedReceiverStore
    private var selectedPairID: UUID?
    public var onRevoked: (@Sendable (UUID) -> Void)?

    public init(store: PairedReceiverStore) {
        self.store = store
    }

    public func receivers() throws -> [PairedReceiver] {
        try store.load().sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func selection(preferredPairID: UUID? = nil) throws -> PairedReceiverSelection {
        let available = try receivers()
        guard !available.isEmpty else { return .none }
        let requested = preferredPairID ?? selectedPairID
        if let requested {
            guard let receiver = available.first(where: { $0.pairID == requested }) else {
                throw PairedReceiverSelectionError.receiverNotFound(requested)
            }
            selectedPairID = requested
            return .selected(receiver)
        }
        guard available.count > 1 else {
            selectedPairID = available[0].pairID
            return .selected(available[0])
        }
        return .requiresChoice(available)
    }

    public func select(pairID: UUID) throws -> PairedReceiver {
        guard case let .selected(receiver) = try selection(preferredPairID: pairID) else {
            throw PairedReceiverSelectionError.receiverNotFound(pairID)
        }
        return receiver
    }

    public func revoke(pairID: UUID) throws {
        try store.remove(pairID: pairID)
        if selectedPairID == pairID { selectedPairID = nil }
        onRevoked?(pairID)
    }

    public func clearSelection() { selectedPairID = nil }
}

public typealias PairedMac = PairedReceiver
public typealias PairedMacCatalog = PairedReceiverCatalog
