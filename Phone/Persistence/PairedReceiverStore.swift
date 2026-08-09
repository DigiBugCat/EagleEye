import Foundation
import GazeCore

public struct PhoneDeviceIdentity: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let displayName: String

    public init(deviceID: UUID, displayName: String) throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard deviceID != zero else { throw PhoneDeviceIdentityStoreError.invalidIdentity }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneDeviceIdentityStoreError.invalidDisplayName
        }
        self.deviceID = deviceID
        self.displayName = displayName
    }
}

public protocol PhoneDeviceIdentityStore: AnyObject {
    func load() throws -> PhoneDeviceIdentity?
    func save(_ identity: PhoneDeviceIdentity) throws
    func loadOrCreate(displayName: String) throws -> PhoneDeviceIdentity
}

public extension PhoneDeviceIdentityStore {
    func loadOrCreate(displayName: String) throws -> PhoneDeviceIdentity {
        if let existing = try load() { return existing }
        let identity = try PhoneDeviceIdentity(deviceID: UUID(), displayName: displayName)
        try save(identity)
        return identity
    }
}

public enum PhoneDeviceIdentityStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidDisplayName
    case corruptData
    case encodingFailed
    #if canImport(Security)
    case status(OSStatus)
    #endif
}

#if canImport(Security)
import Security

/// Stable phone identity stored separately from paired receiver records.
public final class KeychainPhoneDeviceIdentityStore: PhoneDeviceIdentityStore, @unchecked Sendable {
    public static let defaultService = "com.aviary.eaglegaze.phone.identity"
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = KeychainPhoneDeviceIdentityStore.defaultService,
        account: String = "device",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> PhoneDeviceIdentity? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PhoneDeviceIdentityStoreError.status(status)
        }
        do { return try JSONDecoder().decode(PhoneDeviceIdentity.self, from: data) }
        catch { throw PhoneDeviceIdentityStoreError.corruptData }
    }

    public func save(_ identity: PhoneDeviceIdentity) throws {
        let data: Data
        do { data = try JSONEncoder().encode(identity) }
        catch { throw PhoneDeviceIdentityStoreError.encodingFailed }
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PhoneDeviceIdentityStoreError.status(updateStatus)
        }
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PhoneDeviceIdentityStoreError.status(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// Keychain-backed storage for phone pairing records. The entire catalog is
/// one generic-password item so revocation can atomically replace the list.
public final class KeychainPairedReceiverStore: PairedReceiverStore, @unchecked Sendable {
    public static let defaultService = "com.aviary.eaglegaze.phone.paired-receivers"

    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = KeychainPairedReceiverStore.defaultService,
        account: String = "catalog",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> [PairedReceiver] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainPairedReceiverStoreError.status(status)
        }
        do {
            return try JSONDecoder().decode([PairedReceiver].self, from: data)
        } catch {
            throw KeychainPairedReceiverStoreError.corruptData
        }
    }

    public func save(_ receiver: PairedReceiver) throws {
        var values = try load()
        values.removeAll { $0.pairID == receiver.pairID }
        values.append(receiver)
        try replace(values)
    }

    public func remove(pairID: UUID) throws {
        let values = try load().filter { $0.pairID != pairID }
        try replace(values)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPairedReceiverStoreError.status(status)
        }
    }

    private func replace(_ values: [PairedReceiver]) throws {
        guard !values.isEmpty else { return try clear() }
        let data: Data
        do {
            data = try JSONEncoder().encode(values)
        } catch {
            throw KeychainPairedReceiverStoreError.encodingFailed
        }

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainPairedReceiverStoreError.status(updateStatus)
        }

        var add = baseQuery()
        add[kSecValueData as String] = data
        // Device-only accessibility prevents iCloud restore/migration from
        // silently carrying durable pairing material to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainPairedReceiverStoreError.status(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public enum KeychainPairedReceiverStoreError: Error, Equatable, Sendable {
    case status(OSStatus)
    case corruptData
    case encodingFailed
}
#endif

/// Lock-protected fake for unit tests, previews, and simulator flows where a
/// real Keychain is undesirable.
public final class InMemoryPairedReceiverStore: PairedReceiverStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PairedReceiver]

    public init(_ initial: [PairedReceiver] = []) {
        values = initial
    }

    public func load() throws -> [PairedReceiver] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    public func save(_ receiver: PairedReceiver) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeAll { $0.pairID == receiver.pairID }
        values.append(receiver)
    }

    public func remove(pairID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeAll { $0.pairID == pairID }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

public typealias FakePairedReceiverStore = InMemoryPairedReceiverStore

public final class InMemoryPhoneDeviceIdentityStore: PhoneDeviceIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: PhoneDeviceIdentity?

    public init(identity: PhoneDeviceIdentity? = nil) { self.identity = identity }

    public func load() throws -> PhoneDeviceIdentity? {
        lock.lock(); defer { lock.unlock() }
        return identity
    }

    public func save(_ identity: PhoneDeviceIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        self.identity = identity
    }
}

public typealias FakePhoneDeviceIdentityStore = InMemoryPhoneDeviceIdentityStore
