import Foundation
import GazeCore
import Security

/// Keychain-backed Mac store for paired-device metadata and pairing keys.
///
/// Every item is a generic password with `WhenUnlockedThisDeviceOnly`
/// accessibility.  That prevents migration through Keychain backup and keeps
/// pairing material unavailable while the Mac is locked.
public final class KeychainPairedDeviceStore: PairedDeviceStore, @unchecked Sendable {
    public static let defaultService = "com.aviary.EagleGaze.paired-device"

    private let service: String
    private let lock = NSLock()

    public init(service: String = KeychainPairedDeviceStore.defaultService) {
        self.service = service
    }

    public func list() throws -> [PairedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainPairedDeviceStore.error(status) }

        let payloads: [Data]
        if let data = result as? Data {
            payloads = [data]
        } else if let data = result as? [Data] {
            payloads = data
        } else {
            throw PairedDeviceStoreError.persistenceFailed
        }

        do {
            let decoder = JSONDecoder()
            return try payloads.map { try decoder.decode(PairedDeviceRecord.self, from: $0) }
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.pairID.uuidString < rhs.pairID.uuidString
                }
        } catch {
            throw PairedDeviceStoreError.invalidRecord
        }
    }

    public func save(_ record: PairedDeviceRecord) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(record)
        } catch {
            throw PairedDeviceStoreError.invalidRecord
        }

        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecAttrAccount as String] = record.pairID.uuidString
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            status = SecItemUpdate(queryWithoutValue(query) as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainPairedDeviceStore.error(status) }
    }

    public func delete(pairID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecAttrAccount as String] = pairID.uuidString
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPairedDeviceStore.error(status)
        }
    }

    /// Removes all records belonging to this application service.  This is
    /// intended for an explicit "forget all devices" action, not app startup.
    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPairedDeviceStore.error(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private func queryWithoutValue(_ query: [String: Any]) -> [String: Any] {
        var copy = query
        copy.removeValue(forKey: kSecValueData as String)
        return copy
    }

    private static func error(_ status: OSStatus) -> Error {
        // Keep the public error stable while retaining the Security status for
        // diagnostics in the localized description.
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Keychain operation failed (status \(status))."]
        )
    }
}
