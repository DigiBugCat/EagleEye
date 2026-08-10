import Foundation
import GazeCore

/// The Mac persistence boundary for durable pairing records.
///
/// Implementations store only `PairedDeviceRecord` values.  Gaze samples,
/// ARKit transforms, and reconnect session material are deliberately outside
/// this protocol and must remain transient.
public protocol PairedDeviceStore: Sendable {
    func list() throws -> [PairedDeviceRecord]
    func record(pairID: UUID) throws -> PairedDeviceRecord?
    func save(_ record: PairedDeviceRecord) throws
    func delete(pairID: UUID) throws
}

public enum PairedDeviceStoreError: Error, Equatable, Sendable {
    case notFound
    case invalidRecord
    case persistenceFailed
}

public extension PairedDeviceStore {
    /// Returns a record by pair identifier without adding another persistence
    /// primitive to platform stores.
    func record(pairID: UUID) throws -> PairedDeviceRecord? {
        try list().first { $0.pairID == pairID }
    }

    func records() throws -> [PairedDeviceRecord] {
        try list()
    }

    func remove(pairID: UUID) throws {
        try delete(pairID: pairID)
    }
}

/// Deterministic, process-local store for unit tests and previews.
public final class InMemoryPairedDeviceStore: PairedDeviceStore, @unchecked Sendable {
    private var values: [UUID: PairedDeviceRecord]
    private let lock = NSLock()

    public init(records: [PairedDeviceRecord] = []) {
        values = Dictionary(uniqueKeysWithValues: records.map { ($0.pairID, $0) })
    }

    public func list() throws -> [PairedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return values.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.pairID.uuidString < rhs.pairID.uuidString
        }
    }

    public func save(_ record: PairedDeviceRecord) throws {
        lock.lock()
        values[record.pairID] = record
        lock.unlock()
    }

    public func delete(pairID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard values.removeValue(forKey: pairID) != nil else {
            throw PairedDeviceStoreError.notFound
        }
    }

    public func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}

public typealias FakePairedDeviceStore = InMemoryPairedDeviceStore
